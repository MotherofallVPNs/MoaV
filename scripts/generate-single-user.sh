#!/bin/bash
set -euo pipefail

# =============================================================================
# Generate a single new user (called by user-add.sh)
# =============================================================================

source /app/lib/common.sh
source /app/lib/wireguard.sh
source /app/lib/amneziawg.sh
source /app/lib/dnstt.sh
source /app/lib/slipstream.sh
source /app/lib/telemt.sh

USER_ID="${1:-}"

if [[ -z "$USER_ID" ]]; then
    log_error "Usage: generate-single-user.sh <user_id>"
    exit 1
fi

# Load state
STATE_DIR="/state"
source "$STATE_DIR/keys/reality.env"

# Check if user already exists
if [[ -d "$STATE_DIR/users/$USER_ID" ]]; then
    log_error "User $USER_ID already exists"
    exit 1
fi

# Generate credentials
USER_UUID=$(sing-box generate uuid)
USER_PASSWORD=$(pwgen -s 24 1)

# Store credentials
mkdir -p "$STATE_DIR/users/$USER_ID"
cat > "$STATE_DIR/users/$USER_ID/credentials.env" <<EOF
USER_ID=$USER_ID
USER_UUID=$USER_UUID
USER_PASSWORD=$USER_PASSWORD
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# Shadowsocks-2022 per-user PSK (only if SS is enabled)
SS_USER_PSK=""
if [[ "${ENABLE_SS:-false}" == "true" ]]; then
    case "${SS_METHOD:-2022-blake3-aes-128-gcm}" in
        2022-blake3-aes-128-gcm) SS_PSK_BYTES=16 ;;
        *)                       SS_PSK_BYTES=32 ;;
    esac
    SS_USER_PSK=$(openssl rand -base64 "$SS_PSK_BYTES")
    cat > "$STATE_DIR/users/$USER_ID/shadowsocks.env" <<EOF
SS_USER_PSK=$SS_USER_PSK
EOF
fi

log_info "Created credentials for $USER_ID"

# DONATE_ONLY_PROTOCOLS: space-separated list of protocols to provision
# When set, only add user to services needed for those protocols (skip WireGuard, AmneziaWG, etc.)
DONATE_ONLY="${DONATE_ONLY_PROTOCOLS:-}"

# Helper: check if a protocol is in the donate-only list (or if donate mode is off)
donate_needs() {
    local service="$1"
    # If not in donate mode, always include
    [[ -z "$DONATE_ONLY" ]] && return 0
    # Check if any of the given protocols are in the list
    shift
    for proto in "$@"; do
        if echo " $DONATE_ONLY " | grep -q " $proto "; then
            return 0
        fi
    done
    return 1
}

# Add to sing-box config (Reality, Trojan, Hysteria2, CDN — all sing-box inbounds)
CONFIG_FILE="/configs/sing-box/config.json"

if [[ -f "$CONFIG_FILE" ]] && donate_needs singbox reality trojan hysteria2 cdn shadowsocks ss; then
    # Add to Reality inbound
    if donate_needs reality reality; then
        jq --arg name "$USER_ID" --arg uuid "$USER_UUID" \
            '(.inbounds[] | select(.tag == "vless-reality-in") | .users) += [{"name": $name, "uuid": $uuid, "flow": "xtls-rprx-vision"}]' \
            "$CONFIG_FILE" > /tmp/config.tmp && mv -f /tmp/config.tmp "$CONFIG_FILE"
    fi

    # Add to Trojan inbound
    if donate_needs trojan trojan; then
        jq --arg name "$USER_ID" --arg password "$USER_PASSWORD" \
            '(.inbounds[] | select(.tag == "trojan-tls-in") | .users) += [{"name": $name, "password": $password}]' \
            "$CONFIG_FILE" > /tmp/config.tmp && mv -f /tmp/config.tmp "$CONFIG_FILE"
    fi

    # Add to Hysteria2 inbound
    if donate_needs hysteria2 hysteria2; then
        jq --arg name "$USER_ID" --arg password "$USER_PASSWORD" \
            '(.inbounds[] | select(.tag == "hysteria2-in") | .users) += [{"name": $name, "password": $password}]' \
            "$CONFIG_FILE" > /tmp/config.tmp && mv -f /tmp/config.tmp "$CONFIG_FILE"
    fi

    # Add to VLESS WS inbound (CDN)
    if donate_needs cdn cdn; then
        jq --arg name "$USER_ID" --arg uuid "$USER_UUID" \
            '(.inbounds[] | select(.tag == "vless-ws-in") | .users) += [{"name": $name, "uuid": $uuid}]' \
            "$CONFIG_FILE" > /tmp/config.tmp && mv -f /tmp/config.tmp "$CONFIG_FILE"
    fi

    # Add to Shadowsocks-2022 inbound
    if [[ -n "$SS_USER_PSK" ]] && donate_needs shadowsocks ss \
            && jq -e '.inbounds[] | select(.tag == "shadowsocks-in")' "$CONFIG_FILE" >/dev/null 2>&1; then
        jq --arg name "$USER_ID" --arg pass "$SS_USER_PSK" \
            '(.inbounds[] | select(.tag == "shadowsocks-in") | .users) += [{"name": $name, "password": $pass}]' \
            "$CONFIG_FILE" > /tmp/config.tmp && mv -f /tmp/config.tmp "$CONFIG_FILE"
    fi

    log_info "Added $USER_ID to sing-box config"
