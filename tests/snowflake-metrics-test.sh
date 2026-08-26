#!/bin/bash
# Regression test: the Snowflake dashboard is fed by a hybrid of two sources.
#
# 1. The proxy's own /internal/metrics endpoint (enabled with -metrics) is
#    authoritative for per-country connections and connection failures:
#      tor_snowflake_proxy_connections_total{country}
#      tor_snowflake_proxy_connection_timeouts_total
#      tor_snowflake_proxy_traffic_inbound_bytes_total   (live throughput only)
#      tor_snowflake_proxy_traffic_outbound_bytes_total
#    But its byte/connection counters are IN-MEMORY and reset to zero on every
#    proxy restart -- so a proxy that relayed tens of GB reads near-zero right
#    after a routine restart. Summing them for a lifetime total is wrong.
#
# 2. snowflake-exporter parses the proxy's PERSISTENT summary log (a named
#    volume that survives container recreation) into monotonic counters that
#    survive restarts, and owns the cumulative panels:
#      moav_snowflake_relayed_bytes_total{direction}     (already BYTES)
#      moav_snowflake_completed_connections_total
#
# Two live-measured traps this pins:
#  - connections_total is a CounterVec: with no observations it emits NOTHING,
#    so the per-country panel looks absent until a real connection completes.
#  - the NATIVE traffic counters are KILOBYTES despite the *_bytes_total name,
#    so the live-throughput panels must multiply by 1024. The exporter already
#    emits bytes, so its cumulative panels must NOT.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASH="$ROOT/configs/monitoring/grafana/provisioning/dashboards/snowflake.json"
COMPOSE="$ROOT/docker-compose.yml"
PROM="$ROOT/configs/monitoring/prometheus.yml"
ENTRY="$ROOT/scripts/snowflake-entrypoint.sh"
EXP="$ROOT/exporters/snowflake"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "snowflake: native per-country/failures + log-based cumulative exporter"

# --- the cumulative exporter exists and is wired -----------------------------
[ -f "$EXP/main.py" ] && [ -f "$EXP/Dockerfile" ] \
    && ok "exporters/snowflake exists (main.py + Dockerfile)" \
    || bad "exporters/snowflake is missing — cumulative totals have no source"
grep -q 'snowflake-exporter:' "$COMPOSE" \
    && ok "docker-compose defines the snowflake-exporter service" \
    || bad "no snowflake-exporter service in compose"
grep -q 'moav_snowflake_logs:/var/log/snowflake:ro' "$COMPOSE" \
    && ok "exporter mounts the persistent snowflake log read-only" \
    || bad "exporter does not mount moav_snowflake_logs — nothing to parse"
grep -q "targets: \['snowflake-exporter:9105'\]" "$PROM" \
    && ok "prometheus scrapes snowflake-exporter:9105" \
    || bad "prometheus does not scrape the cumulative exporter"

# --- the proxy's own endpoint is still wired (per-country + failures) ---------
grep -q '/internal/metrics' "$PROM" \
    && ok "prometheus scrapes /internal/metrics" \
    || bad "the native metrics path is not in the scrape config"
# snowflake runs network_mode: host, so it has no service DNS name on moav_net.
grep -q "targets: \['host.docker.internal:9998'\]" "$PROM" \
    && ok "the native target uses the host gateway (snowflake is network_mode: host)" \
    || bad "the native target is not host.docker.internal — a service name will not resolve"
grep -q '\-metrics' "$ENTRY" \
    && ok "the entrypoint enables -metrics" \
    || bad "the proxy is started without -metrics, so nothing is exposed"
grep -q 'geoipdb' "$ENTRY" \
    && ok "the entrypoint passes the geoip db (no country label without it)" \
    || bad "no -geoipdb: connections_total would carry country=\"\" forever"

# --- dashboard: cumulative panels use the exporter, live panels use native ----
python3 - "$DASH" <<'PY' > /tmp/sfdash.$$ 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
def panels(ps):
    for p in ps:
        yield p
        for c in p.get("panels", []):
            yield c
for p in panels(d["panels"]):
    f = p.get("fieldConfig", {}).get("defaults", {})
    print("|".join([p.get("type",""), p.get("title",""),
                    " ".join(t.get("expr","") for t in p.get("targets", [])),
                    str(f.get("unit")), str(f.get("min"))]))
PY
dash=/tmp/sfdash.$$
trap 'rm -f "$dash"' EXIT

