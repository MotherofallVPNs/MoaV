#!/bin/bash
# AmneziaWG configuration functions
# DPI-resistant WireGuard fork with obfuscation params

AWG_CONFIG_DIR="/configs/amneziawg"
AWG_PORT=51821
AWG_NETWORK="10.67.67.0/24"
AWG_SERVER_IP="10.67.67.1"
# IPv6 ULA range for AmneziaWG (different from WireGuard's fd00:cafe:beef::/64)
AWG_NETWORK_V6="fd00:cafe:dead::/64"
AWG_SERVER_IP_V6="fd00:cafe:dead::1"

generate_amneziawg_params() {
    # Generate random obfuscation parameters
    # H1-H4: unique random int32 values (5 to 2147483647)
    # S1, S2: random padding sizes (15-150), ensuring S1+56 != S2
    # Jc, Jmin, Jmax: junk packet params (client-side, but stored for user configs)

    local h1 h2 h3 h4 s1 s2

    # Generate unique H values
    h1=$((RANDOM * RANDOM % 2147483640 + 5))
    h2=$((RANDOM * RANDOM % 2147483640 + 5))
    while [ "$h2" = "$h1" ]; do
        h2=$((RANDOM * RANDOM % 2147483640 + 5))
    done
    h3=$((RANDOM * RANDOM % 2147483640 + 5))
    while [ "$h3" = "$h1" ] || [ "$h3" = "$h2" ]; do
        h3=$((RANDOM * RANDOM % 2147483640 + 5))
    done
    h4=$((RANDOM * RANDOM % 2147483640 + 5))
    while [ "$h4" = "$h1" ] || [ "$h4" = "$h2" ] || [ "$h4" = "$h3" ]; do
        h4=$((RANDOM * RANDOM % 2147483640 + 5))
    done

    # Generate S1, S2 ensuring S1+56 != S2
    s1=$((RANDOM % 136 + 15))
    s2=$((RANDOM % 136 + 15))
    while [ $((s1 + 56)) -eq "$s2" ]; do
        s2=$((RANDOM % 136 + 15))
    done

    cat > "$STATE_DIR/keys/amneziawg.env" <<EOF
AWG_H1=$h1
AWG_H2=$h2
AWG_H3=$h3
AWG_H4=$h4
AWG_S1=$s1
AWG_S2=$s2
AWG_JC=4
AWG_JMIN=50
AWG_JMAX=1000
EOF

    log_info "AmneziaWG obfuscation params generated"

    # AWG3 obfuscation on top of the 1.x baseline above.
    amneziawg_ensure_v3_params
}

# Append the AWG3 params (header protection, content padding, randomized
# timings) to amneziawg.env if they aren't there yet. Idempotent, so an
# existing install upgrading to v3 gains them WITHOUT disturbing the
# mandatory-match H1-H4/S1-S2 values its live peers already handshake on.
# S3/S4 are >= 15 (header protection requires S1-S4 >= 12). HeaderProtectionKey
# is a 32-byte key shared by all peers — same wire format as a wg key, so
# `wg genkey` produces it. Range params (a-b) are randomized per-op by the
# daemon at runtime; the ranges themselves are fixed and safe near WG defaults.
amneziawg_ensure_v3_params() {
    local env_file="$STATE_DIR/keys/amneziawg.env"
    [[ -f "$env_file" ]] || return 0
    if grep -q '^AWG_H_KEY=' "$env_file" 2>/dev/null; then
        return 0   # already has the v3 params
    fi

    local s3 s4 hkey
    s3=$((RANDOM % 136 + 15))
    s4=$((RANDOM % 136 + 15))
    hkey=$(wg genkey)

    cat >> "$env_file" <<EOF
AWG_S3=$s3
AWG_S4=$s4
AWG_H_KEY=$hkey
AWG_CPA=16-96
AWG_REKEY_AFTER=110-130
AWG_REKEY_TIMEOUT=5-8
AWG_REJECT_AFTER=170-190
AWG_KEEPALIVE_TIMEOUT=10-15
AWG_MAX_HANDSHAKE=12-20
AWG_PKA=20-30
AWG_RTRAILERS=on
EOF
    log_info "AmneziaWG v3 params generated (header protection, content padding, random trailers, timings)"
}

