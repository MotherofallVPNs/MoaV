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

# Snowflake's counters restart with the container, so a panel reading one raw
# shows a number that falls to zero on every restart. Measured on a live server:
# "Total Downloaded" read 779 KiB while "Downloaded" over the same data read
# 31.5 MiB, because only the second summed across the reset.
out=$(python3 - "$DASH/snowflake.json" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
COUNTERS = ("tor_snowflake_proxy_connections_total",
            "tor_snowflake_proxy_connection_timeouts_total",
            "tor_snowflake_proxy_traffic_inbound_bytes_total",
            "tor_snowflake_proxy_traffic_outbound_bytes_total")
WRAPPED = re.compile(r'\b(increase|rate|irate|delta|deriv|max_over_time|last_over_time|avg_over_time|min_over_time|sum_over_time)\s*\(')
raw = []
for p in d["panels"]:
    for t in p.get("targets", []):
        e = t.get("expr", "")
        if any(c in e for c in COUNTERS) and not WRAPPED.search(e):
            raw.append("%s: %s" % (p.get("title"), e[:60]))
print("RAW=%s" % (raw or "none"))

# The pie and the timeline beside it must be computed the same way, or they
# disagree about which countries exist and it reads as a bug.
def expr(title):
    return next((t.get("expr", "") for p in d["panels"] if p.get("title") == title
                 for t in p.get("targets", [])), "")
pie, ts = expr("Share of Users by Country"), expr("Users Served by Country over Time")
# Both must use max_over_time: increase() misses each country's first
# connection on a counter this sparse, and mixing the two makes them disagree.
print("SAME_BASIS=%s" % (("max_over_time(" in pie) and ("max_over_time(" in ts)))
PY
)
grep -q 'RAW=none' <<<"$out" \
    && ok "no snowflake panel reads a counter that resets with the container" \
    || bad "reads a raw counter, so it drops to zero on restart: $(grep '^RAW=' <<<"$out")"
grep -q 'SAME_BASIS=True' <<<"$out" \
    && ok "the country pie and the country timeline are computed the same way" \
    || bad "pie and timeline use different bases, so they list different countries"

# --- counters that reset must not be read raw, anywhere -----------------------
# cAdvisor's and the proxies' counters restart with their container. Only
# metrics an exporter persists itself may be read raw.
out=$(python3 - "$DASH" <<'PY'
import json, os, re, sys
WRAPPED = re.compile(r'\b(increase|rate|irate|delta|deriv|max_over_time|last_over_time|avg_over_time|min_over_time|sum_over_time)\s*\(')
# _total that are really gauges, and metrics MoaV persists across restarts.
ALLOW = ("wireguard_peers_total", "amneziawg_peers_total",
         "moav_site_traffic_bytes_total", "moav_site_destination_country_bytes_total",
         "moav_site_connections_total")
raw = []
for fn in sorted(os.listdir(sys.argv[1])):
    if not fn.endswith(".json"):
        continue
    d = json.load(open(os.path.join(sys.argv[1], fn)))
    def walk(p):
        for t in p.get("targets", []):
            e = t.get("expr", "")
            if WRAPPED.search(e):
                continue
            for m in re.findall(r'\b([a-z][a-z0-9_]*_total)\b', e):
                if m not in ALLOW:
                    raw.append("%s/%s: %s" % (fn, p.get("title"), m))
        for n in p.get("panels", []):
            walk(n)
    for p in d["panels"]:
        walk(p)
print("RAW=%s" % (sorted(set(raw)) or "none"))
PY
)
grep -q 'RAW=none' <<<"$out" \
    && ok "no dashboard reads a resettable counter raw" \
    || bad "reads a counter that resets with its container: $(grep '^RAW=' <<<"$out" | head -c 200)"

