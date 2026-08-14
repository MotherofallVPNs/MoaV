#!/bin/bash
# Regression test: a panel whose title implies a time window must respect the
# picker.
#
# Reported from a live dashboard: "Share of Users by Country" and "Rendezvous
# Success Rate" never changed when the range changed. Both read a raw cumulative
# counter, so they showed since-exporter-start no matter what was selected.
# Nothing about that looks wrong on screen -- the numbers are real, just not the
# ones the picker asked for.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASH="$ROOT/configs/monitoring/grafana/provisioning/dashboards"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "dashboards: range-scoped panels must use the range"

out=$(python3 - "$DASH" <<'PY'
import json, os, re, sys

# Panels that must move with the picker, and the counter each one reads.
RANGE_SCOPED = {
    ("singbox.json",   "Connections by Country"),
    ("singbox.json",   "Users by Country"),
    ("singbox.json",   "Site Usage"),
}
# A counter read bare is the bug; these wrappers make it range-aware.
WRAPPED = re.compile(r'\b(increase|rate|irate|delta|max_over_time|avg_over_time|'
                     r'min_over_time|sum_over_time|last_over_time|count_over_time)\s*\(')

def panels(d):
    for p in d.get("panels", []):
        yield p
        for n in p.get("panels", []):
            yield n

seen = set()
for fn in sorted(os.listdir(sys.argv[1])):
    if not fn.endswith(".json"):
        continue
    d = json.load(open(os.path.join(sys.argv[1], fn)))
    for p in panels(d):
        key = (fn, p.get("title"))
        if key not in RANGE_SCOPED:
            continue
        seen.add(key)
        for t in p.get("targets", []):
            e = t.get("expr", "")
            if not e:
                continue
            if "_total" in e or "_by_country" in e:
                if not WRAPPED.search(e):
                    print("BARE|%s|%s|%s" % (fn, p["title"], e[:70]))
        if not p.get("description"):
            print("NODESC|%s|%s|" % (fn, p["title"]))

for key in RANGE_SCOPED - seen:
    print("MISSING|%s|%s|" % key)
PY
)
[ -z "$(grep '^BARE|' <<<"$out")" ] \
    && ok "no range-scoped panel reads a counter bare" \
    || bad "reads a cumulative counter, so the picker does nothing: $(grep '^BARE|' <<<"$out" | head -2)"
[ -z "$(grep '^MISSING|' <<<"$out")" ] \
    && ok "every panel this test names still exists" \
    || bad "a panel was renamed or removed and is no longer covered: $(grep '^MISSING|' <<<"$out")"
[ -z "$(grep '^NODESC|' <<<"$out")" ] \
    && ok "each says in its description what it counts and over what" \
    || bad "no description, so the reader cannot tell what window it covers: $(grep '^NODESC|' <<<"$out")"

# Connections and users answer different questions and will not agree. That is
# the thing that reads as a bug, so it has to be written on the panel.
python3 - "$DASH/singbox.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
say = {p["title"]: (p.get("description") or "").lower()
       for p in d["panels"] if p.get("title") in ("Connections by Country", "Users by Country")}
ok = ("connections, not people" in say.get("Connections by Country", "")
      and "people, not connections" in say.get("Users by Country", ""))
sys.exit(0 if ok else 1)
PY
[ $? -eq 0 ] \
    && ok "the two country panels say why their numbers differ" \
    || bad "nothing explains why connections and users disagree; it reads as a bug"

# Snowflake's counters tick once per completed connection and then sit flat, so
# increase() over a window that misses that moment is legitimately zero -- which
# reads as a broken panel. Those stay lifetime, and must say so.
out=$(python3 - "$DASH/snowflake.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
bad = [p["title"] for p in d["panels"]
       if p.get("targets") and "tor_snowflake_proxy_connections_total" in str(p["targets"])
       and "increase(" not in str(p["targets"])
       and p.get("type") != "timeseries"
       and "since start" not in p.get("title", "")]
print("UNLABELLED=%s" % (bad or "none"))
PY
)
grep -q 'UNLABELLED=none' <<<"$out" \
    && ok "every lifetime snowflake panel says so in its title" \
    || bad "a lifetime panel looks range-scoped: $out"

echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