generate_amneziawg_config() {
    ensure_dir "$AWG_CONFIG_DIR"
    ensure_dir "$STATE_DIR/keys"

    # Generate server keys if not exist (uses standard WG key format)
    if [[ ! -f "$STATE_DIR/keys/awg-server.key" ]]; then
        log_info "Generating new AmneziaWG server keys..."
        (umask 077 && wg genkey > "$STATE_DIR/keys/awg-server.key")
    fi

    # Always derive public key from private key
    local server_private_key
    local server_public_key
    server_private_key=$(cat "$STATE_DIR/keys/awg-server.key")
    server_public_key=$(echo "$server_private_key" | wg pubkey)

    # Save public key to state
    echo "$server_public_key" > "$STATE_DIR/keys/awg-server.pub"

    log_info "AmneziaWG server public key: $server_public_key"

    # Generate obfuscation params if not exist
    if [[ ! -f "$STATE_DIR/keys/amneziawg.env" ]]; then
        generate_amneziawg_params
    else
        # Existing install upgrading to v3: backfill the v3 params in place
        # (leaves the live-peer H1-H4/S1-S2 untouched).
        amneziawg_ensure_v3_params
    fi

    source "$STATE_DIR/keys/amneziawg.env"

    # Create server config with obfuscation params
    local server_addresses="$AWG_SERVER_IP/24"
    local postup_rules="iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth+ -j MASQUERADE"
    local postdown_rules="iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth+ -j MASQUERADE"

    # Add IPv6 if server has public IPv6
    if [[ -n "${SERVER_IPV6:-}" ]]; then
        server_addresses="$AWG_SERVER_IP/24, $AWG_SERVER_IP_V6/64"
        postup_rules="$postup_rules; ip6tables -A FORWARD -i %i -j ACCEPT; ip6tables -t nat -A POSTROUTING -o eth+ -j MASQUERADE"
        postdown_rules="$postdown_rules; ip6tables -D FORWARD -i %i -j ACCEPT; ip6tables -t nat -D POSTROUTING -o eth+ -j MASQUERADE"
        log_info "AmneziaWG IPv6 enabled: $AWG_SERVER_IP_V6"
    fi

    # Optional v3.1 DisableCookies (default off: keep WireGuard's handshake-flood
    # DoS defence). AWG_DISABLE_COOKIES=true drops the distinctive cookie-reply
    # packet for a bit more obfuscation, at the cost of that protection. Read at
    # generation time so `moav regenerate-users` applies a change to it.
    local awg_dcookies=""
    [[ "${AWG_DISABLE_COOKIES:-false}" == "true" ]] && awg_dcookies="DisableCookies = on"

    # AWG 1.5 header-protection obfuscation (HeaderProtectionKey / ContentPadding /
    # RandomTrailers). OFF by default: the AmneziaVPN app's .conf importer silently
    # drops these keys, so a bundle imported there sends un-protected handshakes the
    # server can no longer parse -> connects but relays zero traffic. The dedicated
    # AmneziaWG app supports them. Enable only when every client runs the AmneziaWG
    # app, for stronger obfuscation. Read at generation time so regenerate applies it.
    local awg_hdrprot=""
    if [[ "${AMNEZIAWG_HEADER_PROTECTION:-false}" == "true" ]]; then
        printf -v awg_hdrprot 'HeaderProtectionKey = %s\nContentPaddingAddition = %s\nRandomTrailers = %s' \
            "$AWG_H_KEY" "$AWG_CPA" "$AWG_RTRAILERS"
    fi

    cat > "$AWG_CONFIG_DIR/awg0.conf" <<EOF
[Interface]
Address = $server_addresses
ListenPort = $AWG_PORT
PrivateKey = $server_private_key
MTU = 1280
Jc = $AWG_JC
Jmin = $AWG_JMIN
Jmax = $AWG_JMAX
S1 = $AWG_S1
S2 = $AWG_S2
S3 = $AWG_S3
S4 = $AWG_S4
H1 = $AWG_H1
H2 = $AWG_H2
H3 = $AWG_H3
H4 = $AWG_H4
$awg_hdrprot
RekeyAfterTime = $AWG_REKEY_AFTER
RekeyTimeout = $AWG_REKEY_TIMEOUT
RejectAfterTime = $AWG_REJECT_AFTER
KeepaliveTimeout = $AWG_KEEPALIVE_TIMEOUT
MaxHandshakeAttempts = $AWG_MAX_HANDSHAKE
$awg_dcookies
PostUp = $postup_rules
PostDown = $postdown_rules

# Peers are added dynamically
EOF

    # Save server public key for client configs
    cp "$STATE_DIR/keys/awg-server.pub" "$AWG_CONFIG_DIR/server.pub"

    log_info "AmneziaWG server configuration created"
}

