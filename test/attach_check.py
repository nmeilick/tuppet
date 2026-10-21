"""Attach-stream checks for test/protocol.sh: python3 attach_check.py SOCKET CHECK ARGS..."""
import base64
import json
import socket
import subprocess
import sys
import threading
import time

path = sys.argv[1]


def attach(sid, mode="read", force=False, label=None):
    s = socket.socket(socket.AF_UNIX)
    # A broken daemon fails the check instead of hanging it.
    s.settimeout(5)
    s.connect(path)
    req = {"cmd": "attach", "session": sid, "mode": mode, "force": force}
    if label is not None:
        req["label"] = label
    s.sendall(json.dumps(req).encode() + b"\n")
    return s, s.makefile("rb")


def frame(f):
    try:
        line = f.readline()
    except (socket.timeout, OSError):
        return None
    return json.loads(line) if line else None


def until(f, pred, timeout=3):
    """Read frames until pred(frame) holds; False on EOF or timeout."""
    end = time.time() + timeout
    while time.time() < end:
        fr = frame(f)
        if fr is None:
            return False
        if pred(fr):
            return True
    return False


def output_has(text):
    seen = bytearray()

    def pred(fr):
        if "out" in fr:
            seen.extend(base64.b64decode(fr["out"]))
        return text in seen

    return pred


def resized(cols, rows):
    """A resize frame to this size, whatever its seq."""
    return lambda fr: (fr.get("resize") or {}).get("cols") == cols and fr["resize"].get("rows") == rows


def check(ok, what):
    if not ok:
        sys.exit("FAIL: " + what)


def replay(sid, tuppet):
    """The redraw shows earlier output; later output streams live."""
    _, f = attach(sid)
    check(frame(f)["ok"], "attach reply")
    check(b"one" in base64.b64decode(frame(f)["screen"]), "redraw lacks earlier output")
    subprocess.run([tuppet, "key", sid, "echo two", "<Enter>"], check=True)
    check(until(f, output_has(b"two")), "live output did not reach the viewer")


def writers(sid):
    """One writer; force takes over and shows its cleaned label; read-only
    clients cannot write."""
    _, f1 = attach(sid, "write")
    check(frame(f1)["ok"], "first writer")
    _, f2 = attach(sid, "write")
    refused = frame(f2)
    check(not refused["ok"] and refused["code"] == "busy", "second writer was accepted")
    _, f3 = attach(sid, "write", force=True, label="pts\x1b/9\u202e")
    reply = frame(f3)
    check(reply["ok"], "forced writer refused")
    check(reply["status"]["writer"] == {"label": "pts/9"}, "the writer label was not cleaned: %r" % reply["status"]["writer"])
    check(until(f1, lambda fr: fr.get("writer") == "taken"), "displaced writer was not told")
    r, fr_ = attach(sid)
    frame(fr_)
    frame(fr_)
    r.sendall(b'{"data":"eA=="}\n')
    check(until(fr_, lambda fr: fr.get("error", {}).get("code") == "bad_request"), "read-only write frame was accepted")


def slow(sid, tuppet):
    """A viewer that never reads is dropped; others keep working."""
    slow_sock, _ = attach(sid)
    fast_sock, fast = attach(sid)
    fast_sock.settimeout(None)
    got = []

    def drain():
        while fr := frame(fast):
            got.append(len(fr.get("out", "")))

    threading.Thread(target=drain, daemon=True).start()
    subprocess.run([tuppet, "key", sid, "go", "<Enter>"], check=True)
    # Once the fast viewer has seen more than the queue limit, the slow
    # one has fallen behind by that much too.
    end = time.time() + 20
    while sum(got) < 6 << 20 and time.time() < end:
        time.sleep(0.05)
    slow_sock.settimeout(3)
    closed = False
    try:
        while slow_sock.recv(1 << 20):
            pass
        closed = True
    except socket.timeout:
        pass
    check(closed, "slow viewer was not disconnected")
    check(len(got) > 10, "fast viewer stopped receiving")
    check(subprocess.run([tuppet, "view", sid], capture_output=True).returncode == 0, "view failed")


def pipelined(sid):
    """Frames sent right behind the attach request are not lost."""
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(5)
    s.connect(path)
    s.sendall(json.dumps({"cmd": "attach", "session": sid, "mode": "write", "force": True}).encode()
              + b'\n{"resize":{"cols":61,"rows":17}}\n')
    f = s.makefile("rb")
    check(frame(f)["ok"], "attach reply")
    check(until(f, resized(61, 17)), "pipelined resize was lost")


def stalled(sid):
    """Attach and never read (the caller kills this process)."""
    s, _ = attach(sid)  # kept, so that the connection stays open
    time.sleep(30)


def exits(sid):
    """Viewers get the exit event with the final status, then the end;
    attaching to the ended session gets its screen, exit, and end."""
    _, f = attach(sid)
    ended = lambda fr: "exit" in fr and fr["exit"]["code"] == 4 and fr["status"]["state"] == "exited"
    check(until(f, ended, 5), "no exit event with the final status")
    check(frame(f) == {"end": {"reason": "exited"}}, "no end frame after the exit")
    check(frame(f) is None, "stream stayed open after exit")
    _, f = attach(sid)
    check(frame(f)["status"]["state"] == "exited", "attach reply lacks the ended status")
    check("screen" in frame(f) and ended(frame(f)), "an ended session did not send screen, then exit")
    check(frame(f) == {"end": {"reason": "exited"}} and frame(f) is None, "an ended session's stream did not end")


