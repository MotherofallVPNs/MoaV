#!/bin/bash
set -euo pipefail

# =============================================================================
# Generate user bundle with all client configurations
# Usage: generate-user.sh <user_id>
# =============================================================================

source /app/lib/common.sh
source /app/lib/wireguard.sh
source /app/lib/amneziawg.sh
source /app/lib/dnstt.sh
source /app/lib/slipstream.sh
source /app/lib/masterdns.sh
source /app/lib/gooserelay.sh
source /app/lib/telemt.sh

# Default state directory if not set
STATE_DIR="${STATE_DIR:-/state}"

USER_ID="${1:-}"
FORCE_REGENERATE="${2:-false}"  # Pass "force" to overwrite existing configs

if [[ -z "$USER_ID" ]]; then
    log_error "Usage: generate-user.sh <user_id> [force]"
    exit 1
fi

# Track whether any new config was generated (for README.html regeneration)
BUNDLE_CHANGED=false

# Load user credentials
USER_CREDS_FILE="$STATE_DIR/users/$USER_ID/credentials.env"
if [[ ! -f "$USER_CREDS_FILE" ]]; then
    log_error "User credentials not found: $USER_CREDS_FILE"
    exit 1
fi

source "$USER_CREDS_FILE"

# Load Reality keys (only if Reality is enabled)
if [[ "${ENABLE_REALITY:-true}" == "true" ]] && [[ -f "$STATE_DIR/keys/reality.env" ]]; then
    source "$STATE_DIR/keys/reality.env"
fi

# Load Hysteria2 obfuscation password
if [[ "${ENABLE_HYSTERIA2:-true}" == "true" ]] && [[ -f "$STATE_DIR/keys/clash-api.env" ]]; then
    source "$STATE_DIR/keys/clash-api.env"
fi

# Create output directory
OUTPUT_DIR="/outputs/bundles/$USER_ID"
ensure_dir "$OUTPUT_DIR"

# Parse Reality target (only if Reality is enabled)
if [[ "${ENABLE_REALITY:-true}" == "true" ]]; then
    REALITY_TARGET_HOST=$(echo "${REALITY_TARGET:-dl.google.com:443}" | cut -d: -f1)
    REALITY_TARGET_PORT=$(echo "${REALITY_TARGET:-dl.google.com:443}" | cut -d: -f2)
fi

log_info "Generating bundle for $USER_ID..."

# -----------------------------------------------------------------------------
# Generate Reality (VLESS) client config (sing-box 1.12+ format)
# -----------------------------------------------------------------------------
if [[ "${ENABLE_REALITY:-true}" == "true" ]]; then
  if [[ -f "$OUTPUT_DIR/reality.txt" ]] && [[ "$FORCE_REGENERATE" != "force" ]]; then
    log_info "  - Reality config exists, skipping (use 'force' to regenerate)"
  else
    BUNDLE_CHANGED=true
    cat > "$OUTPUT_DIR/reality-singbox.json" <<EOF
{
  "log": {"level": "info"},
  "inbounds": [
    {"type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30"], "auto_route": true, "strict_route": true}
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "proxy",
      "server": "${SERVER_IP}",
      "server_port": 443,
      "uuid": "${USER_UUID}",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_TARGET_HOST}",
        "utls": {"enabled": true, "fingerprint": "random"},
        "reality": {
          "enabled": true,
          "public_key": "${REALITY_PUBLIC_KEY}",
          "short_id": "${REALITY_SHORT_ID}"
        },
        "record_fragment": true
      }
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "final": "proxy"
  }
}
EOF

    # Generate v2rayN/NekoBox compatible link (IPv4)
    REALITY_LINK="vless://${USER_UUID}@${SERVER_IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_TARGET_HOST}&fp=random&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp#MoaV-Reality-${USER_ID}"
    echo "$REALITY_LINK" > "$OUTPUT_DIR/reality.txt"

    # Generate QR code
    qrencode -o "$OUTPUT_DIR/reality-qr.png" -s 6 "$REALITY_LINK" 2>/dev/null || true

    # Generate IPv6 link if available
    if [[ -n "${SERVER_IPV6:-}" ]]; then
        REALITY_LINK_V6="vless://${USER_UUID}@[${SERVER_IPV6}]:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_TARGET_HOST}&fp=random&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp#MoaV-Reality-${USER_ID}-IPv6"
        echo "$REALITY_LINK_V6" > "$OUTPUT_DIR/reality-ipv6.txt"
        qrencode -o "$OUTPUT_DIR/reality-ipv6-qr.png" -s 6 "$REALITY_LINK_V6" 2>/dev/null || true
    fi

    log_info "  - Reality config generated"
  fi
fi

# -----------------------------------------------------------------------------
# Generate Trojan client config (sing-box 1.12+ format)
# -----------------------------------------------------------------------------
if [[ "${ENABLE_TROJAN:-true}" == "true" ]]; then
  if [[ -f "$OUTPUT_DIR/trojan.txt" ]] && [[ "$FORCE_REGENERATE" != "force" ]]; then
    log_info "  - Trojan config exists, skipping"
  else
    BUNDLE_CHANGED=true
    cat > "$OUTPUT_DIR/trojan-singbox.json" <<EOF
{
  "log": {"level": "info"},
  "inbounds": [
    {"type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30"], "auto_route": true, "strict_route": true}
  ],
  "outbounds": [
    {
      "type": "trojan",
      "tag": "proxy",
      "server": "${SERVER_IP}",
      "server_port": 8443,
      "password": "${USER_PASSWORD}",
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "utls": {"enabled": true, "fingerprint": "random"},
        "record_fragment": true
      },
      "multiplex": {
        "enabled": true,
        "protocol": "h2mux",
        "max_connections": 2,
        "padding": true
      }
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "final": "proxy"
  }
}
EOF

    # Generate Trojan URI (IPv4)
    TROJAN_LINK="trojan://${USER_PASSWORD}@${SERVER_IP}:8443?security=tls&sni=${DOMAIN}&type=tcp#MoaV-Trojan-${USER_ID}"
    echo "$TROJAN_LINK" > "$OUTPUT_DIR/trojan.txt"
    qrencode -o "$OUTPUT_DIR/trojan-qr.png" -s 6 "$TROJAN_LINK" 2>/dev/null || true

    # Generate IPv6 link if available
    if [[ -n "${SERVER_IPV6:-}" ]]; then
        TROJAN_LINK_V6="trojan://${USER_PASSWORD}@[${SERVER_IPV6}]:8443?security=tls&sni=${DOMAIN}&type=tcp#MoaV-Trojan-${USER_ID}-IPv6"
        echo "$TROJAN_LINK_V6" > "$OUTPUT_DIR/trojan-ipv6.txt"
        qrencode -o "$OUTPUT_DIR/trojan-ipv6-qr.png" -s 6 "$TROJAN_LINK_V6" 2>/dev/null || true
    fi

    log_info "  - Trojan config generated"
  fi
fi

