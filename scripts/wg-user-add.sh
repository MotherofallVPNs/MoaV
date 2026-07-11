#!/bin/bash
set -euo pipefail

# =============================================================================
# Add a new WireGuard peer
# Usage: ./scripts/wg-user-add.sh <username> [--no-reload]
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

source scripts/lib/common.sh

# Parse arguments
USERNAME=""
NO_RELOAD=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-reload)
            NO_RELOAD=true
            shift
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            USERNAME="$1"
            shift
            ;;
    esac
done

if [[ -z "$USERNAME" ]]; then
    echo "Usage: $0 <username> [--no-reload]"
    echo "Example: $0 john"
    exit 1
fi

# Validate username
if [[ ! "$USERNAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    log_error "Invalid username. Use only letters, numbers, underscores, and hyphens."
    exit 1
fi

# Load environment
if [[ -f .env ]]; then
    set -a
    source .env
    set +a
fi

WG_CONFIG_DIR="configs/wireguard"
STATE_DIR="${STATE_DIR:-./state}"
OUTPUT_DIR="outputs/bundles/$USERNAME"
WG_NETWORK="10.66.66.0/24"
WG_NETWORK_V6="fd00:cafe:beef::/64"

# Check if WireGuard config exists
if [[ ! -f "$WG_CONFIG_DIR/wg0.conf" ]]; then
    log_error "WireGuard config not found. Run bootstrap first or enable WireGuard."
    exit 1
fi

# Create directories
mkdir -p "$OUTPUT_DIR"
mkdir -p "$STATE_DIR/users/$USERNAME"

# Check if peer already exists
if grep -q "# $USERNAME\$" "$WG_CONFIG_DIR/wg0.conf" 2>/dev/null; then
    log_error "WireGuard peer '$USERNAME' already exists."
    exit 1
fi

log_info "Adding WireGuard peer '$USERNAME'..."

# Find next available IP
# Get used IPs from config file AND running interface (prevent collisions if out of sync)
USED_IPS=$(grep 'AllowedIPs = 10\.66\.66\.' "$WG_CONFIG_DIR/wg0.conf" 2>/dev/null | sed 's/.*10\.66\.66\.\([0-9]*\).*/\1/' || echo "")
if docker compose ps wireguard --status running 2>/dev/null | tail -n +2 | grep -q .; then
    RUNNING_IPS=$(docker compose exec -T wireguard wg show wg0 allowed-ips 2>/dev/null | grep '10\.66\.66\.' | sed 's/.*10\.66\.66\.\([0-9]*\).*/\1/' || echo "")
    USED_IPS="$USED_IPS $RUNNING_IPS"
fi
NEXT_IP=2  # Start from .2 (server is .1)

for ip in $USED_IPS; do
    if [[ $ip -ge $NEXT_IP ]]; then
        NEXT_IP=$((ip + 1))
    fi
done

if [[ $NEXT_IP -gt 254 ]]; then
    log_error "No available IPs in WireGuard network"
    exit 1
fi

CLIENT_IP="10.66.66.$NEXT_IP"
log_info "Assigned IP: $CLIENT_IP"

# Assign IPv6 if server has IPv6
CLIENT_IP_V6=""
if [[ -z "${SERVER_IPV6:-}" ]] && [[ "${SERVER_IPV6:-}" != "disabled" ]]; then
    SERVER_IPV6=$(curl -6 -s --max-time 3 https://api6.ipify.org 2>/dev/null || echo "")
fi
[[ "${SERVER_IPV6:-}" == "disabled" ]] && SERVER_IPV6=""

if [[ -n "$SERVER_IPV6" ]]; then
    CLIENT_IP_V6="fd00:cafe:beef::$NEXT_IP"
    log_info "Assigned IPv6: $CLIENT_IP_V6"
fi

# Generate client keys using wg command in wireguard container or locally
if docker compose ps wireguard --status running 2>/dev/null | tail -n +2 | grep -q .; then
    # Use running WireGuard container
    CLIENT_PRIVATE_KEY=$(docker compose exec -T wireguard wg genkey)
    CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | docker compose exec -T wireguard wg pubkey)
elif command -v wg &>/dev/null; then
    # Use local wg command
    CLIENT_PRIVATE_KEY=$(wg genkey)
    CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)
else
    # Generate using docker
    CLIENT_PRIVATE_KEY=$(docker run --rm lscr.io/linuxserver/wireguard wg genkey 2>/dev/null)
    CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | docker run --rm -i lscr.io/linuxserver/wireguard wg pubkey 2>/dev/null)