while IFS='|' read -r type title expr unit min; do
    # A cumulative byte/connection panel must NOT read the resetting native
    # counters. The tells: increase()/max_over_time() of a tor_snowflake_* total.
    case "$expr" in
        *"increase(tor_snowflake_proxy_traffic"*|*"max_over_time(tor_snowflake_proxy_connections_total"*)
            case "$title" in
                # per-country + success-rate legitimately reduce the native
                # counter across a range; they are not cumulative-total panels.
                *Country*|*Countries*|*Success*) : ;;
                *) bad "'$title' builds a cumulative total from the resetting native counter" ;;
            esac ;;
    esac
    # NATIVE traffic counters are KB: any panel using them raw must *1024.
    case "$expr" in
        *traffic_inbound*|*traffic_outbound*)
            case "$expr" in
                *1024*) ok "'$title' scales native KB to bytes" ;;
                *)      bad "'$title' uses a native traffic counter without *1024 — off by 1024x" ;;
            esac ;;
    esac
    # The exporter already emits BYTES: its panels must NOT *1024.
    case "$expr" in
        *moav_snowflake_relayed_bytes_total*)
            case "$expr" in
                *1024*) bad "'$title' scales the exporter's byte counter by 1024 — 1024x too high" ;;
                *)      ok "'$title' uses the exporter's byte counter as-is" ;;
            esac ;;
    esac
done < "$dash"

# --- the panels #183 actually asked for --------------------------------------
grep -q 'by (country)' "$dash" \
    && ok "a per-country panel exists" \
    || bad "no per-country panel — the headline ask of #183"
grep -q 'connection_timeouts_total' "$dash" \
    && ok "failed connections are surfaced" \
    || bad "connection_timeouts_total is exposed but not shown anywhere"
grep -q 'moav_snowflake_completed_connections_total' "$dash" \
    && ok "the People/Connections panels use the cumulative exporter counter" \
    || bad "no panel reads the cumulative connection counter"

# --- exporter parsing unit test ----------------------------------------------
python3 - "$EXP" <<'PY'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("sfexp", sys.argv[1] + "/main.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
# reset shared state, feed sample summary lines (KB=1024 per the exporter)
for k in ("connections","inbound_bytes","outbound_bytes","windows"):
    m.state[k] = 0
lines = [
  "2026/08/26 16:37:41 In the last 1m30s, there were 3 completed successful connections. Traffic Relayed ↓ 8667 KB (0.00 KB/s), ↑ 512 KB (0.00 KB/s).",
  "2026/08/26 16:39:11 In the last 1m30s, there were 0 completed successful connections. Traffic Relayed ↓ 0 KB (0.00 KB/s), ↑ 0 KB (0.00 KB/s).",
  "2026/08/26 16:40:41 In the last 1m30s, there were 2 completed successful connections. Traffic Relayed ↓ 1.5 MB (0.00 KB/s), ↑ 256 KB (0.00 KB/s).",
  "2026/08/26 16:41:00 some unrelated proxy log line that is not a summary",
]
for ln in lines:
    m.parse_line(ln)
exp_conn = 5
exp_in = 8667*1024 + int(1.5*1024*1024)
exp_out = (512+256)*1024
assert m.state["connections"] == exp_conn, ("connections", m.state["connections"], exp_conn)
assert m.state["inbound_bytes"] == exp_in, ("inbound", m.state["inbound_bytes"], exp_in)
assert m.state["outbound_bytes"] == exp_out, ("outbound", m.state["outbound_bytes"], exp_out)
assert m.state["windows"] == 3, ("windows", m.state["windows"])   # the non-summary line ignored
print("PARSE_OK")
PY
if [ $? -eq 0 ]; then ok "exporter parses connections + KB/MB traffic, ignores non-summary lines"
else bad "exporter parse logic is wrong"; fi

# --- version pin -------------------------------------------------------------
# The compose default is only a default: an installed .env pins the old value and
# wins, which is why a rebuild produced 2.11.0 again on a live server.
want=$(grep -oE '^SNOWFLAKE_VERSION=.*' "$ROOT/.env.example" | cut -d= -f2)
grep -q "SNOWFLAKE_VERSION:-$want" "$COMPOSE" \
    && ok "compose default and .env.example agree on $want" \
    || bad "compose default disagrees with .env.example ($want) — installs would differ"

echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
