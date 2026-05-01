#!/bin/bash
set -euo pipefail

# =============================================================================
# Add a new user to sing-box (Reality, Trojan, Hysteria2)
# Usage: ./scripts/singbox-user-add.sh <username> [--no-reload]
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

CONFIG_FILE="configs/sing-box/config.json"
STATE_DIR="${STATE_DIR:-./state}"
OUTPUT_DIR="outputs/bundles/$USERNAME"

# Check if config exists
if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "sing-box config not found. Run bootstrap first."
    exit 1
fi

# Create directories (may need sudo if Docker created parent as root)
mkdir -p "$OUTPUT_DIR" 2>/dev/null || sudo mkdir -p "$OUTPUT_DIR" 2>/dev/null || true
mkdir -p "$STATE_DIR/users/$USERNAME" 2>/dev/null || sudo mkdir -p "$STATE_DIR/users/$USERNAME" 2>/dev/null || true
# Ensure writable
if [[ ! -w "$STATE_DIR/users/$USERNAME" ]]; then
    sudo chmod 777 "$STATE_DIR/users/$USERNAME" 2>/dev/null || true
fi

# Check if user already exists in config
if grep -q "\"name\":\"$USERNAME\"" "$CONFIG_FILE" 2>/dev/null; then
    log_error "User '$USERNAME' already exists in sing-box config."
    exit 1
fi

log_info "Adding user '$USERNAME' to sing-box..."

# Generate credentials
USER_UUID=$(docker compose exec -T sing-box sing-box generate uuid 2>/dev/null || uuidgen | tr '[:upper:]' '[:lower:]')
USER_PASSWORD=$(openssl rand -base64 18 | tr -d '/+=' | head -c 24)

# Save credentials
cat > "$STATE_DIR/users/$USERNAME/credentials.env" <<EOF
USER_ID=$USERNAME
USER_UUID=$USER_UUID
USER_PASSWORD=$USER_PASSWORD
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# Shadowsocks-2022 per-user PSK (only if SS is enabled)
if [[ "${ENABLE_SS:-false}" == "true" ]]; then
    case "${SS_METHOD:-2022-blake3-chacha20-poly1305}" in
        2022-blake3-aes-128-gcm) SS_PSK_BYTES=16 ;;
        *)                       SS_PSK_BYTES=32 ;;
    esac
    SS_USER_PSK=$(openssl rand -base64 "$SS_PSK_BYTES")
    cat > "$STATE_DIR/users/$USERNAME/shadowsocks.env" <<EOF
SS_USER_PSK=$SS_USER_PSK
EOF
fi

log_info "Generated credentials for $USERNAME"

# Add user to sing-box config using jq
# Create temp file with updated config
TEMP_CONFIG=$(mktemp)

# Add to Reality users (vless)
jq --arg name "$USERNAME" --arg uuid "$USER_UUID" \
    '.inbounds |= map(if .tag == "vless-reality-in" then .users += [{"name": $name, "uuid": $uuid, "flow": "xtls-rprx-vision"}] else . end)' \
    "$CONFIG_FILE" > "$TEMP_CONFIG"

# Add to Trojan users
jq --arg name "$USERNAME" --arg pass "$USER_PASSWORD" \
    '.inbounds |= map(if .tag == "trojan-tls-in" then .users += [{"name": $name, "password": $pass}] else . end)' \
    "$TEMP_CONFIG" > "${TEMP_CONFIG}.2"
mv -f "${TEMP_CONFIG}.2" "$TEMP_CONFIG"

# Add to Hysteria2 users
jq --arg name "$USERNAME" --arg pass "$USER_PASSWORD" \
    '.inbounds |= map(if .tag == "hysteria2-in" then .users += [{"name": $name, "password": $pass}] else . end)' \
    "$TEMP_CONFIG" > "${TEMP_CONFIG}.2"
mv -f "${TEMP_CONFIG}.2" "$TEMP_CONFIG"

# Add to VLESS WS users (CDN)
jq --arg name "$USERNAME" --arg uuid "$USER_UUID" \
    '.inbounds |= map(if .tag == "vless-ws-in" then .users += [{"name": $name, "uuid": $uuid}] else . end)' \
    "$TEMP_CONFIG" > "${TEMP_CONFIG}.2"
