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
H1 = $AWG_H1
H2 = $AWG_H2
H3 = $AWG_H3
H4 = $AWG_H4
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
    local user_id="$1"
    local peer_num="$2"

    local client_private_key
    local client_public_key
    local client_ip
    local client_ip_v6=""

    # Load existing client keys if available, only generate if missing
    if [[ -f "$STATE_DIR/users/$user_id/amneziawg.env" ]]; then
        source "$STATE_DIR/users/$user_id/amneziawg.env"
        client_private_key="$AWG_PRIVATE_KEY"
        client_public_key="$AWG_PUBLIC_KEY"
        client_ip="$AWG_CLIENT_IP"
        client_ip_v6="${AWG_CLIENT_IP_V6:-}"
        log_info "Loaded existing AmneziaWG keys for $user_id"
    else
        # Generate client keys (lib/keys.sh — CRLF-safe; standard WG format, AWG-compatible)
        { read -r client_private_key && read -r client_public_key; } < <(wg_keypair)

        # Calculate client IP (IPv4)
        client_ip="10.67.67.$((peer_num + 1))"

        # Calculate client IPv6 if server has IPv6
        if [[ -n "${SERVER_IPV6:-}" ]]; then
            client_ip_v6="fd00:cafe:dead::$((peer_num + 1))"
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
    source "$STATE_DIR/keys/amneziawg.env"

    local server_public_key
    server_public_key=$(cat "$AWG_CONFIG_DIR/server.pub")

    # Build address string (IPv4 + optional IPv6)
    local client_addresses="$AWG_CLIENT_IP/32"
    if [[ -n "${AWG_CLIENT_IP_V6:-}" ]]; then
        client_addresses="$AWG_CLIENT_IP/32, $AWG_CLIENT_IP_V6/128"
    fi

    # AmneziaWG client config (includes obfuscation params)
    cat > "$output_dir/amneziawg.conf" <<EOF
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
H1 = $AWG_H1
H2 = $AWG_H2
H3 = $AWG_H3
H4 = $AWG_H4

[Peer]
PublicKey = $server_public_key
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${SERVER_IP}:${PORT_AMNEZIAWG:-51821}
PersistentKeepalive = 25
EOF

    # Generate IPv6 endpoint config if available
    if [[ -n "${SERVER_IPV6:-}" ]]; then
        cat > "$output_dir/amneziawg-ipv6.conf" <<EOF
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
H1 = $AWG_H1
H2 = $AWG_H2
H3 = $AWG_H3
H4 = $AWG_H4

[Peer]
PublicKey = $server_public_key
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = [${SERVER_IPV6}]:${PORT_AMNEZIAWG:-51821}
PersistentKeepalive = 25
EOF
        log_info "Generated AmneziaWG IPv6 endpoint config"
    fi

    log_info "Generated AmneziaWG client config for $user_id"
}
