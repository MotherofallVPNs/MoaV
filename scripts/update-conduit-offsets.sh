#!/bin/bash
# Run this after every Conduit restart to update the lifetime byte offsets.
# Queries Prometheus for pre-restart peak values and rewrites the rules file,
# then reloads Prometheus via the lifecycle API.
#
# Usage: ./scripts/update-conduit-offsets.sh
#
# Prometheus must be reachable on PROM_URL (default: http://localhost:9091).
# If Prometheus port 9091 is not exposed in docker-compose.yml, either expose
# it under `ports:` or set PROM_URL to the reachable address.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RULES_FILE="${SCRIPT_DIR}/../configs/monitoring/conduit_lifetime.rules.yml"
PROM="${PROM_URL:-http://localhost:9091}"

query() {
    local encoded
    encoded=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$1")
    curl -sf "${PROM}/api/v1/query?query=${encoded}" \
        | python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print(int(float(r[0]['value'][1])) if r else 0)"
}

echo "Querying Prometheus for lifetime offsets..."

# Recover the pre-restart running total, then subtract the current (post-restart)
# session so the new offset = everything accumulated *before* this session.
#
# Query the *_lifetime recording rule, not the raw conduit_bytes_* gauge: the raw
# gauge's max is only the single largest session, so basing the offset on it
# would discard every other prior session and undercount across multiple
# restarts. The lifetime metric already carries the cumulative total, so its peak
# is the true high-water mark. On the very first run the recording rule hasn't
# been evaluated yet (no lifetime series → query returns 0), so fall back to the
# raw gauge for that one bootstrap case.
#
# Window is 15d to match Prometheus' --storage.tsdb.retention.time=15d; samples
# older than retention aren't queryable anyway. Run this soon after a restart.
DL=$(query "max_over_time(conduit_bytes_downloaded_lifetime[15d])")
[[ "$DL" -eq 0 ]] && DL=$(query "max_over_time(conduit_bytes_downloaded[15d])")
UL=$(query "max_over_time(conduit_bytes_uploaded_lifetime[15d])")
[[ "$UL" -eq 0 ]] && UL=$(query "max_over_time(conduit_bytes_uploaded[15d])")
CURRENT_DL=$(query "conduit_bytes_downloaded")
CURRENT_UL=$(query "conduit_bytes_uploaded")

DL_OFFSET=$((DL - CURRENT_DL))
UL_OFFSET=$((UL - CURRENT_UL))

# Never let a transient/empty read push the running total backwards.
[[ "$DL_OFFSET" -lt 0 ]] && DL_OFFSET=0
[[ "$UL_OFFSET" -lt 0 ]] && UL_OFFSET=0
DATE=$(date "+%Y-%m-%d")
DL_GB=$(python3 -c "print(f'{$DL_OFFSET/1e9:.1f}')")
UL_GB=$(python3 -c "print(f'{$UL_OFFSET/1e9:.1f}')")

echo "Download offset: $DL_OFFSET bytes ($DL_GB GB)"
echo "Upload offset:   $UL_OFFSET bytes ($UL_GB GB)"

cat > "$RULES_FILE" << EOF
groups:
  - name: conduit_lifetime
    rules:
      # Lifetime bandwidth totals that survive Conduit process restarts.
      # OFFSET values = bytes accumulated in all previous runs.
      # Run scripts/update-conduit-offsets.sh after each Conduit restart.
      #
      # Last updated: $DATE
      # Download offset: $DL_OFFSET bytes ($DL_GB GB)
      # Upload offset:   $UL_OFFSET bytes ($UL_GB GB)

      - record: conduit_bytes_downloaded_lifetime
        expr: conduit_bytes_downloaded + $DL_OFFSET

      - record: conduit_bytes_uploaded_lifetime
        expr: conduit_bytes_uploaded + $UL_OFFSET
EOF

curl -sf -X POST "${PROM}/-/reload" \
    && echo "✓ Prometheus reloaded" \
    || echo "⚠ Prometheus reload failed — restart it manually"
echo "✓ Offsets updated in $RULES_FILE"
