#!/usr/bin/env python3
"""Single-source protocol roster: generate + drift-check.

`data/protocols.json` is the source of truth. This script (a) regenerates the
marker-delimited overview table in docs/protocols.md, and (b) drift-checks the
surfaces where regeneration is too fragile (prose meta / JSON-LD) by asserting
every protocol appears in them.

  python3 scripts/gen-protocol-docs.py --write    # rewrite generated regions
  python3 scripts/gen-protocol-docs.py --check    # CI: fail on any drift

No third-party deps (stdlib json only).
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "data", "protocols.json")

# Files that must mention every protocol (by its `seo` token), but whose format
# is prose / JSON-LD and so is presence-checked rather than regenerated.
PRESENCE_FILES = ["README.md", "site/index.html", "site/llms.txt"]


def load():
    with open(DATA) as f:
        return json.load(f)["protocols"]


def overview_table(protocols):
    lines = [
        "| Protocol | Port | Stealth | Speed | Domain Required |",
        "|----------|------|---------|-------|-----------------|",
    ]
    for p in protocols:
        lines.append(
            f"| [{p['name']}](#{p['anchor']}) | {p['port']} | {p['stealth']} | {p['speed']} | {p['domain']} |"
        )
    return "\n".join(lines)


# (relative path, marker name, generator function)
GENERATED = [
    ("docs/protocols.md", "overview-table", overview_table),
]


def inject(text, marker, block):
    begin = f"<!-- BEGIN gen:{marker} -->"
    end = f"<!-- END gen:{marker} -->"
    pat = re.compile(re.escape(begin) + r".*?" + re.escape(end), re.DOTALL)
    repl = f"{begin}\n{block}\n{end}"
    if not pat.search(text):
        raise SystemExit(f"marker '{marker}' not found (expected {begin} ... {end})")
    return pat.sub(lambda _m: repl, text)


def run(check):
    protocols = load()
    problems = []

    # 1. Generated regions
    for rel, marker, fn in GENERATED:
        path = os.path.join(ROOT, rel)
        with open(path) as f:
            cur = f.read()
        new = inject(cur, marker, fn(protocols))
        if check:
            if cur != new:
                problems.append(f"{rel}: generated region '{marker}' is out of date (run --write)")
        elif cur != new:
            with open(path, "w") as f:
                f.write(new)
            print(f"wrote {rel} [{marker}]")
        else:
            print(f"ok {rel} [{marker}] (unchanged)")

    # 2. Presence check (both modes — cheap and catches the real drift)
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
        print("\nPROTOCOL ROSTER DRIFT:")
        for pr in problems:
            print(f"  - {pr}")
        return 1
    print("protocol roster: OK" if check else "protocol roster: written + presence OK")
    return 0


def main():
    check = "--check" in sys.argv
    write = "--write" in sys.argv
    if check == write:
        raise SystemExit("usage: gen-protocol-docs.py (--write | --check)")
    sys.exit(run(check))


if __name__ == "__main__":
    main()
