#!/bin/bash
# Regression test: the monitoring stack must never store a user identifier on
# the same series as a destination. Issue #297.
#
# What happened: ghcr.io/zxh326/clash-exporter emits
#   clash_network_traffic_bytes_total{source="<client IP>", destination="<host>"}
# one series per (client, destination) pair. On a live server that was 4,849
# client IPs against 7,592 hostnames -- 389,324 series, 83% of the TSDB -- kept
# for the full 15-day retention. It is a browsing log keyed by user, on a server
# whose users are the people least able to afford one. No dashboard read it.
#
# The rule this file enforces is the policy, not the symptom: a user identifier
# (client IP, username, public key, UUID) must never share a series with a
# destination. Per-user VOLUME is fine and stays -- operators need it for quota
# and abuse, and it says nothing about where anyone went.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROM="$ROOT/configs/monitoring/prometheus.yml"
COMPOSE="$ROOT/docker-compose.yml"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "monitoring privacy: no user identifier on a destination series (#297)"

# --- the leaking metric must be dropped at scrape time -----------------------
# Dropped at the scrape, not queried around: a sample Prometheus never receives
# cannot be read back, exported, or seized.
if python3 - "$PROM" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
job = next((j for j in d["scrape_configs"] if j["job_name"] == "clash"), None)
if job is None:
    sys.exit(0)                      # job removed entirely: also acceptable
rules = job.get("metric_relabel_configs") or []
dropped = any(r.get("action") == "drop"
              and "clash_network_traffic_bytes_total" in str(r.get("regex", ""))
              and "__name__" in (r.get("source_labels") or [])
              for r in rules)
sys.exit(0 if dropped else 1)
PY
then
    ok "clash_network_traffic_bytes_total is dropped before storage (or the job is gone)"
else
    bad "the per-(client,destination) metric is still stored — a browsing log keyed by user"
fi

# --- the exporter that produced it must be gone, not merely filtered ---------
# A drop rule is containment for data already on disk. The metric should not be
# produced at all, so re-adding the scrape job cannot bring the pairing back.
if grep -q '^  clash-exporter:' "$COMPOSE"; then
    bad "clash-exporter is still a service — the drop rule is one config edit away from being undone"
else
    ok "clash-exporter is removed, not filtered"
fi

# --- no dashboard may query a metric nothing produces ------------------------
# A panel pointing at a deleted metric renders "No data" rather than failing, so
# the break is invisible until someone opens the dashboard.
orphan=0
for d in "$ROOT"/configs/monitoring/grafana/provisioning/dashboards/*.json; do
    if grep -o 'clash_[a-z_]*' "$d" | sort -u | grep -q .; then
        bad "$(basename "$d") still queries $(grep -o 'clash_[a-z_]*' "$d" | sort -u | tr '\n' ' ')"
        orphan=1
    fi
done
[ "$orphan" = "0" ] && ok "no dashboard queries a clash_* metric that no longer exists"

# --- and nothing may reintroduce the pairing ---------------------------------
# A future exporter that emits both labels would pass the check above while
# recreating the exact problem, so scan what we ship for the pairing.
pairing=0
for f in "$ROOT"/exporters/*/main.py; do
    [ -f "$f" ] || continue
    if grep -qiE '"(source|client_ip|src_ip)"' "$f" && grep -qiE '"(destination|dest|host)"' "$f"; then
        bad "$(basename "$(dirname "$f")") exporter emits a client identifier alongside a destination"
        pairing=1
    fi
done
[ "$pairing" = "0" ] && ok "no MoaV exporter pairs a client identifier with a destination"

# --- per-user volume must NOT have been removed by over-correcting -----------
# The fix is about linkage, not about blinding the operator. If these went away
# someone went too far.
if grep -rqE 'user|name' "$ROOT"/exporters/singbox/main.py 2>/dev/null; then
    ok "per-user volume metrics still exist (quota and abuse handling need them)"
else
    bad "per-user metrics disappeared — the fix was linkage, not visibility"
fi

# --- retention has a size ceiling, not only an age ---------------------------
grep -q 'storage.tsdb.retention.size' "$COMPOSE" \
    && ok "Prometheus retention has a size ceiling as well as an age" \
    || bad "retention.time alone cannot stop cardinality filling the disk"

# A longer window is only safe because the size cap bounds the disk. Making the
# time configurable without the cap would let one cardinality mistake fill it.
if grep -q 'PROMETHEUS_RETENTION_TIME' "$COMPOSE" && ! grep -q 'PROMETHEUS_RETENTION_SIZE' "$COMPOSE"; then
    bad "retention time is configurable but the size cap is not"
else
    ok "retention time and size cap are configurable together"
fi

# --- the policy has to be written down somewhere operators look --------------
doc_found=0
for d in "$ROOT/../moav-site/docs/OPSEC.md" "$ROOT/docs/OPSEC.md"; do
    [ -f "$d" ] && grep -qiE 'what moav records|never links|data policy' "$d" && doc_found=1
done
[ "$doc_found" = "1" ] \
    && ok "the data policy is documented" \
    || echo "  note  data policy doc not found (lives in moav-site; skipped when absent)"

echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
