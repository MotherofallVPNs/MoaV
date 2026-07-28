#!/bin/sh

# =============================================================================
# AmneziaWG entrypoint - brings up AmneziaWG using awg commands
# Based on WireGuard entrypoint, adapted for AmneziaWG interface/tools
# =============================================================================

set -eu
# `set` is a POSIX SPECIAL builtin: when `set -o pipefail` fails, a
# non-interactive shell exits immediately -- `|| true` does NOT save it. dash
# (debian's /bin/sh) has no pipefail, so the naive guard silently killed the
# conduit container at line 3 with exit 2 and no output. Probe in a SUBSHELL,
# where the exit is contained, then enable it for real only if supported.
if ( set -o pipefail 2>/dev/null ); then set -o pipefail; fi

CONFIG_FILE="/etc/amneziawg/awg0.conf"
INTERFACE="awg0"

echo "[amneziawg] Starting AmneziaWG..."

# Check if config exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "[amneziawg] ERROR: Config file not found at $CONFIG_FILE"
    echo "[amneziawg] Run bootstrap first to generate AmneziaWG configuration"
    exit 1
fi

# Show config info (without private keys)
echo "[amneziawg] Config file: $CONFIG_FILE"
PEER_COUNT=$(grep -c '^\[Peer\]' "$CONFIG_FILE" || echo 0)
echo "[amneziawg] Peer count: $PEER_COUNT"

# IP forwarding is set via docker-compose sysctls
echo "[amneziawg] IP forwarding: $(cat /proc/sys/net/ipv4/ip_forward)"

# Clean up stale interface from previous run (prevents "device or resource busy")
if ip link show "$INTERFACE" > /dev/null 2>&1; then
    echo "[amneziawg] Cleaning up stale $INTERFACE interface..."
    ip link del "$INTERFACE" 2>/dev/null || true
    sleep 1
fi

# Start amneziawg-go userspace daemon in background
echo "[amneziawg] Starting amneziawg-go userspace daemon..."
amneziawg-go "$INTERFACE" &
AWG_PID=$!
sleep 1

# Verify interface was created
if ! ip link show "$INTERFACE" > /dev/null 2>&1; then
    echo "[amneziawg] ERROR: Failed to create interface $INTERFACE"
    exit 1
fi

# Parse config file - use cut -f2- to preserve = in base64 keys
PRIVATE_KEY=$(grep -i 'PrivateKey' "$CONFIG_FILE" | head -1 | cut -d'=' -f2- | tr -d ' \t\r\n' || true)
ADDRESS=$(grep -i 'Address' "$CONFIG_FILE" | head -1 | cut -d'=' -f2- | tr -d ' \t\r\n' || true)
LISTEN_PORT=$(grep -i 'ListenPort' "$CONFIG_FILE" | head -1 | cut -d'=' -f2- | tr -d ' \t\r\n' || true)
MTU=$(grep -i 'MTU' "$CONFIG_FILE" | head -1 | cut -d'=' -f2- | tr -d ' \t\r\n' || true)

# Parse AmneziaWG obfuscation params
JC=$(grep -i '^Jc' "$CONFIG_FILE" | head -1 | cut -d'=' -f2- | tr -d ' \t\r\n' || true)
JMIN=$(grep -i '^Jmin' "$CONFIG_FILE" | head -1 | cut -d'=' -f2- | tr -d ' \t\r\n' || true)
JMAX=$(grep -i '^Jmax' "$CONFIG_FILE" | head -1 | cut -d'=' -f2- | tr -d ' \t\r\n' || true)
S1=$(grep -i '^S1' "$CONFIG_FILE" | head -1 | cut -d'=' -f2- | tr -d ' \t\r\n' || true)
S2=$(grep -i '^S2' "$CONFIG_FILE" | head -1 | cut -d'=' -f2- | tr -d ' \t\r\n' || true)
H1=$(grep -i '^H1' "$CONFIG_FILE" | head -1 | cut -d'=' -f2- | tr -d ' \t\r\n' || true)
H2=$(grep -i '^H2' "$CONFIG_FILE" | head -1 | cut -d'=' -f2- | tr -d ' \t\r\n' || true)
H3=$(grep -i '^H3' "$CONFIG_FILE" | head -1 | cut -d'=' -f2- | tr -d ' \t\r\n' || true)
H4=$(grep -i '^H4' "$CONFIG_FILE" | head -1 | cut -d'=' -f2- | tr -d ' \t\r\n' || true)

# Fail loudly on missing essentials rather than proceeding to the monitor loop
# with an empty key -- that left the container reporting healthy while the
# tunnel was dead. The obfuscation params above are genuinely optional, which is
# exactly why every scraper needed `|| true`: absence is their normal case.
[ -n "$PRIVATE_KEY" ] || { echo "[amneziawg] ERROR: no PrivateKey in $CONFIG_FILE"; exit 1; }
[ -n "$ADDRESS" ]     || { echo "[amneziawg] ERROR: no Address in $CONFIG_FILE"; exit 1; }
[ -n "$LISTEN_PORT" ] || LISTEN_PORT=51821   # optional; awg default