mv -f "${TEMP_CONFIG}.2" "$TEMP_CONFIG"

# Add to Shadowsocks-2022 users (only if the inbound exists in the current config)
if [[ "${ENABLE_SS:-false}" == "true" ]] && [[ -n "${SS_USER_PSK:-}" ]] \
        && jq -e '.inbounds[] | select(.tag == "shadowsocks-in")' "$TEMP_CONFIG" >/dev/null 2>&1; then
    jq --arg name "$USERNAME" --arg pass "$SS_USER_PSK" \
        '.inbounds |= map(if .tag == "shadowsocks-in" then .users += [{"name": $name, "password": $pass}] else . end)' \
        "$TEMP_CONFIG" > "${TEMP_CONFIG}.2"
    mv -f "${TEMP_CONFIG}.2" "$TEMP_CONFIG"
fi

# Validate the new config
if ! jq empty "$TEMP_CONFIG" 2>/dev/null; then
    log_error "Generated invalid JSON config"
    rm -f "$TEMP_CONFIG"
    exit 1
fi

# Apply the config
mv -f "$TEMP_CONFIG" "$CONFIG_FILE"

log_info "Added $USERNAME to sing-box config"

# Load keys for client config generation
if [[ -f "$STATE_DIR/keys/reality.env" ]]; then
    source "$STATE_DIR/keys/reality.env"
else
    # Try docker volume (load all keys including private for derivation fallback)
    REALITY_ENV_CONTENT=$(docker run --rm -v moav_moav_state:/state alpine cat /state/keys/reality.env 2>/dev/null || echo "")
    REALITY_PRIVATE_KEY=$(echo "$REALITY_ENV_CONTENT" | grep REALITY_PRIVATE_KEY | cut -d= -f2)
    REALITY_PUBLIC_KEY=$(echo "$REALITY_ENV_CONTENT" | grep REALITY_PUBLIC_KEY | cut -d= -f2)
    REALITY_SHORT_ID=$(echo "$REALITY_ENV_CONTENT" | grep REALITY_SHORT_ID | cut -d= -f2)
fi

# If public key is missing but private key exists, derive it
if [[ -z "${REALITY_PUBLIC_KEY:-}" ]] && [[ -n "${REALITY_PRIVATE_KEY:-}" ]]; then
    log_info "Reality public key missing, deriving from private key..."
    # x25519 uses the same curve as WireGuard — convert base64url→base64, use wg pubkey, convert back
    REALITY_KEY_B64=$(echo "${REALITY_PRIVATE_KEY}==" | tr '_-' '/+' | head -c 44)
    if docker compose ps wireguard --status running 2>/dev/null | tail -n +2 | grep -q .; then
        REALITY_PUBLIC_KEY=$(echo "$REALITY_KEY_B64" | docker compose exec -T wireguard wg pubkey 2>/dev/null | tr '/+' '_-' | sed 's/=*$//' || echo "")
    elif command -v wg &>/dev/null; then
        REALITY_PUBLIC_KEY=$(echo "$REALITY_KEY_B64" | wg pubkey 2>/dev/null | tr '/+' '_-' | sed 's/=*$//' || echo "")
    fi
    if [[ -n "$REALITY_PUBLIC_KEY" ]]; then
        log_info "Derived Reality public key: ${REALITY_PUBLIC_KEY:0:10}..."
        # Save it back so future runs don't need to derive again
        if [[ -f "$STATE_DIR/keys/reality.env" ]]; then
            sed -i "s/^REALITY_PUBLIC_KEY=.*/REALITY_PUBLIC_KEY=$REALITY_PUBLIC_KEY/" "$STATE_DIR/keys/reality.env"
        fi
        # Also update Docker volume
        docker run --rm -v moav_moav_state:/state alpine sh -c \
            "sed -i 's/^REALITY_PUBLIC_KEY=.*/REALITY_PUBLIC_KEY=$REALITY_PUBLIC_KEY/' /state/keys/reality.env" 2>/dev/null || true
    else
        log_warn "Could not derive Reality public key - Reality links will be incomplete"
    fi
fi

