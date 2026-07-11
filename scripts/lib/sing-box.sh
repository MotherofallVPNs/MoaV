#!/bin/bash
# sing-box specific functions

# Add a new user to sing-box configuration
singbox_add_user() {
    local user_id="$1"
    local user_uuid="$2"
    local user_password="$3"
    local config_file="/configs/sing-box/config.json"

    if [[ ! -f "$config_file" ]]; then
        log_error "sing-box config not found at $config_file"
        return 1
    fi

    # Add to Reality/VLESS users
    jq --arg name "$user_id" --arg uuid "$user_uuid" \
        '.inbounds[] | select(.tag == "vless-reality-in") | .users += [{"name": $name, "uuid": $uuid, "flow": "xtls-rprx-vision"}]' \
        "$config_file" > /tmp/config.tmp && mv /tmp/config.tmp "$config_file"

    # Add to Trojan users
    jq --arg name "$user_id" --arg password "$user_password" \
        '.inbounds[] | select(.tag == "trojan-tls-in") | .users += [{"name": $name, "password": $password}]' \
        "$config_file" > /tmp/config.tmp && mv /tmp/config.tmp "$config_file"

    # Add to Hysteria2 users
    jq --arg name "$user_id" --arg password "$user_password" \
        '.inbounds[] | select(.tag == "hysteria2-in") | .users += [{"name": $name, "password": $password}]' \
        "$config_file" > /tmp/config.tmp && mv /tmp/config.tmp "$config_file"

    # Add to VLESS WS users (CDN)
    jq --arg name "$user_id" --arg uuid "$user_uuid" \
        '.inbounds[] | select(.tag == "vless-ws-in") | .users += [{"name": $name, "uuid": $uuid}]' \
        "$config_file" > /tmp/config.tmp && mv /tmp/config.tmp "$config_file"

    log_info "Added user $user_id to sing-box configuration"
}

# Remove a user from sing-box configuration
singbox_remove_user() {
    local user_id="$1"
    local config_file="/configs/sing-box/config.json"

    if [[ ! -f "$config_file" ]]; then
        log_error "sing-box config not found at $config_file"
        return 1
    fi

    # Remove from all inbounds
    jq --arg name "$user_id" \
        '(.inbounds[].users // []) |= map(select(.name != $name))' \
        "$config_file" > /tmp/config.tmp && mv /tmp/config.tmp "$config_file"

    log_info "Removed user $user_id from sing-box configuration"
}

# Reload sing-box configuration
singbox_reload() {
    # sing-box supports hot reload via SIGHUP
    docker kill --signal=SIGHUP moav-sing-box 2>/dev/null || true
    log_info "Sent reload signal to sing-box"
}

# Add a user to TrustTunnel credentials
trusttunnel_add_user() {
    local user_id="$1"
    local user_password="$2"
    local creds_file="/configs/trusttunnel/credentials.toml"

    if [[ ! -f "$creds_file" ]]; then
        log_info "TrustTunnel not configured, skipping"
        return 0
    fi

    # Check if user already exists
    if grep -q "username = \"$user_id\"" "$creds_file" 2>/dev/null; then
        log_info "User $user_id already exists in TrustTunnel"
        return 0
    fi

    # Append new user
    cat >> "$creds_file" <<EOF

[[client]]
username = "$user_id"
password = "$user_password"
EOF

    log_info "Added user $user_id to TrustTunnel credentials"
}

# Remove a user from TrustTunnel credentials
trusttunnel_remove_user() {
    local user_id="$1"
    local creds_file="/configs/trusttunnel/credentials.toml"

    if [[ ! -f "$creds_file" ]]; then
        return 0
    fi

    # Use awk to remove the credential block for the user
    awk -v user="$user_id" '
    BEGIN { skip=0 }
    /^\[\[client\]\]/ {
        block_start = NR
        skip = 0
        next_block = 1
    }
    next_block && /^username = / {
        if ($0 ~ "username = \"" user "\"") {
            skip = 1
        }
        next_block = 0
    }
    !skip { print }
    ' "$creds_file" > "${creds_file}.tmp" && mv "${creds_file}.tmp" "$creds_file"

    log_info "Removed user $user_id from TrustTunnel credentials"
}

# =============================================================================
# Share-link builders — pure functions of the caller's environment.
# Both the host add-user path (singbox-user-add.sh) and the bundle generator
# (generate-user.sh) emit byte-identical share links; these are the single
# source of truth. Each reads USER_UUID / USER_PASSWORD and the relevant
# protocol keys from the environment, and takes (label, host) so one builder
# serves IPv4 and IPv6 — host is "1.2.3.4" or "[2001:db8::1]", label is e.g.
# "alice" or "alice-IPv6".
# =============================================================================

singbox_reality_link() {
    local label="$1" host="$2"
    echo "vless://${USER_UUID}@${host}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_TARGET_HOST}&fp=random&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp#MoaV-Reality-${label}"
}

singbox_trojan_link() {
    local label="$1" host="$2"
    echo "trojan://${USER_PASSWORD}@${host}:8443?security=tls&sni=${DOMAIN}&type=tcp#MoaV-Trojan-${label}"
}

singbox_anytls_link() {
    local label="$1" host="$2"
    echo "anytls://${USER_PASSWORD}@${host}:${PORT_ANYTLS:-8445}?sni=${DOMAIN}&insecure=0#MoaV-AnyTLS-${label}"
}

singbox_hysteria2_link() {
    local label="$1" host="$2"
    echo "hysteria2://${USER_PASSWORD}@${host}:443?sni=${DOMAIN}&obfs=salamander&obfs-password=${HYSTERIA2_OBFS_PASSWORD}#MoaV-Hysteria2-${label}"
}

# CDN routes through a fronting address (CDN_ADDRESS), not the server IP, so it
# has no IPv6 variant — only the label varies.
singbox_cdn_link() {
    local label="$1"
    echo "vless://${USER_UUID}@${CDN_ADDRESS}:443?security=tls&type=${CDN_TRANSPORT}&path=${CDN_WS_PATH}&sni=${CDN_SNI}&host=${CDN_DOMAIN}&fp=random&alpn=http/1.1#MoaV-CDN-${label}"
}