echo "[amneziawg] Address: $ADDRESS"
echo "[amneziawg] Listen port: $LISTEN_PORT"
echo "[amneziawg] MTU: ${MTU:-default}"
echo "[amneziawg] Obfuscation: Jc=$JC S1=$S1 S2=$S2 H1=$H1 H2=$H2 H3=$H3 H4=$H4"

# Build awg set command with obfuscation params
AWG_SET_ARGS="private-key /dev/stdin listen-port $LISTEN_PORT"
[ -n "$JC" ] && AWG_SET_ARGS="$AWG_SET_ARGS jc $JC"
[ -n "$JMIN" ] && AWG_SET_ARGS="$AWG_SET_ARGS jmin $JMIN"
[ -n "$JMAX" ] && AWG_SET_ARGS="$AWG_SET_ARGS jmax $JMAX"
[ -n "$S1" ] && AWG_SET_ARGS="$AWG_SET_ARGS s1 $S1"
[ -n "$S2" ] && AWG_SET_ARGS="$AWG_SET_ARGS s2 $S2"
[ -n "$H1" ] && AWG_SET_ARGS="$AWG_SET_ARGS h1 $H1"
[ -n "$H2" ] && AWG_SET_ARGS="$AWG_SET_ARGS h2 $H2"
[ -n "$H3" ] && AWG_SET_ARGS="$AWG_SET_ARGS h3 $H3"
[ -n "$H4" ] && AWG_SET_ARGS="$AWG_SET_ARGS h4 $H4"

# Set private key and obfuscation params
echo "$PRIVATE_KEY" | awg set "$INTERFACE" $AWG_SET_ARGS

# Add peers from config
echo "[amneziawg] Adding peers..."
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
            echo "[amneziawg]   Adding peer: ${PEER_PUBKEY:0:20}..."
            awg set "$INTERFACE" peer "$PEER_PUBKEY" allowed-ips "$PEER_ALLOWED"
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
    echo "[amneziawg]   Adding peer: ${PEER_PUBKEY:0:20}..."
    awg set "$INTERFACE" peer "$PEER_PUBKEY" allowed-ips "$PEER_ALLOWED"
fi

# Set interface address and MTU, then bring up
echo "[amneziawg] Setting address $ADDRESS..."
ip addr add "$ADDRESS" dev "$INTERFACE"
[ -n "$MTU" ] && ip link set "$INTERFACE" mtu "$MTU"
ip link set "$INTERFACE" up

# Set up NAT and forwarding
echo "[amneziawg] Setting up NAT and forwarding..."
iptables -A FORWARD -i "$INTERFACE" -j ACCEPT
iptables -A FORWARD -o "$INTERFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -t nat -A POSTROUTING -o eth+ -j MASQUERADE

# Show interface status
echo "[amneziawg] Interface status:"
awg show "$INTERFACE"
ip addr show "$INTERFACE"

# Keep container running and monitor
echo "[amneziawg] AmneziaWG is running. Monitoring..."

# Trap SIGTERM to gracefully shutdown
cleanup() {
    echo "[amneziawg] Shutting down..."
    iptables -D FORWARD -i "$INTERFACE" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -o "$INTERFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    iptables -t nat -D POSTROUTING -o eth+ -j MASQUERADE 2>/dev/null || true
    ip link del "$INTERFACE" 2>/dev/null || true
    kill $AWG_PID 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT

# Keep running
KERNEL_MODE=0
while true; do
    sleep 60
    # Check if amneziawg-go process is still alive
    if ! kill -0 $AWG_PID 2>/dev/null; then
        # Process exited — check if interface is still up (kernel module took over)
        if ip link show "$INTERFACE" > /dev/null 2>&1; then
            if [ "$KERNEL_MODE" = "0" ]; then
                echo "[amneziawg] amneziawg-go exited but $INTERFACE is still up (kernel module active)"
                echo "[amneziawg] Continuing in kernel mode — no userspace daemon needed"
                KERNEL_MODE=1
            fi
        else
            # Interface is truly gone — try to restart
            echo "[amneziawg] Interface $INTERFACE is down, restarting..."
            sleep 1
            amneziawg-go "$INTERFACE" &
            AWG_PID=$!
            sleep 2
            if ip link show "$INTERFACE" > /dev/null 2>&1; then
                echo "$PRIVATE_KEY" | awg set "$INTERFACE" $AWG_SET_ARGS 2>/dev/null || true
                ip addr add "$ADDRESS" dev "$INTERFACE" 2>/dev/null || true
                [ -n "$MTU" ] && ip link set "$INTERFACE" mtu "$MTU" 2>/dev/null || true
                ip link set "$INTERFACE" up 2>/dev/null || true
                KERNEL_MODE=0
            else
                echo "[amneziawg] Failed to recreate interface, will retry..."
            fi
        fi
    fi
done
