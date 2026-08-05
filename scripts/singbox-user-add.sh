#!/bin/bash
set -euo pipefail

# =============================================================================
# Add a new user to sing-box (Reality, Trojan, AnyTLS, Hysteria2)
# Usage: ./scripts/singbox-user-add.sh <username> [--no-reload]
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

source scripts/lib/common.sh
source scripts/lib/sing-box.sh
source scripts/lib/trusttunnel.sh
source scripts/lib/xray.sh
source scripts/lib/telemt.sh

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
# Ensure writable: owner=caller, group=admin, no world bits (was chmod 777)
if [[ ! -w "$STATE_DIR/users/$USERNAME" ]]; then
    sudo chown "$(id -u):$ADMIN_GID" "$STATE_DIR/users/$USERNAME" 2>/dev/null || true
    sudo chmod 2770 "$STATE_DIR/users/$USERNAME" 2>/dev/null || true
fi

# Check if user already exists in config (jq, whitespace-insensitive — the
# legacy grep version required "name":"X" with no spaces, but jq -S writes
# "name": "X" with a space, so the grep returned false-negative).
if jq -e --arg n "$USERNAME" \
        '.inbounds[]? | select(.users != null) | .users[]? | select(.name == $n)' \
        "$CONFIG_FILE" >/dev/null 2>&1; then
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

# Shadowsocks-2022 per-user PSK (only if SS is enabled AND the server is
# bootstrapped for it). If the operator just flipped ENABLE_SS in .env without
# re-bootstrapping, neither the server PSK nor the 'shadowsocks-in' inbound is
# in place — we'd otherwise silently emit a key that's not registered with any
# inbound. Fail loudly with the exact remediation instead.
if [[ "${ENABLE_SS:-true}" == "true" ]]; then
    _ss_psk_path="$STATE_DIR/keys/shadowsocks-server.psk"
    _ss_psk_present=false
    if [[ -s "$_ss_psk_path" ]] \
       || docker run --rm -v moav_moav_state:/state alpine test -s /state/keys/shadowsocks-server.psk 2>/dev/null; then
        _ss_psk_present=true
    fi
    _ss_inbound_present=false
    if [[ -f "$CONFIG_FILE" ]] && jq -e '.inbounds[] | select(.tag == "shadowsocks-in")' "$CONFIG_FILE" >/dev/null 2>&1; then
        _ss_inbound_present=true
    fi
    if ! $_ss_psk_present || ! $_ss_inbound_present; then
        log_error "ENABLE_SS=true in .env, but the server isn't bootstrapped for Shadowsocks yet:"
        $_ss_psk_present     || log_error "  • missing server PSK at $_ss_psk_path"
        $_ss_inbound_present || log_error "  • no 'shadowsocks-in' inbound in $CONFIG_FILE"
        log_error "  Run 'moav bootstrap' first to apply the SS enablement, then re-run 'moav user add $USERNAME'."
        log_warn "Skipping Shadowsocks for $USERNAME (other protocols will still be added)."
    else
        case "${SS_METHOD:-2022-blake3-aes-128-gcm}" in
            2022-blake3-aes-128-gcm) SS_PSK_BYTES=16 ;;
            *)                       SS_PSK_BYTES=32 ;;
        esac
        SS_USER_PSK=$(openssl rand -base64 "$SS_PSK_BYTES")
        cat > "$STATE_DIR/users/$USERNAME/shadowsocks.env" <<EOF
SS_USER_PSK=$SS_USER_PSK
EOF
    fi
fi

log_info "Generated credentials for $USERNAME"

# Add user to sing-box config (canonical mutation: lib/sing-box.sh). Shadowsocks
# is included only when it's enabled, its per-user PSK is set, and a
# shadowsocks-in inbound is actually present in the current config.
SS_ARG=""
if [[ "${ENABLE_SS:-true}" == "true" ]] && [[ -n "${SS_USER_PSK:-}" ]] \
        && jq -e '.inbounds[] | select(.tag == "shadowsocks-in")' "$CONFIG_FILE" >/dev/null 2>&1; then
    SS_ARG="$SS_USER_PSK"