# Load Hysteria2 obfuscation password
if [[ -f "$STATE_DIR/keys/clash-api.env" ]]; then
    source "$STATE_DIR/keys/clash-api.env"
else
    # Try docker volume
    HYSTERIA2_OBFS_PASSWORD=$(docker run --rm -v moav_moav_state:/state alpine cat /state/keys/clash-api.env 2>/dev/null | grep HYSTERIA2_OBFS_PASSWORD | cut -d= -f2 || echo "")
fi

# Get server IP
SERVER_IP="${SERVER_IP:-$(curl -s --max-time 5 https://api.ipify.org || echo "YOUR_SERVER_IP")}"

# Get server IPv6 if available
if [[ -z "${SERVER_IPV6:-}" ]] && [[ "${SERVER_IPV6:-}" != "disabled" ]]; then
    SERVER_IPV6=$(curl -6 -s --max-time 3 https://api6.ipify.org 2>/dev/null || echo "")
fi
[[ "${SERVER_IPV6:-}" == "disabled" ]] && SERVER_IPV6=""

# Parse Reality target
REALITY_TARGET="${REALITY_TARGET:-dl.google.com:443}"
REALITY_TARGET_HOST=$(echo "$REALITY_TARGET" | cut -d: -f1)

# -----------------------------------------------------------------------------
# Generate client configs
# -----------------------------------------------------------------------------

# Reality link (IPv4)
REALITY_LINK="vless://${USER_UUID}@${SERVER_IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_TARGET_HOST}&fp=random&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp#MoaV-Reality-${USERNAME}"
echo "$REALITY_LINK" > "$OUTPUT_DIR/reality.txt"

# Trojan link (IPv4) — only if domain is set (requires TLS cert)
if [[ -n "${DOMAIN:-}" ]]; then
    TROJAN_LINK="trojan://${USER_PASSWORD}@${SERVER_IP}:8443?security=tls&sni=${DOMAIN}&type=tcp#MoaV-Trojan-${USERNAME}"
    echo "$TROJAN_LINK" > "$OUTPUT_DIR/trojan.txt"
fi

# Hysteria2 link (IPv4) — only if domain is set (requires TLS cert)
if [[ -n "${DOMAIN:-}" ]]; then
    HY2_LINK="hysteria2://${USER_PASSWORD}@${SERVER_IP}:443?sni=${DOMAIN}&obfs=salamander&obfs-password=${HYSTERIA2_OBFS_PASSWORD}#MoaV-Hysteria2-${USERNAME}"
    echo "$HY2_LINK" > "$OUTPUT_DIR/hysteria2.txt"
fi

# Generate IPv6 links if available
if [[ -n "$SERVER_IPV6" ]]; then
    REALITY_LINK_V6="vless://${USER_UUID}@[${SERVER_IPV6}]:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_TARGET_HOST}&fp=random&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp#MoaV-Reality-${USERNAME}-IPv6"
    echo "$REALITY_LINK_V6" > "$OUTPUT_DIR/reality-ipv6.txt"

    if [[ -n "${DOMAIN:-}" ]]; then
        TROJAN_LINK_V6="trojan://${USER_PASSWORD}@[${SERVER_IPV6}]:8443?security=tls&sni=${DOMAIN}&type=tcp#MoaV-Trojan-${USERNAME}-IPv6"
        echo "$TROJAN_LINK_V6" > "$OUTPUT_DIR/trojan-ipv6.txt"

        HY2_LINK_V6="hysteria2://${USER_PASSWORD}@[${SERVER_IPV6}]:443?sni=${DOMAIN}&obfs=salamander&obfs-password=${HYSTERIA2_OBFS_PASSWORD}#MoaV-Hysteria2-${USERNAME}-IPv6"
        echo "$HY2_LINK_V6" > "$OUTPUT_DIR/hysteria2-ipv6.txt"
    fi

    log_info "Generated IPv6 links (server: $SERVER_IPV6)"
fi

# Generate QR codes
if command -v qrencode &>/dev/null; then
    qrencode -o "$OUTPUT_DIR/reality-qr.png" -s 6 "$REALITY_LINK" 2>/dev/null || true
    [[ -n "${TROJAN_LINK:-}" ]] && qrencode -o "$OUTPUT_DIR/trojan-qr.png" -s 6 "$TROJAN_LINK" 2>/dev/null || true
    [[ -n "${HY2_LINK:-}" ]] && qrencode -o "$OUTPUT_DIR/hysteria2-qr.png" -s 6 "$HY2_LINK" 2>/dev/null || true

    # IPv6 QR codes
    if [[ -n "$SERVER_IPV6" ]]; then
        qrencode -o "$OUTPUT_DIR/reality-ipv6-qr.png" -s 6 "$REALITY_LINK_V6" 2>/dev/null || true
        [[ -n "${TROJAN_LINK_V6:-}" ]] && qrencode -o "$OUTPUT_DIR/trojan-ipv6-qr.png" -s 6 "$TROJAN_LINK_V6" 2>/dev/null || true
        [[ -n "${HY2_LINK_V6:-}" ]] && qrencode -o "$OUTPUT_DIR/hysteria2-ipv6-qr.png" -s 6 "$HY2_LINK_V6" 2>/dev/null || true
    fi
fi

# Generate CDN VLESS+WS link (if CDN configured)
# Construct CDN_DOMAIN from CDN_SUBDOMAIN + DOMAIN if not explicitly set
CDN_DOMAIN="${CDN_DOMAIN:-$(grep -E '^CDN_DOMAIN=' .env 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "")}"
if [[ -z "$CDN_DOMAIN" ]]; then
    CDN_SUBDOMAIN="${CDN_SUBDOMAIN:-$(grep -E '^CDN_SUBDOMAIN=' .env 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "")}"
    DOMAIN_FROM_ENV="${DOMAIN:-$(grep -E '^DOMAIN=' .env 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "")}"
    if [[ -n "$CDN_SUBDOMAIN" && -n "$DOMAIN_FROM_ENV" ]]; then
        CDN_DOMAIN="${CDN_SUBDOMAIN}.${DOMAIN_FROM_ENV}"
    fi
fi
# Load CDN WS path: .env → state file (bootstrap-generated) → fallback
CDN_WS_PATH="${CDN_WS_PATH:-$(grep -E '^CDN_WS_PATH=' .env 2>/dev/null | cut -d= -f2 | tr -d '"' || true)}"
if [[ -z "${CDN_WS_PATH:-}" ]]; then
    # Check bootstrap-generated state (persisted random path)
    CDN_WS_PATH=$(docker run --rm -v moav_moav_state:/state alpine cat /state/keys/cdn.env 2>/dev/null | grep '^CDN_WS_PATH=' | cut -d= -f2 || true)
fi
CDN_WS_PATH="${CDN_WS_PATH:-/ws}"
CDN_TRANSPORT="${CDN_TRANSPORT:-$(grep -E '^CDN_TRANSPORT=' .env 2>/dev/null | cut -d= -f2 | tr -d '"' || true)}"
CDN_TRANSPORT="${CDN_TRANSPORT:-httpupgrade}"
CDN_SNI="${CDN_SNI:-$(grep -E '^CDN_SNI=' .env 2>/dev/null | cut -d= -f2 | tr -d '"' || true)}"
CDN_SNI="${CDN_SNI:-${DOMAIN_FROM_ENV:-}}"
CDN_ADDRESS="${CDN_ADDRESS:-$(grep -E '^CDN_ADDRESS=' .env 2>/dev/null | cut -d= -f2 | tr -d '"' || true)}"
CDN_ADDRESS="${CDN_ADDRESS:-${CDN_DOMAIN}}"

if [[ -n "$CDN_DOMAIN" ]]; then
    CDN_LINK="vless://${USER_UUID}@${CDN_ADDRESS}:443?security=tls&type=${CDN_TRANSPORT}&path=${CDN_WS_PATH}&sni=${CDN_SNI}&host=${CDN_DOMAIN}&fp=random&alpn=http/1.1#MoaV-CDN-${USERNAME}"
    echo "$CDN_LINK" > "$OUTPUT_DIR/cdn-vless.txt"

    if command -v qrencode &>/dev/null; then
        qrencode -o "$OUTPUT_DIR/cdn-vless-qr.png" -s 6 "$CDN_LINK" 2>/dev/null || true
    fi

    log_info "Generated CDN VLESS link (transport: $CDN_TRANSPORT, domain: $CDN_DOMAIN)"
fi

# Add user to TrustTunnel (if config exists)
TRUSTTUNNEL_CREDS="configs/trusttunnel/credentials.toml"
if [[ -f "$TRUSTTUNNEL_CREDS" ]]; then
    log_info "Adding $USERNAME to TrustTunnel..."

    # Check if user already exists in TrustTunnel
    if grep -q "username = \"$USERNAME\"" "$TRUSTTUNNEL_CREDS" 2>/dev/null; then
        log_info "User '$USERNAME' already exists in TrustTunnel, skipping..."
    else
        # Append new user to credentials.toml
        cat >> "$TRUSTTUNNEL_CREDS" <<EOF

[[client]]
username = "$USERNAME"
password = "$USER_PASSWORD"
EOF
        log_info "Added $USERNAME to TrustTunnel credentials"
    fi

    # Get server IP if not set
    if [[ -z "${SERVER_IP:-}" ]]; then
        SERVER_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
    fi

    # Generate full TOML config for CLI client
    cat > "$OUTPUT_DIR/trusttunnel.toml" <<EOF
# TrustTunnel Client Configuration for $USERNAME
# Generated by MoaV

loglevel = "info"
vpn_mode = "general"
killswitch_enabled = false
killswitch_allow_ports = []
post_quantum_group_enabled = true
exclusions = []

[endpoint]
hostname = "${DOMAIN}"
dns_upstreams = ["tls://1.1.1.1"]
addresses = ["${SERVER_IP}:4443"]
has_ipv6 = false
username = "${USERNAME}"
password = "${USER_PASSWORD}"
client_random = ""
skip_verification = false
certificate = ""
upstream_protocol = "http2"
upstream_fallback_protocol = "http3"
anti_dpi = false

[listener.tun]
bound_if = ""
included_routes = ["0.0.0.0/0", "2000::/3"]
excluded_routes = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
mtu_size = 1280
EOF

    # Generate human-readable text file
    cat > "$OUTPUT_DIR/trusttunnel.txt" <<EOF
TrustTunnel Configuration for $USERNAME
======================================

IP Address: ${SERVER_IP}:4443
Domain: ${DOMAIN}
Username: ${USERNAME}
Password: ${USER_PASSWORD}
DNS Servers: tls://1.1.1.1

CLI Client:
-----------
1. Download from: https://github.com/TrustTunnel/TrustTunnelClient/releases
2. Run: trusttunnel_client trusttunnel.toml

Mobile/Desktop App:
-------------------
1. Download TrustTunnel from app store or https://trusttunnel.org/
2. Add new VPN with the settings above
3. Connect

Note: TrustTunnel supports HTTP/2 and HTTP/3 (QUIC) transports,
which look like regular HTTPS traffic to network observers.
EOF

    cat > "$OUTPUT_DIR/trusttunnel.json" <<EOF
{
  "ip_address": "${SERVER_IP}:4443",
  "domain": "${DOMAIN}",
  "username": "${USERNAME}",
  "password": "${USER_PASSWORD}",
  "dns_servers": ["tls://1.1.1.1"]
}
EOF

    log_info "Generated TrustTunnel client config (toml + txt + json)"
fi

# Add user to Xray (XHTTP) if config exists and enabled
XRAY_CONFIG="configs/xray/config.json"
if [[ "${ENABLE_XHTTP:-true}" == "true" ]] && [[ -f "$XRAY_CONFIG" ]]; then
    log_info "Adding $USERNAME to Xray (XHTTP)..."

    # Check if user already exists (search by UUID in the vless-xhttp-reality inbound)
    if jq -e --arg uuid "$USER_UUID" \
        '[.inbounds[] | select(.tag == "vless-xhttp-reality")] | .[0].settings.clients[] | select(.id == $uuid)' \
        "$XRAY_CONFIG" >/dev/null 2>&1; then
        log_info "User '$USERNAME' already exists in Xray config, skipping..."
    else
        # Add new client entry to the vless-xhttp-reality inbound (flow MUST be empty for XHTTP)
        # Add to ALL vless inbounds (xhttp-reality AND xdns)
        jq --arg id "$USER_UUID" --arg email "${USERNAME}@moav" \
            '(.inbounds[] | select(.protocol == "vless" and .tag != null and (.tag | startswith("vless-")))).settings.clients += [{"id": $id, "email": $email, "flow": ""}]' \
            "$XRAY_CONFIG" > /tmp/xray.tmp && mv -f /tmp/xray.tmp "$XRAY_CONFIG"
        log_info "Added $USERNAME to Xray config (all VLESS inbounds)"
    fi

    # Generate XHTTP client configs
    _xhttp_target="${XHTTP_REALITY_TARGET:-dl.google.com:443}"
    _xhttp_target_host="${_xhttp_target%%:*}"
    _xhttp_port="${PORT_XHTTP:-2096}"

    XHTTP_LINK="vless://${USER_UUID}@${SERVER_IP}:${_xhttp_port}?type=xhttp&security=reality&sni=${_xhttp_target_host}&fp=chrome&headers=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&encryption=none#MoaV-XHTTP-${USERNAME}"

    echo "$XHTTP_LINK" > "$OUTPUT_DIR/xhttp-vless.txt"

    if command -v qrencode &>/dev/null; then
        qrencode -o "$OUTPUT_DIR/xhttp-qr.png" -s 6 -m 2 "$XHTTP_LINK" 2>/dev/null || true
    fi

    cat > "$OUTPUT_DIR/xhttp.txt" <<EOF
XHTTP (VLESS+XHTTP+Reality) Configuration for $USERNAME
=======================================================

Protocol: VLESS + XHTTP + Reality (via Xray-core)
Server: ${SERVER_IP}
Port: ${_xhttp_port}
UUID: ${USER_UUID}
SNI: ${_xhttp_target_host}
Reality Public Key: ${REALITY_PUBLIC_KEY}
Short ID: ${REALITY_SHORT_ID}
Fingerprint: chrome
Transport: xhttp

Share Link:
${XHTTP_LINK}

Client Apps:
- Android: V2rayNG, Hiddify
- iOS: Streisand, V2Box
- Windows: Hiddify, V2rayN
- macOS: V2rayU, Hiddify

Instructions:
1. Install a compatible client app
2. Import using the share link above or scan the QR code
3. Connect
EOF

    log_info "Generated XHTTP client config"
fi

# Generate XDNS client config if enabled
if [[ "${ENABLE_XDNS:-false}" == "true" ]] && [[ -n "${DOMAIN:-}" ]]; then
    _xdns_domain="${XDNS_SUBDOMAIN:-x}.${DOMAIN}"
    _xdns_mtu="${XDNS_MTU:-35}"
    log_info "Generating XDNS client config for $USERNAME..."

    # Full Xray config (for apps that support custom JSON import)
    # Config via DNS resolver (stealthier but may drop after a few minutes)
    cat > "$OUTPUT_DIR/xdns-config.json" <<XDNSEOF
{
  "remarks": "MoaV-XDNS-${USERNAME} (via DNS)",
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 7891,
      "protocol": "socks",
      "settings": {"auth": "noauth", "udp": true}
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "8.8.8.8",
            "port": 53,
            "users": [{"id": "${USER_UUID}", "encryption": "none"}]
          }
        ]
      },
      "streamSettings": {
        "network": "kcp",
        "kcpSettings": {
          "mtu": ${_xdns_mtu},
          "tti": 100,
          "uplinkCapacity": 0,
          "downlinkCapacity": 0,
          "congestion": true
        },
        "finalmask": {
          "udp": [{"type": "xdns", "settings": {"domain": "${_xdns_domain}"}}]
        }
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "ip": ["::/0"],
        "outboundTag": "direct"
      }
    ]
  }
}
XDNSEOF

    # Config via direct connection (more stable but less stealthy)
    cat > "$OUTPUT_DIR/xdns-direct-config.json" <<XDNSEOF2
{
  "remarks": "MoaV-XDNS-${USERNAME} (direct)",
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 7891,
      "protocol": "socks",
      "settings": {"auth": "noauth", "udp": true}
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${SERVER_IP}",
            "port": ${PORT_XDNS:-53},
            "users": [{"id": "${USER_UUID}", "encryption": "none"}]
          }
        ]
      },
      "streamSettings": {
        "network": "kcp",
        "kcpSettings": {
          "mtu": ${_xdns_mtu},
          "tti": 100,
          "uplinkCapacity": 0,
          "downlinkCapacity": 0,
          "congestion": true
        },
        "finalmask": {
          "udp": [{"type": "xdns", "settings": {"domain": "${_xdns_domain}"}}]
        }
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "ip": ["::/0"],
        "outboundTag": "direct"
      }
    ]
  }
}
XDNSEOF2

    cat > "$OUTPUT_DIR/xdns.txt" <<EOF
