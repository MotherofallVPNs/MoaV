#!/bin/bash
# TrustTunnel entrypoint script
set -euo pipefail

CONFIG_DIR="/etc/trusttunnel"
RUNTIME_DIR="/tmp/trusttunnel"
LOG_LEVEL="${LOG_LEVEL:-info}"

echo "[TrustTunnel] Starting TrustTunnel VPN endpoint..."

# Check for required config files
if [[ ! -f "$CONFIG_DIR/vpn.toml" ]]; then
    echo "[TrustTunnel] ERROR: vpn.toml not found in $CONFIG_DIR"
    exit 1
fi

if [[ ! -f "$CONFIG_DIR/hosts.toml" ]]; then
    echo "[TrustTunnel] ERROR: hosts.toml not found in $CONFIG_DIR"
    exit 1
fi

if [[ ! -f "$CONFIG_DIR/credentials.toml" ]]; then
    echo "[TrustTunnel] ERROR: credentials.toml not found in $CONFIG_DIR"
    exit 1
fi

# Copy configs to writable location (source may be read-only mount)
mkdir -p "$RUNTIME_DIR"
cp "$CONFIG_DIR/vpn.toml" "$RUNTIME_DIR/vpn.toml"
cp "$CONFIG_DIR/hosts.toml" "$RUNTIME_DIR/hosts.toml"
cp "$CONFIG_DIR/credentials.toml" "$RUNTIME_DIR/credentials.toml"

# Wait for certificates to be available
CERT_WAIT_TIMEOUT=60
CERT_WAIT_COUNT=0
DOMAIN="${DOMAIN:-}"

if [[ -n "$DOMAIN" ]]; then
    CERT_PATH="/certs/live/$DOMAIN/fullchain.pem"
    echo "[TrustTunnel] Waiting for TLS certificate at $CERT_PATH..."
    while [[ ! -f "$CERT_PATH" ]] && [[ $CERT_WAIT_COUNT -lt $CERT_WAIT_TIMEOUT ]]; do
        sleep 1
        # `$((...))` not `((...))`: the arithmetic-command form returns exit 1 when
        # the pre-increment value is 0, which `set -e` treats as fatal -- so the
        # container died one second into this very wait loop.
        CERT_WAIT_COUNT=$((CERT_WAIT_COUNT + 1))
    done

    if [[ ! -f "$CERT_PATH" ]]; then
        echo "[TrustTunnel] WARNING: Certificate not found after ${CERT_WAIT_TIMEOUT}s"
        echo "[TrustTunnel] TrustTunnel may fail to start without valid TLS certificates"
    else
        echo "[TrustTunnel] Certificate found!"
    fi
fi

echo "[TrustTunnel] Configuration:"
echo "  - Config: $RUNTIME_DIR/vpn.toml"
echo "  - Hosts: $RUNTIME_DIR/hosts.toml"
echo "  - Credentials: $RUNTIME_DIR/credentials.toml"
echo "  - Log level: $LOG_LEVEL"

# Fix volume ownership (volumes may be root-owned from previous runs)
chown -R moav:moav /state /var/log/trusttunnel 2>/dev/null || true

# Copy certs to a moav-readable location (originals are root:root 600, volume is read-only)
if [[ -d /certs/live ]]; then
    for d in /certs/live/*/; do
        dir="/tmp/certs/live/$(basename "$d")"
        mkdir -p "$dir"
        cp -rL "$d"* "$dir/" 2>/dev/null || true
    done
fi
chown -R moav:moav /tmp/certs 2>/dev/null || true

# Rewrite cert paths in runtime config to use the moav-readable copy
sed -i 's|/certs/|/tmp/certs/|g' "$RUNTIME_DIR/hosts.toml"
chown -R moav:moav "$RUNTIME_DIR"

# Start TrustTunnel endpoint as non-root
cd /opt/trusttunnel
exec setpriv --reuid=moav --regid=moav --init-groups \
    --inh-caps=+net_admin,+net_bind_service \
    --ambient-caps=+net_admin,+net_bind_service \
    ./trusttunnel_endpoint \
    --loglvl "$LOG_LEVEL" \
    "$RUNTIME_DIR/vpn.toml" \
    "$RUNTIME_DIR/hosts.toml"
