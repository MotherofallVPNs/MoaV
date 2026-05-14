#!/bin/bash
set -euo pipefail

# =============================================================================
# MoaV Bootstrap Script
# Initializes the stack on first run: generates keys, creates users, configs
# =============================================================================

source /app/lib/common.sh
source /app/lib/sing-box.sh
source /app/lib/wireguard.sh
source /app/lib/amneziawg.sh
source /app/lib/dnstt.sh
source /app/lib/slipstream.sh
source /app/lib/telemt.sh

log_info "Starting MoaV bootstrap..."

# -----------------------------------------------------------------------------
# Validate required environment variables
# -----------------------------------------------------------------------------
required_vars=(
    "INITIAL_USERS"
)

for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        log_error "Required environment variable $var is not set"
        exit 1
    fi
done

# Check if DOMAIN is required (needed for TLS-based protocols)
# Domain is required if ANY of: Reality, Trojan, Hysteria2, or dnstt is enabled
# Note: Reality works without a domain (uses REALITY_TARGET for TLS camouflage)
# Note: Admin UI works without domain using self-signed certificates
# Note: Telegram MTProxy works without domain (IP only + fake-TLS)
domain_required=false
[[ "${ENABLE_TROJAN:-true}" == "true" ]] && domain_required=true
[[ "${ENABLE_HYSTERIA2:-true}" == "true" ]] && domain_required=true
[[ "${ENABLE_DNSTT:-true}" == "true" ]] && domain_required=true
[[ "${ENABLE_SLIPSTREAM:-true}" == "true" ]] && domain_required=true
[[ "${ENABLE_TRUSTTUNNEL:-true}" == "true" ]] && domain_required=true

if [[ "$domain_required" == "true" ]] && [[ -z "${DOMAIN:-}" ]]; then
    log_error "DOMAIN is required when TLS-cert protocols are enabled"
    log_error ""
    log_error "Option 1: Set a domain in .env"
    log_error "  DOMAIN=your-domain.com"
    log_error ""
    log_error "Option 2: Run in domainless mode"
    log_error "  Disable cert-based protocols (Reality still works without domain):"
    log_error "    ENABLE_TROJAN=false"
    log_error "    ENABLE_HYSTERIA2=false"
    log_error "    ENABLE_DNSTT=false"
    log_error "    ENABLE_TRUSTTUNNEL=false"
    log_error ""
    log_error "  Or run: moav domainless"
    exit 1
fi

# Domainless mode notice
if [[ -z "${DOMAIN:-}" ]]; then
    _domainless_protos="Reality, WireGuard, AmneziaWG, Telegram MTProxy, Admin, Conduit, Snowflake"
    [[ "${ENABLE_XHTTP:-true}" == "true" ]] && _domainless_protos="Reality, XHTTP, WireGuard, AmneziaWG, Telegram MTProxy, Admin, Conduit, Snowflake"
    log_info "Running in domainless mode ($_domainless_protos)"

    # Generate self-signed certificate for admin UI (if not exists)
    if [[ "${ENABLE_ADMIN_UI:-true}" == "true" ]]; then
        SELFSIGNED_DIR="/certs/selfsigned"
        if [[ ! -f "$SELFSIGNED_DIR/fullchain.pem" ]]; then
            log_info "Generating self-signed certificate for admin dashboard..."
            mkdir -p "$SELFSIGNED_DIR"
            openssl req -x509 -newkey rsa:4096 \
                -keyout "$SELFSIGNED_DIR/privkey.pem" \
                -out "$SELFSIGNED_DIR/fullchain.pem" \
                -days 365 -nodes \
                -subj "/CN=MoaV Admin" \
                2>/dev/null
            log_info "Self-signed certificate created (valid for 365 days)"
            log_info "Note: Browser will show security warning - this is expected"
        else
            log_info "Self-signed certificate already exists"
        fi
    fi
fi