# -----------------------------------------------------------------------------
# Generate AnyTLS client config (sing-box native, reuses Trojan TLS cert/domain)
# -----------------------------------------------------------------------------
if [[ "${ENABLE_ANYTLS:-false}" == "true" ]]; then
  if [[ -f "$OUTPUT_DIR/anytls.txt" ]] && [[ "$FORCE_REGENERATE" != "force" ]]; then
    log_info "  - AnyTLS config exists, skipping"
  else
    BUNDLE_CHANGED=true
    cat > "$OUTPUT_DIR/anytls-singbox.json" <<EOF
{
  "log": {"level": "info"},
  "inbounds": [
    {"type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30"], "auto_route": true, "strict_route": true}
  ],
  "outbounds": [
    {
      "type": "anytls",
      "tag": "proxy",
      "server": "${SERVER_IP}",
      "server_port": ${PORT_ANYTLS:-8445},
      "password": "${USER_PASSWORD}",
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "utls": {"enabled": true, "fingerprint": "random"}
      }
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "final": "proxy"
  }
}
EOF

    # Generate AnyTLS URI (IPv4)
    ANYTLS_LINK="anytls://${USER_PASSWORD}@${SERVER_IP}:${PORT_ANYTLS:-8445}?sni=${DOMAIN}&insecure=0#MoaV-AnyTLS-${USER_ID}"
    echo "$ANYTLS_LINK" > "$OUTPUT_DIR/anytls.txt"
    qrencode -o "$OUTPUT_DIR/anytls-qr.png" -s 6 "$ANYTLS_LINK" 2>/dev/null || true

    # Generate IPv6 link if available
    if [[ -n "${SERVER_IPV6:-}" ]]; then
        ANYTLS_LINK_V6="anytls://${USER_PASSWORD}@[${SERVER_IPV6}]:${PORT_ANYTLS:-8445}?sni=${DOMAIN}&insecure=0#MoaV-AnyTLS-${USER_ID}-IPv6"
        echo "$ANYTLS_LINK_V6" > "$OUTPUT_DIR/anytls-ipv6.txt"
        qrencode -o "$OUTPUT_DIR/anytls-ipv6-qr.png" -s 6 "$ANYTLS_LINK_V6" 2>/dev/null || true
    fi

    log_info "  - AnyTLS config generated"
  fi
fi

# -----------------------------------------------------------------------------
# Generate Hysteria2 client config
# -----------------------------------------------------------------------------
if [[ "${ENABLE_HYSTERIA2:-true}" == "true" ]]; then
  if [[ -f "$OUTPUT_DIR/hysteria2.txt" ]] && [[ "$FORCE_REGENERATE" != "force" ]]; then
    log_info "  - Hysteria2 config exists, skipping"
  else
    BUNDLE_CHANGED=true
    cat > "$OUTPUT_DIR/hysteria2.yaml" <<EOF
server: ${SERVER_IP}:443
auth: ${USER_PASSWORD}

obfs:
  type: salamander
  salamander:
    password: ${HYSTERIA2_OBFS_PASSWORD}

tls:
  sni: ${DOMAIN}

socks5:
  listen: 127.0.0.1:1080

http:
  listen: 127.0.0.1:8080
EOF

    cat > "$OUTPUT_DIR/hysteria2-singbox.json" <<EOF
{
  "log": {"level": "info"},
  "inbounds": [
    {"type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30"], "auto_route": true, "strict_route": true}
  ],
  "outbounds": [
    {
      "type": "hysteria2",
      "tag": "proxy",
      "server": "${SERVER_IP}",
      "server_port": 443,
      "password": "${USER_PASSWORD}",
      "obfs": {
        "type": "salamander",
        "password": "${HYSTERIA2_OBFS_PASSWORD}"
      },
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}"
      }
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "final": "proxy"
  }
}
EOF

    # Hysteria2 URI (IPv4) - includes obfs parameter
    HY2_LINK="hysteria2://${USER_PASSWORD}@${SERVER_IP}:443?sni=${DOMAIN}&obfs=salamander&obfs-password=${HYSTERIA2_OBFS_PASSWORD}#MoaV-Hysteria2-${USER_ID}"
    echo "$HY2_LINK" > "$OUTPUT_DIR/hysteria2.txt"
    qrencode -o "$OUTPUT_DIR/hysteria2-qr.png" -s 6 "$HY2_LINK" 2>/dev/null || true

    # Generate IPv6 link if available
    if [[ -n "${SERVER_IPV6:-}" ]]; then
        HY2_LINK_V6="hysteria2://${USER_PASSWORD}@[${SERVER_IPV6}]:443?sni=${DOMAIN}&obfs=salamander&obfs-password=${HYSTERIA2_OBFS_PASSWORD}#MoaV-Hysteria2-${USER_ID}-IPv6"
        echo "$HY2_LINK_V6" > "$OUTPUT_DIR/hysteria2-ipv6.txt"
        qrencode -o "$OUTPUT_DIR/hysteria2-ipv6-qr.png" -s 6 "$HY2_LINK_V6" 2>/dev/null || true
    fi

    log_info "  - Hysteria2 config generated (with obfuscation)"
  fi
fi

# -----------------------------------------------------------------------------
# Generate Shadowsocks-2022 client config (sing-box compatible URI format)
# -----------------------------------------------------------------------------
if [[ "${ENABLE_SS:-true}" == "true" ]]; then
  if [[ -f "$OUTPUT_DIR/shadowsocks.txt" ]] && [[ "$FORCE_REGENERATE" != "force" ]]; then
    log_info "  - Shadowsocks config exists, skipping"
  else
    # Load per-user PSK + server PSK
    SS_USER_PSK=""
    if [[ -f "$STATE_DIR/users/$USER_ID/shadowsocks.env" ]]; then
        # shellcheck source=/dev/null
        source "$STATE_DIR/users/$USER_ID/shadowsocks.env"
    fi
    SS_SERVER_PSK_LOCAL="${SS_SERVER_PSK:-}"
    if [[ -z "$SS_SERVER_PSK_LOCAL" && -f "$STATE_DIR/keys/shadowsocks-server.psk" ]]; then
        SS_SERVER_PSK_LOCAL=$(cat "$STATE_DIR/keys/shadowsocks-server.psk")
    fi

    if [[ -z "$SS_USER_PSK" || -z "$SS_SERVER_PSK_LOCAL" ]]; then
        log_error "  - Shadowsocks PSK missing for $USER_ID, skipping"
    else
        BUNDLE_CHANGED=true
        SS_PORT="${PORT_SS:-8388}"
        SS_METHOD_LOCAL="${SS_METHOD:-2022-blake3-aes-128-gcm}"

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
      "server_port": ${SS_PORT},
      "method": "${SS_METHOD_LOCAL}",
      "password": "${SS_SERVER_PSK_LOCAL}:${SS_USER_PSK}",
      "multiplex": {
        "enabled": true,
        "protocol": "h2mux",
        "padding": true
      }
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "final": "proxy"
  }
}
EOF

        # Build ss:// URI per SIP002 with SS-2022 multi-user encoding
        # Format: ss://BASE64URL_NOPAD(method:server_psk:user_psk)@host:port#tag
        SS_USERINFO=$(printf '%s' "${SS_METHOD_LOCAL}:${SS_SERVER_PSK_LOCAL}:${SS_USER_PSK}" | base64 | tr -d '\n=' | tr '/+' '_-')
        SS_LINK="ss://${SS_USERINFO}@${SERVER_IP}:${SS_PORT}#MoaV-Shadowsocks-${USER_ID}"
        echo "$SS_LINK" > "$OUTPUT_DIR/shadowsocks.txt"
        qrencode -o "$OUTPUT_DIR/shadowsocks-qr.png" -s 6 "$SS_LINK" 2>/dev/null || true

        if [[ -n "${SERVER_IPV6:-}" ]]; then
            SS_LINK_V6="ss://${SS_USERINFO}@[${SERVER_IPV6}]:${SS_PORT}#MoaV-Shadowsocks-${USER_ID}-IPv6"
            echo "$SS_LINK_V6" > "$OUTPUT_DIR/shadowsocks-ipv6.txt"
            qrencode -o "$OUTPUT_DIR/shadowsocks-ipv6-qr.png" -s 6 "$SS_LINK_V6" 2>/dev/null || true
        fi

        log_info "  - Shadowsocks-2022 config generated"
    fi
  fi