XDNS (DNS Tunnel via Xray mKCP) Configuration for $USERNAME
============================================================

Protocol: VLESS + mKCP + XDNS FinalMask (via Xray-core)
Domain: ${_xdns_domain}
UUID: ${USER_UUID}
MTU: ${_xdns_mtu}

This protocol tunnels VPN traffic through DNS queries.
It works when almost everything except DNS is blocked.
Speed is slow but connectivity is reliable.

IMPORTANT: XDNS requires Xray-core v26+ with FinalMask support.

Recommended clients:
- Happ (iOS/Android/Desktop) — supports FinalMask
- Xray CLI v26.3+ (any platform) — run: xray run -c xdns-config.json

Two configs included:

  xdns-config.json        Via DNS resolver (8.8.8.8) — stealthier, may reconnect periodically
  xdns-direct-config.json Via direct server connection — more stable, less stealthy

Setup:
1. Import one of the configs into an Xray-compatible app with FinalMask support
2. Use as SOCKS5 proxy: 127.0.0.1:7891
3. For Telegram: tap https://t.me/socks?server=127.0.0.1&port=7891

Tips:
- Try the DNS resolver config first (stealthier)
- Switch to direct if connections keep dropping
- Other DNS resolvers to try: 1.1.1.1, your ISP's DNS

