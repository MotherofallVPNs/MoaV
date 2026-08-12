#!/bin/bash
set -euo pipefail

# =============================================================================
# Generate user bundle with all client configurations
# Usage: generate-user.sh <user_id>
# =============================================================================

source /app/lib/common.sh
source /app/lib/keys.sh
source /app/lib/wireguard.sh
source /app/lib/amneziawg.sh
source /app/lib/dnstt.sh
source /app/lib/slipstream.sh
source /app/lib/masterdns.sh
source /app/lib/gooserelay.sh
source /app/lib/telemt.sh
source /app/lib/sing-box.sh
source /app/lib/trusttunnel.sh
source /app/lib/xray.sh
source /app/lib/bundle-readme.sh

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

# Load Reality keys whenever they exist. Deliberately NOT gated on
# ENABLE_REALITY: XHTTP is VLESS+Reality-over-xhttp and needs the same keys, and
# ENABLE_XHTTP defaults to true. Gating the source on ENABLE_REALITY meant
# ENABLE_REALITY=false left REALITY_PUBLIC_KEY unset while the XHTTP bundle still
# read it, so every user failed to regenerate.
if [[ -f "$STATE_DIR/keys/reality.env" ]]; then
    source "$STATE_DIR/keys/reality.env"
fi

# Same for the Hysteria2 obfuscation password.
if [[ -f "$STATE_DIR/keys/clash-api.env" ]]; then
    source "$STATE_DIR/keys/clash-api.env"
fi

