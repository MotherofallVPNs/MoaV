#!/bin/sh

# =============================================================================
# WireGuard entrypoint - brings up WireGuard without wg-quick
# Uses raw ip/wg commands to avoid wg-quick shell compatibility issues
# =============================================================================

set -eu
# `set` is a POSIX SPECIAL builtin: when `set -o pipefail` fails, a
# non-interactive shell exits immediately -- `|| true` does NOT save it. dash
# (debian's /bin/sh) has no pipefail, so the naive guard silently killed the
# conduit container at line 3 with exit 2 and no output. Probe in a SUBSHELL,
# where the exit is contained, then enable it for real only if supported.
if ( set -o pipefail 2>/dev/null ); then set -o pipefail; fi

CONFIG_FILE="/etc/wireguard/wg0.conf"
INTERFACE="wg0"

echo "[wireguard] Starting WireGuard..."

# Check if config exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "[wireguard] ERROR: Config file not found at $CONFIG_FILE"
    echo "[wireguard] Run bootstrap first to generate WireGuard configuration"
    exit 1
fi

# Show config info (without private keys)
echo "[wireguard] Config file: $CONFIG_FILE"
# grep -c already prints 0 on no match (and exits 1); `|| echo 0` appended a
# SECOND zero, so this used to report "Peer count: 0 0".
PEER_COUNT=$(grep -c '^\[Peer\]' "$CONFIG_FILE" 2>/dev/null || true)
[ -n "$PEER_COUNT" ] || PEER_COUNT=0
echo "[wireguard] Peer count: $PEER_COUNT"

# IP forwarding is set via docker-compose sysctls
echo "[wireguard] IP forwarding: $(cat /proc/sys/net/ipv4/ip_forward)"

# Parse config file - use cut -f2- to preserve = in base64 keys
# `|| true` on each: `grep | head -1` gets SIGPIPE (exit 141) once head closes
# the pipe -- which pipefail propagates even on a SUCCESSFUL match -- and grep
# exits 1 when the key is legitimately absent. Either would kill the container
# at startup under `set -e`.
PRIVATE_KEY=$(grep -i 'PrivateKey' "$CONFIG_FILE" | head -1 | cut -d'=' -f2- | tr -d ' \t\r\n' || true)
ADDRESS=$(grep -i 'Address' "$CONFIG_FILE" | head -1 | cut -d'=' -f2- | tr -d ' \t\r\n' || true)
LISTEN_PORT=$(grep -i 'ListenPort' "$CONFIG_FILE" | head -1 | cut -d'=' -f2- | tr -d ' \t\r\n' || true)

# Fail loudly on missing essentials. Previously an empty PRIVATE_KEY sailed past
# `wg set`, the script reached its monitor loop, and the container reported
# healthy while the tunnel was dead.
[ -n "$PRIVATE_KEY" ] || { echo "[wireguard] ERROR: no PrivateKey in $CONFIG_FILE"; exit 1; }
[ -n "$ADDRESS" ]     || { echo "[wireguard] ERROR: no Address in $CONFIG_FILE"; exit 1; }
[ -n "$LISTEN_PORT" ] || LISTEN_PORT=51820   # optional; wg default

echo "[wireguard] Address: $ADDRESS"
echo "[wireguard] Listen port: $LISTEN_PORT"

# Remove existing interface if present
ip link del "$INTERFACE" 2>/dev/null || true

# Create WireGuard interface
echo "[wireguard] Creating interface $INTERFACE..."
ip link add "$INTERFACE" type wireguard

# Set private key
echo "$PRIVATE_KEY" | wg set "$INTERFACE" private-key /dev/stdin listen-port "$LISTEN_PORT"

# Add peers from config
echo "[wireguard] Adding peers..."
IN_PEER=0
PEER_PUBKEY=""
PEER_ALLOWED=""