Telegram quick setup (after XDNS client is connected):
  Tap this link to add proxy to Telegram:
  https://t.me/socks?server=127.0.0.1&port=7891

MTU tuning (client side only — server uses MTU 900 for return path):
- MTU ${_xdns_mtu} = safest (works with all resolvers)
- MTU 67 = works with most resolvers (faster)
- MTU 130 = unrestricted resolvers only (fastest)
- MTU depends on domain name length: shorter domain = higher MTU possible
EOF

    log_info "Generated XDNS client config"
fi

# Add user to telemt (Telegram MTProxy) if config exists
TELEMT_CONFIG="configs/telemt/config.toml"
if [[ "${ENABLE_TELEMT:-true}" == "true" ]] && [[ -f "$TELEMT_CONFIG" ]]; then
    log_info "Adding $USERNAME to telemt..."

    # Check if user already exists
    if grep -q "^${USERNAME} = " "$TELEMT_CONFIG" 2>/dev/null; then
        log_info "User '$USERNAME' already exists in telemt, skipping..."
    else
        # Generate 32-hex MTProxy secret
        TELEMT_SECRET=$(openssl rand -hex 16)

        # Save secret to state
        cat > "$STATE_DIR/users/$USERNAME/telemt.env" <<EOF
TELEMT_SECRET=$TELEMT_SECRET
EOF

        # Add user to [access.users] section (before [access.user_max_tcp_conns])
        sed -i "/^\[access\.user_max_tcp_conns\]/i ${USERNAME} = \"${TELEMT_SECRET}\"" "$TELEMT_CONFIG"

        # Add connection limit (before [access.user_max_unique_ips])
        sed -i "/^\[access\.user_max_unique_ips\]/i ${USERNAME} = ${TELEMT_MAX_TCP_CONNS:-100}" "$TELEMT_CONFIG"

        # Add IP limit (append at end)
        echo "${USERNAME} = ${TELEMT_MAX_UNIQUE_IPS:-10}" >> "$TELEMT_CONFIG"

        log_info "Added $USERNAME to telemt config"
    fi