# -----------------------------------------------------------------------------
# Detect server IP if not provided
# -----------------------------------------------------------------------------
if [[ -z "${SERVER_IP:-}" ]]; then
    log_info "SERVER_IP not set, detecting..."
    SERVER_IP=$(curl -s --max-time 5 https://api.ipify.org || curl -s --max-time 5 https://ifconfig.me || echo "")
    if [[ -z "$SERVER_IP" ]]; then
        log_error "Could not detect server IP. Please set SERVER_IP in .env"
        exit 1
    fi
    log_info "Detected server IP: $SERVER_IP"
fi

export SERVER_IP

# -----------------------------------------------------------------------------
# Detect server IPv6 if not provided or disabled
# -----------------------------------------------------------------------------
if [[ "${SERVER_IPV6:-}" == "disabled" ]]; then
    log_info "IPv6 explicitly disabled"
    SERVER_IPV6=""
elif [[ -z "${SERVER_IPV6:-}" ]]; then
    log_info "SERVER_IPV6 not set, detecting..."
    SERVER_IPV6=$(curl -6 -s --max-time 5 https://api6.ipify.org 2>/dev/null || curl -6 -s --max-time 5 https://ifconfig.me 2>/dev/null || echo "")
    if [[ -n "$SERVER_IPV6" ]]; then
        log_info "Detected server IPv6: $SERVER_IPV6"
    else
        log_info "No IPv6 detected (this is normal, IPv6 is optional)"
    fi
fi

export SERVER_IPV6

# -----------------------------------------------------------------------------
# Initialize state directory
# -----------------------------------------------------------------------------
export STATE_DIR="/state"
mkdir -p "$STATE_DIR"/{users,keys}

# Check if already bootstrapped
if [[ -f "$STATE_DIR/.bootstrapped" ]]; then
    log_info "Already bootstrapped. To re-bootstrap, run:"
    log_info "  docker run --rm -v moav_moav_state:/state alpine rm /state/.bootstrapped"
    log_info "  docker compose --profile setup run --rm bootstrap"
    exit 0
fi

# -----------------------------------------------------------------------------
# Generate Reality keys if not provided (only if Reality is enabled)
# -----------------------------------------------------------------------------
if [[ "${ENABLE_REALITY:-true}" == "true" ]]; then
    # Load existing Reality keys from state if available
    if [[ -f "$STATE_DIR/keys/reality.env" ]]; then
        log_info "Loading existing Reality keys from state..."
        source "$STATE_DIR/keys/reality.env"
    fi

    if [[ -z "${REALITY_PRIVATE_KEY:-}" ]]; then
        log_info "Generating Reality keypair..."
        REALITY_KEYS=$(sing-box generate reality-keypair)
        REALITY_PRIVATE_KEY=$(echo "$REALITY_KEYS" | grep "PrivateKey" | awk '{print $2}')
        REALITY_PUBLIC_KEY=$(echo "$REALITY_KEYS" | grep "PublicKey" | awk '{print $2}')
    else
        log_info "Reality private key already exists, skipping generation"
        # Only derive public key if it's missing (don't clobber existing value)
        if [[ -z "${REALITY_PUBLIC_KEY:-}" ]]; then
            log_info "Reality public key missing, deriving from private key..."
            # x25519 is the same curve as WireGuard's Curve25519 — convert base64url to base64,
            # derive via wg pubkey (available in bootstrap container), convert back to base64url
            REALITY_KEY_B64=$(echo "${REALITY_PRIVATE_KEY}==" | tr '_-' '/+' | head -c 44)
            REALITY_PUBLIC_KEY=$(echo "$REALITY_KEY_B64" | wg pubkey 2>/dev/null | tr '/+' '_-' | sed 's/=*$//' || echo "")
            if [[ -n "$REALITY_PUBLIC_KEY" ]]; then
                log_info "Derived Reality public key: ${REALITY_PUBLIC_KEY:0:10}..."
            else
                log_error "Failed to derive Reality public key! Client configs will be incomplete."
            fi
        fi
    fi

    if [[ -z "${REALITY_SHORT_ID:-}" ]]; then
        REALITY_SHORT_ID=$(openssl rand -hex 4)
    else
        log_info "Reality short ID already exists, skipping generation"
    fi

    # Save keys to state
    cat > "$STATE_DIR/keys/reality.env" <<EOF
REALITY_PRIVATE_KEY=$REALITY_PRIVATE_KEY
REALITY_PUBLIC_KEY=$REALITY_PUBLIC_KEY
REALITY_SHORT_ID=$REALITY_SHORT_ID
EOF

    log_info "Reality keys saved to $STATE_DIR/keys/reality.env"
else
    log_info "Reality is disabled, skipping key generation"
    REALITY_PUBLIC_KEY=""
    REALITY_SHORT_ID=""
fi

# -----------------------------------------------------------------------------
# Generate Clash API secret (only if sing-box protocols are enabled)
# -----------------------------------------------------------------------------
if [[ "${ENABLE_REALITY:-true}" == "true" ]] || [[ "${ENABLE_TROJAN:-true}" == "true" ]] || [[ "${ENABLE_HYSTERIA2:-true}" == "true" ]]; then
    # Load existing secrets from state if available
    if [[ -f "$STATE_DIR/keys/clash-api.env" ]]; then
        source "$STATE_DIR/keys/clash-api.env"
    fi

    if [[ -z "${CLASH_API_SECRET:-}" ]]; then
        CLASH_API_SECRET=$(pwgen -s 32 1)
        log_info "Generated new Clash API secret"
    else
        log_info "Clash API secret already exists, skipping generation"
    fi

    # Generate Hysteria2 obfuscation password (for bypassing QUIC blocking)
    if [[ -z "${HYSTERIA2_OBFS_PASSWORD:-}" ]]; then
        HYSTERIA2_OBFS_PASSWORD=$(pwgen -s 24 1)
        log_info "Generated Hysteria2 obfuscation password"
    else
        log_info "Hysteria2 obfuscation password already exists, skipping generation"
    fi

    # Save to state
    cat > "$STATE_DIR/keys/clash-api.env" <<EOF
CLASH_API_SECRET=$CLASH_API_SECRET
HYSTERIA2_OBFS_PASSWORD=$HYSTERIA2_OBFS_PASSWORD
EOF

    # Parse Reality target
    REALITY_TARGET_HOST=$(echo "${REALITY_TARGET:-dl.google.com:443}" | cut -d: -f1)
    REALITY_TARGET_PORT=$(echo "${REALITY_TARGET:-dl.google.com:443}" | cut -d: -f2)
else
    CLASH_API_SECRET=""
    HYSTERIA2_OBFS_PASSWORD=""
    REALITY_TARGET_HOST=""
    REALITY_TARGET_PORT=""
fi

# -----------------------------------------------------------------------------
# Export variables needed by generate-user.sh
# -----------------------------------------------------------------------------
export REALITY_PUBLIC_KEY
export REALITY_SHORT_ID
export REALITY_TARGET="${REALITY_TARGET:-dl.google.com:443}"
export HYSTERIA2_OBFS_PASSWORD
# In domainless mode, DOMAIN stays empty; otherwise use as-is
export DOMAIN="${DOMAIN:-}"
export DNSTT_SUBDOMAIN="${DNSTT_SUBDOMAIN:-t}"
export ENABLE_REALITY="${ENABLE_REALITY:-true}"
export ENABLE_TROJAN="${ENABLE_TROJAN:-true}"
export ENABLE_HYSTERIA2="${ENABLE_HYSTERIA2:-true}"
export ENABLE_WIREGUARD="${ENABLE_WIREGUARD:-true}"
export ENABLE_AMNEZIAWG="${ENABLE_AMNEZIAWG:-true}"
export ENABLE_DNSTT="${ENABLE_DNSTT:-true}"
export ENABLE_SLIPSTREAM="${ENABLE_SLIPSTREAM:-true}"
export SLIPSTREAM_SUBDOMAIN="${SLIPSTREAM_SUBDOMAIN:-s}"
export ENABLE_TRUSTTUNNEL="${ENABLE_TRUSTTUNNEL:-true}"
export ENABLE_XHTTP="${ENABLE_XHTTP:-true}"
export PORT_XHTTP="${PORT_XHTTP:-2096}"
export XHTTP_REALITY_TARGET="${XHTTP_REALITY_TARGET:-dl.google.com:443}"
export ENABLE_XDNS="${ENABLE_XDNS:-false}"
export XDNS_SUBDOMAIN="${XDNS_SUBDOMAIN:-x}"
export XDNS_MTU="${XDNS_MTU:-35}"
export PORT_XDNS="${PORT_XDNS:-53}"
export ENABLE_TELEMT="${ENABLE_TELEMT:-true}"
export PORT_TELEMT="${PORT_TELEMT:-993}"
export ENABLE_SS="${ENABLE_SS:-false}"
export PORT_SS="${PORT_SS:-8388}"
export SS_METHOD="${SS_METHOD:-2022-blake3-aes-128-gcm}"
export TELEMT_TLS_DOMAIN="${TELEMT_TLS_DOMAIN:-dl.google.com}"
export TELEMT_MAX_TCP_CONNS="${TELEMT_MAX_TCP_CONNS:-100}"
export TELEMT_MAX_UNIQUE_IPS="${TELEMT_MAX_UNIQUE_IPS:-10}"
# Telemt tuning (anti-DPI, resilience, monitoring)
export TELEMT_KEEPALIVE_RANDOM="${TELEMT_KEEPALIVE_RANDOM:-true}"
export TELEMT_KEEPALIVE_JITTER="${TELEMT_KEEPALIVE_JITTER:-4}"
export TELEMT_KEEPALIVE_INTERVAL="${TELEMT_KEEPALIVE_INTERVAL:-20}"
export TELEMT_WARMUP_JITTER="${TELEMT_WARMUP_JITTER:-200}"
export TELEMT_POOL_SIZE="${TELEMT_POOL_SIZE:-12}"
export TELEMT_REINIT_SECS="${TELEMT_REINIT_SECS:-600}"
export TELEMT_HARDSWAP="${TELEMT_HARDSWAP:-true}"
export TELEMT_HARDSWAP_DELAY_MIN="${TELEMT_HARDSWAP_DELAY_MIN:-500}"
export TELEMT_HARDSWAP_DELAY_MAX="${TELEMT_HARDSWAP_DELAY_MAX:-1200}"
export TELEMT_FAST_RETRIES="${TELEMT_FAST_RETRIES:-10}"
export TELEMT_BACKOFF_BASE="${TELEMT_BACKOFF_BASE:-300}"
export TELEMT_BACKOFF_CAP="${TELEMT_BACKOFF_CAP:-10000}"
export TELEMT_STABLE_SNAPSHOTS="${TELEMT_STABLE_SNAPSHOTS:-3}"
export TELEMT_APPLY_COOLDOWN="${TELEMT_APPLY_COOLDOWN:-120}"
export TELEMT_STUN_TCP_FALLBACK="${TELEMT_STUN_TCP_FALLBACK:-true}"
export TELEMT_API_ENABLED="${TELEMT_API_ENABLED:-true}"
export TELEMT_API_PORT="${TELEMT_API_PORT:-9091}"
# Construct CDN_DOMAIN from CDN_SUBDOMAIN + DOMAIN if not explicitly set
if [[ -z "${CDN_DOMAIN:-}" && -n "${CDN_SUBDOMAIN:-}" && -n "${DOMAIN:-}" ]]; then
    export CDN_DOMAIN="${CDN_SUBDOMAIN}.${DOMAIN}"
else
    export CDN_DOMAIN="${CDN_DOMAIN:-}"
fi

# Generate or load CDN WS path (realistic-looking to evade DPI)
if [[ -f "$STATE_DIR/keys/cdn.env" ]]; then
    source "$STATE_DIR/keys/cdn.env"
fi
if [[ -z "${CDN_WS_PATH:-}" || "${CDN_WS_PATH}" == "/ws" ]]; then
    # Generate a random realistic-looking path that blends with normal web traffic
    _cdn_prefixes=("api/v3/storage" "api/v2/assets" "api/v4/cdn" "api/v1/files" "cdn/v2/objects" "static/v3/resources" "dl/v2/packages")
    _cdn_mids=("download" "fetch" "get" "retrieve" "sync" "export" "backup")
    _cdn_files=("update-bundle" "resource-pack" "data-snapshot" "system-archive" "content-index" "cache-manifest" "config-bundle")
    _cdn_exts=("bin" "dat" "pkg" "gz" "zip" "enc")
    _rand_prefix=${_cdn_prefixes[$((RANDOM % ${#_cdn_prefixes[@]}))]}
    _rand_mid=${_cdn_mids[$((RANDOM % ${#_cdn_mids[@]}))]}
    _rand_file=${_cdn_files[$((RANDOM % ${#_cdn_files[@]}))]}
    _rand_ext=${_cdn_exts[$((RANDOM % ${#_cdn_exts[@]}))]}
    _rand_num=$((RANDOM % 90 + 10))
    CDN_WS_PATH="/${_rand_prefix}/${_rand_mid}/${_rand_file}-${_rand_num}.${_rand_ext}"
    log_info "Generated CDN WS path: $CDN_WS_PATH"

    # Persist for subsequent bootstraps
    mkdir -p "$STATE_DIR/keys"
    echo "CDN_WS_PATH=$CDN_WS_PATH" > "$STATE_DIR/keys/cdn.env"
fi
export CDN_WS_PATH
export CDN_TRANSPORT="${CDN_TRANSPORT:-httpupgrade}"
export CDN_SNI="${CDN_SNI:-${DOMAIN:-}}"
export CDN_ADDRESS="${CDN_ADDRESS:-${CDN_DOMAIN:-}}"

# -----------------------------------------------------------------------------
# Generate WireGuard server config (before creating users)
# -----------------------------------------------------------------------------
if [[ "${ENABLE_WIREGUARD:-true}" == "true" ]]; then
    if [[ -f "$STATE_DIR/keys/wg-server.key" ]]; then
        log_info "WireGuard server key exists, regenerating config with existing keys..."
    else
        log_info "Generating new WireGuard server keys and configuration..."
    fi
    generate_wireguard_config

    # Verify keys are consistent
    if [[ -f "$STATE_DIR/keys/wg-server.key" ]] && [[ -f "/configs/wireguard/server.pub" ]]; then
        DERIVED_PUB=$(cat "$STATE_DIR/keys/wg-server.key" | wg pubkey)
        SAVED_PUB=$(cat "/configs/wireguard/server.pub")
        if [[ "$DERIVED_PUB" == "$SAVED_PUB" ]]; then
            log_info "WireGuard keys verified: public key matches private key"
        else
            log_error "WireGuard key mismatch! Fixing..."
            echo "$DERIVED_PUB" > "/configs/wireguard/server.pub"
            echo "$DERIVED_PUB" > "$STATE_DIR/keys/wg-server.pub"
            log_info "Fixed server.pub to match private key"
        fi
    fi
fi

# -----------------------------------------------------------------------------
# Generate AmneziaWG server config (before creating users)
# -----------------------------------------------------------------------------
if [[ "${ENABLE_AMNEZIAWG:-true}" == "true" ]]; then
    if [[ -f "$STATE_DIR/keys/awg-server.key" ]]; then
        log_info "AmneziaWG server key exists, regenerating config with existing keys..."
    else
        log_info "Generating new AmneziaWG server keys and configuration..."
    fi
    generate_amneziawg_config

    # Verify keys are consistent
    if [[ -f "$STATE_DIR/keys/awg-server.key" ]] && [[ -f "/configs/amneziawg/server.pub" ]]; then
        DERIVED_PUB=$(cat "$STATE_DIR/keys/awg-server.key" | wg pubkey)
        SAVED_PUB=$(cat "/configs/amneziawg/server.pub")
        if [[ "$DERIVED_PUB" == "$SAVED_PUB" ]]; then
            log_info "AmneziaWG keys verified: public key matches private key"
        else
            log_error "AmneziaWG key mismatch! Fixing..."
            echo "$DERIVED_PUB" > "/configs/amneziawg/server.pub"
            echo "$DERIVED_PUB" > "$STATE_DIR/keys/awg-server.pub"
            log_info "Fixed server.pub to match private key"
        fi
    fi
fi

# -----------------------------------------------------------------------------
# Generate dnstt server config (before creating users)
# -----------------------------------------------------------------------------
if [[ "${ENABLE_DNSTT:-true}" == "true" ]]; then
    log_info "Generating dnstt server configuration..."
    if generate_dnstt_config; then
        log_info "dnstt configuration complete"
        # Verify key file exists
        if [[ -f "$STATE_DIR/keys/dnstt-server.key.hex" ]]; then
            log_info "dnstt key file verified: $(wc -c < "$STATE_DIR/keys/dnstt-server.key.hex") bytes"
        else
            log_error "dnstt key file NOT found after generation!"
        fi
    else
        log_error "dnstt configuration FAILED"
    fi
else
    log_info "dnstt is disabled, skipping configuration"
fi

# -----------------------------------------------------------------------------
# Generate Slipstream config (before creating users)
# -----------------------------------------------------------------------------
if [[ "${ENABLE_SLIPSTREAM:-true}" == "true" ]]; then
    log_info "Generating Slipstream configuration..."
    if generate_slipstream_config; then
        log_info "Slipstream configuration complete"
        if [[ -f "$STATE_DIR/keys/slipstream-cert.pem" ]]; then
            log_info "Slipstream certificate verified"
        else
            log_error "Slipstream certificate NOT found after generation!"
        fi
    else
        log_error "Slipstream configuration FAILED"
    fi
else
    log_info "Slipstream is disabled, skipping configuration"
fi

# -----------------------------------------------------------------------------
# Generate / load Shadowsocks-2022 server PSK (stable across re-bootstraps)
# Key length depends on the cipher: aes-128 → 16 bytes, aes-256/chacha20 → 32 bytes.
# -----------------------------------------------------------------------------
ss_psk_bytes() {
    case "$1" in
        2022-blake3-aes-128-gcm) echo 16 ;;
        *)                       echo 32 ;;  # aes-256-gcm, chacha20-poly1305, future ciphers
    esac
}

if [[ "${ENABLE_SS:-false}" == "true" ]]; then
    case "$SS_METHOD" in
        2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm) : ;;
        *)
            log_error "SS_METHOD=$SS_METHOD is not supported in multi-user mode."
            log_error "Use 2022-blake3-aes-128-gcm or 2022-blake3-aes-256-gcm."
            log_error "(2022-blake3-chacha20-poly1305 is single-user only and will fail at sing-box startup.)"
            exit 1 ;;
    esac

    expected_psk_len=$(ss_psk_bytes "$SS_METHOD")
    # If the saved PSK no longer matches the cipher's key length (operator changed
    # SS_METHOD), wipe the SS state so we regenerate everything cleanly.
    if [[ -f "$STATE_DIR/keys/shadowsocks-server.psk" ]]; then
        actual_psk_len=$(base64 -d < "$STATE_DIR/keys/shadowsocks-server.psk" 2>/dev/null | wc -c | tr -d ' ')
        if [[ "$actual_psk_len" != "$expected_psk_len" ]]; then
            log_info "SS_METHOD changed (server PSK is ${actual_psk_len} bytes, cipher expects ${expected_psk_len}); regenerating SS keys"
            rm -f "$STATE_DIR/keys/shadowsocks-server.psk"
            rm -f "$STATE_DIR"/users/*/shadowsocks.env 2>/dev/null || true
        fi
    fi

    if [[ -f "$STATE_DIR/keys/shadowsocks-server.psk" ]]; then
        SS_SERVER_PSK=$(cat "$STATE_DIR/keys/shadowsocks-server.psk")
        log_info "Loaded existing Shadowsocks server PSK"
    else
        SS_SERVER_PSK=$(openssl rand -base64 "$expected_psk_len")
        mkdir -p "$STATE_DIR/keys"
        echo "$SS_SERVER_PSK" > "$STATE_DIR/keys/shadowsocks-server.psk"
        log_info "Generated Shadowsocks server PSK"
    fi
    export SS_SERVER_PSK
fi

# -----------------------------------------------------------------------------
# Create initial users
# -----------------------------------------------------------------------------
log_info "Creating $INITIAL_USERS initial users..."

REALITY_USERS_JSON="["
TROJAN_USERS_JSON="["
HYSTERIA2_USERS_JSON="["
VLESS_WS_USERS_JSON="["
SHADOWSOCKS_USERS_JSON="["
TRUSTTUNNEL_CREDENTIALS=""
XRAY_USERS_JSON=""
TELEMT_USERS_TOML=""
TELEMT_CONNS_TOML=""
TELEMT_IPS_TOML=""

for i in $(seq -w 1 "$INITIAL_USERS"); do
    # Use "demouser" for single user, otherwise "user01", "user02", etc.
    if [[ "$INITIAL_USERS" == "1" ]]; then
        USER_ID="demouser"
        export IS_DEMO_USER="true"
    else
        USER_ID="user$i"
        export IS_DEMO_USER="false"
    fi

    mkdir -p "$STATE_DIR/users/$USER_ID"

    # Load existing credentials if available, only generate if missing
    if [[ -f "$STATE_DIR/users/$USER_ID/credentials.env" ]]; then
        log_info "Loading existing credentials for user: $USER_ID"
        source "$STATE_DIR/users/$USER_ID/credentials.env"
    else
        USER_UUID=$(sing-box generate uuid)
        USER_PASSWORD=$(pwgen -s 24 1)
        log_info "Creating new user: $USER_ID"

        # Store user credentials
        cat > "$STATE_DIR/users/$USER_ID/credentials.env" <<EOF
USER_ID=$USER_ID
USER_UUID=$USER_UUID
USER_PASSWORD=$USER_PASSWORD
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
    fi

    # Build JSON arrays for sing-box config
    [[ $i -gt 1 ]] && REALITY_USERS_JSON+=","
    [[ $i -gt 1 ]] && TROJAN_USERS_JSON+=","
    [[ $i -gt 1 ]] && HYSTERIA2_USERS_JSON+=","
    [[ $i -gt 1 ]] && VLESS_WS_USERS_JSON+=","
    [[ $i -gt 1 ]] && SHADOWSOCKS_USERS_JSON+=","

    REALITY_USERS_JSON+="{\"name\":\"$USER_ID\",\"uuid\":\"$USER_UUID\",\"flow\":\"xtls-rprx-vision\"}"
    TROJAN_USERS_JSON+="{\"name\":\"$USER_ID\",\"password\":\"$USER_PASSWORD\"}"
    HYSTERIA2_USERS_JSON+="{\"name\":\"$USER_ID\",\"password\":\"$USER_PASSWORD\"}"
    VLESS_WS_USERS_JSON+="{\"name\":\"$USER_ID\",\"uuid\":\"$USER_UUID\"}"

    # Shadowsocks-2022 per-user PSK — same length as the server PSK
    if [[ "${ENABLE_SS:-false}" == "true" ]]; then
        if [[ -f "$STATE_DIR/users/$USER_ID/shadowsocks.env" ]]; then
            source "$STATE_DIR/users/$USER_ID/shadowsocks.env"
        else
            SS_USER_PSK=$(openssl rand -base64 "$(ss_psk_bytes "$SS_METHOD")")
            cat > "$STATE_DIR/users/$USER_ID/shadowsocks.env" <<EOF
SS_USER_PSK=$SS_USER_PSK
EOF
        fi
        SHADOWSOCKS_USERS_JSON+="{\"name\":\"$USER_ID\",\"password\":\"$SS_USER_PSK\"}"
    fi

    # TrustTunnel credentials (TOML format - uses [[client]] not [[credentials]])
    TRUSTTUNNEL_CREDENTIALS+="[[client]]
username = \"$USER_ID\"
password = \"$USER_PASSWORD\"

"

    # Xray user entry (XHTTP - flow MUST be empty for XHTTP transport)
    if [[ "${ENABLE_XHTTP:-true}" == "true" ]]; then
        [[ -n "$XRAY_USERS_JSON" ]] && XRAY_USERS_JSON+=","
        XRAY_USERS_JSON+="{\"id\":\"$USER_UUID\",\"email\":\"${USER_ID}@moav\",\"flow\":\"\"}"
    fi

    # telemt (Telegram MTProxy) per-user secret
    if [[ "${ENABLE_TELEMT:-true}" == "true" ]]; then
        telemt_generate_secret "$USER_ID"
        TELEMT_USERS_TOML+="${USER_ID} = \"${TELEMT_SECRET}\"
"
        TELEMT_CONNS_TOML+="${USER_ID} = ${TELEMT_MAX_TCP_CONNS}
"
        TELEMT_IPS_TOML+="${USER_ID} = ${TELEMT_MAX_UNIQUE_IPS}
"
    fi

    # Generate user bundle (non-fatal: don't let one user's bundle failure block the whole bootstrap)
    /app/generate-user.sh "$USER_ID" || log_error "Failed to generate bundle for $USER_ID (continuing...)"
done

# -----------------------------------------------------------------------------
# Re-add existing users that were created via 'moav user add' (not in INITIAL_USERS)
# On re-bootstrap, wg0.conf/awg0.conf are regenerated fresh with only INITIAL_USERS.
# This loop picks up any additional users from state and re-adds their peers + configs.
# -----------------------------------------------------------------------------
PROCESSED_USERS=""
# Build list of users already processed above
for i in $(seq -w 1 "$INITIAL_USERS"); do
    if [[ "$INITIAL_USERS" == "1" ]]; then
        PROCESSED_USERS="demouser"
    else
        PROCESSED_USERS="$PROCESSED_USERS user$i"
    fi
done

# Import users from host state dir (/host-state) into Docker volume (/state)
# Users created via 'moav user add' write to host ./state/ which is mounted as /host-state.
# The Docker volume /state only has users created by bootstrap. This step syncs them.
IMPORT_COUNT=0
if [[ -d "/host-state/users" ]]; then
    for host_user_dir in /host-state/users/*/; do
        [[ ! -d "$host_user_dir" ]] && continue
        IMPORT_USER_ID=$(basename "$host_user_dir")

        # Skip users already in Docker volume state
        if [[ -d "$STATE_DIR/users/$IMPORT_USER_ID" ]]; then
            continue
        fi

        # Skip users already processed in INITIAL_USERS loop
        if echo " $PROCESSED_USERS " | grep -q " $IMPORT_USER_ID "; then
            continue
        fi

        # Must have credentials to be a valid user
        if [[ ! -f "/host-state/users/$IMPORT_USER_ID/credentials.env" ]]; then
            continue
        fi

        log_info "Importing user from host state: $IMPORT_USER_ID"
        mkdir -p "$STATE_DIR/users/$IMPORT_USER_ID"
        cp -a "/host-state/users/$IMPORT_USER_ID/"* "$STATE_DIR/users/$IMPORT_USER_ID/" 2>/dev/null || true

        # Also import AWG credentials from output bundle if not already in state
        if [[ ! -f "$STATE_DIR/users/$IMPORT_USER_ID/amneziawg.env" ]] && \
           [[ -f "/outputs/bundles/$IMPORT_USER_ID/amneziawg.env" ]]; then
            cp "/outputs/bundles/$IMPORT_USER_ID/amneziawg.env" \
               "$STATE_DIR/users/$IMPORT_USER_ID/amneziawg.env"
        fi

        ((IMPORT_COUNT++)) || true
    done
fi

if [[ $IMPORT_COUNT -gt 0 ]]; then
    log_info "Imported $IMPORT_COUNT users from host state into Docker volume"
fi

EXTRA_USER_COUNT=0
for user_dir in "$STATE_DIR"/users/*/; do
    [[ ! -d "$user_dir" ]] && continue
    EXTRA_USER_ID=$(basename "$user_dir")

    # Skip users already processed in INITIAL_USERS loop
    if echo " $PROCESSED_USERS " | grep -q " $EXTRA_USER_ID "; then
        continue
    fi

    # Must have credentials to be a valid user
    if [[ ! -f "$STATE_DIR/users/$EXTRA_USER_ID/credentials.env" ]]; then
        continue
    fi

    log_info "Re-adding existing user: $EXTRA_USER_ID"
    source "$STATE_DIR/users/$EXTRA_USER_ID/credentials.env"

    # Add to sing-box JSON arrays (need comma separator)
    REALITY_USERS_JSON+=",{\"name\":\"$EXTRA_USER_ID\",\"uuid\":\"$USER_UUID\",\"flow\":\"xtls-rprx-vision\"}"
    TROJAN_USERS_JSON+=",{\"name\":\"$EXTRA_USER_ID\",\"password\":\"$USER_PASSWORD\"}"
    HYSTERIA2_USERS_JSON+=",{\"name\":\"$EXTRA_USER_ID\",\"password\":\"$USER_PASSWORD\"}"
    VLESS_WS_USERS_JSON+=",{\"name\":\"$EXTRA_USER_ID\",\"uuid\":\"$USER_UUID\"}"

    TRUSTTUNNEL_CREDENTIALS+="[[client]]
username = \"$EXTRA_USER_ID\"
password = \"$USER_PASSWORD\"

"

    # Xray user entry for extra user
    if [[ "${ENABLE_XHTTP:-true}" == "true" ]]; then
        [[ -n "$XRAY_USERS_JSON" ]] && XRAY_USERS_JSON+=","
        XRAY_USERS_JSON+="{\"id\":\"$USER_UUID\",\"email\":\"${EXTRA_USER_ID}@moav\",\"flow\":\"\"}"
    fi

    # telemt secret for extra user
    if [[ "${ENABLE_TELEMT:-true}" == "true" ]]; then
        telemt_generate_secret "$EXTRA_USER_ID"
        TELEMT_USERS_TOML+="${EXTRA_USER_ID} = \"${TELEMT_SECRET}\"
"
        TELEMT_CONNS_TOML+="${EXTRA_USER_ID} = ${TELEMT_MAX_TCP_CONNS}
"
        TELEMT_IPS_TOML+="${EXTRA_USER_ID} = ${TELEMT_MAX_UNIQUE_IPS}
"
    fi

    # Regenerate user bundle (adds WG/AWG peers via guards + generates configs)
    # Non-fatal: user must still be in server configs even if bundle generation fails
    export USER_ID="$EXTRA_USER_ID"
    export IS_DEMO_USER="false"
    /app/generate-user.sh "$EXTRA_USER_ID" || log_error "Failed to generate bundle for $EXTRA_USER_ID (continuing...)"

    ((EXTRA_USER_COUNT++)) || true
done

if [[ $EXTRA_USER_COUNT -gt 0 ]]; then
    log_info "Re-added $EXTRA_USER_COUNT existing users from previous sessions"
fi

REALITY_USERS_JSON+="]"
TROJAN_USERS_JSON+="]"
HYSTERIA2_USERS_JSON+="]"
VLESS_WS_USERS_JSON+="]"
SHADOWSOCKS_USERS_JSON+="]"

# -----------------------------------------------------------------------------
# Generate TrustTunnel config (if enabled)
# -----------------------------------------------------------------------------
if [[ "${ENABLE_TRUSTTUNNEL:-true}" == "true" ]]; then
    log_info "Generating TrustTunnel configuration (credentials from user list)..."

    export TRUSTTUNNEL_CREDENTIALS

    # Generate credentials.toml
    envsubst < /configs/trusttunnel/credentials.toml.template > /configs/trusttunnel/credentials.toml

    # Generate hosts.toml
    envsubst < /configs/trusttunnel/hosts.toml.template > /configs/trusttunnel/hosts.toml

    # Generate vpn.toml (no substitution needed but copy for consistency)
    envsubst < /configs/trusttunnel/vpn.toml.template > /configs/trusttunnel/vpn.toml

    log_info "TrustTunnel configuration written to /configs/trusttunnel/"
fi

# -----------------------------------------------------------------------------
# Generate Xray config (if enabled)
# -----------------------------------------------------------------------------
if [[ "${ENABLE_XHTTP:-true}" == "true" ]]; then
    # Count users in Xray config for verification
    XRAY_USER_COUNT=$(echo "$XRAY_USERS_JSON" | grep -o '"id"' | wc -l || echo "0")
    log_info "Generating Xray-core (XHTTP) configuration with $XRAY_USER_COUNT users (reusing Reality keys from sing-box)..."

    export XRAY_USERS_JSON
    export PORT_XHTTP
    export XHTTP_REALITY_TARGET

    # Extract host from target (e.g., "dl.google.com:443" -> "dl.google.com")
    XHTTP_REALITY_TARGET_HOST="${XHTTP_REALITY_TARGET%%:*}"
    export XHTTP_REALITY_TARGET_HOST

    # Reuse Reality keys from sing-box
    export REALITY_PRIVATE_KEY
    export REALITY_SHORT_ID

    envsubst < /configs/xray/config.json.template > /configs/xray/config.json

    # Add XDNS inbound if enabled
    if [[ "${ENABLE_XDNS:-false}" == "true" ]] && [[ -n "${DOMAIN:-}" ]]; then
        xdns_domain="${XDNS_SUBDOMAIN:-x}.${DOMAIN}"
        xdns_mtu="${XDNS_MTU:-35}"
        log_info "Adding XDNS inbound (domain: $xdns_domain, mtu: $xdns_mtu)..."

        # Insert XDNS inbound into the inbounds array using python (jq alternative for complex JSON)
        python3 -c "
import json, sys
with open('/configs/xray/config.json') as f:
    config = json.load(f)
xdns_inbound = {
    'tag': 'vless-xdns',
    'listen': '0.0.0.0',
    'port': 5355,
    'protocol': 'vless',
    'settings': {
        'users': config['inbounds'][1]['settings']['users'],
        'decryption': 'none'
    },
    'streamSettings': {
        'network': 'kcp',
        'kcpSettings': {
            'mtu': 900,
            'tti': 100,
            'uplinkCapacity': 0,
            'downlinkCapacity': 0,
            'congestion': True
        },
        'finalmask': {
            'udp': [{'type': 'xdns', 'settings': {'domain': '$xdns_domain'}}]
        }
    }
}
config['inbounds'].append(xdns_inbound)
# No special routing rule needed for XDNS — traffic falls through to:
# 1. IPv6 blackhole (blocks IPv6)
# 2. Catch-all direct (handles IPv4)
with open('/configs/xray/config.json', 'w') as f:
    json.dump(config, f, indent=2)
" && log_info "XDNS inbound added to Xray config" || log_error "Failed to add XDNS inbound"
    fi

    log_info "Xray configuration written to /configs/xray/config.json"
fi

# -----------------------------------------------------------------------------
# Generate telemt config (if enabled)
# -----------------------------------------------------------------------------
if [[ "${ENABLE_TELEMT:-true}" == "true" ]]; then
    telemt_write_config
fi

# -----------------------------------------------------------------------------
# Generate sing-box config (only if TLS protocols are enabled)
# -----------------------------------------------------------------------------
singbox_needed=false
[[ "${ENABLE_REALITY:-true}" == "true" ]] && singbox_needed=true
[[ "${ENABLE_TROJAN:-true}" == "true" ]] && singbox_needed=true
[[ "${ENABLE_HYSTERIA2:-true}" == "true" ]] && singbox_needed=true
[[ "${ENABLE_SS:-false}" == "true" ]] && singbox_needed=true

if [[ "$singbox_needed" == "true" ]]; then
    log_info "Generating sing-box configuration (using existing keys)..."

    export REALITY_USERS_JSON
    export TROJAN_USERS_JSON
    export HYSTERIA2_USERS_JSON
    export VLESS_WS_USERS_JSON
    export SHADOWSOCKS_USERS_JSON="${SHADOWSOCKS_USERS_JSON:-[]}"
    export SS_SERVER_PSK="${SS_SERVER_PSK:-}"
    export SS_METHOD
    export PORT_SS
    export REALITY_PRIVATE_KEY
    export REALITY_SHORT_ID
    export REALITY_TARGET_HOST
    export REALITY_TARGET_PORT
    export REALITY_SERVER_NAME="$REALITY_TARGET_HOST"
    export CLASH_API_SECRET
    export HYSTERIA2_OBFS_PASSWORD
    export CDN_WS_PATH
    export CDN_TRANSPORT
    export LOG_LEVEL="${LOG_LEVEL:-info}"

    envsubst < /configs/sing-box/config.json.template > /configs/sing-box/config.json

    # Remove disabled protocol inbounds from the generated config
    config_file="/configs/sing-box/config.json"
    if [[ "${ENABLE_TROJAN:-true}" != "true" ]]; then
        jq 'del(.inbounds[] | select(.tag == "trojan-tls-in"))' "$config_file" > "${config_file}.tmp" && mv -f "${config_file}.tmp" "$config_file"
        log_info "  Removed Trojan inbound (disabled)"
    fi
    if [[ "${ENABLE_HYSTERIA2:-true}" != "true" ]]; then
        jq 'del(.inbounds[] | select(.tag == "hysteria2-in"))' "$config_file" > "${config_file}.tmp" && mv -f "${config_file}.tmp" "$config_file"
        log_info "  Removed Hysteria2 inbound (disabled)"
    fi
    if [[ -z "${CDN_DOMAIN:-}" ]]; then
        jq 'del(.inbounds[] | select(.tag == "vless-ws-in"))' "$config_file" > "${config_file}.tmp" && mv -f "${config_file}.tmp" "$config_file"
        log_info "  Removed CDN VLESS inbound (no CDN domain)"
    fi
    if [[ "${ENABLE_REALITY:-true}" != "true" ]]; then
        jq 'del(.inbounds[] | select(.tag == "vless-reality-in"))' "$config_file" > "${config_file}.tmp" && mv -f "${config_file}.tmp" "$config_file"
        log_info "  Removed Reality inbound (disabled)"
    fi
    if [[ "${ENABLE_SS:-false}" != "true" ]]; then
        jq 'del(.inbounds[] | select(.tag == "shadowsocks-in"))' "$config_file" > "${config_file}.tmp" && mv -f "${config_file}.tmp" "$config_file"
        log_info "  Removed Shadowsocks inbound (disabled)"
    fi

    log_info "sing-box configuration written to /configs/sing-box/config.json"
else
    log_info "sing-box not needed (no TLS protocols enabled)"
fi

# -----------------------------------------------------------------------------
# Fix permissions on generated configs (admin container runs as non-root uid 1000)
# -----------------------------------------------------------------------------
chown -R 0:1000 /configs/ 2>/dev/null || true
chmod -R g+r /configs/ 2>/dev/null || true
chown -R 0:1000 /outputs/ 2>/dev/null || true
chmod -R g+r /outputs/ 2>/dev/null || true

# -----------------------------------------------------------------------------
# Mark as bootstrapped
# -----------------------------------------------------------------------------
date -u +%Y-%m-%dT%H:%M:%SZ > "$STATE_DIR/.bootstrapped"

log_info "Bootstrap complete!"
log_info "User bundles are in /outputs/bundles/"
log_info ""
log_info "Next steps:"
log_info "  1. Configure DNS records (see docs/DNS.md)"
log_info "  2. Start the stack: docker compose up -d"
log_info "  3. Distribute user bundles to your contacts"
