"""Attach-stream checks for test/protocol.sh: python3 attach_check.py SOCKET CHECK ARGS..."""
import base64
import json
import socket
import subprocess
import sys
import threading
import time

path = sys.argv[1]


def attach(sid, mode="read", force=False):
    s = socket.socket(socket.AF_UNIX)
    # A broken daemon fails the check instead of hanging it.
    s.settimeout(5)
    s.connect(path)
    s.sendall(json.dumps({"cmd": "attach", "id": sid, "mode": mode, "force": force}).encode() + b"\n")
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
    """One writer; force takes over; read-only clients cannot write."""
    _, f1 = attach(sid, "write")
    check(frame(f1)["ok"], "first writer")
    _, f2 = attach(sid, "write")
    check(not frame(f2)["ok"], "second writer was accepted")
    _, f3 = attach(sid, "write", force=True)
    check(frame(f3)["ok"], "forced writer refused")
    check(until(f1, lambda fr: fr.get("writer") == "taken"), "displaced writer was not told")
    r, fr_ = attach(sid)
    frame(fr_)
    frame(fr_)
    r.sendall(b'{"data":"eA=="}\n')
    check(until(fr_, lambda fr: "error" in fr), "read-only write frame was accepted")


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
    subprocess.run([tuppet, "send", sid, "go\n"], check=True)
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
    s.sendall(json.dumps({"cmd": "attach", "id": sid, "mode": "write", "force": True}).encode()
              + b'\n{"resize":{"cols":61,"rows":17}}\n')
    f = s.makefile("rb")
    check(frame(f)["ok"], "attach reply")
    check(until(f, lambda fr: fr.get("resize") == {"cols": 61, "rows": 17}), "pipelined resize was lost")


def stalled(sid):
    """Attach and never read (the caller kills this process)."""
    attach(sid)
    time.sleep(30)


def exits(sid):
    """Viewers get the exit event, then the stream closes."""
    _, f = attach(sid)
    check(until(f, lambda fr: "exit" in fr and fr["exit"]["code"] == 4, 5), "no exit event")
    check(frame(f) is None, "stream stayed open after exit")


globals()[sys.argv[2]](*sys.argv[3:])