def detach(sid):
    """A detach ends the stream with an end frame."""
    s, f = attach(sid)
    frame(f)
    frame(f)
    s.sendall(b'{"detach":true}\n')
    check(until(f, lambda fr: fr == {"end": {"reason": "detach"}}), "no end frame after a detach")


def sized(sid):
    """A writer's size from its request applies before the reply and the
    first screen; a resize frame that changes the size brings a fresh
    screen to the writer."""
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(5)
    s.connect(path)
    s.sendall(json.dumps({"cmd": "attach", "session": sid, "mode": "write", "force": True, "cols": 70, "rows": 21}).encode() + b"\n")
    f = s.makefile("rb")
    st = frame(f)["status"]
    check((st["cols"], st["rows"]) == (70, 21), "the attach request's size was not applied first: %r" % ((st["cols"], st["rows"]),))
    check("screen" in frame(f), "no screen after the reply")
    s.sendall(b'{"resize":{"cols":72,"rows":22}}\n')
    got = []
    check(until(f, lambda fr: resized(72, 22)(fr) and not got.append(fr["resize"])), "the writer's resize was lost")
    check(until(f, lambda fr: "screen" in fr), "no fresh screen after the writer's resize")
    # The frame carries the seq of the reflow; the same size again carries
    # none.
    seq = got[0]["seq"]
    check(isinstance(seq, int) and seq > st["seq"], "the resize frame's seq: %r" % got[0])
    s.sendall(b'{"resize":{"cols":72,"rows":22}}\n')
    check(until(f, lambda fr: fr.get("resize") == {"cols": 72, "rows": 22, "seq": None}), "a resize to the same size did not say seq null")
    # A resize request that must find no writer is refused.
    r = socket.socket(socket.AF_UNIX)
    r.connect(path)
    r.sendall(json.dumps({"cmd": "resize", "session": sid, "cols": 80, "rows": 24, "require": {"unattended": True}}).encode() + b"\n")
    refused = json.loads(r.makefile("rb").readline())
    check(refused["code"] == "guard" and refused["guard"] == "unattended" and refused["status"]["cols"] == 72, "an attended resize was not refused: %r" % refused)


def preview(sid, tuppet):
    """A preview counts in status.previews, not in viewers."""
    _, f = attach(sid, "preview")
    check(frame(f)["ok"], "preview attach")
    st = json.loads(subprocess.run([tuppet, "list", "-j", sid], capture_output=True, check=True).stdout)["sessions"][0]
    check((st["previews"], st["viewers"]) == (1, 0), "a preview counted as %r" % ((st["previews"], st["viewers"]),))


def size_of(tuppet, sid):
    out = subprocess.run([tuppet, "list", "-j", sid], capture_output=True, check=True).stdout
    st = json.loads(out)["sessions"][0]
    return (st["cols"], st["rows"])


def restore(sid, tuppet):
    """A writer's size goes when it detaches; one a request set stays."""
    before = size_of(tuppet, sid)
    for explicit in (False, True):
        s, f = attach(sid, "write")
        frame(f)
        s.sendall(b'{"resize":{"cols":61,"rows":17}}\n')
        check(until(f, resized(61, 17)), "the writer's resize was lost")
        if explicit:
            subprocess.run([tuppet, "resize", sid, "70x20"], check=True)
            check(until(f, resized(70, 20)), "the request's resize was lost")
        s.sendall(b'{"detach":true}\n')
        check(until(f, lambda fr: "end" in fr), "no end frame after a detach")
        s.close()
        want = (70, 20) if explicit else before
        end = time.time() + 3
        while size_of(tuppet, sid) != want and time.time() < end:
            time.sleep(0.02)
        check(size_of(tuppet, sid) == want, "after the writer left the size is %r, not %r" % (size_of(tuppet, sid), want))


def hold(sid, tuppet):
    """A writer typing during a batch is held, and its keys come after the
    batch's, in order."""
    s, f = attach(sid, "write")
    frame(f)
    batch = subprocess.Popen([tuppet, "do", sid, "-s", "A", "--sleep", "1s", "--sleep", "1s", "-s", "C"])
    check(until(f, output_has(b"A")), "the batch's first key did not arrive")
    s.sendall(b'{"data":"Qg=="}\n')
    check(until(f, lambda fr: fr.get("hold") is True), "the writer was not told it is held")
    check(until(f, lambda fr: fr.get("hold") is False), "the hold did not end")
    check(batch.wait(5) == 0, "the batch failed")
    waited = subprocess.run([tuppet, "wait", sid, "-m", "ACB", "-t", "3s"], capture_output=True)
    check(waited.returncode == 0, "the keys came out of order: %r" % subprocess.run([tuppet, "view", sid], capture_output=True).stdout)


globals()[sys.argv[2]](*sys.argv[3:])
