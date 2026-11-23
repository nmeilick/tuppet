"""Boxes in the daemon, driven over the protocol for test/over.sh: python3 over_check.py SOCKET TUPPET"""
import json
import socket
import subprocess
import sys
import time

path, tuppet = sys.argv[1], sys.argv[2]


def check(ok, what):
    if not ok:
        sys.exit("FAIL: " + what)


def connect():
    s = socket.socket(socket.AF_UNIX)
    # A broken daemon fails the check instead of hanging it.
    s.settimeout(5)
    s.connect(path)
    return s


def ask(req):
    s = connect()
    s.sendall(json.dumps(req).encode() + b"\n")
    with s, s.makefile("rb") as f:
        return json.loads(f.readline())


class Stream:
    """An attach or events stream, open until closed."""

    def __init__(self, req):
        self.s = connect()
        self.s.sendall(json.dumps(req).encode() + b"\n")
        self.f = self.s.makefile("rb")
        self.reply = self.next()

    def next(self):
        try:
            line = self.f.readline()
        except (socket.timeout, OSError):
            return None
        return json.loads(line) if line else None

    def until(self, pred):
        while (fr := self.next()) is not None:
            if pred(fr):
                return fr
        return None

    def close(self):
        self.f.close()
        self.s.close()


def run(over=None, name=None, argv=("cat",)):
    req = {"cmd": "run", "argv": list(argv)}
    if name:
        req["name"] = name
    if over is not None:
        req["over"] = over
    return ask(req)


def status(sid):
    sessions = ask({"cmd": "list", "sessions": [str(sid)]})["sessions"]
    return sessions[0] if sessions else None


def poll(what, sid, pred, timeout=5):
    end = time.time() + timeout
    while time.time() < end:
        st = status(sid)
        if st is not None and pred(st):
            return st
        time.sleep(0.02)
    sys.exit("FAIL: %s: %r" % (what, status(sid)))


def refused(reply, code, what):
    check(not reply["ok"] and reply["code"] == code, "%s: %r" % (what, reply))


under = run(name="under")["status"]["id"]
other = run(name="under2")["status"]["id"]
done = run(argv=["true"])["status"]["id"]
poll("a program that ends at once did not end", done, lambda st: st["state"] == "exited")
events = Stream({"cmd": "events", "sessions": [str(under)]})
check(events.until(lambda fr: fr["type"] == "synced") is not None, "the events stream did not sync")

# The box is an ordinary session that knows what it is shown over; the
# session underneath lists it. A title loses its controls.
first = run({"session": "under", "title": "deploy\x1b[1m?‮"})
check(first["ok"], "run with over failed: %r" % first)
box = first["status"]["id"]
over = first["status"]["over"]
check(over == {"id": under, "title": "deploy[1m?", "backdrop": "frozen", "grab": "pause", "shown": False, "held": False,
               "ended_by": None}, "the box's over: %r" % over)
check((first["status"]["cols"], first["status"]["rows"]) == (120, 40), "a box changed run's default size")
check(status(under)["under"] == [box] and status(under)["over"] is None, "the session underneath: %r" % status(under))
check(events.until(lambda fr: fr["type"] == "changed" and "under" in fr["fields"]) is not None,
      "no changed frame named under")
events.close()

refused(run({"session": "nosuch"}), "no_session", "a box over no session")
refused(run({"session": "under*"}), "ambiguous", "a box over several sessions")
refused(run({"session": str(done)}), "ended", "a box over an ended session")
refused(run({"session": str(box)}), "bad_request", "a box over a box")
refused(ask({"cmd": "run", "argv": ["cat"], "if_exists": "keep", "over": {"session": "under"}}), "bad_request",
        "over with if_exists keep")
