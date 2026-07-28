#!/bin/bash
# Xray-core entrypoint script (VLESS+XHTTP+Reality)
set -euo pipefail

CONFIG_FILE="/etc/xray/config.json"

echo "[Xray] Starting Xray-core (VLESS+XHTTP+Reality)..."

# Check for config
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[Xray] ERROR: config.json not found at $CONFIG_FILE"
    exit 1
fi

echo "[Xray] Configuration:"
echo "  - Config: $CONFIG_FILE"
# `|| true`: `xray version | head -1` raises SIGPIPE (141) once head closes the
# pipe, which pipefail turns into a fatal error -- on a purely cosmetic line.
echo "  - Version: $(xray version 2>/dev/null | head -1 || true)"

# Check for Stats API configuration
if grep -q '"api-in"' "$CONFIG_FILE"; then
    echo "  - Stats API: enabled (port 10085)"
else
    echo "  - Stats API: NOT configured (per-user traffic metrics will be unavailable)"
fi

# Start Xray
exec xray run -c "$CONFIG_FILE"
