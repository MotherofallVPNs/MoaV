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
    # [ -f ] is also false on EACCES; tell the two apart so nobody re-bootstraps a perms bug.
    _read_err=$(cat "$CONFIG_FILE" 2>&1 >/dev/null || true)
    case "$_read_err" in
        *[Pp]ermission\ denied*)
            echo "[amneziawg] ERROR: permission denied reading $CONFIG_FILE"
            echo "[amneziawg] $(ls -ldn "$(dirname "$CONFIG_FILE")" 2>&1)"
            echo "[amneziawg] This container has no DAC override, so root must OWN the config."
            echo "[amneziawg] Run 'moav start' to repair permissions (do not re-run bootstrap)."
            ;;
        *)
            echo "[amneziawg] ERROR: Config file not found at $CONFIG_FILE"
            echo "[amneziawg] Run bootstrap first to generate AmneziaWG configuration"
            ;;
    esac
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

# Fail loudly on missing essentials rather than proceeding to the monitor loop
# with an empty key -- that left the container reporting healthy while the
# tunnel was dead.
[ -n "$PRIVATE_KEY" ] || { echo "[amneziawg] ERROR: no PrivateKey in $CONFIG_FILE"; exit 1; }
[ -n "$ADDRESS" ]     || { echo "[amneziawg] ERROR: no Address in $CONFIG_FILE"; exit 1; }
[ -n "$LISTEN_PORT" ] || LISTEN_PORT=51821   # optional; awg default

echo "[amneziawg] Address: $ADDRESS"
echo "[amneziawg] Listen port: $LISTEN_PORT"
echo "[amneziawg] MTU: ${MTU:-default}"

# Load the private key + every obfuscation param (Jc/S1-S4/H1-H4 + the AWG3
# keys: HeaderProtectionKey, ContentPaddingAddition, timings) + all peers in one
# shot via `awg setconf`, which reads the config keys directly. This replaces a
# hand-rolled `awg set` arg builder + peer loop: the AWG3 `awg set` tokens are
# inconsistently named (hyphen vs underscore) and header-protection-key can't be
# piped alongside the private key. setconf only speaks wg-protocol keys, so strip
# the wg-quick-only directives (Address/DNS/MTU/PostUp/PostDown) — applied with
# ip(8)/iptables below.
STRIPPED=$(mktemp)
awk '
    /^[[:space:]]*\[Interface\]/ {section="i"; print; next}
    /^[[:space:]]*\[Peer\]/      {section="p"; print; next}
    /^[[:space:]]*$/             {print; next}
    /^[[:space:]]*#/             {print; next}
    section=="i" && /^[[:space:]]*(Address|DNS|MTU|PostUp|PostDown|SaveConfig)[[:space:]]*=/ {next}
    {print}
' "$CONFIG_FILE" > "$STRIPPED"

if ! awg setconf "$INTERFACE" "$STRIPPED"; then
    echo "[amneziawg] ERROR: awg setconf failed"
    cat "$STRIPPED"
    rm -f "$STRIPPED"
    exit 1
fi
rm -f "$STRIPPED"

# Peers were loaded by `awg setconf` above (it reads every [Peer] block).

# Egress isolation goes in while the interface is still down, ahead of the
# ACCEPT below. A failure is fatal: an exit must not come up unfiltered.
. /egress-isolation.sh
egress_firewall "$INTERFACE" || { echo "[amneziawg] ERROR: egress isolation rules failed (EGRESS_ISOLATION=off bypasses)"; exit 1; }

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
    egress_firewall_clear "$INTERFACE"
    ip link del "$INTERFACE" 2>/dev/null || true
    kill $AWG_PID 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT

# Publish interface state for the metrics exporter.
#
# The exporter used to obtain this by mounting the raw Docker socket and running
# `docker exec moav-amneziawg awg show` -- unrestricted Docker API access, i.e. a
# path to host root, for a read-only metrics scrape. `awg show` genuinely needs
# this container's network namespace, so there is no API to query instead: the
# state is published here and the exporter reads a file.
#
# Written tmp-then-rename so a scrape can never observe a half-written file.
METRICS_STATE_DIR="${METRICS_STATE_DIR:-/var/lib/moav-metrics}"
METRICS_STATE_FILE="$METRICS_STATE_DIR/awg-show.txt"
publish_state() {
    [ -d "$METRICS_STATE_DIR" ] || return 0
    if awg show > "$METRICS_STATE_FILE.tmp" 2>/dev/null; then
        mv -f "$METRICS_STATE_FILE.tmp" "$METRICS_STATE_FILE" 2>/dev/null || true
    else
        rm -f "$METRICS_STATE_FILE.tmp" 2>/dev/null || true
    fi
}
publish_state

# Keep running.
# Publishes every 15s (Prometheus scrapes ~15s); the daemon/interface health check
# below stays on its original 60s cadence, so this adds sampling without changing
# recovery behaviour.
KERNEL_MODE=0
_tick=0
while true; do
    sleep 15
    publish_state
    _tick=$((_tick + 1))
    [ "$((_tick % 4))" -eq 0 ] || continue
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