fi

# Add to TrustTunnel config (skip in donate mode — not donatable)
TRUSTTUNNEL_CREDS="/configs/trusttunnel/credentials.toml"
if [[ -f "$TRUSTTUNNEL_CREDS" ]] && donate_needs trusttunnel; then
    # Check if user already exists
    if grep -q "username = \"$USER_ID\"" "$TRUSTTUNNEL_CREDS" 2>/dev/null; then
        log_info "User $USER_ID already exists in TrustTunnel"
    else
        # Append new user
        cat >> "$TRUSTTUNNEL_CREDS" <<EOF

[[client]]
username = "$USER_ID"
password = "$USER_PASSWORD"
EOF
        log_info "Added $USER_ID to TrustTunnel credentials"
    fi
fi

# Add to AmneziaWG config (skip in donate mode — not donatable)
AWG_CONFIG="/configs/amneziawg/awg0.conf"
if [[ -f "$AWG_CONFIG" ]] && donate_needs amneziawg; then
    # Check if user already exists
    if grep -q "# $USER_ID" "$AWG_CONFIG" 2>/dev/null; then
        log_info "User $USER_ID already exists in AmneziaWG"
    else
        # Generate client keys
        AWG_CLIENT_PRIVATE=$(wg genkey)
        AWG_CLIENT_PUBLIC=$(echo "$AWG_CLIENT_PRIVATE" | wg pubkey)

        # Count existing peers for IP assignment
        AWG_PEER_COUNT=$(grep -c '^\[Peer\]' "$AWG_CONFIG" 2>/dev/null) || true
        AWG_PEER_COUNT=${AWG_PEER_COUNT:-0}
        AWG_PEER_NUM=$((AWG_PEER_COUNT + 1))
        AWG_CLIENT_IP="10.67.67.$((AWG_PEER_NUM + 1))"

        # Save client credentials
        cat > "$STATE_DIR/users/$USER_ID/amneziawg.env" <<EOF
AWG_PRIVATE_KEY=$AWG_CLIENT_PRIVATE
AWG_PUBLIC_KEY=$AWG_CLIENT_PUBLIC
AWG_CLIENT_IP=$AWG_CLIENT_IP
AWG_CLIENT_IP_V6=
EOF

        # Append peer to server config
        cat >> "$AWG_CONFIG" <<EOF

[Peer]
# $USER_ID
PublicKey = $AWG_CLIENT_PUBLIC
AllowedIPs = $AWG_CLIENT_IP/32
EOF
        log_info "Added $USER_ID to AmneziaWG config"
    fi
fi

# Add to Xray config (XHTTP)
XRAY_CONFIG="/configs/xray/config.json"
if [[ "${ENABLE_XHTTP:-true}" == "true" ]] && [[ -f "$XRAY_CONFIG" ]]; then
    # Check if user already exists
    if jq -e --arg uuid "$USER_UUID" '.inbounds[0].settings.clients[] | select(.id == $uuid)' "$XRAY_CONFIG" >/dev/null 2>&1; then
        log_info "User $USER_ID already exists in Xray config"
    else
        # Add new client entry (flow MUST be empty for XHTTP)
        jq --arg id "$USER_UUID" --arg email "${USER_ID}@moav" \
            '.inbounds[0].settings.clients += [{"id": $id, "email": $email, "flow": ""}]' \
            "$XRAY_CONFIG" > /tmp/xray.tmp && mv -f /tmp/xray.tmp "$XRAY_CONFIG"
        log_info "Added $USER_ID to Xray config"
    fi
fi

# Add to telemt config
TELEMT_CONFIG="/configs/telemt/config.toml"
if [[ "${ENABLE_TELEMT:-true}" == "true" ]] && [[ -f "$TELEMT_CONFIG" ]] && donate_needs telemt telegram; then
    telemt_generate_secret "$USER_ID"
    telemt_add_user_to_config "$USER_ID" "$TELEMT_SECRET"
fi

# Generate bundle — override ENABLE_* flags in donate mode to only generate needed configs
export STATE_DIR
export USER_ID USER_UUID USER_PASSWORD
export REALITY_PUBLIC_KEY REALITY_SHORT_ID
export SERVER_IP="${SERVER_IP:-$(curl -s --max-time 5 https://api.ipify.org)}"
export DOMAIN="${DOMAIN:-}"
export REALITY_TARGET="${REALITY_TARGET:-dl.google.com:443}"