# Fail with a remediation hint rather than an opaque "unbound variable" when a
# protocol is switched on but bootstrap never generated its key material.
require_keys() {
    local why="$1"; shift
    local missing=() v
    for v in "$@"; do [[ -n "${!v:-}" ]] || missing+=("$v"); done
    if (( ${#missing[@]} )); then
        log_error "$why needs ${missing[*]}, which is not in $STATE_DIR/keys/."
        log_error "Run 'moav bootstrap' to generate the missing key material, then retry."
        exit 1
    fi
}
if [[ "${ENABLE_REALITY:-true}" == "true" || "${ENABLE_XHTTP:-true}" == "true" ]]; then
    require_keys "Reality/XHTTP" REALITY_PUBLIC_KEY REALITY_SHORT_ID
fi
if [[ "${ENABLE_HYSTERIA2:-true}" == "true" ]]; then
    require_keys "Hysteria2" HYSTERIA2_OBFS_PASSWORD
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
    REALITY_LINK=$(singbox_reality_link "$USER_ID" "$SERVER_IP")
    echo "$REALITY_LINK" > "$OUTPUT_DIR/reality.txt"

    # Generate QR code
    qrencode -o "$OUTPUT_DIR/reality-qr.png" -s 6 "$REALITY_LINK" 2>/dev/null || true

    # Generate IPv6 link if available
    if [[ -n "${SERVER_IPV6:-}" ]]; then
        REALITY_LINK_V6=$(singbox_reality_link "IPv6-${USER_ID}" "[${SERVER_IPV6}]")
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
    TROJAN_LINK=$(singbox_trojan_link "$USER_ID" "$SERVER_IP")
    echo "$TROJAN_LINK" > "$OUTPUT_DIR/trojan.txt"
    qrencode -o "$OUTPUT_DIR/trojan-qr.png" -s 6 "$TROJAN_LINK" 2>/dev/null || true

    # Generate IPv6 link if available
    if [[ -n "${SERVER_IPV6:-}" ]]; then
        TROJAN_LINK_V6=$(singbox_trojan_link "IPv6-${USER_ID}" "[${SERVER_IPV6}]")
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
    ANYTLS_LINK=$(singbox_anytls_link "$USER_ID" "$SERVER_IP")
    echo "$ANYTLS_LINK" > "$OUTPUT_DIR/anytls.txt"
    qrencode -o "$OUTPUT_DIR/anytls-qr.png" -s 6 "$ANYTLS_LINK" 2>/dev/null || true

    # Generate IPv6 link if available
    if [[ -n "${SERVER_IPV6:-}" ]]; then
        ANYTLS_LINK_V6=$(singbox_anytls_link "IPv6-${USER_ID}" "[${SERVER_IPV6}]")
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
    HY2_LINK=$(singbox_hysteria2_link "$USER_ID" "$SERVER_IP")
    echo "$HY2_LINK" > "$OUTPUT_DIR/hysteria2.txt"
    qrencode -o "$OUTPUT_DIR/hysteria2-qr.png" -s 6 "$HY2_LINK" 2>/dev/null || true

    # Generate IPv6 link if available
    if [[ -n "${SERVER_IPV6:-}" ]]; then
        HY2_LINK_V6=$(singbox_hysteria2_link "IPv6-${USER_ID}" "[${SERVER_IPV6}]")
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
        SS_USERINFO=$(singbox_ss_userinfo "$SS_METHOD_LOCAL" "$SS_SERVER_PSK_LOCAL" "$SS_USER_PSK")
        SS_LINK=$(singbox_ss_link "$USER_ID" "$SERVER_IP" "$SS_USERINFO" "$SS_PORT")
        echo "$SS_LINK" > "$OUTPUT_DIR/shadowsocks.txt"
        qrencode -o "$OUTPUT_DIR/shadowsocks-qr.png" -s 6 "$SS_LINK" 2>/dev/null || true

        if [[ -n "${SERVER_IPV6:-}" ]]; then
            SS_LINK_V6=$(singbox_ss_link "IPv6-${USER_ID}" "[${SERVER_IPV6}]" "$SS_USERINFO" "$SS_PORT")
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
if ! cdn_enabled; then
    CDN_DOMAIN=""
elif [[ -z "${CDN_DOMAIN:-}" ]]; then
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

    CDN_LINK=$(singbox_cdn_link "$USER_ID")
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
    # Canonical client bundle (lib/trusttunnel.sh): trusttunnel.toml + .json
    trusttunnel_write_client_bundle "$OUTPUT_DIR" "$USER_ID" "$USER_PASSWORD"

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
    xray_write_xhttp_bundle "$OUTPUT_DIR" "$USER_ID"
    log_info "  - XHTTP config generated"
  fi
fi

# -----------------------------------------------------------------------------
# Generate WireGuard config (if enabled)
# -----------------------------------------------------------------------------
if [[ "${ENABLE_WIREGUARD:-true}" == "true" ]]; then
    # Always add peer to server config (wireguard_add_peer has its own guard).
    # It now allocates the next free octet by scanning wg0.conf, so no peer-count
    # is passed (the old count+1 collided with revoked-user gaps).
    # rc=2 => the server has a peer for this user but state has no key
    # material; the private key is unrecoverable, so DON'T re-render the
    # client config from bogus state — that would hand them credentials the
    # server does not know. Leave their working bundle exactly as it is.
    _peer_rc=0; wireguard_add_peer "$USER_ID" || _peer_rc=$?
    if [[ "$_peer_rc" -eq 2 ]]; then
        log_warn "  - WireGuard left untouched for $USER_ID (no key material in state)"
    elif [[ -f "$OUTPUT_DIR/$(moav_wg_basename wg).conf" ]] && [[ "$FORCE_REGENERATE" != "force" ]]; then
        log_info "  - WireGuard config exists, skipping"
    else
        BUNDLE_CHANGED=true
        wireguard_generate_client_config "$USER_ID" "$OUTPUT_DIR"
        qrencode -o "$OUTPUT_DIR/wireguard-qr.png" -s 6 -r "$OUTPUT_DIR/$(moav_wg_basename wg).conf" 2>/dev/null || true
        if [[ -n "${SERVER_IPV6:-}" ]] && [[ -f "$OUTPUT_DIR/$(moav_wg_basename wg6).conf" ]]; then
            qrencode -o "$OUTPUT_DIR/wireguard-ipv6-qr.png" -s 6 -r "$OUTPUT_DIR/$(moav_wg_basename wg6).conf" 2>/dev/null || true
        fi
        log_info "  - WireGuard config generated (direct + wstunnel${SERVER_IPV6:+ + ipv6})"
    fi
fi

# -----------------------------------------------------------------------------
# Generate AmneziaWG config (if enabled)
# -----------------------------------------------------------------------------
if [[ "${ENABLE_AMNEZIAWG:-true}" == "true" ]]; then
    # Always add peer to server config (amneziawg_add_peer has its own guard).
    # It now allocates the next free octet by scanning awg0.conf, so no peer-count
    # is passed (the old count+1 collided with revoked-user gaps).
    # rc=2 => the server has a peer for this user but state has no key
    # material; the private key is unrecoverable, so DON'T re-render the
    # client config from bogus state — that would hand them credentials the
    # server does not know. Leave their working bundle exactly as it is.
    _peer_rc=0; amneziawg_add_peer "$USER_ID" || _peer_rc=$?
    if [[ "$_peer_rc" -eq 2 ]]; then
        log_warn "  - AmneziaWG left untouched for $USER_ID (no key material in state)"
    elif [[ -f "$OUTPUT_DIR/$(moav_wg_basename awg).conf" ]] && [[ "$FORCE_REGENERATE" != "force" ]]; then
        log_info "  - AmneziaWG config exists, skipping"
    else
        BUNDLE_CHANGED=true
        amneziawg_generate_client_config "$USER_ID" "$OUTPUT_DIR"
        qrencode -o "$OUTPUT_DIR/amneziawg-qr.png" -s 6 -r "$OUTPUT_DIR/$(moav_wg_basename awg).conf" 2>/dev/null || true
        if [[ -n "${SERVER_IPV6:-}" ]] && [[ -f "$OUTPUT_DIR/$(moav_wg_basename awg6).conf" ]]; then
            qrencode -o "$OUTPUT_DIR/amneziawg-ipv6-qr.png" -s 6 -r "$OUTPUT_DIR/$(moav_wg_basename awg6).conf" 2>/dev/null || true
        fi
        log_info "  - AmneziaWG config generated (obfuscated WireGuard${SERVER_IPV6:+ + ipv6})"
    fi
fi

# -----------------------------------------------------------------------------
# Generate Slipstream instructions (if enabled)
# -----------------------------------------------------------------------------
if [[ "${ENABLE_SLIPSTREAM:-true}" == "true" ]]; then
    if [[ -f "$OUTPUT_DIR/slipstream-cert.pem" ]] && [[ "$FORCE_REGENERATE" != "force" ]]; then
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
    if [[ -f "$OUTPUT_DIR/masterdns-client_config.toml" ]] && [[ "$FORCE_REGENERATE" != "force" ]]; then
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
    if [[ -f "$OUTPUT_DIR/gooserelay-client_config.json" ]] && [[ "$FORCE_REGENERATE" != "force" ]]; then
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
    if [[ ! -f "$STATE_DIR/users/$USER_ID/telemt.env" ]]; then
        # Donate-mode users are provisioned for a subset of protocols, so no
        # secret means "not this user" -- not a failure. Without this the
        # generator returns 1 and set -e loses the whole bundle over a protocol
        # the user was never meant to have.
        log_info "  - telemt: not provisioned for this user, skipping"
    elif [[ -f "$OUTPUT_DIR/telegram-proxy-link.txt" ]] && [[ "$FORCE_REGENERATE" != "force" ]]; then
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
        # Resolve the user UUID: credentials.env (sourced above) provides
        # USER_UUID on current installs; older installs kept it in uuid.env —
        # let that override when present, but don't blank it out when absent.
        _xdns_uuid="${USER_UUID:-}"
        if [[ -f "$STATE_DIR/users/$USER_ID/uuid.env" ]]; then
            source "$STATE_DIR/users/$USER_ID/uuid.env"
            _xdns_uuid="${USER_UUID:-$_xdns_uuid}"
        fi

        if [[ -n "$_xdns_uuid" ]]; then
            xray_write_xdns_bundle "$OUTPUT_DIR" "$USER_ID" "$_xdns_uuid"
            log_info "  - XDNS configs generated"
        fi
    fi
fi

# -----------------------------------------------------------------------------
# Generate README.html from template (shared renderer — lib/bundle-readme.sh)
# -----------------------------------------------------------------------------
TEMPLATE_FILE="/templates/client-guide-template.html"
OUTPUT_HTML="$OUTPUT_DIR/README.html"

# Regenerate README.html if: bundle changed, doesn't exist, or template is newer
if [[ -f "$OUTPUT_HTML" ]] && [[ "$BUNDLE_CHANGED" == "false" ]] && [[ "$FORCE_REGENERATE" != "force" ]] && [[ ! "$TEMPLATE_FILE" -nt "$OUTPUT_HTML" ]]; then
    log_info "  - README.html exists and no new configs, skipping"
else
    # DNSTT public key source is context-specific (state volume in the container).
    DNSTT_PUBKEY=$(cat "$STATE_DIR/keys/dnstt-server.pub.hex" 2>/dev/null || echo "")
    if [[ "${ENABLE_DNSTT:-true}" == "true" && -n "$DNSTT_PUBKEY" ]]; then
        dnstt_write_client_pubkey "$OUTPUT_DIR" "$DNSTT_PUBKEY" || true
    else
        DNSTT_PUBKEY=""
    fi
    render_bundle_readme "$USER_ID" "$OUTPUT_DIR" "$TEMPLATE_FILE" "container"
fi

log_info "Bundle generated at $OUTPUT_DIR"