fi
if ! singbox_add_user "$CONFIG_FILE" "$USERNAME" "$USER_UUID" "$USER_PASSWORD" "$SS_ARG"; then
    log_error "Failed to add $USERNAME to sing-box config (invalid JSON or no matching inbound)"
    exit 1
fi

log_info "Added $USERNAME to sing-box config"

# Load keys for client config generation
if [[ -f "$STATE_DIR/keys/reality.env" ]]; then
    source "$STATE_DIR/keys/reality.env"
else
    # Try docker volume (load all keys including private for derivation fallback)
    REALITY_ENV_CONTENT=$(docker run --rm -v moav_moav_state:/state alpine cat /state/keys/reality.env 2>/dev/null || echo "")
    # `|| true` on each: when the volume read comes back empty, grep exits 1 and
    # pipefail propagates it to the assignment, which set -e turns into a silent
    # exit -- the operator saw "Failed to add sing-box user" and nothing more.
    REALITY_PRIVATE_KEY=$(echo "$REALITY_ENV_CONTENT" | grep REALITY_PRIVATE_KEY | cut -d= -f2 || true)
    REALITY_PUBLIC_KEY=$(echo "$REALITY_ENV_CONTENT" | grep REALITY_PUBLIC_KEY | cut -d= -f2 || true)
    REALITY_SHORT_ID=$(echo "$REALITY_ENV_CONTENT" | grep REALITY_SHORT_ID | cut -d= -f2 || true)
fi

# If public key is missing but private key exists, derive it
if [[ -z "${REALITY_PUBLIC_KEY:-}" ]] && [[ -n "${REALITY_PRIVATE_KEY:-}" ]]; then
    log_info "Reality public key missing, deriving from private key..."
    # x25519 uses the same curve as WireGuard — convert base64url→base64, use wg pubkey, convert back
    REALITY_KEY_B64=$(echo "${REALITY_PRIVATE_KEY}==" | tr '_-' '/+' | head -c 44)
    if docker compose ps wireguard --status running 2>/dev/null | tail -n +2 | grep -q .; then
        REALITY_PUBLIC_KEY=$(echo "$REALITY_KEY_B64" | docker compose exec -T wireguard wg pubkey 2>/dev/null | tr -d '\r\n' | tr '/+' '_-' | sed 's/=*$//' || echo "")
    elif command -v wg &>/dev/null; then
        REALITY_PUBLIC_KEY=$(echo "$REALITY_KEY_B64" | wg pubkey 2>/dev/null | tr -d '\r\n' | tr '/+' '_-' | sed 's/=*$//' || echo "")
    fi
    if [[ -n "${REALITY_PUBLIC_KEY:-}" ]]; then
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
REALITY_LINK=$(singbox_reality_link "$USERNAME" "$SERVER_IP")
echo "$REALITY_LINK" > "$OUTPUT_DIR/reality.txt"

# Trojan link (IPv4) — only if domain is set (requires TLS cert)
if [[ -n "${DOMAIN:-}" ]]; then
    TROJAN_LINK=$(singbox_trojan_link "$USERNAME" "$SERVER_IP")
    echo "$TROJAN_LINK" > "$OUTPUT_DIR/trojan.txt"
fi

# AnyTLS link (IPv4) — only if enabled and domain is set (requires TLS cert)
if [[ "${ENABLE_ANYTLS:-false}" == "true" ]] && [[ -n "${DOMAIN:-}" ]]; then
    ANYTLS_LINK=$(singbox_anytls_link "$USERNAME" "$SERVER_IP")
    echo "$ANYTLS_LINK" > "$OUTPUT_DIR/anytls.txt"
fi

# Hysteria2 link (IPv4) — only if domain is set (requires TLS cert)
if [[ -n "${DOMAIN:-}" ]]; then
    HY2_LINK=$(singbox_hysteria2_link "$USERNAME" "$SERVER_IP")
    echo "$HY2_LINK" > "$OUTPUT_DIR/hysteria2.txt"
fi