if [[ -n "$DONATE_ONLY" ]]; then
    # In donate mode, only enable protocols being donated
    export ENABLE_WIREGUARD=false
    export ENABLE_AMNEZIAWG=false
    export ENABLE_DNSTT=false
    export ENABLE_SLIPSTREAM=false
    export ENABLE_TRUSTTUNNEL=false
    # Enable specific protocols only if in the donate list
    if echo " $DONATE_ONLY " | grep -q " reality "; then
        export ENABLE_REALITY=true
    else
        export ENABLE_REALITY=false
    fi
    if echo " $DONATE_ONLY " | grep -q " trojan "; then
        export ENABLE_TROJAN=true
    else
        export ENABLE_TROJAN=false
    fi
    if echo " $DONATE_ONLY " | grep -q " hysteria2 "; then
        export ENABLE_HYSTERIA2=true
    else
        export ENABLE_HYSTERIA2=false
    fi
    if echo " $DONATE_ONLY " | grep -q " telegram "; then
        export ENABLE_TELEMT=true
    else
        export ENABLE_TELEMT=false
    fi
    if echo " $DONATE_ONLY " | grep -q -E " (shadowsocks|ss) "; then
        export ENABLE_SS=true
    else
        export ENABLE_SS=false
    fi
    if echo " $DONATE_ONLY " | grep -q " xhttp "; then
        export ENABLE_XHTTP=true
    else
        export ENABLE_XHTTP=false
    fi
    # CDN is controlled by CDN_DOMAIN — clear it if cdn not in donate list
    if ! echo " $DONATE_ONLY " | grep -q " cdn "; then
        export CDN_DOMAIN=""
    fi
else
    export ENABLE_WIREGUARD="${ENABLE_WIREGUARD:-true}"
    export ENABLE_AMNEZIAWG="${ENABLE_AMNEZIAWG:-true}"
    export ENABLE_DNSTT="${ENABLE_DNSTT:-true}"
    export ENABLE_SLIPSTREAM="${ENABLE_SLIPSTREAM:-true}"
    export ENABLE_HYSTERIA2="${ENABLE_HYSTERIA2:-true}"
    export ENABLE_TRUSTTUNNEL="${ENABLE_TRUSTTUNNEL:-true}"
    export ENABLE_XHTTP="${ENABLE_XHTTP:-true}"
    export ENABLE_TELEMT="${ENABLE_TELEMT:-true}"
    export ENABLE_SS="${ENABLE_SS:-false}"
fi
export PORT_SS="${PORT_SS:-8388}"
export SS_METHOD="${SS_METHOD:-2022-blake3-aes-128-gcm}"
if [[ -f "$STATE_DIR/keys/shadowsocks-server.psk" ]]; then
    export SS_SERVER_PSK="$(cat "$STATE_DIR/keys/shadowsocks-server.psk")"
fi
export PORT_XHTTP="${PORT_XHTTP:-2096}"
export XHTTP_REALITY_TARGET="${XHTTP_REALITY_TARGET:-dl.google.com:443}"
export PORT_TELEMT="${PORT_TELEMT:-993}"
export TELEMT_TLS_DOMAIN="${TELEMT_TLS_DOMAIN:-dl.google.com}"
export TELEMT_MAX_TCP_CONNS="${TELEMT_MAX_TCP_CONNS:-100}"
export TELEMT_MAX_UNIQUE_IPS="${TELEMT_MAX_UNIQUE_IPS:-10}"
export DNSTT_SUBDOMAIN="${DNSTT_SUBDOMAIN:-t}"
export SLIPSTREAM_SUBDOMAIN="${SLIPSTREAM_SUBDOMAIN:-s}"
# Construct CDN_DOMAIN from CDN_SUBDOMAIN + DOMAIN if not explicitly set
if [[ -z "${CDN_DOMAIN:-}" && -n "${CDN_SUBDOMAIN:-}" && -n "${DOMAIN:-}" ]]; then
    export CDN_DOMAIN="${CDN_SUBDOMAIN}.${DOMAIN}"
else
    export CDN_DOMAIN="${CDN_DOMAIN:-}"
fi
export CDN_WS_PATH="${CDN_WS_PATH:-/ws}"

# Load Hysteria2 obfuscation password if available
if [[ -f "$STATE_DIR/keys/clash-api.env" ]]; then
    source "$STATE_DIR/keys/clash-api.env"
    export HYSTERIA2_OBFS_PASSWORD
fi

/app/generate-user.sh "$USER_ID"

log_info "User $USER_ID bundle generated at /outputs/bundles/$USER_ID/"