while IFS= read -r line || [ -n "$line" ]; do
    # Trim whitespace
    line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # Skip empty lines and comments
    [ -z "$line" ] && continue
    echo "$line" | grep -q '^#' && continue

    # Check for [Peer] section
    if echo "$line" | grep -qi '^\[Peer\]'; then
        # Add previous peer if exists
        if [ -n "$PEER_PUBKEY" ] && [ -n "$PEER_ALLOWED" ]; then
            echo "[wireguard]   Adding peer: ${PEER_PUBKEY:0:20}..."
            wg set "$INTERFACE" peer "$PEER_PUBKEY" allowed-ips "$PEER_ALLOWED"
        fi
        IN_PEER=1
        PEER_PUBKEY=""
        PEER_ALLOWED=""
        continue
    fi

    # Check for [Interface] section (exit peer mode)
    if echo "$line" | grep -qi '^\[Interface\]'; then
        IN_PEER=0
        continue
    fi

    # Parse peer settings
    if [ "$IN_PEER" = "1" ]; then
        if echo "$line" | grep -qi '^PublicKey'; then
            PEER_PUBKEY=$(echo "$line" | cut -d'=' -f2- | tr -d ' \t\r\n')
        elif echo "$line" | grep -qi '^AllowedIPs'; then
            PEER_ALLOWED=$(echo "$line" | cut -d'=' -f2- | tr -d ' \t\r\n')
        fi
    fi
done < "$CONFIG_FILE"

# Add last peer if exists
if [ -n "$PEER_PUBKEY" ] && [ -n "$PEER_ALLOWED" ]; then
    echo "[wireguard]   Adding peer: ${PEER_PUBKEY:0:20}..."
    wg set "$INTERFACE" peer "$PEER_PUBKEY" allowed-ips "$PEER_ALLOWED"
fi

# Set interface address and bring up
echo "[wireguard] Setting address $ADDRESS..."
ip addr add "$ADDRESS" dev "$INTERFACE"
ip link set "$INTERFACE" up

# Run PostUp iptables rules
echo "[wireguard] Setting up NAT and forwarding..."
iptables -A FORWARD -i "$INTERFACE" -j ACCEPT
iptables -A FORWARD -o "$INTERFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -t nat -A POSTROUTING -o eth+ -j MASQUERADE

# Show interface status
echo "[wireguard] Interface status:"
wg show "$INTERFACE"
ip addr show "$INTERFACE"

# Keep container running and monitor
echo "[wireguard] WireGuard is running. Monitoring..."

# Trap SIGTERM to gracefully shutdown
cleanup() {
    echo "[wireguard] Shutting down..."
    iptables -D FORWARD -i "$INTERFACE" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -o "$INTERFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    iptables -t nat -D POSTROUTING -o eth+ -j MASQUERADE 2>/dev/null || true
    ip link del "$INTERFACE" 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT

# Publish interface state for the metrics exporter.
#
# The exporter used to obtain this by mounting the raw Docker socket and running
# `docker exec wireguard wg show` -- unrestricted Docker API access, i.e. a path
# to host root, for a read-only metrics scrape. `wg show` genuinely needs this
# container's network namespace, so there is no API to query instead: the state
# is published here and the exporter reads a file.
#
# Written tmp-then-rename so a scrape can never observe a half-written file.
METRICS_STATE_DIR="${METRICS_STATE_DIR:-/var/lib/moav-metrics}"
METRICS_STATE_FILE="$METRICS_STATE_DIR/wg-show.txt"
publish_state() {
    [ -d "$METRICS_STATE_DIR" ] || return 0
    if wg show > "$METRICS_STATE_FILE.tmp" 2>/dev/null; then
        mv -f "$METRICS_STATE_FILE.tmp" "$METRICS_STATE_FILE" 2>/dev/null || true
    else
        rm -f "$METRICS_STATE_FILE.tmp" 2>/dev/null || true
    fi
}
publish_state

# Keep running.
# Publishes every 15s (Prometheus scrapes ~15s); the interface health check stays
# on its original 60s cadence, so this adds sampling without changing recovery
# behaviour.
_tick=0
while true; do
    sleep 15
    publish_state
    _tick=$((_tick + 1))
    [ "$((_tick % 4))" -eq 0 ] || continue
    # Check if interface is still up
    if ! wg show "$INTERFACE" > /dev/null 2>&1; then
        echo "[wireguard] Interface down, attempting restart..."
        ip link add "$INTERFACE" type wireguard 2>/dev/null || true
        echo "$PRIVATE_KEY" | wg set "$INTERFACE" private-key /dev/stdin listen-port "$LISTEN_PORT" 2>/dev/null || true
        ip addr add "$ADDRESS" dev "$INTERFACE" 2>/dev/null || true
        ip link set "$INTERFACE" up 2>/dev/null || true
    fi
done
