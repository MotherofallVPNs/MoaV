#!/bin/bash
# WireGuard configuration functions

WG_CONFIG_DIR="/configs/wireguard"
WG_PORT=51820
WG_NETWORK="10.66.66.0/24"
WG_SERVER_IP="10.66.66.1"
# IPv6 ULA (Unique Local Address) range for WireGuard
WG_NETWORK_V6="fd00:cafe:beef::/64"
WG_SERVER_IP_V6="fd00:cafe:beef::1"

generate_wireguard_config() {
    ensure_dir "$WG_CONFIG_DIR"
    ensure_dir "$STATE_DIR/keys"

    # Generate server keys if not exist
    if [[ ! -f "$STATE_DIR/keys/wg-server.key" ]]; then
        log_info "Generating new WireGuard server keys..."
        # Use umask to ensure private key is only readable by owner
        (umask 077 && wg genkey > "$STATE_DIR/keys/wg-server.key")
    fi

    # Always derive public key from private key to ensure consistency
    local server_private_key
    local server_public_key
    server_private_key=$(cat "$STATE_DIR/keys/wg-server.key")
    server_public_key=$(echo "$server_private_key" | wg pubkey)

    # Save public key to state (authoritative source)
    echo "$server_public_key" > "$STATE_DIR/keys/wg-server.pub"

    log_info "WireGuard server private key: $STATE_DIR/keys/wg-server.key"
    log_info "WireGuard server public key: $server_public_key"

    # Create server config with IPv6 support if available
    local server_addresses="$WG_SERVER_IP/24"
    local postup_rules="iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth+ -j MASQUERADE"
    local postdown_rules="iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth+ -j MASQUERADE"

    # Add IPv6 if server has public IPv6
    if [[ -n "${SERVER_IPV6:-}" ]]; then
        server_addresses="$WG_SERVER_IP/24, $WG_SERVER_IP_V6/64"
        postup_rules="$postup_rules; ip6tables -A FORWARD -i %i -j ACCEPT; ip6tables -t nat -A POSTROUTING -o eth+ -j MASQUERADE"
        postdown_rules="$postdown_rules; ip6tables -D FORWARD -i %i -j ACCEPT; ip6tables -t nat -D POSTROUTING -o eth+ -j MASQUERADE"
        log_info "WireGuard IPv6 enabled: $WG_SERVER_IP_V6"
    fi

    cat > "$WG_CONFIG_DIR/wg0.conf" <<EOF
[Interface]
Address = $server_addresses
ListenPort = $WG_PORT
PrivateKey = $server_private_key
MTU = 1280
PostUp = $postup_rules
PostDown = $postdown_rules

# Peers are added dynamically
EOF

    # Save server public key for client configs (copy from state)
    cp "$STATE_DIR/keys/wg-server.pub" "$WG_CONFIG_DIR/server.pub"

    log_info "WireGuard server configuration created"
    log_info "Server public key saved to: $WG_CONFIG_DIR/server.pub"
}

# Add a WireGuard peer
wireguard_add_peer() {
    local user_id="$1"
    local peer_num="$2"

    local client_private_key
    local client_public_key
    local client_ip
    local client_ip_v6=""

    # Load existing client keys if available, only generate if missing
    if [[ -f "$STATE_DIR/users/$user_id/wireguard.env" ]]; then
        source "$STATE_DIR/users/$user_id/wireguard.env"
        client_private_key="$WG_PRIVATE_KEY"
        client_public_key="$WG_PUBLIC_KEY"
        client_ip="$WG_CLIENT_IP"
        client_ip_v6="${WG_CLIENT_IP_V6:-}"
        log_info "Loaded existing WireGuard keys for $user_id"
    else
        # Generate new client keys (lib/keys.sh — CRLF-safe)
        { read -r client_private_key && read -r client_public_key; } < <(wg_keypair)

        # Calculate client IP (IPv4)
        client_ip="10.66.66.$((peer_num + 1))"

        # Calculate client IPv6 if server has IPv6
        if [[ -n "${SERVER_IPV6:-}" ]]; then
            client_ip_v6="fd00:cafe:beef::$((peer_num + 1))"
        fi

        # Save client credentials
        cat > "$STATE_DIR/users/$user_id/wireguard.env" <<EOF
WG_PRIVATE_KEY=$client_private_key
WG_PUBLIC_KEY=$client_public_key
WG_CLIENT_IP=$client_ip
WG_CLIENT_IP_V6=$client_ip_v6
EOF
    fi

    # Add peer to server config (skip if already exists)
    local allowed_ips="$client_ip/32"
    if [[ -n "$client_ip_v6" ]]; then
        allowed_ips="$client_ip/32, $client_ip_v6/128"
    fi

    if grep -q "# $user_id$" "$WG_CONFIG_DIR/wg0.conf" 2>/dev/null; then
        log_info "WireGuard peer for $user_id already in config, skipping"
    else
        cat >> "$WG_CONFIG_DIR/wg0.conf" <<EOF

[Peer]
# $user_id
PublicKey = $client_public_key
AllowedIPs = $allowed_ips
EOF
        log_info "Added WireGuard peer for $user_id (IP: $client_ip${client_ip_v6:+, IPv6: $client_ip_v6})"
    fi
}

# Generate WireGuard client config
wireguard_generate_client_config() {
    local user_id="$1"
    local output_dir="$2"

    source "$STATE_DIR/users/$user_id/wireguard.env"
    local server_public_key
    server_public_key=$(cat "$WG_CONFIG_DIR/server.pub")

    # Build address string (IPv4 + optional IPv6)
    local client_addresses="$WG_CLIENT_IP/32"
    if [[ -n "${WG_CLIENT_IP_V6:-}" ]]; then
        client_addresses="$WG_CLIENT_IP/32, $WG_CLIENT_IP_V6/128"
    fi

    # Direct WireGuard config (IPv4 endpoint)
    cat > "$output_dir/wireguard.conf" <<EOF
[Interface]
PrivateKey = $WG_PRIVATE_KEY
Address = $client_addresses
DNS = 1.1.1.1, 8.8.8.8
MTU = 1280

[Peer]
PublicKey = $server_public_key
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${SERVER_IP}:${PORT_WIREGUARD:-51820}
PersistentKeepalive = 25
EOF

    # Generate IPv6 endpoint config if available
    if [[ -n "${SERVER_IPV6:-}" ]]; then
        cat > "$output_dir/wireguard-ipv6.conf" <<EOF
[Interface]
PrivateKey = $WG_PRIVATE_KEY
Address = $client_addresses
DNS = 1.1.1.1, 2606:4700:4700::1111
MTU = 1280

[Peer]
PublicKey = $server_public_key
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = [${SERVER_IPV6}]:${PORT_WIREGUARD:-51820}
PersistentKeepalive = 25
EOF
        log_info "Generated WireGuard IPv6 endpoint config"
    fi

    # WireGuard-wstunnel config (for censored networks)
    # Points to localhost - user must run wstunnel client first
    cat > "$output_dir/wireguard-wstunnel.conf" <<EOF
[Interface]
PrivateKey = $WG_PRIVATE_KEY
Address = $client_addresses
DNS = 1.1.1.1, 8.8.8.8
MTU = 1280

[Peer]
PublicKey = $server_public_key
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 127.0.0.1:51820
PersistentKeepalive = 25
EOF

    log_info "Generated WireGuard client config for $user_id"
}