fi

# Save credentials
cat > "$STATE_DIR/users/$USERNAME/wireguard.env" <<EOF
WG_PRIVATE_KEY=$CLIENT_PRIVATE_KEY
WG_PUBLIC_KEY=$CLIENT_PUBLIC_KEY
WG_CLIENT_IP=$CLIENT_IP
WG_CLIENT_IP_V6=$CLIENT_IP_V6
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# Get server public key - prefer from running WireGuard, fallback to file
SERVER_PUBLIC_KEY=""

# If WireGuard is running, get the actual public key and sync it
if docker compose ps wireguard --status running 2>/dev/null | tail -n +2 | grep -q .; then
    SERVER_PUBLIC_KEY=$(docker compose exec -T wireguard wg show wg0 public-key 2>/dev/null | tr -d '\r\n')
    if [[ -n "$SERVER_PUBLIC_KEY" ]]; then
        # Best-effort sync to server.pub. If the caller (e.g. the admin container
        # running as uid 1000) only has read perms on configs/ — set by bootstrap
        # via `chown -R 0:1000` + `chmod -R g+r` — the write fails and we proceed
        # with the in-memory key, which is already authoritative.
        if echo "$SERVER_PUBLIC_KEY" > "$WG_CONFIG_DIR/server.pub" 2>/dev/null; then
            log_info "Synced server public key from running WireGuard"
        else
            log_info "Could not write $WG_CONFIG_DIR/server.pub (read-only); using in-memory key"
        fi
    fi
fi

# Fallback to file if not running or couldn't get key
if [[ -z "$SERVER_PUBLIC_KEY" ]]; then
    SERVER_PUBLIC_KEY=$(cat "$WG_CONFIG_DIR/server.pub" 2>/dev/null | tr -d '\r\n')
fi

if [[ -z "$SERVER_PUBLIC_KEY" ]]; then
    log_error "Server public key not found. Is WireGuard configured?"
    exit 1
fi

log_info "Using server public key: $SERVER_PUBLIC_KEY"

# Get server IP
SERVER_IP="${SERVER_IP:-$(curl -s --max-time 5 https://api.ipify.org || echo "YOUR_SERVER_IP")}"

# Build AllowedIPs (IPv4 + optional IPv6)
ALLOWED_IPS="$CLIENT_IP/32"
if [[ -n "$CLIENT_IP_V6" ]]; then
    ALLOWED_IPS="$CLIENT_IP/32, $CLIENT_IP_V6/128"
fi

# Add peer to server config file
cat >> "$WG_CONFIG_DIR/wg0.conf" <<EOF

[Peer]
# $USERNAME
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = $ALLOWED_IPS
EOF

log_info "Added peer to wg0.conf"

# Get WireGuard port from env or default
WG_PORT="${PORT_WIREGUARD:-51820}"

# Build client address (IPv4 + optional IPv6)
CLIENT_ADDRESSES="$CLIENT_IP/32"
if [[ -n "$CLIENT_IP_V6" ]]; then
    CLIENT_ADDRESSES="$CLIENT_IP/32, $CLIENT_IP_V6/128"
fi

# Generate DIRECT client config (simple, for mobile) - IPv4 endpoint
cat > "$OUTPUT_DIR/wireguard.conf" <<EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $CLIENT_ADDRESSES
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${SERVER_IP}:${WG_PORT}
PersistentKeepalive = 25
EOF

log_info "Generated direct WireGuard config"

# Generate IPv6 endpoint config if server has IPv6
if [[ -n "$SERVER_IPV6" ]]; then
    cat > "$OUTPUT_DIR/wireguard-ipv6.conf" <<EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $CLIENT_ADDRESSES
DNS = 1.1.1.1, 2606:4700:4700::1111

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = [${SERVER_IPV6}]:${WG_PORT}
PersistentKeepalive = 25
EOF
    log_info "Generated IPv6 endpoint WireGuard config"
fi

# Generate wstunnel config (for restrictive networks)
cat > "$OUTPUT_DIR/wireguard-wstunnel.conf" <<EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $CLIENT_ADDRESSES
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 127.0.0.1:51820
PersistentKeepalive = 25
EOF

log_info "Generated wstunnel-mode config"

# Generate wstunnel instructions
WSTUNNEL_CMD="$(wstunnel_client_cmd)"
if [[ -n "${DOMAIN:-}" && "${DOMAIN:-}" != "YOUR_DOMAIN" ]]; then
    WSTUNNEL_SERVER_URL="wss://${DOMAIN}:8080"
