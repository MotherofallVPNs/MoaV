#!/bin/bash
# Regression test: the Snowflake exporter's metric types and the dashboard that
# reads them. Issue #183.
#
# The panels were not broken by Grafana. Every "over time" panel plotted
# `max(<cumulative gauge>)` -- the lifetime total -- so the line was flat by
# construction and "Total Bandwidth Donated" auto-scaled its axis to the noise
# band (150.07845 .. 150.07848 GB). The values were also GB floats, which drift
# as they accumulate and push unit handling into every panel.
#
# Cumulative, monotonically increasing values are COUNTERS. Typed correctly,
# rate()/increase() work, and a restart -- which replays the log from zero --
# reads as a counter reset rather than a cliff.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPORTER="$ROOT/exporters/snowflake/main.py"
DASH="$ROOT/configs/monitoring/grafana/provisioning/dashboards/snowflake.json"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "snowflake exporter: counter types + dashboard queries (#183)"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"; [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null' EXIT

# --- scrape the real exporter against real log lines -------------------------
# Two hourly summaries in the format the proxy actually writes.
cat > "$TMP/snowflake.log" <<'LOG'
snowflake-proxy 2026/08/12 10:00:00 In the last 1h0m0s, there were 33 completed successful connections. Traffic Relayed ↓ 4006 KB (1.11 KB/s), ↑ 1705 KB (0.47 KB/s)
snowflake-proxy 2026/08/12 11:00:00 In the last 1h0m0s, there were 41 completed successful connections. Traffic Relayed ↓ 12.5 MB (3.5 KB/s), ↑ 3.2 MB (0.9 KB/s)
LOG

PORT=$(python3 -c "
import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")
SNOWFLAKE_EXPORTER_PORT="$PORT" python3 "$EXPORTER" "$TMP/snowflake.log" >/dev/null 2>&1 &
PID=$!
for _ in $(seq 1 30); do
    curl -fsS "http://127.0.0.1:$PORT/metrics" -o "$TMP/metrics" 2>/dev/null && break
    sleep 0.3
done

if [ ! -s "$TMP/metrics" ]; then
    bad "the exporter never served /metrics — cannot check anything else"
    echo ""; echo "  passed: $pass   failed: $fail"; exit 1
fi
ok "the exporter serves /metrics"

# --- the counters must be typed as counters ----------------------------------
for m in snowflake_connections_total snowflake_relayed_bytes_total; do
    if grep -q "^# TYPE $m counter$" "$TMP/metrics"; then
        ok "$m is a counter"
    else
        got=$(grep "^# TYPE $m " "$TMP/metrics" || echo "absent")
        bad "$m is not a counter ($got) — rate()/increase() cannot work and every trend panel goes flat"
    fi
done

# --- and the arithmetic must be right ----------------------------------------
# 33 + 41 connections; 4006 KiB + 12.5 MiB down; 1705 KiB + 3.2 MiB up.
want_down=$(python3 -c "print(int(4006*1024 + 12.5*1024**2))")
want_up=$(python3 -c "print(int(1705*1024 + 3.2*1024**2))")
got_conn=$(awk '/^snowflake_connections_total /{print $2}' "$TMP/metrics")
got_down=$(awk -F'[ }]' '/^snowflake_relayed_bytes_total\{direction="down"\}/{print $NF}' "$TMP/metrics")
got_up=$(awk -F'[ }]' '/^snowflake_relayed_bytes_total\{direction="up"\}/{print $NF}' "$TMP/metrics")

[ "$got_conn" = "74" ] && ok "connections accumulate across log lines (74)" \
                       || bad "connections wrong: got '$got_conn', want 74"
[ "$got_down" = "$want_down" ] && ok "download bytes are exact ($want_down)" \
                               || bad "download wrong: got '$got_down', want $want_down"
[ "$got_up" = "$want_up" ] && ok "upload bytes are exact ($want_up)" \
                           || bad "upload wrong: got '$got_up', want $want_up"

# --- the old names must survive the upgrade ----------------------------------
# An operator may have their own panels; renaming without an alias breaks them
# silently on the next rebuild.
for legacy in served_people download_gb upload_gb; do
    grep -q "^$legacy " "$TMP/metrics" \
        && ok "legacy $legacy still exported" \
        || bad "dropped $legacy — an operator's own panels would go blank"
done

# --- the dashboard must not plot lifetime totals as a trend ------------------
python3 - "$DASH" <<'PY' > "$TMP/dash.txt"
import json, sys
d = json.load(open(sys.argv[1]))
for p in d["panels"]:
    f = p.get("fieldConfig", {}).get("defaults", {})
    print("|".join([p.get("type",""), p.get("title",""),
                    " ".join(t.get("expr","") for t in p.get("targets", [])),
                    str(f.get("unit")), str(f.get("min"))]))
PY

while IFS='|' read -r type title expr unit min; do
    [ "$type" = "timeseries" ] || continue
    case "$expr" in
        *rate\(*|*increase\(*)
            ok "'$title' plots a rate, not the lifetime total" ;;
        *)
            if [ "$min" = "0" ]; then
                ok "'$title' plots a cumulative total but pins the axis to 0"
            else
                bad "'$title' plots '$expr' with no rate() and no min=0 — flat line, unreadable axis"
            fi ;;
    esac
done < "$TMP/dash.txt"

# The unit must not be the old decimal-GB float any more.
if grep -q 'decgbytes' "$TMP/dash.txt"; then
    bad "a panel still uses decgbytes — the exporter now reports bytes"
else
    ok "no panel still expects GB floats"
fi

# --- and a fix must actually reach a running container -----------------------
# exporters/*/Dockerfile COPYs the code in, so a change needs a rebuild.
if grep -qE 'exporters/\*/\*\)' "$ROOT/lib/update.sh"; then
    ok "moav update maps an exporters/ change to a rebuild"
else
    bad "an exporter change queues no rebuild — the old code keeps running after update"
fi

echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