fi

# -----------------------------------------------------------------------------
# Generate CDN VLESS+WS client config (if CDN_DOMAIN is set)
# -----------------------------------------------------------------------------
# Construct CDN_DOMAIN from CDN_SUBDOMAIN + DOMAIN if not explicitly set
if [[ -z "${CDN_DOMAIN:-}" ]]; then
    if [[ -n "${CDN_SUBDOMAIN:-}" && -n "${DOMAIN:-}" ]]; then
        CDN_DOMAIN="${CDN_SUBDOMAIN}.${DOMAIN}"
    fi
fi

if [[ -n "${CDN_DOMAIN:-}" ]]; then
  if [[ -f "$OUTPUT_DIR/cdn-vless.txt" ]] && [[ "$FORCE_REGENERATE" != "force" ]]; then
    log_info "  - CDN VLESS config exists, skipping"
  else
    BUNDLE_CHANGED=true
    CDN_WS_PATH="${CDN_WS_PATH:-/ws}"
    CDN_TRANSPORT="${CDN_TRANSPORT:-ws}"
    CDN_SNI="${CDN_SNI:-${DOMAIN:-${CDN_DOMAIN}}}"
    CDN_ADDRESS="${CDN_ADDRESS:-${CDN_DOMAIN}}"

    cat > "$OUTPUT_DIR/cdn-vless-singbox.json" <<EOF
{
  "log": {"level": "info"},
  "inbounds": [
    {"type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30"], "auto_route": true, "strict_route": true}
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "proxy",
      "server": "${CDN_ADDRESS}",
      "server_port": 443,
      "uuid": "${USER_UUID}",
      "tls": {
        "enabled": true,
        "server_name": "${CDN_SNI}",
        "utls": {"enabled": true, "fingerprint": "random"},
        "alpn": ["http/1.1"]
      },
      "transport": {
        "type": "${CDN_TRANSPORT}",
        "path": "${CDN_WS_PATH}",
        "headers": {"Host": "${CDN_DOMAIN}"}
      },
      "multiplex": {
        "enabled": true,
        "protocol": "h2mux",
        "max_connections": 2,
        "padding": true
      }
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "final": "proxy"
  }
}
EOF

    CDN_LINK="vless://${USER_UUID}@${CDN_ADDRESS}:443?security=tls&type=${CDN_TRANSPORT}&path=${CDN_WS_PATH}&sni=${CDN_SNI}&host=${CDN_DOMAIN}&fp=random&alpn=http/1.1#MoaV-CDN-${USER_ID}"
    echo "$CDN_LINK" > "$OUTPUT_DIR/cdn-vless.txt"
    qrencode -o "$OUTPUT_DIR/cdn-vless-qr.png" -s 6 "$CDN_LINK" 2>/dev/null || true

    log_info "  - CDN VLESS config generated (transport: $CDN_TRANSPORT, domain: $CDN_DOMAIN)"
  fi
fi

# -----------------------------------------------------------------------------
# Generate TrustTunnel client config (if enabled)
# -----------------------------------------------------------------------------
if [[ "${ENABLE_TRUSTTUNNEL:-true}" == "true" ]]; then
  if [[ -f "$OUTPUT_DIR/trusttunnel.toml" ]] && [[ "$FORCE_REGENERATE" != "force" ]]; then
    log_info "  - TrustTunnel config exists, skipping"
  else
    BUNDLE_CHANGED=true
    # TrustTunnel uses username/password authentication
    # Generate full TOML config for CLI client

    cat > "$OUTPUT_DIR/trusttunnel.toml" <<EOF
# TrustTunnel Client Configuration for $USER_ID
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
has_ipv6 = ${SERVER_IPV6:+true}${SERVER_IPV6:-false}
username = "${USER_ID}"
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

    # Generate human-readable text file with instructions
    cat > "$OUTPUT_DIR/trusttunnel.txt" <<EOF
TrustTunnel Configuration for $USER_ID
======================================

IP Address: ${SERVER_IP}:4443
Domain: ${DOMAIN}
Username: ${USER_ID}
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

    # Generate JSON config for programmatic use
    cat > "$OUTPUT_DIR/trusttunnel.json" <<EOF
{
  "ip_address": "${SERVER_IP}:4443",
  "domain": "${DOMAIN}",
  "username": "${USER_ID}",
  "password": "${USER_PASSWORD}",
  "dns_servers": ["tls://1.1.1.1"]
}
EOF

    log_info "  - TrustTunnel config generated"
  fi
fi

# -----------------------------------------------------------------------------
# Generate XHTTP (Xray-core) client config (if enabled)
# -----------------------------------------------------------------------------
if [[ "${ENABLE_XHTTP:-true}" == "true" ]]; then
  if [[ -f "$OUTPUT_DIR/xhttp-vless.txt" ]] && [[ "$FORCE_REGENERATE" != "force" ]]; then
    log_info "  - XHTTP config exists, skipping"
  else
    BUNDLE_CHANGED=true
    # XHTTP Reality target host (strip port)
    _xhttp_target="${XHTTP_REALITY_TARGET:-dl.google.com:443}"
    _xhttp_target_host="${_xhttp_target%%:*}"
    _xhttp_port="${PORT_XHTTP:-2096}"

    # Generate VLESS XHTTP share link
    XHTTP_LINK="vless://${USER_UUID}@${SERVER_IP}:${_xhttp_port}?type=xhttp&security=reality&sni=${_xhttp_target_host}&fp=chrome&headers=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&encryption=none#MoaV-XHTTP-${USER_ID}"

    echo "$XHTTP_LINK" > "$OUTPUT_DIR/xhttp-vless.txt"

    # Generate QR code
    if command -v qrencode &>/dev/null; then
        qrencode -o "$OUTPUT_DIR/xhttp-qr.png" -s 6 -m 2 "$XHTTP_LINK"
    fi

    # Generate human-readable text file
    cat > "$OUTPUT_DIR/xhttp.txt" <<EOF
