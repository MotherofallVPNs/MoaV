#!/bin/bash
set -euo pipefail

# =============================================================================
# MoaV telemt (Telegram MTProxy) entrypoint
# =============================================================================

CONFIG_FILE="/etc/telemt/config.toml"

echo "================================================"
echo "  MoaV Telegram MTProxy (telemt)"
echo "================================================"

# Wait for config file (bootstrap may still be generating it)
WAIT_TIMEOUT=30
WAITED=0
while [[ ! -f "$CONFIG_FILE" ]]; do
    if [[ $WAITED -ge $WAIT_TIMEOUT ]]; then
        echo "[telemt] ERROR: Config file not found after ${WAIT_TIMEOUT}s: $CONFIG_FILE"
        echo "[telemt] Run 'moav setup' or check bootstrap logs"
        exit 1
    fi
    echo "[telemt] Waiting for config file... (${WAITED}s)"
    sleep 2
    WAITED=$((WAITED + 2))
done

# Extract info from config for logging
PORT=$(grep -E '^\s*port\s*=' "$CONFIG_FILE" | head -1 | sed 's/.*=\s*//' | tr -d ' ')
TLS_DOMAIN=$(grep -E '^\s*tls_domain\s*=' "$CONFIG_FILE" | head -1 | sed 's/.*=\s*"//' | sed 's/".*//')
USER_COUNT=$(grep -c '=' <(sed -n '/\[access\.users\]/,/^\[/p' "$CONFIG_FILE" 2>/dev/null) 2>/dev/null || echo "0")

echo "[telemt] Config: $CONFIG_FILE"
echo "[telemt] Listen: 0.0.0.0:${PORT:-993}"
echo "[telemt] TLS domain: ${TLS_DOMAIN:-unknown}"
echo "[telemt] Users: ${USER_COUNT}"
echo "================================================"

# Fix tmpfs directory ownership (mounted as root, telemt runs as moav)
chown -R moav:moav /app/tlsfront /app/cache 2>/dev/null || true

# Start telemt as moav user. cwd is /app/cache (an existing tmpfs) so the
# runtime observability snapshot — `beobachten.txt`, written relative to cwd —
# lands in a writable filesystem instead of failing every 15s against the
# read-only / root (#117). Config uses an absolute path for tls_front_dir, so
# the cwd change is safe.
cd /app/cache
exec su-exec moav telemt "$CONFIG_FILE"
