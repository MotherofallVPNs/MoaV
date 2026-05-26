#!/bin/bash
set -euo pipefail

# =============================================================================
# GooseRelay exit-server entrypoint
# SOCKS5-over-Google-Apps-Script tunnel exit node — MahsaNG v16 component.
# =============================================================================

echo "================================================"
echo "  MoaV GooseRelay (Apps-Script tunnel exit)"
echo "================================================"

ENABLE_GOOSERELAY="${ENABLE_GOOSERELAY:-false}"

# Opt-in. When disabled, idle quietly instead of crash-looping
# (the service ships in the gooserelay/all profiles).
if [[ "$ENABLE_GOOSERELAY" != "true" ]]; then
    echo "[gooserelay] ENABLE_GOOSERELAY is not 'true' — GooseRelay disabled, idling."
    echo "[gooserelay] Set ENABLE_GOOSERELAY=true in .env to activate."
    # Portable idle (busybox sleep has no 'infinity'); keep the container up.
    while true; do sleep 3600; done
fi

CONFIG_FILE="/etc/gooserelay/server_config.json"

echo "[gooserelay] Looking for server config..."
timeout=60
elapsed=0
while [[ ! -s "$CONFIG_FILE" ]]; do
    echo "[gooserelay] Waiting for $CONFIG_FILE ..."
    sleep 2
    elapsed=$((elapsed + 2))
    if [[ $elapsed -ge $timeout ]]; then
        echo "[gooserelay] ERROR: config not found after ${timeout}s. Run bootstrap first."
        echo "[gooserelay] Expected: $CONFIG_FILE"
        ls -la /etc/gooserelay/ 2>&1 || true
        exit 1
    fi
done

echo "[gooserelay] Config: $CONFIG_FILE"
echo "[gooserelay] Listening on :8443 (/tunnel). Apps Script RELAY_URL must"
echo "[gooserelay] point at this server's public IP:PORT_GOOSE."
echo "================================================"

exec goose-server -config "$CONFIG_FILE"
