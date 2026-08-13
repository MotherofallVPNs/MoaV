#!/bin/bash
# Regression test: the Snowflake dashboard reads the proxy's own metrics. #183
#
# We used to run a 213-line exporter that regex-parsed the proxy's summary log
# lines. The proxy has exposed a Prometheus endpoint since 2.11 (path
# /internal/metrics, enabled with -metrics), and it carries strictly more:
#
#   tor_snowflake_proxy_connections_total{country}   per-country, the thing #183 asked for
#   tor_snowflake_proxy_connection_timeouts_total    failures, which we never had
#   tor_snowflake_proxy_traffic_inbound_bytes_total  relayed traffic
#   tor_snowflake_proxy_traffic_outbound_bytes_total
#
# Two traps, both measured on a live proxy rather than reasoned about:
#
# 1. connections_total is a CounterVec. A CounterVec with no observations emits
#    NOTHING -- no HELP, no TYPE, no series -- so on a proxy that has not yet
#    completed a connection the country metric looks like it does not exist. It
#    took a proxy with real completed connections to see RU=3, DE=2, ??=1.
#
# 2. The traffic counters are in KILOBYTES despite being named *_bytes_total.
#    A 95-second counter delta of 8667 matched the log line "Traffic Relayed
#    ↓ 8667 KB" exactly. Every bandwidth panel must multiply by 1024 or it is
#    wrong by three orders of magnitude.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASH="$ROOT/configs/monitoring/grafana/provisioning/dashboards/snowflake.json"
COMPOSE="$ROOT/docker-compose.yml"
PROM="$ROOT/configs/monitoring/prometheus.yml"
ENTRY="$ROOT/scripts/snowflake-entrypoint.sh"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "snowflake: native proxy metrics replace the log exporter (#183)"

# --- the custom exporter is gone ---------------------------------------------
[ -d "$ROOT/exporters/snowflake" ] \
    && bad "exporters/snowflake still exists — the native endpoint supersedes it" \
    || ok "the log-parsing exporter is deleted"
grep -q 'snowflake-exporter' "$COMPOSE" \
    && bad "docker-compose.yml still defines snowflake-exporter" \
    || ok "no snowflake-exporter service in compose"
grep -q "targets: \['snowflake-exporter" "$PROM" \
    && bad "prometheus still scrapes the deleted exporter" \
    || ok "prometheus no longer scrapes the deleted exporter"

# --- and the proxy's own endpoint is wired -----------------------------------
grep -q '/internal/metrics' "$PROM" \
    && ok "prometheus scrapes /internal/metrics" \
    || bad "the native metrics path is not in the scrape config"
# snowflake runs network_mode: host, so it has no service DNS name on moav_net.
grep -q "targets: \['host.docker.internal:9998'\]" "$PROM" \
    && ok "the target uses the host gateway (snowflake is network_mode: host)" \
    || bad "the target is not host.docker.internal — a service name will not resolve"
grep -q '\-metrics' "$ENTRY" \
    && ok "the entrypoint enables -metrics" \
    || bad "the proxy is started without -metrics, so nothing is exposed"
grep -q 'geoipdb' "$ENTRY" \
    && ok "the entrypoint passes the geoip db (no country label without it)" \
    || bad "no -geoipdb: connections_total would carry country=\"\" forever"

# --- the KB trap must be handled ---------------------------------------------
python3 - "$DASH" <<'PY' > /tmp/sfdash.$$ 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
for p in d["panels"]:
    f = p.get("fieldConfig", {}).get("defaults", {})
    print("|".join([p.get("type",""), p.get("title",""),
                    " ".join(t.get("expr","") for t in p.get("targets", [])),
                    str(f.get("unit")), str(f.get("min"))]))
PY
dash=/tmp/sfdash.$$
trap 'rm -f "$dash"' EXIT

while IFS='|' read -r type title expr unit min; do
    case "$expr" in
        *traffic_inbound*|*traffic_outbound*)
            case "$expr" in
                *1024*) ok "'$title' scales KB to bytes" ;;
                *)      bad "'$title' uses a traffic counter without *1024 — off by 1024x" ;;
            esac ;;
    esac
    if [ "$type" = "timeseries" ]; then
        case "$expr" in
            *rate\(*|*increase\(*) : ;;
            *) [ "$min" = "0" ] || bad "'$title' plots a lifetime total with no min=0 — flat line, unreadable axis" ;;
        esac
    fi
done < "$dash"

# --- the panels #183 actually asked for --------------------------------------
grep -q 'by (country)' "$dash" \
    && ok "a per-country panel exists" \
    || bad "no per-country panel — the headline ask of #183"
grep -q 'connection_timeouts_total' "$dash" \
    && ok "failed connections are surfaced" \
    || bad "connection_timeouts_total is exposed but not shown anywhere"
grep -qE 'served_people|download_gb|upload_gb' "$dash" \
    && bad "a panel still queries a metric from the deleted exporter" \
    || ok "no panel references the old exporter's metrics"

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