fi

# Try to reload sing-box (hot reload) unless --no-reload was passed
if [[ "$NO_RELOAD" != "true" ]]; then
    if docker compose ps sing-box --status running 2>/dev/null | tail -n +2 | grep -q .; then
        log_info "Reloading sing-box..."
        if docker compose exec -T sing-box sing-box reload 2>/dev/null; then
            log_info "sing-box reloaded successfully"
        else
            log_info "Hot reload failed, restarting sing-box..."
            docker compose restart sing-box
        fi
    else
        log_info "sing-box not running, config will apply on next start"
    fi

    # Try to reload TrustTunnel (if running)
    if [[ -f "$TRUSTTUNNEL_CREDS" ]]; then
        if docker compose ps trusttunnel --status running 2>/dev/null | tail -n +2 | grep -q .; then
            log_info "Restarting TrustTunnel to apply new credentials..."
            docker compose restart trusttunnel
        fi
    fi

    # Try to reload Xray (if running)
    if [[ -f "$XRAY_CONFIG" ]] && [[ "${ENABLE_XHTTP:-true}" == "true" ]]; then
        if docker compose --profile xhttp ps xray --status running 2>/dev/null | tail -n +2 | grep -q .; then
            log_info "Restarting Xray to apply new user..."
            docker compose --profile xhttp restart xray
        fi
    fi

    # Try to reload telemt (if running)
    if [[ -f "$TELEMT_CONFIG" ]]; then
        if docker compose --profile telegram ps telemt --status running 2>/dev/null | tail -n +2 | grep -q .; then
            log_info "Restarting telemt to apply new user..."
            docker compose --profile telegram restart telemt
        fi
    fi
