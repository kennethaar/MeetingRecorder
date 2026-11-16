"""Drives Transcribe's model downloads with fake downloads for TestModelDownload (#16).

Usage: python -I FetchTest.py <repository root> <empty temp folder>
Prints one line per case; RunTests.ahk checks them.
"""
import os
import re
import sys
import time

root, tmp = sys.argv[1], sys.argv[2]
sys.path.insert(0, root)
import Transcribe as T

status = os.path.join(tmp, "transcribe.ini")


def read(key):
    with open(status, encoding="utf-16") as f:
        found = re.search("^%s=(.*)$" % key, f.read(), re.M)
    return found.group(1) if found else "(none)"


def grower(folder, parts, pause=1.2, seen=None):
    def grow():
        os.makedirs(folder, exist_ok=True)
        for i in range(parts):
            with open(os.path.join(folder, "model.incomplete"), "ab") as f:
                f.write(b"x" * 1000000)
            time.sleep(pause)
            if seen is not None:
                seen.append(read("Detail") + " / " + read("Download"))
    return grow


print("left", " | ".join(T.time_left_text(s) for s in (None, 30, 720, 6000)))

# The speech model is needed before anything else, so this waits, and says what it downloads.
seen = []
print("grew", T.fetch(status, "the speech model", os.path.join(tmp, "a"), 4000000, grower(os.path.join(tmp, "a"), 4, seen=seen), stall=5), " || ".join(seen))

start = time.time()
print("stuck", T.fetch(status, "the stuck model", os.path.join(tmp, "a"), 8000000, lambda: time.sleep(60), stall=2), round(time.time() - start))


def fail():
    raise OSError("no network")


try:
    T.fetch(status, "the missing model", os.path.join(tmp, "a"), 1, fail)
    print("failed none")
except OSError as e:
    print("failed", e)

# The word-timing model downloads while the transcript is written: the steps go on, and the
# download shows beside them until it is done. The transcriber waits for it before it ends.
T.start_background(T.Download("the word-timing model", os.path.join(tmp, "b"), 3000000, grower(os.path.join(tmp, "b"), 3, pause=1.5)))
time.sleep(1.0)
T.set_state(status, "Working", 40, "Writing down what others said", 3)
print("during", read("Detail"), "/", read("Download"))
time.sleep(1.5)
print("ticked", read("Download"))
start = time.time()
T.finish_background()
print("finished", round(time.time() - start))
T.set_state(status, "Done", 100, "Transcript ready", 4)
print("after", read("Download") or "(empty)")