XHTTP (VLESS+XHTTP+Reality) Configuration for $USER_ID
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

    log_info "  - XHTTP config generated"
  fi
fi

# -----------------------------------------------------------------------------
# Generate WireGuard config (if enabled)
# -----------------------------------------------------------------------------
if [[ "${ENABLE_WIREGUARD:-true}" == "true" ]]; then
    # Always add peer to server config (wireguard_add_peer has its own guard)
    PEER_COUNT=$(grep -c '^\[Peer\]' "$WG_CONFIG_DIR/wg0.conf" 2>/dev/null) || true
    PEER_COUNT=${PEER_COUNT:-0}
    PEER_NUM=$((PEER_COUNT + 1))
    wireguard_add_peer "$USER_ID" "$PEER_NUM"

    if [[ -f "$OUTPUT_DIR/wireguard.conf" ]] && [[ "$FORCE_REGENERATE" != "force" ]]; then
        log_info "  - WireGuard config exists, skipping"
    else
        BUNDLE_CHANGED=true
        wireguard_generate_client_config "$USER_ID" "$OUTPUT_DIR"
        qrencode -o "$OUTPUT_DIR/wireguard-qr.png" -s 6 -r "$OUTPUT_DIR/wireguard.conf" 2>/dev/null || true
        qrencode -o "$OUTPUT_DIR/wireguard-wstunnel-qr.png" -s 6 -r "$OUTPUT_DIR/wireguard-wstunnel.conf" 2>/dev/null || true
        if [[ -n "${SERVER_IPV6:-}" ]] && [[ -f "$OUTPUT_DIR/wireguard-ipv6.conf" ]]; then
            qrencode -o "$OUTPUT_DIR/wireguard-ipv6-qr.png" -s 6 -r "$OUTPUT_DIR/wireguard-ipv6.conf" 2>/dev/null || true
        fi
        log_info "  - WireGuard config generated (direct + wstunnel${SERVER_IPV6:+ + ipv6})"
    fi
fi

# -----------------------------------------------------------------------------
# Generate AmneziaWG config (if enabled)
# -----------------------------------------------------------------------------
if [[ "${ENABLE_AMNEZIAWG:-true}" == "true" ]]; then
    # Always add peer to server config (amneziawg_add_peer has its own guard)
    AWG_PEER_COUNT=$(grep -c '^\[Peer\]' "$AWG_CONFIG_DIR/awg0.conf" 2>/dev/null) || true
    AWG_PEER_COUNT=${AWG_PEER_COUNT:-0}
    AWG_PEER_NUM=$((AWG_PEER_COUNT + 1))
    amneziawg_add_peer "$USER_ID" "$AWG_PEER_NUM"

    if [[ -f "$OUTPUT_DIR/amneziawg.conf" ]] && [[ "$FORCE_REGENERATE" != "force" ]]; then
        log_info "  - AmneziaWG config exists, skipping"
    else
        BUNDLE_CHANGED=true
        amneziawg_generate_client_config "$USER_ID" "$OUTPUT_DIR"
        qrencode -o "$OUTPUT_DIR/amneziawg-qr.png" -s 6 -r "$OUTPUT_DIR/amneziawg.conf" 2>/dev/null || true
        if [[ -n "${SERVER_IPV6:-}" ]] && [[ -f "$OUTPUT_DIR/amneziawg-ipv6.conf" ]]; then
            qrencode -o "$OUTPUT_DIR/amneziawg-ipv6-qr.png" -s 6 -r "$OUTPUT_DIR/amneziawg-ipv6.conf" 2>/dev/null || true
        fi
        log_info "  - AmneziaWG config generated (obfuscated WireGuard${SERVER_IPV6:+ + ipv6})"
    fi
fi

# -----------------------------------------------------------------------------
# Generate dnstt instructions (if enabled)
# -----------------------------------------------------------------------------
if [[ "${ENABLE_DNSTT:-true}" == "true" ]]; then
    if [[ -f "$OUTPUT_DIR/dnstt-instructions.txt" ]] && [[ "$FORCE_REGENERATE" != "force" ]]; then
        log_info "  - dnstt instructions exist, skipping"
    else
        BUNDLE_CHANGED=true
        dnstt_generate_client_instructions "$USER_ID" "$OUTPUT_DIR"
        log_info "  - dnstt instructions generated"
    fi
fi

# -----------------------------------------------------------------------------
# Generate Slipstream instructions (if enabled)
# -----------------------------------------------------------------------------
if [[ "${ENABLE_SLIPSTREAM:-true}" == "true" ]]; then
    if [[ -f "$OUTPUT_DIR/slipstream-instructions.txt" ]] && [[ "$FORCE_REGENERATE" != "force" ]]; then
        log_info "  - Slipstream instructions exist, skipping"
    else
        BUNDLE_CHANGED=true
        slipstream_generate_client_instructions "$USER_ID" "$OUTPUT_DIR"
        log_info "  - Slipstream instructions generated"
    fi
fi

# -----------------------------------------------------------------------------
# Generate MasterDNS instructions (if enabled) — MahsaNG v16 component
# -----------------------------------------------------------------------------
if [[ "${ENABLE_MASTERDNS:-true}" == "true" ]]; then
    if [[ -f "$OUTPUT_DIR/masterdns-instructions.txt" ]] && [[ "$FORCE_REGENERATE" != "force" ]]; then
        log_info "  - MasterDNS instructions exist, skipping"
    else
        BUNDLE_CHANGED=true
        masterdns_generate_client_instructions "$USER_ID" "$OUTPUT_DIR"
        log_info "  - MasterDNS instructions generated"
    fi
fi

# -----------------------------------------------------------------------------
# Generate GooseRelay instructions (if enabled) — MahsaNG v16 component
# -----------------------------------------------------------------------------
if [[ "${ENABLE_GOOSERELAY:-false}" == "true" ]]; then
    if [[ -f "$OUTPUT_DIR/gooserelay-instructions.txt" ]] && [[ "$FORCE_REGENERATE" != "force" ]]; then
        log_info "  - GooseRelay instructions exist, skipping"
    else
        BUNDLE_CHANGED=true
        gooserelay_generate_client_instructions "$USER_ID" "$OUTPUT_DIR"
        log_info "  - GooseRelay instructions generated"
    fi
fi

# -----------------------------------------------------------------------------
# Generate telemt (Telegram MTProxy) instructions (if enabled)
# -----------------------------------------------------------------------------
if [[ "${ENABLE_TELEMT:-true}" == "true" ]]; then
    if [[ -f "$OUTPUT_DIR/telegram-proxy-link.txt" ]] && [[ "$FORCE_REGENERATE" != "force" ]]; then
        log_info "  - telemt config exists, skipping"
    else
        BUNDLE_CHANGED=true
        telemt_generate_client_instructions "$USER_ID" "$OUTPUT_DIR"
        log_info "  - telemt (Telegram MTProxy) config generated"
    fi