fi

echo ""
log_info "=== User '$USERNAME' created ==="
echo ""
echo "Reality Link:"
echo "$REALITY_LINK"
if [[ -n "${TROJAN_LINK:-}" ]]; then
    echo ""
    echo "Trojan Link:"
    echo "$TROJAN_LINK"
fi
if [[ -n "${HY2_LINK:-}" ]]; then
    echo ""
    echo "Hysteria2 Link:"
    echo "$HY2_LINK"
fi
echo ""

if [[ -n "${SERVER_IPV6:-}" ]]; then
    echo "=== IPv6 Links ==="
    echo ""
    echo "Reality (IPv6):"
    echo "$REALITY_LINK_V6"
    if [[ -n "${TROJAN_LINK_V6:-}" ]]; then
        echo ""
        echo "Trojan (IPv6):"
        echo "$TROJAN_LINK_V6"
    fi
    if [[ -n "${HY2_LINK_V6:-}" ]]; then
        echo ""
        echo "Hysteria2 (IPv6):"
        echo "$HY2_LINK_V6"
    fi
    echo ""
fi

if [[ -n "${CDN_DOMAIN:-}" ]]; then
    echo "CDN VLESS+WS Link:"
    echo "$CDN_LINK"
    echo ""
fi

if [[ -n "${XHTTP_LINK:-}" ]]; then
    echo "XHTTP Link:"
    echo "$XHTTP_LINK"
    echo ""
fi

if [[ -f "$TRUSTTUNNEL_CREDS" ]]; then
    echo "TrustTunnel:"
    echo "  IP Address: ${SERVER_IP}:4443"
    echo "  Domain: ${DOMAIN}"
    echo "  Username: ${USERNAME}"
    echo "  Password: ${USER_PASSWORD}"
    echo "  DNS Servers: tls://1.1.1.1"
    echo ""
fi

if [[ -n "${TELEMT_SECRET:-}" ]] && [[ -f "$TELEMT_CONFIG" ]]; then
    PORT_TELEMT="${PORT_TELEMT:-993}"
    TELEMT_TLS_DOMAIN="${TELEMT_TLS_DOMAIN:-dl.google.com}"
    HEX_DOMAIN=$(printf '%s' "$TELEMT_TLS_DOMAIN" | od -An -tx1 | tr -d ' \n')
    echo "Telegram MTProxy:"
    echo "  tg://proxy?server=${SERVER_IP}&port=${PORT_TELEMT}&secret=ee${TELEMT_SECRET}${HEX_DOMAIN}"
    echo ""
fi

log_info "Config files saved to: $OUTPUT_DIR/"
