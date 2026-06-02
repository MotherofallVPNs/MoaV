#!/bin/bash
set -euo pipefail

# =============================================================================
# Add user(s) to ALL enabled services
# Usage: ./scripts/user-add.sh <username> [username2...] [options]
#        ./scripts/user-add.sh --batch N [--prefix NAME] [options]
#
# Options:
#   --package, -p     Create distributable zip with HTML guide for each user
#   --batch N         Create N users with auto-generated names
#   --prefix NAME     Prefix for batch usernames (default: "user")
#
# Examples:
#   ./scripts/user-add.sh alice bob charlie
#   ./scripts/user-add.sh --batch 5
#   ./scripts/user-add.sh --batch 10 --prefix team --package
#
# This is the master script that calls individual service scripts:
#   - singbox-user-add.sh (Reality, Trojan, Hysteria2)
#   - wg-user-add.sh (WireGuard)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

source scripts/lib/common.sh

# Parse arguments
USERNAMES=()
CREATE_PACKAGE=false
BATCH_COUNT=0
BATCH_PREFIX="user"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --package|-p)
            CREATE_PACKAGE=true
            shift
            ;;
        --batch|-b)
            BATCH_COUNT="${2:-0}"
            shift 2
            ;;
        --prefix)
            BATCH_PREFIX="${2:-user}"
            shift 2
            ;;
        -*)
            echo "Unknown option: $1"
            exit 1
            ;;
        *)
            USERNAMES+=("$1")
            shift
            ;;
    esac
done

# Generate batch usernames if --batch was specified
if [[ "$BATCH_COUNT" -gt 0 ]]; then
    # Find the next available number for this prefix
    START_NUM=1
    while [[ -d "outputs/bundles/${BATCH_PREFIX}$(printf '%02d' $START_NUM)" ]]; do
        ((START_NUM++))
    done

    for ((i=0; i<BATCH_COUNT; i++)); do
        NUM=$((START_NUM + i))
        USERNAMES+=("${BATCH_PREFIX}$(printf '%02d' $NUM)")
    done
fi

