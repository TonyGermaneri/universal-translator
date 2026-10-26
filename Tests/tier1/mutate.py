#!/usr/bin/env python3
"""Mutation check for tier1: break each decision in turn, run the tests that should notice, expect them to fail (not
merely fail to compile), and restore the file. A mutation that passes is a decision no test guards.

usage: Tests/tier1/mutate.py SPEC.json
  SPEC: {"filter": "<swift test --filter>", "mutations": [{"name": ..., "file": ..., "from": ..., "to": ...}, ...]}
  "from" must occur exactly once in "file". Exits 1 unless every mutation is caught.
"""
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    spec = json.load(open(sys.argv[1], encoding="utf-8"))
    caught = 0
    for m in spec["mutations"]:
        path = os.path.join(ROOT, m["file"])
        original = open(path, encoding="utf-8").read()
        if original.count(m["from"]) != 1:
            sys.exit(f"{m['name']}: the text to replace isn't in {m['file']} exactly once")
        open(path, "w", encoding="utf-8").write(original.replace(m["from"], m["to"]))
        try:
            r = subprocess.run([os.path.join(ROOT, "Tests", "tier1", "run.sh"), "--filter", spec["filter"]],
                               capture_output=True, text=True, cwd=ROOT)
            compiled = "error:" not in r.stdout + r.stderr
            ok = compiled and r.returncode != 0
            caught += ok
            print(f"{'caught' if ok else ('DID NOT COMPILE' if not compiled else 'MISSED')}: {m['name']}", flush=True)
        finally:
            open(path, "w", encoding="utf-8").write(original)
    print(f"{caught}/{len(spec['mutations'])} caught")
    sys.exit(0 if caught == len(spec["mutations"]) else 1)


if __name__ == "__main__":
    main()
