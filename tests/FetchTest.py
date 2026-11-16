"""Drives Transcribe.fetch with fake downloads for TestModelDownload (#16).

Usage: python -I FetchTest.py <repository root> <empty temp folder>
"""
import os
import re
import sys
import time

root, tmp = sys.argv[1], sys.argv[2]
sys.path.insert(0, root)
import Transcribe as T

status = os.path.join(tmp, "transcribe.ini")
folder = os.path.join(tmp, "models--test")
seen = []


def grow():
    os.makedirs(folder, exist_ok=True)
    for i in range(4):
        with open(os.path.join(folder, "model.incomplete"), "ab") as f:
            f.write(b"x" * 1000000)
        time.sleep(1.2)
        with open(status, encoding="utf-16") as f:
            seen.append(re.search("Detail=(.*)", f.read()).group(1))


print("grew", T.fetch(status, "the test model", folder, 4000000, grow, stall=5), "|".join(seen))
start = time.time()
print("stuck", T.fetch(status, "the stuck model", folder, 8000000, lambda: time.sleep(60), stall=2), round(time.time() - start))


def fail():
    raise OSError("no network")


try:
    T.fetch(status, "the missing model", folder, 1, fail)
    print("failed none")
except OSError as e:
    print("failed", e)