if [[ ${#USERNAMES[@]} -eq 0 ]]; then
    echo "Usage: $0 <username> [username2...] [--package]"
    echo "       $0 --batch N [--prefix NAME] [--package]"
    echo ""
    echo "Options:"
    echo "  --package, -p     Create distributable zip with HTML guide"
    echo "  --batch N         Create N users with auto-generated names"
    echo "  --prefix NAME     Prefix for batch usernames (default: \"user\")"
    echo ""
    echo "Examples:"
    echo "  $0 alice bob charlie        # Add three users"
    echo "  $0 --batch 5                # Create user01, user02, ..., user05"
    echo "  $0 --batch 10 --prefix team # Create team01, team02, ..., team10"
    echo ""
    echo "For individual services:"
    echo "  ./scripts/singbox-user-add.sh <username>  # Reality, Trojan, Hysteria2"
    echo "  ./scripts/wg-user-add.sh <username>       # WireGuard"
    exit 1
fi

# Determine if we're in batch mode (multiple users)
BATCH_MODE=false
if [[ ${#USERNAMES[@]} -gt 1 ]]; then
    BATCH_MODE=true
fi

# Validate all usernames first
for USERNAME in "${USERNAMES[@]}"; do
    if [[ ! "$USERNAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "Invalid username '$USERNAME'. Use only letters, numbers, underscores, and hyphens."
        exit 1
    fi
    if [[ -d "outputs/bundles/$USERNAME" ]]; then
        log_error "User '$USERNAME' already exists. Use a different name or revoke first."
        log_error "To revoke: ./scripts/user-revoke.sh $USERNAME"
        exit 1
    fi
done

# Repair config-file perms — previous runs (especially sudo'd CLI) may have
# left files root-owned with restrictive perms, which then blocks the admin
# container from writing on subsequent ops. cat-overwrite-style writes (used
# everywhere since the wg/awg fix) preserve perms once they're right, but
# this sweep heals any historical breakage on every invocation.
for _f in configs/sing-box/config.json configs/xray/config.json \
          configs/wireguard/wg0.conf configs/amneziawg/awg0.conf \
          configs/trusttunnel/credentials.toml configs/telemt/config.toml; do
    [[ -f "$_f" ]] && chmod a+rw "$_f" 2>/dev/null || true
done

# Load environment
if [[ -f .env ]]; then
    # Auto-heal: GOPROXY's value is pipe-separated (proxy|proxy|direct). If the
    # line is unquoted (older .env files), `source` below parses the `|` as a
    # shell pipe and tries to run the URLs as commands. Heal in a tempfile —
    # works even when .env is on a RO mount (admin container), and we only
    # persist the heal back to .env when it's writable (CLI on the host).
    _ENV_TMP=$(mktemp)
    sed -E '/^GOPROXY=[^"]*\|/ s/^GOPROXY=(.*)$/GOPROXY="\1"/' .env > "$_ENV_TMP"
    if [[ -w .env ]] && ! cmp -s "$_ENV_TMP" .env; then
        cat "$_ENV_TMP" > .env
    fi
    set -a
    source "$_ENV_TMP"
    set +a
    rm -f "$_ENV_TMP"
fi

# DONATE_ONLY_PROTOCOLS: lightweight user creation for config donation
# When set, only provision the listed protocols (skip WireGuard, AmneziaWG, etc.)
DONATE_ONLY="${DONATE_ONLY_PROTOCOLS:-}"
if [[ -n "$DONATE_ONLY" ]]; then
    log_info "Donate mode: only provisioning protocols: $DONATE_ONLY"
    # Disable heavy services unconditionally
    ENABLE_WIREGUARD=false
    ENABLE_AMNEZIAWG=false
    ENABLE_DNSTT=false
    ENABLE_SLIPSTREAM=false
    ENABLE_TRUSTTUNNEL=false
    # Enable/disable based on donate list
    echo " $DONATE_ONLY " | grep -q " reality "   && ENABLE_REALITY=true   || ENABLE_REALITY=false
    echo " $DONATE_ONLY " | grep -q " trojan "    && ENABLE_TROJAN=true    || ENABLE_TROJAN=false
    echo " $DONATE_ONLY " | grep -q " hysteria2 " && ENABLE_HYSTERIA2=true || ENABLE_HYSTERIA2=false
    echo " $DONATE_ONLY " | grep -q " telegram "  && ENABLE_TELEMT=true    || ENABLE_TELEMT=false
    echo " $DONATE_ONLY " | grep -q " xhttp "     && ENABLE_XHTTP=true    || ENABLE_XHTTP=false
    # CDN: clear CDN_DOMAIN if not in donate list
    if ! echo " $DONATE_ONLY " | grep -q " cdn "; then
        CDN_SUBDOMAIN=""
    fi
fi

# Display batch info
if [[ "$BATCH_MODE" == "true" ]]; then
    log_info "========================================"
    log_info "Batch creating ${#USERNAMES[@]} users"
    log_info "========================================"
    echo ""
    echo "Users to create:"
    for u in "${USERNAMES[@]}"; do
        echo "  • $u"
    done
    echo ""
fi

# Track created users for summary
CREATED_USERS=()
FAILED_USERS=()

# Ensure directories exist and are writable (Docker creates them as root)
# Try: direct mkdir → sudo mkdir → su-exec root mkdir (admin container has su-exec)
_fix_perms() {
    local dir="$1"
    mkdir -p "$dir" 2>/dev/null || \
        sudo mkdir -p "$dir" 2>/dev/null || \
        su-exec root mkdir -p "$dir" 2>/dev/null || true
    if [[ -d "$dir" ]] && [[ ! -w "$dir" ]]; then
        sudo chmod 777 "$dir" 2>/dev/null || \
            su-exec root chmod 777 "$dir" 2>/dev/null || true
    fi
}

for _dir in "outputs/bundles" "state/users" "configs/sing-box" "configs/xray" "configs/amneziawg" "configs/wireguard" "configs/trusttunnel" "configs/telemt"; do
    _fix_perms "$_dir"
done
# Also fix state/ parent and config files that may be root-owned
for _dir in "state" "configs/amneziawg" "configs/wireguard"; do
    _fix_perms "$_dir"
    # Fix root-owned config files so we can append peers
    for _f in "$_dir"/*.conf; do
        if [[ -f "$_f" ]] && [[ ! -w "$_f" ]]; then
            sudo chmod 666 "$_f" 2>/dev/null || \
                su-exec root chmod 666 "$_f" 2>/dev/null || true
        fi
    done
done
if [[ ! -w "outputs/bundles" ]]; then
    log_error "Cannot write to outputs/bundles/ — try: sudo chmod 777 outputs/bundles"
    exit 1
fi

# -----------------------------------------------------------------------------
# Create each user
# -----------------------------------------------------------------------------
for USERNAME in "${USERNAMES[@]}"; do
    OUTPUT_DIR="outputs/bundles/$USERNAME"
    mkdir -p "$OUTPUT_DIR"

    log_info "========================================"
    log_info "Adding user '$USERNAME' to all services"
    log_info "========================================"
    echo ""

    ERRORS=()

    # Determine reload flag for sub-scripts
    RELOAD_FLAG=""
    if [[ "$BATCH_MODE" == "true" ]]; then
        RELOAD_FLAG="--no-reload"
    fi

    # -------------------------------------------------------------------------
    # Add to sing-box (Reality, Trojan, Hysteria2)
    # -------------------------------------------------------------------------
    if [[ -f "configs/sing-box/config.json" ]]; then
        log_info "[1/3] Adding to sing-box (Reality, Trojan, Hysteria2)..."
        if "$SCRIPT_DIR/singbox-user-add.sh" "$USERNAME" $RELOAD_FLAG; then
            log_info "✓ sing-box user added"
        else
            ERRORS+=("sing-box")
            log_error "✗ Failed to add sing-box user"
        fi
    else
        log_info "[1/3] Skipping sing-box (not configured)"
    fi

    echo ""

    # -------------------------------------------------------------------------
    # Add to WireGuard
    # -------------------------------------------------------------------------
    if [[ "${ENABLE_WIREGUARD:-true}" == "true" ]] && [[ -f "configs/wireguard/wg0.conf" ]]; then
        # Check if WireGuard service is actually running or wg tools are available
        if docker compose ps wireguard --status running 2>/dev/null | tail -n +2 | grep -q . || command -v wg &>/dev/null; then
            log_info "[2/3] Adding to WireGuard..."
            if "$SCRIPT_DIR/wg-user-add.sh" "$USERNAME" $RELOAD_FLAG; then
                log_info "✓ WireGuard peer added"
            else
                ERRORS+=("wireguard")
                log_error "✗ Failed to add WireGuard peer"
            fi
        else
            log_info "[2/3] Skipping WireGuard (service not running)"
        fi
    else
        log_info "[2/3] Skipping WireGuard (not enabled or not configured)"
    fi

    echo ""

    # -------------------------------------------------------------------------
    # Add to AmneziaWG
    # -------------------------------------------------------------------------
    if [[ "${ENABLE_AMNEZIAWG:-true}" == "true" ]] && [[ -f "configs/amneziawg/awg0.conf" ]]; then
        log_info "[3/3] Adding to AmneziaWG..."
        (
            # Generate client keys (standard WG key format, compatible with AWG)
            # Use running container for key generation (host may not have wg/awg)
            if docker compose ps amneziawg --status running 2>/dev/null | tail -n +2 | grep -q .; then
                AWG_CLIENT_PRIVATE=$(docker compose exec -T amneziawg awg genkey)
                AWG_CLIENT_PUBLIC=$(echo "$AWG_CLIENT_PRIVATE" | docker compose exec -T amneziawg awg pubkey)
            elif docker compose ps wireguard --status running 2>/dev/null | tail -n +2 | grep -q .; then
                AWG_CLIENT_PRIVATE=$(docker compose exec -T wireguard wg genkey)
                AWG_CLIENT_PUBLIC=$(echo "$AWG_CLIENT_PRIVATE" | docker compose exec -T wireguard wg pubkey)
            elif command -v wg &>/dev/null; then
                AWG_CLIENT_PRIVATE=$(wg genkey)
                AWG_CLIENT_PUBLIC=$(echo "$AWG_CLIENT_PRIVATE" | wg pubkey)
            else
                log_error "No wg/awg command available (install wireguard-tools or ensure amneziawg container is running)"
                exit 1
            fi

            # Find next available IP (extract actual used IPs from config AND running interface)
            USED_AWG_IPS=$(grep 'AllowedIPs = 10\.67\.67\.' "configs/amneziawg/awg0.conf" 2>/dev/null | sed 's/.*10\.67\.67\.\([0-9]*\).*/\1/' || echo "")
            if docker compose ps amneziawg --status running 2>/dev/null | tail -n +2 | grep -q .; then
                RUNNING_AWG_IPS=$(docker compose exec -T amneziawg awg show awg0 allowed-ips 2>/dev/null | grep '10\.67\.67\.' | sed 's/.*10\.67\.67\.\([0-9]*\).*/\1/' || echo "")
                USED_AWG_IPS="$USED_AWG_IPS $RUNNING_AWG_IPS"
            fi
            AWG_NEXT_IP=2  # Start from .2 (server is .1)
            for _ip in $USED_AWG_IPS; do
                if [[ $_ip -ge $AWG_NEXT_IP ]]; then
                    AWG_NEXT_IP=$((_ip + 1))
                fi
            done
            if [[ $AWG_NEXT_IP -gt 254 ]]; then
                log_error "No available IPs in AmneziaWG network"
                exit 1
            fi
            AWG_CLIENT_IP="10.67.67.$AWG_NEXT_IP"

            # Calculate client IPv6 if server has IPv6
            AWG_CLIENT_IP_V6=""
            if [[ -n "${SERVER_IPV6:-}" ]]; then
                AWG_CLIENT_IP_V6="fd00:cafe:dead::$AWG_NEXT_IP"
            fi

            # Save client credentials to bundle dir and host state dir
            cat > "$OUTPUT_DIR/amneziawg.env" <<CREDEOF
AWG_PRIVATE_KEY=$AWG_CLIENT_PRIVATE
AWG_PUBLIC_KEY=$AWG_CLIENT_PUBLIC
AWG_CLIENT_IP=$AWG_CLIENT_IP
AWG_CLIENT_IP_V6=$AWG_CLIENT_IP_V6
CREDEOF
            # Also save to host state dir for bootstrap sync
            mkdir -p "./state/users/$USERNAME" 2>/dev/null || true
            cp "$OUTPUT_DIR/amneziawg.env" "./state/users/$USERNAME/amneziawg.env" 2>/dev/null || true

            # Add peer to server config
            AWG_ALLOWED="$AWG_CLIENT_IP/32"
            if [[ -n "$AWG_CLIENT_IP_V6" ]]; then
                AWG_ALLOWED="$AWG_CLIENT_IP/32, $AWG_CLIENT_IP_V6/128"
            fi

            cat >> "configs/amneziawg/awg0.conf" <<PEEREOF

[Peer]
# $USERNAME
PublicKey = $AWG_CLIENT_PUBLIC
AllowedIPs = $AWG_ALLOWED
PEEREOF

            # Hot-add peer to running AmneziaWG (unless batch mode — batch reloads later)
            if [[ "$BATCH_MODE" != "true" ]]; then
                if docker compose ps amneziawg --status running 2>/dev/null | tail -n +2 | grep -q .; then
                    log_info "Adding peer to running AmneziaWG..."
                    if docker compose exec -T amneziawg awg set awg0 peer "$AWG_CLIENT_PUBLIC" allowed-ips "$AWG_ALLOWED" 2>/dev/null; then
                        log_info "Peer added to running AmneziaWG (hot reload)"
                    else
                        log_info "Hot reload failed, you may need to restart AmneziaWG"
                        log_info "Run: docker compose --profile amneziawg restart amneziawg"
                    fi
                else
                    log_info "AmneziaWG not running, config will apply on next start"
                fi
            fi

            # Read obfuscation params and server key from the server config (bind mount)
            AWG_SERVER_PUB=$(cat "configs/amneziawg/server.pub")
            AWG_JC=$(grep '^Jc' "configs/amneziawg/awg0.conf" | head -1 | awk '{print $3}')
            AWG_JMIN=$(grep '^Jmin' "configs/amneziawg/awg0.conf" | head -1 | awk '{print $3}')
            AWG_JMAX=$(grep '^Jmax' "configs/amneziawg/awg0.conf" | head -1 | awk '{print $3}')
            AWG_S1=$(grep '^S1' "configs/amneziawg/awg0.conf" | head -1 | awk '{print $3}')
            AWG_S2=$(grep '^S2' "configs/amneziawg/awg0.conf" | head -1 | awk '{print $3}')
            AWG_H1=$(grep '^H1' "configs/amneziawg/awg0.conf" | head -1 | awk '{print $3}')
            AWG_H2=$(grep '^H2' "configs/amneziawg/awg0.conf" | head -1 | awk '{print $3}')
            AWG_H3=$(grep '^H3' "configs/amneziawg/awg0.conf" | head -1 | awk '{print $3}')
            AWG_H4=$(grep '^H4' "configs/amneziawg/awg0.conf" | head -1 | awk '{print $3}')

            AWG_ADDRESSES="$AWG_CLIENT_IP/32"
            if [[ -n "$AWG_CLIENT_IP_V6" ]]; then
                AWG_ADDRESSES="$AWG_CLIENT_IP/32, $AWG_CLIENT_IP_V6/128"
            fi

            cat > "$OUTPUT_DIR/amneziawg.conf" <<CONFEOF
[Interface]
PrivateKey = $AWG_CLIENT_PRIVATE
Address = $AWG_ADDRESSES
DNS = 1.1.1.1, 8.8.8.8
MTU = 1280
Jc = $AWG_JC
Jmin = $AWG_JMIN
Jmax = $AWG_JMAX
S1 = $AWG_S1
S2 = $AWG_S2
H1 = $AWG_H1
H2 = $AWG_H2
H3 = $AWG_H3
H4 = $AWG_H4

[Peer]
PublicKey = $AWG_SERVER_PUB
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${SERVER_IP}:${PORT_AMNEZIAWG:-51821}
PersistentKeepalive = 25
CONFEOF

            # Generate QR code
            qrencode -o "$OUTPUT_DIR/amneziawg-qr.png" -s 6 -r "$OUTPUT_DIR/amneziawg.conf" 2>/dev/null || true

            # IPv6 endpoint config
            if [[ -n "${SERVER_IPV6:-}" ]]; then
                cat > "$OUTPUT_DIR/amneziawg-ipv6.conf" <<CONFEOF
[Interface]
PrivateKey = $AWG_CLIENT_PRIVATE
Address = $AWG_ADDRESSES
DNS = 1.1.1.1, 2606:4700:4700::1111
MTU = 1280
Jc = $AWG_JC
Jmin = $AWG_JMIN
Jmax = $AWG_JMAX
S1 = $AWG_S1
S2 = $AWG_S2
H1 = $AWG_H1
H2 = $AWG_H2
H3 = $AWG_H3
H4 = $AWG_H4

[Peer]
PublicKey = $AWG_SERVER_PUB
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = [${SERVER_IPV6}]:${PORT_AMNEZIAWG:-51821}
PersistentKeepalive = 25
CONFEOF
                qrencode -o "$OUTPUT_DIR/amneziawg-ipv6-qr.png" -s 6 -r "$OUTPUT_DIR/amneziawg-ipv6.conf" 2>/dev/null || true
            fi
        ) && log_info "✓ AmneziaWG peer added" || {
            ERRORS+=("amneziawg")
            log_error "✗ Failed to add AmneziaWG peer"
        }
    else
        log_info "[3/3] Skipping AmneziaWG (not enabled or not configured)"
    fi

echo ""

# -----------------------------------------------------------------------------
# Generate dnstt instructions (shared for all users)
# -----------------------------------------------------------------------------
if [[ "${ENABLE_DNSTT:-true}" == "true" ]] && [[ -f "outputs/dnstt/server.pub" ]]; then
    DNSTT_PUBKEY=$(cat "outputs/dnstt/server.pub" 2>/dev/null || echo "KEY_NOT_FOUND")
    DNSTT_DOMAIN="${DNSTT_SUBDOMAIN:-t}.${DOMAIN}"

    cat > "$OUTPUT_DIR/dnstt-instructions.txt" <<EOF
# dnstt DNS Tunnel Instructions
# =============================
# Use this as a LAST RESORT when other methods are blocked.
# DNS tunneling is SLOW but often works when everything else fails.

# Server Public Key (hex):
$DNSTT_PUBKEY

# Tunnel Domain:
$DNSTT_DOMAIN

# -------------------------
# Option 1: Using DoH (DNS over HTTPS) - RECOMMENDED
# -------------------------

# Download dnstt-client from: https://www.bamsoftware.com/software/dnstt/

# Run (creates a local SOCKS5 proxy on port 1080):
dnstt-client -doh https://1.1.1.1/dns-query -pubkey $DNSTT_PUBKEY $DNSTT_DOMAIN 127.0.0.1:1080

# Then configure your apps to use SOCKS5 proxy: 127.0.0.1:1080

# -------------------------
# Option 2: Using Plain UDP DNS
# -------------------------

# If DoH is blocked, try plain UDP (use a public resolver):
dnstt-client -udp 8.8.8.8:53 -pubkey $DNSTT_PUBKEY $DNSTT_DOMAIN 127.0.0.1:1080
EOF
    log_info "✓ dnstt instructions generated"
fi

# -----------------------------------------------------------------------------
# Generate Slipstream instructions (shared for all users)
# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# Generate telemt instructions (if enabled)
# -----------------------------------------------------------------------------
if [[ "${ENABLE_TELEMT:-true}" == "true" ]] && [[ -f "configs/telemt/config.toml" ]]; then
    # Load telemt secret from state (generated by singbox-user-add → generate-single-user)
    TELEMT_SECRET=""
    if [[ -f "state/users/$USERNAME/telemt.env" ]]; then
        source "state/users/$USERNAME/telemt.env"
    fi
    if [[ -n "$TELEMT_SECRET" ]]; then
        PORT_TELEMT="${PORT_TELEMT:-993}"
        TELEMT_TLS_DOMAIN="${TELEMT_TLS_DOMAIN:-dl.google.com}"
        HEX_DOMAIN=$(printf '%s' "$TELEMT_TLS_DOMAIN" | od -An -tx1 | tr -d ' \n')

        TG_LINK="tg://proxy?server=${SERVER_IP}&port=${PORT_TELEMT}&secret=ee${TELEMT_SECRET}${HEX_DOMAIN}"
        HTTPS_LINK="https://t.me/proxy?server=${SERVER_IP}&port=${PORT_TELEMT}&secret=ee${TELEMT_SECRET}${HEX_DOMAIN}"

        echo "$TG_LINK" > "$OUTPUT_DIR/telegram-proxy-link.txt"
        qrencode -o "$OUTPUT_DIR/telegram-proxy-qr.png" -s 6 "$TG_LINK" 2>/dev/null || true

        cat > "$OUTPUT_DIR/telegram-proxy-instructions.txt" <<EOF
# Telegram MTProxy Instructions for $USERNAME
# ============================================
# Quick Setup (tap/click the link):
$TG_LINK
$HTTPS_LINK

# Manual: Server=${SERVER_IP} Port=${PORT_TELEMT}
# Secret: ee${TELEMT_SECRET}${HEX_DOMAIN}
EOF
        log_info "✓ telemt instructions generated"
    fi
fi

if [[ "${ENABLE_SLIPSTREAM:-true}" == "true" ]] && [[ -f "outputs/slipstream/cert.pem" ]]; then
    SLIPSTREAM_DOMAIN="${SLIPSTREAM_SUBDOMAIN:-s}.${DOMAIN}"

    # Copy cert to user bundle
    cp "outputs/slipstream/cert.pem" "$OUTPUT_DIR/slipstream-cert.pem"

    cat > "$OUTPUT_DIR/slipstream-instructions.txt" <<EOF
# Slipstream DNS Tunnel Instructions
# ====================================
# QUIC-over-DNS tunnel - faster than dnstt (1.5-5x speedup).

# Tunnel Domain:
$SLIPSTREAM_DOMAIN

# Certificate: slipstream-cert.pem (included in this bundle)

# -------------------------
# Option 1: Resolver Mode (RECOMMENDED - stealthier)
# -------------------------

# Download slipstream-client from:
# https://github.com/net2share/slipstream-rust-build/releases

# Run (creates a local SOCKS5 proxy on port 1080):
slipstream-client --domain $SLIPSTREAM_DOMAIN --cert slipstream-cert.pem --dns-server 1.1.1.1:53 --socks-listen 127.0.0.1:1080

# -------------------------
# Option 2: Authoritative/Direct Mode (FASTER but less stealthy)
# -------------------------

# slipstream-client --domain $SLIPSTREAM_DOMAIN --cert slipstream-cert.pem --authoritative SERVER_IP:${PORT_DNS:-53} --socks-listen 127.0.0.1:1080
EOF
    log_info "✓ Slipstream instructions generated"
fi

# -----------------------------------------------------------------------------
# Generate MasterDNS instructions (shared per-server tunnel key)
# -----------------------------------------------------------------------------
# Mirrors lib/masterdns.sh::masterdns_generate_client_instructions so a fast
# host-side `moav user add` yields a complete bundle (no follow-up
# `moav regenerate-users` needed). The host can't read the /state volume, so
# the shared key is taken from outputs/masterdns/encrypt_key.txt (published by
# bootstrap). Keep the text in sync with lib/masterdns.sh.
if [[ "${ENABLE_MASTERDNS:-true}" == "true" ]] && [[ -f "outputs/masterdns/encrypt_key.txt" ]]; then
    MASTERDNS_DOMAIN="${MASTERDNS_SUBDOMAIN:-m}.${DOMAIN}"
    MD_ENC_METHOD="${MASTERDNS_ENC_METHOD:-5}"
    MD_KEY=$(tr -d '\n\r ' < "outputs/masterdns/encrypt_key.txt")
    [[ -z "$MD_KEY" ]] && MD_KEY="KEY_NOT_GENERATED"

    cat > "$OUTPUT_DIR/masterdns-instructions.txt" <<EOF
# MasterDNS Tunnel Instructions
# =============================
# Advanced DNS tunnel (low-overhead ARQ + resolver load-balancing).
# Faster and more loss-tolerant than dnstt; bundled in MahsaNG v16.
# Use when other methods are blocked — DNS tunnels work when little else does.
#
# Project: https://github.com/masterking32/MasterDnsVPN
# Bundled in: MahsaNG (https://github.com/GFW-knocker/MahsaNG)

# Tunnel Domain:
$MASTERDNS_DOMAIN

# Data encryption method (must match server):
$MD_ENC_METHOD   # 5 = AES-256-GCM

# Encryption key (keep secret — anyone with this key can use the tunnel):
$MD_KEY

# -------------------------
# Option A: MahsaNG (Android) — easiest
# -------------------------
# 1. Install MahsaNG v16+ from https://github.com/GFW-knocker/MahsaNG/releases
# 2. Add a MasterDNS config with the domain, encryption method and key above.

# -------------------------
# Option B: MasterDnsVPN standalone client
# -------------------------
# Download the client for your OS from:
#   https://github.com/masterking32/MasterDnsVPN/releases
#
# Minimal client_config.toml:
#   DOMAINS = ["$MASTERDNS_DOMAIN"]
#   DATA_ENCRYPTION_METHOD = $MD_ENC_METHOD
#   ENCRYPTION_KEY = "$MD_KEY"
#   PROTOCOL_TYPE = "SOCKS5"
#   LISTEN_IP = "127.0.0.1"
#   LISTEN_PORT = 18000
#
# Run the client, then point your apps at SOCKS5 127.0.0.1:18000.
# The client also needs a resolver list (client_resolvers) — use the sample
# bundled with the client and/or public resolvers (1.1.1.1:53, 8.8.8.8:53).

# -------------------------
# Notes:
# -------------------------
# - DNS tunneling is slow by design but extremely hard to block.
# - Faster and more stable under packet loss than dnstt/Slipstream.
# - Traffic exits through the MoaV server (your IP appears as the server IP).
# - The NS record for $MASTERDNS_DOMAIN must delegate to this server (see docs/DNS.md).
EOF
    log_info "✓ MasterDNS instructions generated"
fi

# -----------------------------------------------------------------------------
# Generate GooseRelay bundle (shared per-server tunnel key + ready Apps Script)
# -----------------------------------------------------------------------------
# Mirrors lib/gooserelay.sh::gooserelay_generate_client_instructions. Off by
# default; only emitted when ENABLE_GOOSERELAY=true and bootstrap has published
# the tunnel key. Keep the text/JSON in sync with lib/gooserelay.sh.
if [[ "${ENABLE_GOOSERELAY:-false}" == "true" ]] && [[ -f "outputs/gooserelay/tunnel_key.txt" ]]; then
    GR_KEY=$(tr -d '\n\r ' < "outputs/gooserelay/tunnel_key.txt")
    [[ -z "$GR_KEY" ]] && GR_KEY="KEY_NOT_GENERATED"
    GR_ENDPOINT="http://${SERVER_IP:-YOUR_SERVER_IP}:${PORT_GOOSE:-8444}/tunnel"

    if [[ -f "configs/gooserelay/Code.gs.template" ]]; then
        sed "s|__GOOSE_RELAY_ENDPOINT__|$GR_ENDPOINT|g" \
            "configs/gooserelay/Code.gs.template" > "$OUTPUT_DIR/gooserelay-AppsScript.gs"
    fi

    cat > "$OUTPUT_DIR/gooserelay-client_config.json" <<EOF
{
  "debug_timing": false,
  "socks_host": "127.0.0.1",
  "socks_port": 1080,
  "google_host": "216.239.38.120",
  "sni": ["www.google.com", "mail.google.com", "accounts.google.com"],
  "script_keys": [
    {"id": "REPLACE_WITH_YOUR_APPS_SCRIPT_DEPLOYMENT_ID", "account": "acct-a"}
  ],
  "tunnel_key": "$GR_KEY",
  "coalesce_step_ms": 0,
  "idle_slots_per_bucket": 2
}
EOF

    cat > "$OUTPUT_DIR/gooserelay-instructions.txt" <<EOF
# GooseRelay Instructions
# =======================
# SOCKS5 over a Google Apps Script web app -> this VPS exit server.
# To the network you only ever appear to talk TLS to google.com.
# End-to-end AES-256-GCM; Google never sees plaintext or the key.
# Interoperable with the GooseRelay client in MahsaNG v16 (GooseRelay v1.7.1).
#
# Project: https://github.com/kianmhz/GooseRelayVPN
# Bundled in: MahsaNG (https://github.com/GFW-knocker/MahsaNG)

# This bundle ships TWO ready-made files so you don't hand-edit anything:
#   gooserelay-AppsScript.gs       -> paste into script.google.com; the
#                                     RELAY_URLS array already points here
#   gooserelay-client_config.json  -> ready for the GooseRelay / MahsaNG v16
#                                     client; only the Deployment ID is blank

# Shared tunnel key (already in the config; keep SECRET — anyone with it can
# use your VPS as you):
$GR_KEY

# This server's exit endpoint (already wired into gooserelay-AppsScript.gs):
$GR_ENDPOINT

# -------------------------
# Setup (one-time, in YOUR Google account)
# -------------------------
# 1. Open https://script.google.com  ->  New project
# 2. Paste the WHOLE contents of  gooserelay-AppsScript.gs  (no edits needed)
# 3. Deploy -> New deployment -> type "Web app"
#       Execute as: Me
#       Who has access: Anyone
#    Copy the Deployment ID it shows.
#    (Re-deploy as a NEW deployment whenever you change the script.)
# 4. In gooserelay-client_config.json, replace
#    REPLACE_WITH_YOUR_APPS_SCRIPT_DEPLOYMENT_ID with that Deployment ID.
# 5. Load gooserelay-client_config.json into the GooseRelay client (or the
#    MahsaNG v16 GooseRelay tab), then point apps at SOCKS5 127.0.0.1:1080.
#    A pre-flight check confirms the relay is healthy and the key matches.

# -------------------------
# Notes:
# -------------------------
# - Apps Script quota is ~20,000 calls/day PER Google account. Deploy under
#   several accounts and add each Deployment ID to "script_keys" for capacity.
# - Real-time apps (Telegram/X) drain the quota fast due to constant polling.
# - Traffic exits through the MoaV server (your IP appears as the server IP).
# - All deployments forwarding here must use this exact tunnel_key.
EOF
    log_info "✓ GooseRelay bundle generated"
fi

# -----------------------------------------------------------------------------
# Generate README.html from template
# -----------------------------------------------------------------------------
TEMPLATE_FILE="docs/client-guide-template.html"
OUTPUT_HTML="$OUTPUT_DIR/README.html"

if [[ -f "$TEMPLATE_FILE" ]]; then
    log_info "Generating HTML guide..."

    # Get server info
    SERVER_IP="${SERVER_IP:-$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "YOUR_SERVER_IP")}"
    GENERATED_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Read config values
    CONFIG_REALITY=$(cat "$OUTPUT_DIR/reality.txt" 2>/dev/null | tr -d '\n' || echo "")
    CONFIG_HYSTERIA2=$(cat "$OUTPUT_DIR/hysteria2.txt" 2>/dev/null | tr -d '\n' || echo "")
    CONFIG_TROJAN=$(cat "$OUTPUT_DIR/trojan.txt" 2>/dev/null | tr -d '\n' || echo "")
    CONFIG_SHADOWSOCKS=$(cat "$OUTPUT_DIR/shadowsocks.txt" 2>/dev/null | tr -d '\n' || echo "")
    CONFIG_CDN=$(cat "$OUTPUT_DIR/cdn-vless.txt" 2>/dev/null | tr -d '\n' || echo "")
    CONFIG_WIREGUARD=$(cat "$OUTPUT_DIR/wireguard.conf" 2>/dev/null || echo "")
    CONFIG_WIREGUARD_WSTUNNEL=$(cat "$OUTPUT_DIR/wireguard-wstunnel.conf" 2>/dev/null || echo "")
    CONFIG_AMNEZIAWG=$(cat "$OUTPUT_DIR/amneziawg.conf" 2>/dev/null || echo "")
    CONFIG_XHTTP=$(cat "$OUTPUT_DIR/xhttp-vless.txt" 2>/dev/null | tr -d '\n' || echo "")

    # Construct CDN_DOMAIN from CDN_SUBDOMAIN + DOMAIN if not explicitly set
    CDN_DOMAIN="${CDN_DOMAIN:-}"
    if [[ -z "$CDN_DOMAIN" ]]; then
        _cdn_sub="${CDN_SUBDOMAIN:-}"
        _cdn_dom="${DOMAIN:-}"
        if [[ -n "$_cdn_sub" && -n "$_cdn_dom" ]]; then
            CDN_DOMAIN="${_cdn_sub}.${_cdn_dom}"
        fi
    fi
    # CDN split SNI/Address for anti-DPI stealth
    CDN_SNI="${CDN_SNI:-${DOMAIN:-}}"
    CDN_ADDRESS="${CDN_ADDRESS:-${CDN_DOMAIN}}"
    export CDN_SNI CDN_ADDRESS

    # Read user password from trusttunnel.json or credentials
    if [[ -f "$OUTPUT_DIR/trusttunnel.json" ]]; then
        USER_PASSWORD=$(jq -r '.password // empty' "$OUTPUT_DIR/trusttunnel.json" 2>/dev/null || echo "")
    elif [[ -f "state/users/$USERNAME/credentials.env" ]]; then
        USER_PASSWORD=$(grep "^USER_PASSWORD=" "state/users/$USERNAME/credentials.env" 2>/dev/null | cut -d= -f2 || echo "")
    else
        USER_PASSWORD=""
    fi

    # Get dnstt info
    DNSTT_DOMAIN="${DNSTT_SUBDOMAIN:-t}.${DOMAIN}"
    DNSTT_PUBKEY=$(cat "outputs/dnstt/server.pub" 2>/dev/null || echo "")

    # Get Slipstream info
    SLIPSTREAM_DOMAIN="${SLIPSTREAM_SUBDOMAIN:-s}.${DOMAIN}"
    CONFIG_SLIPSTREAM=$(cat "$OUTPUT_DIR/slipstream-instructions.txt" 2>/dev/null || echo "")

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
    QR_WIREGUARD_B64=$(qr_to_base64 "$OUTPUT_DIR/wireguard-qr.png")
    QR_WIREGUARD_WSTUNNEL_B64=$(qr_to_base64 "$OUTPUT_DIR/wireguard-wstunnel-qr.png")
    QR_AMNEZIAWG_B64=$(qr_to_base64 "$OUTPUT_DIR/amneziawg-qr.png")
    QR_TELEMT_B64=$(qr_to_base64 "$OUTPUT_DIR/telegram-proxy-qr.png")
    QR_XHTTP_B64=$(qr_to_base64 "$OUTPUT_DIR/xhttp-qr.png")
    QR_SHADOWSOCKS_B64=$(qr_to_base64 "$OUTPUT_DIR/shadowsocks-qr.png")

    # Copy template
    cp "$TEMPLATE_FILE" "$OUTPUT_HTML"

    # Simple replacements (use .bak for portability, then clean up)
    sed -i.bak "s|{{USERNAME}}|$USERNAME|g" "$OUTPUT_HTML"
    sed -i.bak "s|{{SERVER_IP}}|$SERVER_IP|g" "$OUTPUT_HTML"
    sed -i.bak "s|{{DOMAIN}}|${DOMAIN:-YOUR_DOMAIN}|g" "$OUTPUT_HTML"
    sed -i.bak "s|{{PORT_SS}}|${PORT_SS:-8388}|g" "$OUTPUT_HTML"
    sed -i.bak "s|{{GENERATED_DATE}}|$GENERATED_DATE|g" "$OUTPUT_HTML"
    sed -i.bak "s|{{DNSTT_DOMAIN}}|$DNSTT_DOMAIN|g" "$OUTPUT_HTML"
    sed -i.bak "s|{{DNSTT_PUBKEY}}|$DNSTT_PUBKEY|g" "$OUTPUT_HTML"
    sed -i.bak "s|{{SLIPSTREAM_DOMAIN}}|$SLIPSTREAM_DOMAIN|g" "$OUTPUT_HTML"

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

    # TrustTunnel password
    if [[ -n "${USER_PASSWORD:-}" ]]; then
        replace_placeholder "{{TRUSTTUNNEL_PASSWORD}}" "$USER_PASSWORD"
    else
        replace_placeholder "{{TRUSTTUNNEL_PASSWORD}}" "See trusttunnel.txt"
    fi

    # Remove demo notice placeholders (not a demo user)
    replace_placeholder "{{DEMO_NOTICE_EN}}" ""
    replace_placeholder "{{DEMO_NOTICE_FA}}" ""

    # QR codes (base64) - these are safe for sed (no special chars in base64)
    sed -i.bak "s|{{QR_REALITY}}|$QR_REALITY_B64|g" "$OUTPUT_HTML"
    sed -i.bak "s|{{QR_HYSTERIA2}}|$QR_HYSTERIA2_B64|g" "$OUTPUT_HTML"
    sed -i.bak "s|{{QR_TROJAN}}|$QR_TROJAN_B64|g" "$OUTPUT_HTML"
    sed -i.bak "s|{{QR_WIREGUARD}}|$QR_WIREGUARD_B64|g" "$OUTPUT_HTML"
    sed -i.bak "s|{{QR_WIREGUARD_WSTUNNEL}}|$QR_WIREGUARD_WSTUNNEL_B64|g" "$OUTPUT_HTML"
    sed -i.bak "s|{{QR_AMNEZIAWG}}|$QR_AMNEZIAWG_B64|g" "$OUTPUT_HTML"
    sed -i.bak "s|{{QR_TELEMT}}|$QR_TELEMT_B64|g" "$OUTPUT_HTML"
    sed -i.bak "s|{{QR_XHTTP}}|$QR_XHTTP_B64|g" "$OUTPUT_HTML"
    sed -i.bak "s|{{QR_SHADOWSOCKS}}|$QR_SHADOWSOCKS_B64|g" "$OUTPUT_HTML"

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

    if [[ -n "$CONFIG_SHADOWSOCKS" ]]; then
        replace_placeholder "{{CONFIG_SHADOWSOCKS}}" "$CONFIG_SHADOWSOCKS"
    else
        replace_placeholder "{{CONFIG_SHADOWSOCKS}}" "No Shadowsocks config available"
    fi

    # CDN VLESS+WS config
    if [[ -n "$CONFIG_CDN" ]]; then
        replace_placeholder "{{CONFIG_CDN}}" "$CONFIG_CDN"
        replace_placeholder "{{CDN_DOMAIN}}" "$CDN_DOMAIN"
        # CDN QR code
        QR_CDN_B64=$(qr_to_base64 "$OUTPUT_DIR/cdn-vless-qr.png")
        sed -i.bak "s|{{QR_CDN}}|$QR_CDN_B64|g" "$OUTPUT_HTML"
    else
        replace_placeholder "{{CONFIG_CDN}}" "CDN not configured"
        replace_placeholder "{{CDN_DOMAIN}}" "Not configured"
        sed -i.bak "s|{{QR_CDN}}||g" "$OUTPUT_HTML"
    fi

    # WireGuard configs (multiline)
    if [[ -n "$CONFIG_WIREGUARD" ]]; then
        replace_placeholder "{{CONFIG_WIREGUARD}}" "$CONFIG_WIREGUARD"
    else
        replace_placeholder "{{CONFIG_WIREGUARD}}" "No WireGuard config available"
    fi

    if [[ -n "$CONFIG_WIREGUARD_WSTUNNEL" ]]; then
        replace_placeholder "{{CONFIG_WIREGUARD_WSTUNNEL}}" "$CONFIG_WIREGUARD_WSTUNNEL"
    else
        replace_placeholder "{{CONFIG_WIREGUARD_WSTUNNEL}}" "No WireGuard-wstunnel config available"
    fi

    # AmneziaWG config (multiline)
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

    # telemt (Telegram MTProxy) link
    if [[ -n "${CONFIG_TELEMT:-}" ]]; then
        replace_placeholder "{{CONFIG_TELEMT}}" "$CONFIG_TELEMT"
    else
        replace_placeholder "{{CONFIG_TELEMT}}" "Telegram MTProxy not enabled"
    fi

    # XHTTP (Xray-core) share link
    if [[ -n "${CONFIG_XHTTP:-}" ]]; then
        replace_placeholder "{{CONFIG_XHTTP}}" "$CONFIG_XHTTP"
    else
        replace_placeholder "{{CONFIG_XHTTP}}" "XHTTP not enabled"
    fi

    # XDNS configs (multiline JSON — use file-based replacement)
    if [[ -f "$OUTPUT_DIR/xdns-config.json" ]]; then
        python3 -c "
import sys
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

    # MasterDNS / GooseRelay (MahsaNG v16). These use a server-shared key that
    # lives in the docker state volume, so the host-side `moav user add` path
    # can't generate the instructions — `moav regenerate-users` (which runs in
    # the bootstrap container) populates them. Toggle the section off here unless
    # an instructions file is already present in the bundle.
    if [[ -f "$OUTPUT_DIR/masterdns-instructions.txt" ]]; then
        replace_placeholder "{{CONFIG_MASTERDNS}}" "$(cat "$OUTPUT_DIR/masterdns-instructions.txt")"
        replace_placeholder "{{MASTERDNS_DISPLAY}}" ""
    else
        replace_placeholder "{{CONFIG_MASTERDNS}}" "Run 'moav regenerate-users' to include MasterDNS"
        replace_placeholder "{{MASTERDNS_DISPLAY}}" "display:none"
    fi
    if [[ -f "$OUTPUT_DIR/gooserelay-instructions.txt" ]]; then
        replace_placeholder "{{CONFIG_GOOSERELAY}}" "$(cat "$OUTPUT_DIR/gooserelay-instructions.txt")"
        replace_placeholder "{{GOOSERELAY_DISPLAY}}" ""
    else
        replace_placeholder "{{CONFIG_GOOSERELAY}}" "Run 'moav regenerate-users' to include GooseRelay"
        replace_placeholder "{{GOOSERELAY_DISPLAY}}" "display:none"
    fi

    # V2Ray subscription: base64 of the newline-joined compatible share-links,
    # so the user can paste it once into any V2Ray app (MahsaNG, v2rayNG,
    # Hiddify, ...) to import all proxy protocols. DNS tunnels + GooseRelay are
    # configured separately and intentionally excluded.
    _mahsanet_uris=""
    for _f in reality cdn-vless xhttp-vless trojan shadowsocks hysteria2 \
              reality-ipv6 trojan-ipv6 shadowsocks-ipv6 hysteria2-ipv6; do
        [[ -f "$OUTPUT_DIR/$_f.txt" ]] || continue
        _u=$(tr -d '\r' < "$OUTPUT_DIR/$_f.txt" | grep -aE '^(vless|trojan|ss|hysteria2|vmess)://' | head -1 || true)
        [[ -n "$_u" ]] && _mahsanet_uris+="$_u"$'\n'
    done
    if [[ -n "$_mahsanet_uris" ]]; then
        _mahsanet_sub=$(printf '%s' "$_mahsanet_uris" | base64 | tr -d '\n')
        # Also drop the subscription as a standalone file so the bundle isn't
        # HTML-only (handy for hosting as a sub URL or importing from a file).
        printf '%s\n' "$_mahsanet_sub" > "$OUTPUT_DIR/subscription.txt"
        replace_placeholder "{{MAHSANET_SUB}}" "$_mahsanet_sub"
        replace_placeholder "{{MAHSANET_DISPLAY}}" ""
    else
        replace_placeholder "{{MAHSANET_SUB}}" "No V2Ray-compatible configs in this bundle"
        replace_placeholder "{{MAHSANET_DISPLAY}}" "display:none"
    fi

    # Clean up backup files
    rm -f "$OUTPUT_HTML.bak"

    log_info "✓ README.html generated"
else
    log_warn "Template not found: $TEMPLATE_FILE - skipping HTML guide"
fi

    # -------------------------------------------------------------------------
    # Summary for this user
    # -------------------------------------------------------------------------
    echo ""
    if [[ ${#ERRORS[@]} -gt 0 ]]; then
        log_error "User '$USERNAME' failed: ${ERRORS[*]}"
        FAILED_USERS+=("$USERNAME")
    else
        log_info "✓ User '$USERNAME' created successfully"
        CREATED_USERS+=("$USERNAME")
    fi

    # -------------------------------------------------------------------------
    # Sync credentials to Docker volume (for bootstrap persistence)
    # user-add.sh writes to host ./state/, but bootstrap reads from Docker volume.
    # -------------------------------------------------------------------------
    if [[ ${#ERRORS[@]} -eq 0 ]] && [[ -d "./state/users/$USERNAME" ]]; then
        docker run --rm \
            -v moav_moav_state:/state \
            -v "$(pwd)/state/users/$USERNAME:/host-user:ro" \
            alpine sh -c "mkdir -p /state/users/$USERNAME && cp -a /host-user/* /state/users/$USERNAME/" \
            2>/dev/null && log_info "✓ Synced credentials to Docker volume" \
            || log_warn "Could not sync to Docker volume (bootstrap will import on next run)"
    fi

    # -------------------------------------------------------------------------
    # Create package if requested
    # -------------------------------------------------------------------------
    if [[ "$CREATE_PACKAGE" == "true" ]]; then
        log_info "Creating package for $USERNAME..."
        if "$SCRIPT_DIR/user-package.sh" "$USERNAME"; then
            log_info "✓ Package created: outputs/bundles/$USERNAME.zip"
        else
            log_error "✗ Failed to create package for $USERNAME"
        fi
    fi

    echo ""
done
# End of user creation loop

# -----------------------------------------------------------------------------
# Reload services once (for batch mode)
# -----------------------------------------------------------------------------
if [[ "$BATCH_MODE" == "true" ]] && [[ ${#CREATED_USERS[@]} -gt 0 ]]; then
    echo ""
    log_info "========================================"
    log_info "Reloading services..."
    log_info "========================================"

    # Reload sing-box
    if [[ -f "configs/sing-box/config.json" ]]; then
        if docker compose ps sing-box --status running 2>/dev/null | tail -n +2 | grep -q .; then
            log_info "Reloading sing-box..."
            if docker compose exec -T sing-box sing-box reload 2>/dev/null; then
                log_info "✓ sing-box reloaded"
            else
                log_info "Hot reload failed, restarting sing-box..."
                docker compose restart sing-box
            fi
        fi
    fi

    # Reload WireGuard (needs to sync peers)
    if [[ "${ENABLE_WIREGUARD:-true}" == "true" ]] && [[ -f "configs/wireguard/wg0.conf" ]]; then
        if docker compose ps wireguard --status running 2>/dev/null | tail -n +2 | grep -q .; then
            log_info "Syncing WireGuard peers..."
            docker compose exec -T wireguard wg syncconf wg0 <(docker compose exec -T wireguard wg-quick strip wg0) 2>/dev/null || \
                docker compose restart wireguard
            log_info "✓ WireGuard synced"
        fi
    fi

    # Reload AmneziaWG
    if [[ "${ENABLE_AMNEZIAWG:-true}" == "true" ]] && [[ -f "configs/amneziawg/awg0.conf" ]]; then
        if docker compose ps amneziawg --status running 2>/dev/null | tail -n +2 | grep -q .; then
            log_info "Restarting AmneziaWG..."
            docker compose restart amneziawg
            log_info "✓ AmneziaWG restarted"
        fi
    fi

    # Reload TrustTunnel
    if [[ -f "configs/trusttunnel/credentials.toml" ]]; then
        if docker compose ps trusttunnel --status running 2>/dev/null | tail -n +2 | grep -q .; then
            log_info "Restarting TrustTunnel..."
            docker compose restart trusttunnel
            log_info "✓ TrustTunnel restarted"
        fi
    fi

    # Reload Xray (XHTTP)
    if [[ -f "configs/xray/config.json" ]]; then
        if docker compose --profile xhttp ps xray --status running 2>/dev/null | tail -n +2 | grep -q .; then
            log_info "Restarting Xray..."
            docker compose --profile xhttp restart xray
            log_info "✓ Xray restarted"
        fi
    fi

    # Reload telemt
    if [[ -f "configs/telemt/config.toml" ]]; then
        if docker compose --profile telegram ps telemt --status running 2>/dev/null | tail -n +2 | grep -q .; then
            log_info "Restarting telemt..."
            docker compose --profile telegram restart telemt
            log_info "✓ telemt restarted"
        fi
    fi
fi

# -----------------------------------------------------------------------------
# Final Summary
# -----------------------------------------------------------------------------
echo ""
log_info "========================================"
log_info "Batch Creation Summary"
log_info "========================================"
echo ""

if [[ ${#CREATED_USERS[@]} -gt 0 ]]; then
    log_info "✓ Created ${#CREATED_USERS[@]} users:"
    for u in "${CREATED_USERS[@]}"; do
        echo "    • $u"
    done
fi

if [[ ${#FAILED_USERS[@]} -gt 0 ]]; then
    log_error "✗ Failed ${#FAILED_USERS[@]} users:"
    for u in "${FAILED_USERS[@]}"; do
        echo "    • $u"
    done
fi

echo ""
log_info "Bundles location: outputs/bundles/"

if [[ "$CREATE_PACKAGE" != "true" ]] && [[ ${#CREATED_USERS[@]} -gt 0 ]]; then
    log_info "Tip: Use --package to create zip files with HTML guides"
fi

# Exit with error if any users failed
if [[ ${#FAILED_USERS[@]} -gt 0 ]]; then
    exit 1
fi