# Add an AmneziaWG peer
amneziawg_add_peer() {
    local user_id="$1"; shift
    # Remaining args: octets already in use on a live interface (host path scrapes
    # `awg show awg0 allowed-ips`). Merged with the config scan for collision safety.
    local extra_used="$*"

    local client_private_key
    local client_public_key
    local client_ip
    local client_ip_v6=""

    # Load existing client keys if available, only generate if missing
    local have_state=false
    if [[ -f "$STATE_DIR/users/$user_id/amneziawg.env" ]]; then
        # Clear first: source does not unset, so without this a truncated file
        # would silently validate against whatever a previous call left behind.
        unset AWG_PRIVATE_KEY AWG_PUBLIC_KEY AWG_CLIENT_IP AWG_CLIENT_IP_V6
        source "$STATE_DIR/users/$user_id/amneziawg.env"
        # Validate before trusting it. A truncated state file -- a previous run
        # that died between the mkdir and the heredoc write -- used to crash on
        # the bare $AWG_PRIVATE_KEY below and never self-heal, because the broken
        # file kept winning this branch on every retry.
        if [[ -n "${AWG_PRIVATE_KEY:-}" && -n "${AWG_PUBLIC_KEY:-}" && -n "${AWG_CLIENT_IP:-}" ]]; then
            have_state=true
        else
            log_warn "AmneziaWG: ignoring incomplete state file for $user_id"
        fi
    fi
    if [[ "$have_state" == true ]]; then
        client_private_key="$AWG_PRIVATE_KEY"
        client_public_key="$AWG_PUBLIC_KEY"
        client_ip="$AWG_CLIENT_IP"
        client_ip_v6="${AWG_CLIENT_IP_V6:-}"
        log_info "Loaded existing AmneziaWG keys for $user_id"
        if net_ip_claimed_by_other "$AWG_CONFIG_DIR/awg0.conf" "$client_ip" "$user_id"; then
            local octet
            octet=$(net_next_free_octet "$AWG_CONFIG_DIR/awg0.conf" "10.67.67" $extra_used) || {
                log_error "No available IPs in AmneziaWG network"; return 1; }
            log_warn "AmneziaWG: stored IP $client_ip for $user_id is taken; reassigning to 10.67.67.$octet"
            client_ip="10.67.67.$octet"
            if [[ -n "${SERVER_IPV6:-}" ]]; then client_ip_v6="fd00:cafe:dead::$octet"; else client_ip_v6=""; fi
            cat > "$STATE_DIR/users/$user_id/amneziawg.env" <<EOF
AWG_PRIVATE_KEY=$client_private_key
AWG_PUBLIC_KEY=$client_public_key
AWG_CLIENT_IP=$client_ip
AWG_CLIENT_IP_V6=$client_ip_v6
EOF
        fi
    elif grep -q "# $user_id$" "${AWG_CONFIG_DIR}/awg0.conf" 2>/dev/null; then
        # Third state: the server already has a peer for this user, but their key
        # material is NOT in state. The private key only ever existed in their
        # bundle, so it cannot be recovered — minting a fresh keypair here would
        # write a bundle whose key the server does not know (the append below is
        # skipped for an existing peer), silently breaking a user who works today.
        # Leave both the peer and any existing bundle alone and tell the caller.
        log_warn "AmneziaWG: $user_id has a server peer but no key material in state"
        log_warn "  leaving the existing peer and bundle untouched (private key is unrecoverable)"
        log_warn "  to re-issue this user: moav user revoke $user_id && moav user add $user_id"
        return 2
    else
        # Generate client keys (lib/keys.sh — CRLF-safe; standard WG format, AWG-compatible)
        # Guarded: if wg_keypair fails it emits nothing, the first read returns 1,
        # && short-circuits, and client_public_key stays declared-but-unset -- which
        # under set -u kills the run later with a misleading "unbound variable".
        if ! { read -r client_private_key && read -r client_public_key; } < <(wg_keypair); then
            log_error "AmneziaWG: no wg/awg key generator available (install wireguard-tools or start the container)"
            return 1
        fi

        # Allocate the next free host octet (collision-safe across revoked-user
        # gaps; supersedes the old peer-count+1 scheme that reused freed IPs).
        local octet
        octet=$(net_next_free_octet "$AWG_CONFIG_DIR/awg0.conf" "10.67.67" $extra_used) || {
            log_error "No available IPs in AmneziaWG network"
            return 1
        }
        client_ip="10.67.67.$octet"

        # Calculate client IPv6 if server has IPv6
        if [[ -n "${SERVER_IPV6:-}" ]]; then
            client_ip_v6="fd00:cafe:dead::$octet"
        fi

        # Save client credentials
        cat > "$STATE_DIR/users/$user_id/amneziawg.env" <<EOF
AWG_PRIVATE_KEY=$client_private_key
AWG_PUBLIC_KEY=$client_public_key
AWG_CLIENT_IP=$client_ip
AWG_CLIENT_IP_V6=$client_ip_v6
EOF
    fi

    # Add peer to server config (skip if already exists)
    local allowed_ips="$client_ip/32"
    if [[ -n "$client_ip_v6" ]]; then
        allowed_ips="$client_ip/32, $client_ip_v6/128"
    fi

    if grep -q "# $user_id$" "$AWG_CONFIG_DIR/awg0.conf" 2>/dev/null; then
        log_info "AmneziaWG peer for $user_id already in config, skipping"
    else
        cat >> "$AWG_CONFIG_DIR/awg0.conf" <<EOF

[Peer]
# $user_id
PublicKey = $client_public_key
AllowedIPs = $allowed_ips
EOF
        log_info "Added AmneziaWG peer for $user_id (IP: $client_ip${client_ip_v6:+, IPv6: $client_ip_v6})"
    fi
}