# Generate IPv6 links if available
if [[ -n "$SERVER_IPV6" ]]; then
    REALITY_LINK_V6=$(singbox_reality_link "${USERNAME}-IPv6" "[${SERVER_IPV6}]")
    echo "$REALITY_LINK_V6" > "$OUTPUT_DIR/reality-ipv6.txt"

    if [[ -n "${DOMAIN:-}" ]]; then
        TROJAN_LINK_V6=$(singbox_trojan_link "${USERNAME}-IPv6" "[${SERVER_IPV6}]")
        echo "$TROJAN_LINK_V6" > "$OUTPUT_DIR/trojan-ipv6.txt"

        if [[ "${ENABLE_ANYTLS:-false}" == "true" ]]; then
            ANYTLS_LINK_V6=$(singbox_anytls_link "${USERNAME}-IPv6" "[${SERVER_IPV6}]")
            echo "$ANYTLS_LINK_V6" > "$OUTPUT_DIR/anytls-ipv6.txt"
        fi

        HY2_LINK_V6=$(singbox_hysteria2_link "${USERNAME}-IPv6" "[${SERVER_IPV6}]")
        echo "$HY2_LINK_V6" > "$OUTPUT_DIR/hysteria2-ipv6.txt"
    fi

    log_info "Generated IPv6 links (server: $SERVER_IPV6)"
fi

# Generate QR codes
if command -v qrencode &>/dev/null; then
    qrencode -o "$OUTPUT_DIR/reality-qr.png" -s 6 "$REALITY_LINK" 2>/dev/null || true
    [[ -n "${TROJAN_LINK:-}" ]] && qrencode -o "$OUTPUT_DIR/trojan-qr.png" -s 6 "$TROJAN_LINK" 2>/dev/null || true
    [[ -n "${ANYTLS_LINK:-}" ]] && qrencode -o "$OUTPUT_DIR/anytls-qr.png" -s 6 "$ANYTLS_LINK" 2>/dev/null || true
    [[ -n "${HY2_LINK:-}" ]] && qrencode -o "$OUTPUT_DIR/hysteria2-qr.png" -s 6 "$HY2_LINK" 2>/dev/null || true

    # IPv6 QR codes
    if [[ -n "$SERVER_IPV6" ]]; then
        qrencode -o "$OUTPUT_DIR/reality-ipv6-qr.png" -s 6 "$REALITY_LINK_V6" 2>/dev/null || true
        [[ -n "${TROJAN_LINK_V6:-}" ]] && qrencode -o "$OUTPUT_DIR/trojan-ipv6-qr.png" -s 6 "$TROJAN_LINK_V6" 2>/dev/null || true
        [[ -n "${ANYTLS_LINK_V6:-}" ]] && qrencode -o "$OUTPUT_DIR/anytls-ipv6-qr.png" -s 6 "$ANYTLS_LINK_V6" 2>/dev/null || true
        [[ -n "${HY2_LINK_V6:-}" ]] && qrencode -o "$OUTPUT_DIR/hysteria2-ipv6-qr.png" -s 6 "$HY2_LINK_V6" 2>/dev/null || true
    fi
fi

# Generate CDN VLESS+WS link (if CDN configured)
# Construct CDN_DOMAIN from CDN_SUBDOMAIN + DOMAIN if not explicitly set
CDN_DOMAIN="${CDN_DOMAIN:-$(get_env_val "CDN_DOMAIN" ".env" "")}"
if [[ -z "$CDN_DOMAIN" ]]; then
    CDN_SUBDOMAIN="${CDN_SUBDOMAIN:-$(get_env_val "CDN_SUBDOMAIN" ".env" "")}"
    DOMAIN_FROM_ENV="${DOMAIN:-$(get_env_val "DOMAIN" ".env" "")}"
    if [[ -n "$CDN_SUBDOMAIN" && -n "$DOMAIN_FROM_ENV" ]]; then
        CDN_DOMAIN="${CDN_SUBDOMAIN}.${DOMAIN_FROM_ENV}"
    fi