else
    WSTUNNEL_SERVER_URL="ws://${SERVER_IP}:8080"
fi
cat > "$OUTPUT_DIR/wireguard-instructions.txt" <<EOF
# WireGuard over WebSocket (wstunnel) Instructions
# ================================================
#
# This setup tunnels WireGuard through WebSocket to bypass firewalls.
# You need to run wstunnel client BEFORE connecting WireGuard.

# Step 1: Download wstunnel
# -------------------------
# - Windows/Mac/Linux: https://github.com/erebe/wstunnel/releases
# - Or: cargo install wstunnel

# Step 2: Run wstunnel client
# ---------------------------
# This creates a local UDP tunnel to the server:

${WSTUNNEL_CMD}

# Step 3: Connect WireGuard
# -------------------------
# Import wireguard-wstunnel.conf into your WireGuard app.
# The config points to 127.0.0.1:51820 (the local wstunnel endpoint).

# For Android/iOS:
# ----------------
# 1. Install WireGuard app AND a wstunnel-compatible app (or Termux)
# 2. Run wstunnel in background
# 3. Then activate WireGuard

# For desktop:
# ------------
# Terminal 1: ${WSTUNNEL_CMD}
# Terminal 2: wg-quick up ./wireguard-wstunnel.conf

# Server info:
# ------------
# wstunnel server: ${WSTUNNEL_SERVER_URL}
# Your WireGuard IP: $CLIENT_IP
EOF

log_info "Generated wstunnel instructions"

# Hot-add peer to running WireGuard if available (unless --no-reload)
if [[ "$NO_RELOAD" != "true" ]]; then
    if docker compose ps wireguard --status running 2>/dev/null | tail -n +2 | grep -q .; then
        log_info "Adding peer to running WireGuard..."

        # Use wg set to add peer dynamically
        if docker compose exec -T wireguard wg set wg0 peer "$CLIENT_PUBLIC_KEY" allowed-ips "$ALLOWED_IPS" 2>/dev/null; then
            log_info "Peer added to running WireGuard (hot reload)"
        else
            log_info "Hot reload failed, you may need to restart WireGuard"
            log_info "Run: docker compose --profile wireguard restart wireguard"
        fi
    else
        log_info "WireGuard not running, config will apply on next start"
    fi
fi

# Display results
echo ""
log_info "=== WireGuard peer '$USERNAME' created ==="
echo ""
echo "Client IP: $CLIENT_IP"
if [[ -n "$CLIENT_IP_V6" ]]; then
    echo "Client IPv6: $CLIENT_IP_V6"
fi
echo ""
echo "Configs generated:"
echo "  - wireguard.conf          (direct mode - IPv4 endpoint)"
if [[ -n "$SERVER_IPV6" ]]; then
    echo "  - wireguard-ipv6.conf     (direct mode - IPv6 endpoint)"
fi
echo "  - wireguard-wstunnel.conf (wstunnel mode - for restrictive networks)"
echo "  - wireguard-instructions.txt (setup guide)"
echo ""

# Generate QR images for user bundle
if command -v qrencode &>/dev/null; then
    qrencode -o "$OUTPUT_DIR/wireguard-qr.png" -s 6 -r "$OUTPUT_DIR/wireguard.conf" 2>/dev/null && \
        log_info "QR image saved to: $OUTPUT_DIR/wireguard-qr.png"

    # IPv6 QR code
    if [[ -n "$SERVER_IPV6" ]]; then
        qrencode -o "$OUTPUT_DIR/wireguard-ipv6-qr.png" -s 6 -r "$OUTPUT_DIR/wireguard-ipv6.conf" 2>/dev/null && \
            log_info "IPv6 QR image saved to: $OUTPUT_DIR/wireguard-ipv6-qr.png"
    fi

    # wstunnel QR code
    qrencode -o "$OUTPUT_DIR/wireguard-wstunnel-qr.png" -s 6 -r "$OUTPUT_DIR/wireguard-wstunnel.conf" 2>/dev/null && \
        log_info "wstunnel QR image saved to: $OUTPUT_DIR/wireguard-wstunnel-qr.png"
fi

echo ""
echo "=== Direct Config (use this for mobile) ==="
cat "$OUTPUT_DIR/wireguard.conf"
echo ""
echo "=== wstunnel Mode (for restrictive networks) ==="
echo "Run wstunnel first:"
echo "  ${WSTUNNEL_CMD}"
echo "Then use wireguard-wstunnel.conf"