# --- one country, one colour, everywhere --------------------------------------
# palette-classic assigns colours by series index, so US was green in the pie and
# red in the timeline beside it. by-name hashes the series name instead.
out=$(python3 - "$DASH" <<'PY'
import json, os, sys
wrong = []
for fn in sorted(os.listdir(sys.argv[1])):
    if not fn.endswith(".json"):
        continue
    d = json.load(open(os.path.join(sys.argv[1], fn)))
    def walk(p):
        col = (p.get("fieldConfig", {}).get("defaults", {}).get("color") or {})
        lf = " ".join(t.get("legendFormat", "") for t in p.get("targets", []))
        if ("{{" in lf and col.get("mode") == "palette-classic"
                and p.get("type") in ("timeseries", "barchart")):
            wrong.append("%s/%s" % (fn, p.get("title")))
        if col.get("mode") == "palette-classic-by-name" and p.get("type") == "piechart":
            wrong.append("%s/%s (by-name paints every slice alike)" % (fn, p.get("title")))
        for n in p.get("panels", []):
            walk(n)
    for p in d["panels"]:
        walk(p)
print("BYINDEX=%s" % (wrong or "none"))
PY
)
grep -q 'BYINDEX=none' <<<"$out" \
    && ok "label-driven panels colour by series name, so a country keeps one colour" \
    || bad "colours assigned by index; the same label differs between panels: $(grep '^BYINDEX=' <<<"$out" | head -c 200)"

# --- every target must name its datasource --------------------------------------
# Panels inside a collapsed row were created without one and inherited nothing.
out=$(python3 - "$DASH" <<'PY'
import json, os, sys
missing = []
for fn in sorted(os.listdir(sys.argv[1])):
    if not fn.endswith(".json"):
        continue
    d = json.load(open(os.path.join(sys.argv[1], fn)))
    def walk(p):
        for t in p.get("targets", []):
            if t.get("expr") and not t.get("datasource"):
                missing.append("%s/%s" % (fn, p.get("title")))
        for n in p.get("panels", []):
            walk(n)
    for p in d["panels"]:
        walk(p)
print("NODS=%s" % (sorted(set(missing)) or "none"))
PY
)
grep -q 'NODS=none' <<<"$out" \
    && ok "every target names its datasource" \
    || bad "target has no datasource: $(grep '^NODS=' <<<"$out" | head -c 160)"

# --- site counters step hourly, so a sub-hour rate is meaningless ---------------
# sitestats advances its counters once per bucket. rate() over $__rate_interval
# reads zero between rolls and one huge spike at the roll -- it showed 20 MB/s
# for a site averaging a few KB/s, and nothing at all on a one-hour window.
out=$(python3 - "$DASH/singbox.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
bad = []
def walk(p):
    for t in p.get("targets", []):
        e = t.get("expr", "")
        if "moav_site_" in e and ("$__rate_interval" in e or "$__interval" in e):
            bad.append("%s: %s" % (p.get("title"), e[:50]))
    for n in p.get("panels", []):
        walk(n)
for p in d["panels"]:
    walk(p)
print("SUBHOUR=%s" % (bad or "none"))
PY
)
grep -q 'SUBHOUR=none' <<<"$out" \
    && ok "no site panel samples the hourly counters at sub-hour resolution" \
    || bad "a sub-hour rate on an hourly counter reads 0 or spikes: $(grep '^SUBHOUR=' <<<"$out" | head -c 140)"

# The counters step exactly on the hour. Sampling at exactly 1h aligns every
# window between two steps, so the chart reads 0 while the data is fine.
out=$(python3 - "$DASH/singbox.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
bad = []
def walk(p):
    if p.get("interval") == "1h" and any("moav_site_" in t.get("expr", "")
                                         for t in p.get("targets", [])):
        bad.append(p.get("title"))
    for n in p.get("panels", []):
        walk(n)
for p in d["panels"]:
    walk(p)
print("ALIGNED=%s" % (bad or "none"))
PY
)
grep -q 'ALIGNED=none' <<<"$out" \
    && ok "no site panel is pinned to the bucket length (it would sample between steps)" \
    || bad "interval pinned to 1h on an hourly counter reads all zeros: $(grep '^ALIGNED=' <<<"$out")"

# The table's columns must agree with each other: one cumulative column beside
# three range-scoped ones showed clients next to a row of zeros.
out=$(python3 - "$DASH/singbox.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
def find(t):
    for p in d["panels"]:
        for n in p.get("panels", []) or [p]:
            if n.get("title") == t:
                return n
    return None
t = find("Site Usage")
kinds = {("range" if "$__range" in x.get("expr", "") else "cumulative")
         for x in (t or {}).get("targets", [])}
print("MIXED=%s" % (len(kinds) > 1))
PY
)
grep -q 'MIXED=False' <<<"$out" \
    && ok "the Site Usage columns are all the same kind" \
    || bad "the table mixes cumulative and range columns, so some read 0 while others do not"

echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