fi
# Load CDN WS path: .env → state file (bootstrap-generated) → fallback
CDN_WS_PATH="${CDN_WS_PATH:-$(get_env_val "CDN_WS_PATH" ".env")}"
if [[ -z "${CDN_WS_PATH:-}" ]]; then
    # Check bootstrap-generated state (persisted random path)
    CDN_WS_PATH=$(docker run --rm -v moav_moav_state:/state alpine cat /state/keys/cdn.env 2>/dev/null | grep '^CDN_WS_PATH=' | cut -d= -f2 || true)
fi
CDN_WS_PATH="${CDN_WS_PATH:-/ws}"
CDN_TRANSPORT="${CDN_TRANSPORT:-$(get_env_val "CDN_TRANSPORT" ".env")}"
CDN_TRANSPORT="${CDN_TRANSPORT:-ws}"
CDN_SNI="${CDN_SNI:-$(get_env_val "CDN_SNI" ".env")}"
CDN_SNI="${CDN_SNI:-${DOMAIN_FROM_ENV:-}}"
CDN_ADDRESS="${CDN_ADDRESS:-$(get_env_val "CDN_ADDRESS" ".env")}"
CDN_ADDRESS="${CDN_ADDRESS:-${CDN_DOMAIN}}"

if [[ -n "$CDN_DOMAIN" ]]; then
    CDN_LINK=$(singbox_cdn_link "$USERNAME")
    echo "$CDN_LINK" > "$OUTPUT_DIR/cdn-vless.txt"

    if command -v qrencode &>/dev/null; then
        qrencode -o "$OUTPUT_DIR/cdn-vless-qr.png" -s 6 "$CDN_LINK" 2>/dev/null || true
    fi

    log_info "Generated CDN VLESS link (transport: $CDN_TRANSPORT, domain: $CDN_DOMAIN)"
fi

# Generate Shadowsocks-2022 bundle (only if SS is enabled and we have the PSKs)
if [[ "${ENABLE_SS:-true}" == "true" ]] && [[ -n "${SS_USER_PSK:-}" ]]; then
    # Load server PSK from host state (via docker volume since the canonical copy is in the container)
    SS_SERVER_PSK=""
    if [[ -f "$STATE_DIR/keys/shadowsocks-server.psk" ]]; then
        SS_SERVER_PSK=$(cat "$STATE_DIR/keys/shadowsocks-server.psk" 2>/dev/null | tr -d '\n')
    fi
    if [[ -z "$SS_SERVER_PSK" ]]; then
        SS_SERVER_PSK=$(docker run --rm -v moav_moav_state:/state alpine cat /state/keys/shadowsocks-server.psk 2>/dev/null | tr -d '\n' || echo "")
    fi

    if [[ -z "$SS_SERVER_PSK" ]]; then
        log_warn "Shadowsocks server PSK not found — skipping SS bundle for $USERNAME"
    else
        SS_PORT_LOCAL="${PORT_SS:-$(get_env_val "PORT_SS" ".env" "8388")}"
        SS_METHOD_LOCAL="${SS_METHOD:-$(get_env_val "SS_METHOD" ".env" "2022-blake3-aes-128-gcm")}"

        # SIP002 ss:// URI with SS-2022 multi-user encoding: BASE64URL_NOPAD(method:server_psk:user_psk)@host:port#tag
        SS_USERINFO=$(singbox_ss_userinfo "$SS_METHOD_LOCAL" "$SS_SERVER_PSK" "$SS_USER_PSK")
        SS_LINK=$(singbox_ss_link "$USERNAME" "$SERVER_IP" "$SS_USERINFO" "$SS_PORT_LOCAL")
        echo "$SS_LINK" > "$OUTPUT_DIR/shadowsocks.txt"

        cat > "$OUTPUT_DIR/shadowsocks-singbox.json" <<EOF
{
  "log": {"level": "info"},
  "inbounds": [
    {"type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30"], "auto_route": true, "strict_route": true}
  ],
  "outbounds": [
    {
      "type": "shadowsocks",
      "tag": "proxy",
      "server": "${SERVER_IP}",
      "server_port": ${SS_PORT_LOCAL},
      "method": "${SS_METHOD_LOCAL}",
      "password": "${SS_SERVER_PSK}:${SS_USER_PSK}",
      "multiplex": {"enabled": true, "protocol": "h2mux", "padding": true}
    }
  ],
  "route": {"auto_detect_interface": true, "final": "proxy"}
}
EOF

        if command -v qrencode &>/dev/null; then
            qrencode -o "$OUTPUT_DIR/shadowsocks-qr.png" -s 6 "$SS_LINK" 2>/dev/null || true
        fi

        if [[ -n "$SERVER_IPV6" ]]; then
            SS_LINK_V6=$(singbox_ss_link "${USERNAME}-IPv6" "[${SERVER_IPV6}]" "$SS_USERINFO" "$SS_PORT_LOCAL")
            echo "$SS_LINK_V6" > "$OUTPUT_DIR/shadowsocks-ipv6.txt"
            command -v qrencode &>/dev/null && qrencode -o "$OUTPUT_DIR/shadowsocks-ipv6-qr.png" -s 6 "$SS_LINK_V6" 2>/dev/null || true
        fi

        log_info "Generated Shadowsocks-2022 bundle (port $SS_PORT_LOCAL, $SS_METHOD_LOCAL)"
    fi
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

    # Canonical client bundle (lib/trusttunnel.sh): trusttunnel.toml + .json.
    # Uses the same renderer as the container path, so has_ipv6 is now derived
    # from SERVER_IPV6 here too (this path hardcoded it to false).
    trusttunnel_write_client_bundle "$OUTPUT_DIR" "$USERNAME" "$USER_PASSWORD"

    log_info "Generated TrustTunnel client config (toml + txt + json)"