# Generate AmneziaWG client config
amneziawg_generate_client_config() {
    local user_id="$1"
    local output_dir="$2"

    source "$STATE_DIR/users/$user_id/amneziawg.env"

    # Obfuscation params: read from the awg0.conf [Interface] header — the
    # always-present source on both host and container (state/keys/amneziawg.env
    # exists only in the container). One consistent config-read path; the values
    # are identical to the state file (both are written from the same params).
    local awg_conf="$AWG_CONFIG_DIR/awg0.conf"
    local AWG_JC AWG_JMIN AWG_JMAX AWG_S1 AWG_S2 AWG_H1 AWG_H2 AWG_H3 AWG_H4
    local AWG_S3 AWG_S4 AWG_HKEY AWG_CPA AWG_REKEY_AFTER AWG_REKEY_TIMEOUT
    local AWG_REJECT_AFTER AWG_KEEPALIVE_TIMEOUT AWG_MAX_HANDSHAKE AWG_RTRAILERS AWG_DCOOKIES
    AWG_JC=$(awk '/^Jc[[:space:]]*=/{print $3; exit}'   "$awg_conf")
    AWG_JMIN=$(awk '/^Jmin[[:space:]]*=/{print $3; exit}' "$awg_conf")
    AWG_JMAX=$(awk '/^Jmax[[:space:]]*=/{print $3; exit}' "$awg_conf")
    AWG_S1=$(awk '/^S1[[:space:]]*=/{print $3; exit}'   "$awg_conf")
    AWG_S2=$(awk '/^S2[[:space:]]*=/{print $3; exit}'   "$awg_conf")
    AWG_H1=$(awk '/^H1[[:space:]]*=/{print $3; exit}'   "$awg_conf")
    AWG_H2=$(awk '/^H2[[:space:]]*=/{print $3; exit}'   "$awg_conf")
    AWG_H3=$(awk '/^H3[[:space:]]*=/{print $3; exit}'   "$awg_conf")
    AWG_H4=$(awk '/^H4[[:space:]]*=/{print $3; exit}'   "$awg_conf")
    # v3 params (must be read from awg0.conf so the mandatory-match ones —
    # HeaderProtectionKey, S3, S4 — are byte-identical to the server's).
    AWG_S3=$(awk '/^S3[[:space:]]*=/{print $3; exit}'   "$awg_conf")
    AWG_S4=$(awk '/^S4[[:space:]]*=/{print $3; exit}'   "$awg_conf")
    AWG_HKEY=$(awk '/^HeaderProtectionKey[[:space:]]*=/{print $3; exit}' "$awg_conf")
    AWG_CPA=$(awk '/^ContentPaddingAddition[[:space:]]*=/{print $3; exit}' "$awg_conf")
    AWG_REKEY_AFTER=$(awk '/^RekeyAfterTime[[:space:]]*=/{print $3; exit}' "$awg_conf")
    AWG_REKEY_TIMEOUT=$(awk '/^RekeyTimeout[[:space:]]*=/{print $3; exit}' "$awg_conf")
    AWG_REJECT_AFTER=$(awk '/^RejectAfterTime[[:space:]]*=/{print $3; exit}' "$awg_conf")
    AWG_KEEPALIVE_TIMEOUT=$(awk '/^KeepaliveTimeout[[:space:]]*=/{print $3; exit}' "$awg_conf")
    AWG_MAX_HANDSHAKE=$(awk '/^MaxHandshakeAttempts[[:space:]]*=/{print $3; exit}' "$awg_conf")
    AWG_RTRAILERS=$(awk '/^RandomTrailers[[:space:]]*=/{print $3; exit}' "$awg_conf")
    AWG_DCOOKIES=$(awk '/^DisableCookies[[:space:]]*=/{print $3; exit}' "$awg_conf")
    local dcookies_line=""
    [[ -n "$AWG_DCOOKIES" ]] && dcookies_line="DisableCookies = $AWG_DCOOKIES"

    # Mirror the server's awg0.conf: emit the AWG 1.5 header-protection block only
    # when the server actually has it (AMNEZIAWG_HEADER_PROTECTION=true). Empty ->
    # omit, so a compat-mode bundle never ships a bare `HeaderProtectionKey =` and
    # every client (incl. the AmneziaVPN importer) can handshake.
    local awg_hdrprot=""
    if [[ -n "$AWG_HKEY" ]]; then
        printf -v awg_hdrprot 'HeaderProtectionKey = %s\nContentPaddingAddition = %s\nRandomTrailers = %s' \
            "$AWG_HKEY" "$AWG_CPA" "$AWG_RTRAILERS"
    fi

    local server_public_key
    server_public_key=$(cat "$AWG_CONFIG_DIR/server.pub")

    # Build address string (IPv4 + optional IPv6)
    local client_addresses="$AWG_CLIENT_IP/32"
    if [[ -n "${AWG_CLIENT_IP_V6:-}" ]]; then
        client_addresses="$AWG_CLIENT_IP/32, $AWG_CLIENT_IP_V6/128"
    fi

    # docker-compose env_file does not strip inline comments, so a .env line like
    # `PORT_AMNEZIAWG=51821 # AmneziaWG (obfuscated WireGuard, UDP)` arrives as the
    # whole string. Keep only the leading digits, or the generated Endpoint becomes
    # `IP:51821 # AmneziaWG ...` and clients reject the config outright.
    local awg_port="${PORT_AMNEZIAWG:-51821}"
    awg_port="${awg_port%%[!0-9]*}"
    [[ -n "$awg_port" ]] || awg_port="51821"

    # AmneziaWG client config (includes obfuscation params)
    cat > "$output_dir/$(moav_wg_basename awg).conf" <<EOF
[Interface]
PrivateKey = $AWG_PRIVATE_KEY
Address = $client_addresses
DNS = 1.1.1.1, 8.8.8.8
MTU = 1280
Jc = $AWG_JC
Jmin = $AWG_JMIN
Jmax = $AWG_JMAX
S1 = $AWG_S1
S2 = $AWG_S2
S3 = $AWG_S3
S4 = $AWG_S4
H1 = $AWG_H1
H2 = $AWG_H2
H3 = $AWG_H3
H4 = $AWG_H4
$awg_hdrprot
RekeyAfterTime = $AWG_REKEY_AFTER
RekeyTimeout = $AWG_REKEY_TIMEOUT
RejectAfterTime = $AWG_REJECT_AFTER
KeepaliveTimeout = $AWG_KEEPALIVE_TIMEOUT
MaxHandshakeAttempts = $AWG_MAX_HANDSHAKE
$dcookies_line

[Peer]
PublicKey = $server_public_key
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${SERVER_IP}:${awg_port}
PersistentKeepalive = 22-30
EOF

    # Generate IPv6 endpoint config if available
    if [[ -n "${SERVER_IPV6:-}" ]]; then
        cat > "$output_dir/$(moav_wg_basename awg6).conf" <<EOF
[Interface]
PrivateKey = $AWG_PRIVATE_KEY
Address = $client_addresses
DNS = 1.1.1.1, 2606:4700:4700::1111
MTU = 1280
Jc = $AWG_JC
Jmin = $AWG_JMIN
Jmax = $AWG_JMAX
S1 = $AWG_S1
S2 = $AWG_S2
S3 = $AWG_S3
S4 = $AWG_S4
H1 = $AWG_H1
H2 = $AWG_H2
H3 = $AWG_H3
H4 = $AWG_H4
$awg_hdrprot
RekeyAfterTime = $AWG_REKEY_AFTER
RekeyTimeout = $AWG_REKEY_TIMEOUT
RejectAfterTime = $AWG_REJECT_AFTER
KeepaliveTimeout = $AWG_KEEPALIVE_TIMEOUT
MaxHandshakeAttempts = $AWG_MAX_HANDSHAKE
$dcookies_line

[Peer]
PublicKey = $server_public_key
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = [${SERVER_IPV6}]:${awg_port}
PersistentKeepalive = 22-30
EOF
        log_info "Generated AmneziaWG IPv6 endpoint config"
    fi

    # Same as WireGuard: remove the pre-rename filenames so a regenerated bundle
    # never ships a stale second copy of the tunnel.
    rm -f "$output_dir/amneziawg.conf" "$output_dir/amneziawg-ipv6.conf" 2>/dev/null || true

    log_info "Generated AmneziaWG client config for $user_id"
}