fi

# -----------------------------------------------------------------------------
# Generate XDNS client configs (if enabled)
# -----------------------------------------------------------------------------
if [[ "${ENABLE_XDNS:-false}" == "true" ]] && [[ -n "${DOMAIN:-}" ]]; then
    if [[ -f "$OUTPUT_DIR/xdns-config.json" ]] && [[ -f "$OUTPUT_DIR/xdns-direct-config.json" ]] && [[ "$FORCE_REGENERATE" != "force" ]]; then
        log_info "  - XDNS config exists, skipping"
    else
        BUNDLE_CHANGED=true
        _xdns_domain="${XDNS_SUBDOMAIN:-x}.${DOMAIN}"
        _xdns_mtu="${XDNS_MTU:-35}"
        # Multi-resolver round-robin for DNS-tunnel mode (Xray v26.4.13+, PR #5872).
        # Direct mode omits resolvers since it bypasses public DNS.
        _xdns_resolvers_csv="${XDNS_RESOLVERS:-1.1.1.1,8.8.8.8}"
        # Record mode for the finalmask resolver: txt (default, widest client
        # compat) or aaaa (Xray >= v26.6.1, higher throughput per query, #6123).
        _xdns_method="${XDNS_METHOD:-txt}"
        _xdns_finalmask_settings=$(XDNS_DOMAIN="$_xdns_domain" XDNS_RESOLVERS_CSV="$_xdns_resolvers_csv" XDNS_METHOD="$_xdns_method" python3 -c '
import os, json
domain = os.environ["XDNS_DOMAIN"]
csv = os.environ.get("XDNS_RESOLVERS_CSV", "").strip()
method = os.environ.get("XDNS_METHOD", "txt").strip().lower()
# txt is the default record mode and is expressed by omitting the suffix.
suffix = "" if method in ("", "txt") else ":" + method
ips = [x.strip() for x in csv.split(",") if x.strip()] if csv else []
if not ips:
    ips = ["1.1.1.1"]
# Xray v26.x finalmask: the client side uses "resolvers", each formatted as
# "domain[:method]+udp://server:port". The old singular "domain" field was
# removed; "domains" is server-side only.
resolvers = [domain + suffix + "+udp://" + (ip if ":" in ip else ip + ":53") for ip in ips]
print(json.dumps({"resolvers": resolvers}))
')
        _xdns_finalmask_settings_direct=$(XDNS_DOMAIN="$_xdns_domain" XDNS_DIRECT_TARGET="${SERVER_IP}:${PORT_XDNS:-5356}" XDNS_METHOD="$_xdns_method" python3 -c '
import os, json
domain = os.environ["XDNS_DOMAIN"]
target = os.environ["XDNS_DIRECT_TARGET"]
method = os.environ.get("XDNS_METHOD", "txt").strip().lower()
suffix = "" if method in ("", "txt") else ":" + method
# Direct mode: send xdns-encoded queries straight to the server XDNS port
# (host PORT_XDNS -> xray:5355), with no public recursive resolver in between.
print(json.dumps({"resolvers": [domain + suffix + "+udp://" + target]}))
')

        # Load user UUID. credentials.env (sourced above) already provides
        # USER_UUID on current installs; older installs kept it in a separate
        # uuid.env. Prefer whatever's already loaded, then let uuid.env override
        # if it exists — don't blank it out when uuid.env is absent.
        _xdns_uuid="${USER_UUID:-}"
        if [[ -f "$STATE_DIR/users/$USER_ID/uuid.env" ]]; then
            source "$STATE_DIR/users/$USER_ID/uuid.env"
            _xdns_uuid="${USER_UUID:-$_xdns_uuid}"
        fi

        if [[ -n "$_xdns_uuid" ]]; then
            # DNS resolver config
            cat > "$OUTPUT_DIR/xdns-config.json" <<XDNSEOF
{
  "remarks": "MoaV-XDNS-${USER_ID} (via DNS)",
  "log": {"loglevel": "warning"},
  "inbounds": [{"listen": "127.0.0.1", "port": 7891, "protocol": "socks", "settings": {"auth": "noauth", "udp": true}}],
  "outbounds": [
    {"tag": "proxy", "protocol": "vless", "settings": {"vnext": [{"address": "8.8.8.8", "port": 53, "users": [{"id": "$_xdns_uuid", "encryption": "none"}]}]}, "streamSettings": {"network": "kcp", "kcpSettings": {"mtu": $_xdns_mtu, "tti": 100, "uplinkCapacity": 0, "downlinkCapacity": 0, "congestion": true}, "finalmask": {"udp": [{"type": "xdns", "settings": ${_xdns_finalmask_settings}}]}}},
    {"tag": "direct", "protocol": "freedom"}
  ],
  "routing": {"rules": [{"type": "field", "ip": ["::/0"], "outboundTag": "direct"}]}
}
XDNSEOF

            # Direct connection config
            cat > "$OUTPUT_DIR/xdns-direct-config.json" <<XDNSEOF2
{
  "remarks": "MoaV-XDNS-${USER_ID} (direct)",
  "log": {"loglevel": "warning"},
  "inbounds": [{"listen": "127.0.0.1", "port": 7891, "protocol": "socks", "settings": {"auth": "noauth", "udp": true}}],
  "outbounds": [
    {"tag": "proxy", "protocol": "vless", "settings": {"vnext": [{"address": "${SERVER_IP}", "port": ${PORT_XDNS:-5356}, "users": [{"id": "$_xdns_uuid", "encryption": "none"}]}]}, "streamSettings": {"network": "kcp", "kcpSettings": {"mtu": $_xdns_mtu, "tti": 100, "uplinkCapacity": 0, "downlinkCapacity": 0, "congestion": true}, "finalmask": {"udp": [{"type": "xdns", "settings": ${_xdns_finalmask_settings_direct}}]}}},
    {"tag": "direct", "protocol": "freedom"}
  ],
  "routing": {"rules": [{"type": "field", "ip": ["::/0"], "outboundTag": "direct"}]}
}
XDNSEOF2

            # Human-readable instructions (kept in sync with the JSON above so it
            # doesn't go stale after a domain/resolver change — see issue #98).
            cat > "$OUTPUT_DIR/xdns.txt" <<XDNSTXTEOF
XDNS (DNS Tunnel via Xray mKCP) Configuration for $USER_ID
============================================================

Protocol: VLESS + mKCP + XDNS FinalMask (via Xray-core)
Domain: ${_xdns_domain}
UUID: ${_xdns_uuid}
MTU: ${_xdns_mtu}

This protocol tunnels VPN traffic through DNS queries.
It works when almost everything except DNS is blocked.
Speed is slow but connectivity is reliable.

IMPORTANT: XDNS requires Xray-core v26+ with FinalMask support.

Recommended clients:
- Happ (iOS/Android/Desktop) — supports FinalMask
- Xray CLI v26.3+ (any platform) — run: xray run -c xdns-config.json

Two configs included:

  xdns-config.json        Via DNS resolver — stealthier, may reconnect periodically
  xdns-direct-config.json Via direct server connection — more stable, less stealthy

Setup:
1. Import one of the configs into an Xray-compatible app with FinalMask support
2. Use as SOCKS5 proxy: 127.0.0.1:7891
3. For Telegram: tap https://t.me/socks?server=127.0.0.1&port=7891

Tips:
- Try the DNS resolver config first (stealthier)
- Switch to direct if connections keep dropping
- The DNS-resolver config round-robins across: ${_xdns_resolvers_csv:-(single resolver mode)}
- If those keep dropping, edit the "resolvers" array in xdns-config.json
  with DNS servers that actually answer on your network.
- Scanners that find reachable resolvers:
    findns   https://github.com/SamNet-dev/findns
    dns-mns  https://gitlab.com/E-Gurl/dns-mns

MTU tuning (client side only — server uses MTU 900 for return path):
- MTU ${_xdns_mtu} = safest (works with all resolvers)
- MTU 67 = works with most resolvers (faster)
- MTU 130 = unrestricted resolvers only (fastest)
- MTU depends on domain name length: shorter domain = higher MTU possible
XDNSTXTEOF

            log_info "  - XDNS configs generated"
        fi
    fi
fi

# -----------------------------------------------------------------------------
# Generate README.html from template
# -----------------------------------------------------------------------------
TEMPLATE_FILE="/docs/client-guide-template.html"
OUTPUT_HTML="$OUTPUT_DIR/README.html"

# Regenerate README.html if: bundle changed, doesn't exist, or template is newer
if [[ -f "$OUTPUT_HTML" ]] && [[ "$BUNDLE_CHANGED" == "false" ]] && [[ "$FORCE_REGENERATE" != "force" ]] && [[ ! "$TEMPLATE_FILE" -nt "$OUTPUT_HTML" ]]; then
    log_info "  - README.html exists and no new configs, skipping"
elif [[ -f "$TEMPLATE_FILE" ]]; then
    # Read config values
    CONFIG_REALITY=$(cat "$OUTPUT_DIR/reality.txt" 2>/dev/null | tr -d '\n' || echo "")
    CONFIG_HYSTERIA2=$(cat "$OUTPUT_DIR/hysteria2.txt" 2>/dev/null | tr -d '\n' || echo "")
    CONFIG_TROJAN=$(cat "$OUTPUT_DIR/trojan.txt" 2>/dev/null | tr -d '\n' || echo "")
    CONFIG_ANYTLS=$(cat "$OUTPUT_DIR/anytls.txt" 2>/dev/null | tr -d '\n' || echo "")
    CONFIG_CDN=$(cat "$OUTPUT_DIR/cdn-vless.txt" 2>/dev/null | tr -d '\n' || echo "")
    CONFIG_WIREGUARD=$(cat "$OUTPUT_DIR/wireguard.conf" 2>/dev/null || echo "")
    CONFIG_WIREGUARD_WSTUNNEL=$(cat "$OUTPUT_DIR/wireguard-wstunnel.conf" 2>/dev/null || echo "")
    CONFIG_AMNEZIAWG=$(cat "$OUTPUT_DIR/amneziawg.conf" 2>/dev/null || echo "")

    # Get dnstt info
    DNSTT_DOMAIN="${DNSTT_SUBDOMAIN:-t}.${DOMAIN}"
    DNSTT_PUBKEY=$(cat "$STATE_DIR/keys/dnstt-server.pub.hex" 2>/dev/null || echo "")

    # Get Slipstream info
    SLIPSTREAM_DOMAIN="${SLIPSTREAM_SUBDOMAIN:-s}.${DOMAIN}"
    CONFIG_SLIPSTREAM=$(cat "$OUTPUT_DIR/slipstream-instructions.txt" 2>/dev/null || echo "")

    # Get XDNS info
    CONFIG_XDNS=$(cat "$OUTPUT_DIR/xdns-config.json" 2>/dev/null || echo "")
    CONFIG_XDNS_DIRECT=$(cat "$OUTPUT_DIR/xdns-direct-config.json" 2>/dev/null || echo "")
    XDNS_DISPLAY=""
    [[ -z "$CONFIG_XDNS" ]] && XDNS_DISPLAY="display:none"

    # Get MasterDNS / GooseRelay info (MahsaNG v16 extras; instructions text + display toggle)
    CONFIG_MASTERDNS=$(cat "$OUTPUT_DIR/masterdns-instructions.txt" 2>/dev/null || echo "")
    MASTERDNS_DISPLAY=""
    [[ -z "$CONFIG_MASTERDNS" ]] && MASTERDNS_DISPLAY="display:none"
    CONFIG_GOOSERELAY=$(cat "$OUTPUT_DIR/gooserelay-instructions.txt" 2>/dev/null || echo "")
    GOOSERELAY_DISPLAY=""
    [[ -z "$CONFIG_GOOSERELAY" ]] && GOOSERELAY_DISPLAY="display:none"

    # Get telemt info
    CONFIG_TELEMT=$(cat "$OUTPUT_DIR/telegram-proxy-link.txt" 2>/dev/null | tr -d '\n' || echo "")

    # Convert QR images to base64
    qr_to_base64() {
        local file="$1"
        if [[ -f "$file" ]]; then
            base64 < "$file" 2>/dev/null | tr -d '\n' || echo ""
        else
            echo ""
        fi
    }

    QR_REALITY_B64=$(qr_to_base64 "$OUTPUT_DIR/reality-qr.png")
    QR_HYSTERIA2_B64=$(qr_to_base64 "$OUTPUT_DIR/hysteria2-qr.png")
    QR_TROJAN_B64=$(qr_to_base64 "$OUTPUT_DIR/trojan-qr.png")
    QR_ANYTLS_B64=$(qr_to_base64 "$OUTPUT_DIR/anytls-qr.png")
    QR_CDN_B64=$(qr_to_base64 "$OUTPUT_DIR/cdn-vless-qr.png")
    QR_WIREGUARD_B64=$(qr_to_base64 "$OUTPUT_DIR/wireguard-qr.png")
    QR_WIREGUARD_WSTUNNEL_B64=$(qr_to_base64 "$OUTPUT_DIR/wireguard-wstunnel-qr.png")
    QR_AMNEZIAWG_B64=$(qr_to_base64 "$OUTPUT_DIR/amneziawg-qr.png")
    QR_TELEMT_B64=$(qr_to_base64 "$OUTPUT_DIR/telegram-proxy-qr.png")

    GENERATED_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Copy template and replace placeholders
    cp "$TEMPLATE_FILE" "$OUTPUT_HTML"

    # Simple replacements
    sed -i "s|{{USERNAME}}|$USER_ID|g" "$OUTPUT_HTML"
    sed -i "s|{{SERVER_IP}}|$SERVER_IP|g" "$OUTPUT_HTML"
    sed -i "s|{{DOMAIN}}|$DOMAIN|g" "$OUTPUT_HTML"
    sed -i "s|{{WSTUNNEL_CMD}}|$(wstunnel_client_cmd)|g" "$OUTPUT_HTML"
    sed -i "s|{{GENERATED_DATE}}|$GENERATED_DATE|g" "$OUTPUT_HTML"
    sed -i "s|{{DNSTT_DOMAIN}}|$DNSTT_DOMAIN|g" "$OUTPUT_HTML"
    sed -i "s|{{DNSTT_PUBKEY}}|$DNSTT_PUBKEY|g" "$OUTPUT_HTML"
    sed -i "s|{{SLIPSTREAM_DOMAIN}}|$SLIPSTREAM_DOMAIN|g" "$OUTPUT_HTML"

    # V2Ray subscription: base64 of the newline-joined compatible share-links,
    # so the user can paste it once into any V2Ray app (MahsaNG, v2rayNG,
    # Hiddify, ...) to import all proxy protocols. DNS tunnels + GooseRelay are
    # configured separately and intentionally excluded. base64 has no '|', so it
    # is safe in the sed replacement below.
    _mahsanet_uris=""
    for _f in reality cdn-vless xhttp-vless trojan anytls shadowsocks hysteria2 \
              reality-ipv6 trojan-ipv6 anytls-ipv6 shadowsocks-ipv6 hysteria2-ipv6; do
        [[ -f "$OUTPUT_DIR/$_f.txt" ]] || continue
        _u=$(tr -d '\r' < "$OUTPUT_DIR/$_f.txt" | grep -aE '^(vless|trojan|anytls|ss|hysteria2|vmess)://' | head -1 || true)
        [[ -n "$_u" ]] && _mahsanet_uris+="$_u"$'\n'
    done
    if [[ -n "$_mahsanet_uris" ]]; then
        _mahsanet_sub=$(printf '%s' "$_mahsanet_uris" | base64 | tr -d '\n')
        # Also drop the subscription as a standalone file so the bundle isn't
        # HTML-only (handy for hosting as a sub URL or importing from a file).
        printf '%s\n' "$_mahsanet_sub" > "$OUTPUT_DIR/subscription.txt"
        sed -i "s|{{MAHSANET_SUB}}|$_mahsanet_sub|g" "$OUTPUT_HTML"
        sed -i "s|{{MAHSANET_DISPLAY}}||g" "$OUTPUT_HTML"
    else
        sed -i "s|{{MAHSANET_SUB}}|No V2Ray-compatible configs in this bundle|g" "$OUTPUT_HTML"
        sed -i "s|{{MAHSANET_DISPLAY}}|display:none|g" "$OUTPUT_HTML"
    fi

    # TrustTunnel password (same as user password) - escape special chars
    if [[ -n "${USER_PASSWORD:-}" ]]; then
        escaped_pw=$(printf '%s' "$USER_PASSWORD" | sed -e 's/[&\\/]/\\&/g')
        sed -i "s|{{TRUSTTUNNEL_PASSWORD}}|${escaped_pw}|g" "$OUTPUT_HTML"
    else
        sed -i "s|{{TRUSTTUNNEL_PASSWORD}}|See trusttunnel.txt|g" "$OUTPUT_HTML"
    fi

    # Demo user notice (only for bootstrap demouser)
    if [[ "${IS_DEMO_USER:-false}" == "true" ]]; then
        # Build list of disabled services
        DISABLED_SERVICES=""
        [[ "${ENABLE_WIREGUARD:-true}" != "true" ]] && DISABLED_SERVICES+="WireGuard, "
        [[ "${ENABLE_DNSTT:-true}" != "true" ]] && DISABLED_SERVICES+="DNS Tunnel, "
        [[ "${ENABLE_TROJAN:-true}" != "true" ]] && DISABLED_SERVICES+="Trojan, "
        [[ "${ENABLE_ANYTLS:-false}" != "true" ]] && DISABLED_SERVICES+="AnyTLS, "
        [[ "${ENABLE_HYSTERIA2:-true}" != "true" ]] && DISABLED_SERVICES+="Hysteria2, "
        [[ "${ENABLE_REALITY:-true}" != "true" ]] && DISABLED_SERVICES+="Reality, "
        DISABLED_SERVICES="${DISABLED_SERVICES%, }"  # Remove trailing comma

        # English notice
        DEMO_NOTICE_EN='<div class="warning" style="background: rgba(210, 153, 34, 0.1); border-color: var(--accent-orange); color: var(--accent-orange); margin-top: 12px;"><strong>Demo User Notice:</strong> This is a demo account created during initial setup. Some config files may be missing if services were not enabled'"${DISABLED_SERVICES:+ ($DISABLED_SERVICES)}"'. See <a href="https://github.com/moav-project/moav/tree/main/docs" style="color: var(--accent-orange);">documentation</a> for setup.</div>'

        # Farsi notice
        DEMO_NOTICE_FA='<div class="warning" style="background: rgba(210, 153, 34, 0.1); border-color: var(--accent-orange); color: var(--accent-orange); margin-top: 12px;"><strong>توجه:</strong> این یک حساب کاربری آزمایشی است. برخی فایل‌های پیکربندی ممکن است وجود نداشته باشند. برای راهنمایی به <a href="https://github.com/moav-project/moav/tree/main/docs" style="color: var(--accent-orange);">مستندات</a> مراجعه کنید.</div>'

        sed -i "s|{{DEMO_NOTICE_EN}}|$DEMO_NOTICE_EN|g" "$OUTPUT_HTML"
        sed -i "s|{{DEMO_NOTICE_FA}}|$DEMO_NOTICE_FA|g" "$OUTPUT_HTML"
    else
        # Remove placeholders for non-demo users
        sed -i "s|{{DEMO_NOTICE_EN}}||g" "$OUTPUT_HTML"
        sed -i "s|{{DEMO_NOTICE_FA}}||g" "$OUTPUT_HTML"
    fi

    # Clean up any .bak files
    rm -f "$OUTPUT_HTML.bak"

    # QR codes (base64) - safe for sed as base64 has no special chars
    sed -i "s|{{QR_REALITY}}|$QR_REALITY_B64|g" "$OUTPUT_HTML"
    sed -i "s|{{QR_HYSTERIA2}}|$QR_HYSTERIA2_B64|g" "$OUTPUT_HTML"
    sed -i "s|{{QR_TROJAN}}|$QR_TROJAN_B64|g" "$OUTPUT_HTML"
    sed -i "s|{{QR_ANYTLS}}|$QR_ANYTLS_B64|g" "$OUTPUT_HTML"
    sed -i "s|{{QR_CDN}}|$QR_CDN_B64|g" "$OUTPUT_HTML"
    sed -i "s|{{QR_WIREGUARD}}|$QR_WIREGUARD_B64|g" "$OUTPUT_HTML"
    sed -i "s|{{QR_WIREGUARD_WSTUNNEL}}|$QR_WIREGUARD_WSTUNNEL_B64|g" "$OUTPUT_HTML"
    sed -i "s|{{QR_AMNEZIAWG}}|$QR_AMNEZIAWG_B64|g" "$OUTPUT_HTML"
    sed -i "s|{{QR_TELEMT}}|$QR_TELEMT_B64|g" "$OUTPUT_HTML"

    # Python-based placeholder replacement - handles special chars and multiline safely
    replace_placeholder() {
        local placeholder="$1"
        local value="$2"
        python3 -c "
import sys
placeholder = sys.argv[1]
value = sys.argv[2]
filepath = sys.argv[3]
with open(filepath, 'r') as f:
    content = f.read()
content = content.replace(placeholder, value)
with open(filepath, 'w') as f:
    f.write(content)
" "$placeholder" "$value" "$OUTPUT_HTML"
    }

    if [[ -n "$CONFIG_REALITY" ]]; then
        replace_placeholder "{{CONFIG_REALITY}}" "$CONFIG_REALITY"
    else
        replace_placeholder "{{CONFIG_REALITY}}" "No Reality config available"
    fi

    if [[ -n "$CONFIG_HYSTERIA2" ]]; then
        replace_placeholder "{{CONFIG_HYSTERIA2}}" "$CONFIG_HYSTERIA2"
    else
        replace_placeholder "{{CONFIG_HYSTERIA2}}" "No Hysteria2 config available"
    fi

    if [[ -n "$CONFIG_TROJAN" ]]; then
        replace_placeholder "{{CONFIG_TROJAN}}" "$CONFIG_TROJAN"
    else
        replace_placeholder "{{CONFIG_TROJAN}}" "No Trojan config available"
    fi

    if [[ -n "$CONFIG_ANYTLS" ]]; then
        replace_placeholder "{{CONFIG_ANYTLS}}" "$CONFIG_ANYTLS"
    else
        replace_placeholder "{{CONFIG_ANYTLS}}" "No AnyTLS config available"
    fi

    # CDN VLESS+WS config
    if [[ -n "$CONFIG_CDN" ]]; then
        replace_placeholder "{{CONFIG_CDN}}" "$CONFIG_CDN"
        replace_placeholder "{{CDN_DOMAIN}}" "${CDN_DOMAIN:-}"
    else
        replace_placeholder "{{CONFIG_CDN}}" "CDN not configured"
        replace_placeholder "{{CDN_DOMAIN}}" "Not configured"
    fi

    # WireGuard config is multiline - use Python replacement
    if [[ -n "$CONFIG_WIREGUARD" ]]; then
        replace_placeholder "{{CONFIG_WIREGUARD}}" "$CONFIG_WIREGUARD"
    else
        replace_placeholder "{{CONFIG_WIREGUARD}}" "No WireGuard config available"
    fi

    # WireGuard-wstunnel config is multiline
    if [[ -n "$CONFIG_WIREGUARD_WSTUNNEL" ]]; then
        replace_placeholder "{{CONFIG_WIREGUARD_WSTUNNEL}}" "$CONFIG_WIREGUARD_WSTUNNEL"
    else
        replace_placeholder "{{CONFIG_WIREGUARD_WSTUNNEL}}" "No WireGuard-wstunnel config available"
    fi

    # AmneziaWG config is multiline
    if [[ -n "$CONFIG_AMNEZIAWG" ]]; then
        replace_placeholder "{{CONFIG_AMNEZIAWG}}" "$CONFIG_AMNEZIAWG"
    else
        replace_placeholder "{{CONFIG_AMNEZIAWG}}" "No AmneziaWG config available"
    fi

    # Slipstream instructions
    if [[ -n "${CONFIG_SLIPSTREAM:-}" ]]; then
        replace_placeholder "{{CONFIG_SLIPSTREAM}}" "$CONFIG_SLIPSTREAM"
    else
        replace_placeholder "{{CONFIG_SLIPSTREAM}}" "Slipstream not enabled"
    fi

    # XDNS config (multiline JSON — use file-based replacement to avoid shell escaping issues)
    if [[ -f "$OUTPUT_DIR/xdns-config.json" ]]; then
        python3 -c "
import sys, os
html_path = sys.argv[1]
dns_path = sys.argv[2]
direct_path = sys.argv[3]
with open(html_path, 'r') as f: html = f.read()
try:
    with open(dns_path, 'r') as f: dns_cfg = f.read().strip()
except: dns_cfg = 'XDNS config not available'
try:
    with open(direct_path, 'r') as f: direct_cfg = f.read().strip()
except: direct_cfg = 'XDNS direct config not available'
html = html.replace('{{CONFIG_XDNS}}', dns_cfg)
html = html.replace('{{CONFIG_XDNS_DIRECT}}', direct_cfg)
html = html.replace('{{XDNS_DISPLAY}}', '')
with open(html_path, 'w') as f: f.write(html)
" "$OUTPUT_HTML" "$OUTPUT_DIR/xdns-config.json" "$OUTPUT_DIR/xdns-direct-config.json"
    else
        replace_placeholder "{{CONFIG_XDNS}}" "XDNS not enabled"
        replace_placeholder "{{CONFIG_XDNS_DIRECT}}" "XDNS not enabled"
        replace_placeholder "{{XDNS_DISPLAY}}" "display:none"
    fi

    # MasterDNS / GooseRelay (MahsaNG v16) — multiline instructions; file-based
    # replacement avoids shell-escaping issues, and toggles the section + TOC
    # entry off (display:none) when the protocol isn't enabled for this user.
    python3 -c "
import sys
html_path = sys.argv[1]
with open(html_path) as f: html = f.read()
def fill(name, path, label):
    global html
    try:
        with open(path) as f: cfg = f.read().strip()
    except Exception:
        cfg = ''
    if cfg:
        html = html.replace('{{CONFIG_%s}}' % name, cfg)
        html = html.replace('{{%s_DISPLAY}}' % name, '')
    else:
        html = html.replace('{{CONFIG_%s}}' % name, label + ' not enabled')
        html = html.replace('{{%s_DISPLAY}}' % name, 'display:none')
fill('MASTERDNS', sys.argv[2], 'MasterDNS')
fill('GOOSERELAY', sys.argv[3], 'GooseRelay')
with open(html_path, 'w') as f: f.write(html)
" "$OUTPUT_HTML" "$OUTPUT_DIR/masterdns-instructions.txt" "$OUTPUT_DIR/gooserelay-instructions.txt"

    # telemt (Telegram MTProxy) link
    if [[ -n "${CONFIG_TELEMT:-}" ]]; then
        replace_placeholder "{{CONFIG_TELEMT}}" "$CONFIG_TELEMT"
    else
        replace_placeholder "{{CONFIG_TELEMT}}" "Telegram MTProxy not enabled"
    fi

    log_info "  - README.html generated"
else
    log_info "  - README.html skipped (template not found)"
fi

log_info "Bundle generated at $OUTPUT_DIR"