refused(run({"session": "under", "grab": "never", "backdrop": "live"}), "bad_request", "a backdrop with grab never")
refused(run({"session": "under", "backdrop": None}), "bad_request", "no backdrop with grab pause")
refused(run({"session": "under", "unseen_ms": 0}), "bad_request", "unseen_ms 0")
notice = run({"session": "under", "grab": "never", "backdrop": None})["status"]
check(notice["over"]["backdrop"] is None and notice["over"]["title"] is None, "a notice's over: %r" % notice["over"])

# A preview watches in passing; a viewer shows the box, a writer holds it.
watch = Stream({"cmd": "events"})
check(watch.until(lambda fr: fr["type"] == "synced") is not None, "the events stream did not sync")
preview = Stream({"cmd": "attach", "session": str(box), "mode": "preview"})
check(not status(box)["over"]["shown"], "a preview showed the box")
viewer = Stream({"cmd": "attach", "session": str(box), "mode": "read"})
check(viewer.reply["status"]["over"]["shown"], "the read attach's reply does not show the box shown")
check(not status(box)["over"]["held"], "a viewer held the box")
check(watch.until(lambda fr: fr["type"] == "changed" and fr["id"] == box and "over" in fr["fields"]) is not None,
      "no changed frame named over")
watch.close()
writer = Stream({"cmd": "attach", "session": str(box), "mode": "write"})
check(status(box)["over"]["held"], "a writer did not hold the box")
for stream in (preview, viewer, writer):
    stream.close()

# unseen_ms counts until a writer holds the box; a viewer is not enough,
# but it is for a notice, which takes no keys.
seen_notice = run({"session": "under", "grab": "never", "unseen_ms": 1000})["status"]["id"]
Stream({"cmd": "attach", "session": str(seen_notice)}).close()
unseen = run({"session": "under", "unseen_ms": 1000})["status"]["id"]
viewer = Stream({"cmd": "attach", "session": str(unseen)})
st = poll("unseen_ms did not stop the box", unseen, lambda st: st["state"] != "running")
viewer.close()
check(st["over"]["ended_by"] == "unseen" and st["over"]["shown"] and not st["over"]["held"], "unseen: %r" % st["over"])
check(st["exit"]["stopped"] and st["seen"]["ended"], "the unseen box: exit %r, seen %r" % (st["exit"], st["seen"]))
poll("the ended box stayed under", under, lambda st: unseen not in st["under"])
# Its time ran out before the other box's did.
check(status(seen_notice)["state"] == "running", "unseen_ms stopped a notice that was shown")

# 16 running boxes at most.
boxes = [box, notice["id"], seen_notice]
while len(boxes) < 16:
    reply = run({"session": "under"})
    check(reply["ok"], "box %d failed: %r" % (len(boxes) + 1, reply))
    boxes.append(reply["status"]["id"])
check(status(under)["under"] == sorted(boxes), "under: %r" % status(under)["under"])
refused(run({"session": "under"}), "limit", "a 17th box")
check(run({"session": "under2"})["ok"], "the limit counted another session's boxes")

# The session underneath ends: the daemon stops every box over it.
check(ask({"cmd": "stop", "sessions": [str(under)]})["results"][0]["ok"], "the session underneath did not stop")
for b in boxes:
    st = poll("box %d outlived the session underneath" % b, b, lambda st: st["state"] != "running")
    check(st["over"]["ended_by"] == "under", "box %d ended by %r" % (b, st["over"]["ended_by"]))
    check(st["seen"]["ended"], "the ended box %d needs someone" % b)
poll("the boxes stayed under", under, lambda st: st["under"] == [])

# What became of a box stays with it in the store.
ask({"cmd": "shutdown"})
end = time.time() + 5
while subprocess.run([tuppet, "list"], capture_output=True).returncode != 0 and time.time() < end:
    time.sleep(0.05)
kept = status(box)["over"]
check(kept["held"] and kept["shown"] and kept["ended_by"] == "under" and kept["title"] == "deploy[1m?",
      "the stored box: %r" % kept)