fi

# Add user to Xray (XHTTP) if config exists and enabled
XRAY_CONFIG="configs/xray/config.json"
if [[ "${ENABLE_XHTTP:-true}" == "true" ]] && [[ -f "$XRAY_CONFIG" ]]; then
    log_info "Adding $USERNAME to Xray (XHTTP)..."

    # Canonical mutation (lib/xray.sh): idempotent insert into every vless-*
    # inbound, into whichever field (settings.users/clients) the config uses.
    if xray_add_user "$XRAY_CONFIG" "$USER_UUID" "$USERNAME"; then
        log_info "Added $USERNAME to Xray config (all VLESS inbounds)"
    else
        log_info "User '$USERNAME' already in Xray config (or unchanged), skipping..."
    fi

    # Generate XHTTP client bundle (canonical: lib/xray.sh)
    xray_write_xhttp_bundle "$OUTPUT_DIR" "$USERNAME"

    log_info "Generated XHTTP client config"
fi

# Generate XDNS client config if enabled
if [[ "${ENABLE_XDNS:-false}" == "true" ]] && [[ -n "${DOMAIN:-}" ]]; then
    log_info "Generating XDNS client config for $USERNAME..."

    # Generate XDNS client bundle (canonical: lib/xray.sh)
    xray_write_xdns_bundle "$OUTPUT_DIR" "$USERNAME" "$USER_UUID"

    log_info "Generated XDNS client config"
fi

# Add user to telemt (Telegram MTProxy) via the shared lib functions. This was an
# inline copy of telemt_add_user_to_config; using the lib removes the duplication
# and gains idempotency -- telemt_generate_secret reuses an existing secret rather
# than minting a new one, so re-running no longer invalidates the user's bundle.
TELEMT_CONFIG="configs/telemt/config.toml"  # referenced again by the reload + share-link blocks below
if [[ "${ENABLE_TELEMT:-true}" == "true" ]] && [[ -f "$TELEMT_CONFIG" ]]; then
    log_info "Adding $USERNAME to telemt..."
    telemt_generate_secret "$USERNAME"
    telemt_add_user_to_config "$USERNAME" "$TELEMT_SECRET" "$TELEMT_CONFIG"
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
if [[ -n "${ANYTLS_LINK:-}" ]]; then
    echo ""
    echo "AnyTLS Link:"
    echo "$ANYTLS_LINK"
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
    if [[ -n "${ANYTLS_LINK_V6:-}" ]]; then
        echo ""
        echo "AnyTLS (IPv6):"
        echo "$ANYTLS_LINK_V6"
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
