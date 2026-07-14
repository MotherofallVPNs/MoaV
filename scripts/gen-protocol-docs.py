#!/usr/bin/env python3
"""Protocol-roster drift gate.

`data/protocols.json` is the source of truth for the protocol roster. The
human-readable overview table lives on the docs site (moav-site); this repo only
drift-checks that every protocol still appears in the server README prose so the
roster can't silently diverge.

  python3 scripts/gen-protocol-docs.py --check    # CI: fail on any drift

No third-party deps (stdlib json only).
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "data", "protocols.json")

# Prose surfaces that must mention every protocol (by its `seo` token).
PRESENCE_FILES = ["README.md"]


def load():
    with open(DATA) as f:
        return json.load(f)["protocols"]


def run():
    protocols = load()
    problems = []
    for rel in PRESENCE_FILES:
        path = os.path.join(ROOT, rel)
        if not os.path.exists(path):
            continue
        with open(path) as f:
            body = f.read()
        for p in protocols:
            if p["seo"] not in body:
                problems.append(f"{rel}: missing protocol '{p['name']}' (token '{p['seo']}')")
    if problems:
        print("PROTOCOL ROSTER DRIFT:")
        for pr in problems:
            print(f"  - {pr}")
        return 1
    print("protocol roster: OK")
    return 0


def main():
    if "--check" not in sys.argv:
        raise SystemExit("usage: gen-protocol-docs.py --check")
    sys.exit(run())


if __name__ == "__main__":
    main()
