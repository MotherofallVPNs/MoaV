#!/bin/sh
set -eu
# `set` is a POSIX SPECIAL builtin: when `set -o pipefail` fails, a
# non-interactive shell exits immediately -- `|| true` does NOT save it. dash
# (debian's /bin/sh) has no pipefail, so the naive guard silently killed the
# conduit container at line 3 with exit 2 and no output. Probe in a SUBSHELL,
# where the exit is contained, then enable it for real only if supported.
if ( set -o pipefail 2>/dev/null ); then set -o pipefail; fi

# =============================================================================
# Psiphon Conduit v2 entrypoint
# =============================================================================

CONDUIT_BANDWIDTH="${CONDUIT_BANDWIDTH:-200}"
# Backwards-compat: accept old CONDUIT_MAX_CLIENTS if new var isn't set
CONDUIT_MAX_COMMON_CLIENTS="${CONDUIT_MAX_COMMON_CLIENTS:-${CONDUIT_MAX_CLIENTS:-100}}"
CONDUIT_DATA_DIR="${CONDUIT_DATA_DIR:-/data}"
CONDUIT_METRICS_ADDR="${CONDUIT_METRICS_ADDR:-:9090}"

echo "[conduit] Starting Psiphon Conduit v2"
echo "[conduit] Bandwidth limit: ${CONDUIT_BANDWIDTH} Mbps"
echo "[conduit] Max common clients: $CONDUIT_MAX_COMMON_CLIENTS"
echo "[conduit] Metrics endpoint: $CONDUIT_METRICS_ADDR"
echo "[conduit] Data directory: $CONDUIT_DATA_DIR"

# Handle shutdown gracefully - use signal numbers for POSIX compatibility
# 15 = SIGTERM, 2 = SIGINT
cleanup() {
    echo "[conduit] Shutting down..."
    if [ -n "$CONDUIT_PID" ]; then
        kill "$CONDUIT_PID" 2>/dev/null || true
    fi
    exit 0
}
trap cleanup 15 2

# Display Ryve deep link after key is generated (runs in background)
show_ryve_link() {
    # Wait for conduit to generate its key file (up to 30s)
    attempts=0
    while [ ! -f "$CONDUIT_DATA_DIR/conduit_key.json" ] && [ $attempts -lt 30 ]; do
        sleep 1
        attempts=$((attempts + 1))
    done

    if [ ! -f "$CONDUIT_DATA_DIR/conduit_key.json" ]; then
        echo "[conduit] Warning: Key file not found after 30s"
        return
    fi

    # Extract private key from JSON (without jq)
    # `|| true` is REQUIRED here, not defensive: grep exits 1 when the key is
    # absent, and the very next line (`if [ -z "$PRIVATE_KEY" ]`) exists to
    # handle exactly that case. Under pipefail the script would die before
    # reaching its own guard.
    PRIVATE_KEY=$(grep -o '"privateKeyBase64"[[:space:]]*:[[:space:]]*"[^"]*"' \
        "$CONDUIT_DATA_DIR/conduit_key.json" | sed 's/.*:.*"\([^"]*\)".*/\1/' || true)

    if [ -z "$PRIVATE_KEY" ]; then
        echo "[conduit] Warning: Could not extract key from conduit_key.json"
        return
    fi

    # Build Ryve claim payload and deep link
    CONDUIT_NAME="${CONDUIT_NAME:-MoaV Conduit}"
    PAYLOAD="{\"version\":1,\"data\":{\"key\":\"${PRIVATE_KEY}\",\"name\":\"${CONDUIT_NAME}\"}}"
    ENCODED=$(echo -n "$PAYLOAD" | base64 | tr -d '\n' | tr '+/' '-_')
    DEEP_LINK="network.ryve.app://(app)/conduits?claim=${ENCODED}"

    echo ""
    echo "[conduit] =========================================="
    echo "[conduit]   Ryve Deep Link (import to mobile app)"
    echo "[conduit] =========================================="
    echo "[conduit] $DEEP_LINK"
    echo "[conduit] =========================================="
    echo ""
} &

# Fix volume ownership (volumes may be root-owned from previous runs)
chown -R moav:moav "$CONDUIT_DATA_DIR" 2>/dev/null || true

# Run conduit as non-root in foreground
# Strip application timestamps (Docker already adds them)
setpriv --reuid=moav --regid=moav --init-groups /app/conduit start \
    -d "$CONDUIT_DATA_DIR" \
    -b "$CONDUIT_BANDWIDTH" \
    -m "$CONDUIT_MAX_COMMON_CLIENTS" \
    --metrics-addr "$CONDUIT_METRICS_ADDR" \
    -v 2>&1 | sed -u 's/^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\} [0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\} //' &
CONDUIT_PID=$!

# Wait for conduit to exit
wait $CONDUIT_PID
