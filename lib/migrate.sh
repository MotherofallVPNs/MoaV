#!/bin/bash
# lib/migrate.sh — moving a deployment: `moav export` / `moav import` (state,
# configs and user bundles as one archive) and `moav migrate-ip` (rewrite the
# server address across configs and bundles after a VPS move).
#
# Sourced by moav.sh after lib/common.sh; reached from the dispatcher and from
# the interactive menu.
#
# Definitions only — nothing here runs at source time.

cmd_export() {
    print_section "Export MoaV Configuration"

    local output_file="${1:-}"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local default_name="moav-backup-${timestamp}.tar.gz"

    if [[ -z "$output_file" ]]; then
        output_file="$default_name"
    fi

    # Ensure .tar.gz extension
    if [[ "$output_file" != *.tar.gz ]]; then
        output_file="${output_file}.tar.gz"
    fi

    info "Creating backup: $output_file"
    echo ""

    # Create temp directory for export
    local temp_dir=$(mktemp -d)
    local export_dir="$temp_dir/moav-export"
    mkdir -p "$export_dir"

    # 1. Export .env file
    if [[ -f ".env" ]]; then
        info "  Exporting .env..."
        cp ".env" "$export_dir/"
    else
        warn "  No .env file found"
    fi

    # 2. Export state from Docker volume (keys + users)
    info "  Exporting state (keys, users)..."
    if docker volume inspect moav_moav_state &>/dev/null; then
        mkdir -p "$export_dir/state"
        docker run --rm \
            -v moav_moav_state:/state:ro \
            -v "$export_dir/state:/backup" \
            alpine sh -c "cp -a /state/. /backup/ 2>/dev/null || true"

        # Verify key files were exported
        if [[ -f "$export_dir/state/keys/reality.env" ]]; then
            success "    Reality keys exported"
        fi
        if [[ -f "$export_dir/state/keys/wg-server.key" ]]; then
            success "    WireGuard keys exported"
        fi
        if [[ -f "$export_dir/state/keys/dnstt-server.key.hex" ]]; then
            success "    dnstt keys exported"
        fi

    else
        warn "  State volume not found (moav_moav_state)"
    fi

    # Count actual users from bundles directory
    local user_count=0
    if [[ -d "outputs/bundles" ]]; then
        for user_dir in outputs/bundles/*/; do
            if [[ -d "$user_dir" ]]; then
                local username=$(basename "$user_dir")
                # Skip zip file extractions and temp directories
                [[ "$username" == *-configs ]] && continue
                [[ "$username" == *-moav-configs ]] && continue
                ((user_count++)) || true
            fi
        done
    fi
    if [[ "$user_count" -gt 0 ]]; then
        success "    $user_count user(s) found"
    fi

    # 2b. Export conduit data (Psiphon key)
    if docker volume inspect moav_moav_conduit &>/dev/null; then
        info "  Exporting conduit data..."
        mkdir -p "$export_dir/conduit"
        docker run --rm \
            -v moav_moav_conduit:/data:ro \
            -v "$export_dir/conduit:/backup" \
            alpine sh -c "cp -a /data/. /backup/ 2>/dev/null || true"
        success "    Conduit data exported"
    fi

    # 2c. Export TLS certificates
    if docker volume inspect moav_moav_certs &>/dev/null; then
        info "  Exporting TLS certificates..."
        mkdir -p "$export_dir/certs"
        docker run --rm \
            -v moav_moav_certs:/certs:ro \
            -v "$export_dir/certs:/backup" \
            alpine sh -c "cp -a /certs/. /backup/ 2>/dev/null || true"
        success "    TLS certificates exported"
    fi

    # 3. Export configs directory
    if [[ -d "configs" ]]; then
        info "  Exporting configs..."
        mkdir -p "$export_dir/configs"
        cp -a configs/. "$export_dir/configs/" 2>/dev/null || true
    fi

    # 4. Export outputs/bundles (user configs)
    if [[ -d "outputs/bundles" ]]; then
        info "  Exporting user bundles..."
        mkdir -p "$export_dir/outputs/bundles"
        cp -a outputs/bundles/. "$export_dir/outputs/bundles/" 2>/dev/null || true
    fi

    # 5. Export dnstt outputs (public key for clients)
    if [[ -d "outputs/dnstt" ]]; then
        info "  Exporting dnstt outputs..."
        mkdir -p "$export_dir/outputs/dnstt"
        cp -a outputs/dnstt/. "$export_dir/outputs/dnstt/" 2>/dev/null || true
    fi

    # 5b. Export slipstream outputs (cert for clients)
    if [[ -d "outputs/slipstream" ]]; then
        info "  Exporting slipstream outputs..."
        mkdir -p "$export_dir/outputs/slipstream"
        cp -a outputs/slipstream/. "$export_dir/outputs/slipstream/" 2>/dev/null || true
    fi

    # 6. Create manifest
    info "  Creating manifest..."
    cat > "$export_dir/manifest.json" <<EOF
{
    "version": "1.0",
    "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "moav_version": "${MOAV_VERSION:-unknown}",
    "hostname": "$(hostname)",
    "server_ip": "$(get_env_val "SERVER_IP" ".env" "unknown")",
    "domain": "$(get_env_val "DOMAIN" ".env" "unknown")"
}
EOF

    # The container-based `cp -a` steps above (state, conduit, certs) preserve
    # root ownership, which a non-root operator's host-side tar then can't read
    # ("Permission denied" on keys/conduit datastore). Hand the staged copy back
    # to the invoking user via a root container so the tar can read everything.
    if [[ "$(id -u)" -ne 0 ]]; then
        docker run --rm -v "$temp_dir:/export" alpine \
            chown -R "$(id -u):$(id -g)" /export 2>/dev/null || true
    fi

    # 7. Create tarball
    info "  Creating archive..."
    tar -czf "$output_file" -C "$temp_dir" moav-export

    # Cleanup
    rm -rf "$temp_dir"

    local size=$(du -h "$output_file" | cut -f1)
    echo ""
    success "Backup created: $output_file ($size)"
    echo ""
    echo -e "${CYAN}Contents:${NC}"
    # `head` closes the pipe after 30 lines; tar then gets SIGPIPE and reports a
    # write error, which under `set -o pipefail` would fail the whole command
    # once a backup has >30 entries (any real deployment). Tolerate it.
    tar -tzf "$output_file" 2>/dev/null | head -30 || true
    echo ""
    echo -e "${YELLOW}Security Note:${NC} This backup contains private keys."
    echo "  Transfer securely and delete after import."
    echo ""
    echo -e "${CYAN}To import on new server:${NC}"
    echo "  1. Copy this file to the new server"
    echo "  2. Run: moav import $output_file"
    echo "  3. Update .env with new SERVER_IP if needed"
    echo "  4. Run: moav migrate-ip NEW_IP"
}

cmd_import() {
    print_section "Import MoaV Configuration"

    local input_file="${1:-}"

    if [[ -z "$input_file" ]]; then
        error "Usage: moav import <backup-file.tar.gz>"
        exit 1
    fi

    # Resolve relative paths from original working directory
    if [[ "$input_file" != /* ]]; then
        if [[ -f "$ORIGINAL_PWD/$input_file" ]]; then
            input_file="$ORIGINAL_PWD/$input_file"
        fi
    fi

    if [[ ! -f "$input_file" ]]; then
        error "File not found: $input_file"
        exit 1
    fi

    info "Importing from: $input_file"
    echo ""

    # Check if this will overwrite existing data
    local has_existing=false
    if [[ -f ".env" ]] || docker volume inspect moav_moav_state &>/dev/null 2>&1; then
        has_existing=true
        warn "Existing configuration detected!"
        echo ""
        echo -e "${YELLOW}This will overwrite:${NC}"
        [[ -f ".env" ]] && echo "  - .env file"
        docker volume inspect moav_moav_state &>/dev/null 2>&1 && echo "  - State volume (keys, users)"
        [[ -d "configs" ]] && echo "  - configs directory"
        echo ""
        printf "Continue? [y/N] "
        read -r confirm < /dev/tty 2>/dev/null || confirm="n"
        if [[ ! "$confirm" =~ ^[Yy] ]]; then
            info "Import cancelled."
            exit 0
        fi
        echo ""
    fi

    # Extract to temp directory
    local temp_dir=$(mktemp -d)
    info "  Extracting archive..."
    tar -xzf "$input_file" -C "$temp_dir"

    local export_dir="$temp_dir/moav-export"
    if [[ ! -d "$export_dir" ]]; then
        error "Invalid backup format"
        rm -rf "$temp_dir"
        exit 1
    fi

    # Show manifest
    if [[ -f "$export_dir/manifest.json" ]]; then
        echo ""
        echo -e "${CYAN}Backup Info:${NC}"
        cat "$export_dir/manifest.json" | grep -E '(created|server_ip|domain)' | sed 's/[",]//g' | sed 's/^/  /'
        echo ""
    fi

    # 1. Import .env file
    if [[ -f "$export_dir/.env" ]]; then
        info "  Importing .env..."
        cp "$export_dir/.env" ".env"
        success "    .env imported"
    fi

    # 2. Import state to Docker volume
    if [[ -d "$export_dir/state" ]]; then
        info "  Importing state (keys, users)..."

        # Create volume if it doesn't exist
        docker volume create moav_moav_state &>/dev/null || true

        # Copy state to volume
        docker run --rm \
            -v moav_moav_state:/state \
            -v "$export_dir/state:/backup:ro" \
            alpine sh -c "rm -rf /state/* && cp -a /backup/. /state/"

        success "    State imported to Docker volume"
    fi

    # 2b. Import conduit data (Psiphon key)
    if [[ -d "$export_dir/conduit" ]]; then
        info "  Importing conduit data..."
        docker volume create moav_moav_conduit &>/dev/null || true
        docker run --rm \
            -v moav_moav_conduit:/data \
            -v "$export_dir/conduit:/backup:ro" \
            alpine sh -c "rm -rf /data/* && cp -a /backup/. /data/"
        success "    Conduit data imported"
    fi

    # 2c. Import TLS certificates
    if [[ -d "$export_dir/certs" ]]; then
        info "  Importing TLS certificates..."
        docker volume create moav_moav_certs &>/dev/null || true
        docker run --rm \
            -v moav_moav_certs:/certs \
            -v "$export_dir/certs:/backup:ro" \
            alpine sh -c "rm -rf /certs/* && cp -a /backup/. /certs/"
        success "    TLS certificates imported"
    fi

    # 3. Import configs
    if [[ -d "$export_dir/configs" ]]; then
        info "  Importing configs..."
        mkdir -p configs
        cp -a "$export_dir/configs/." configs/
        success "    Configs imported"
    fi

    # 4. Import outputs/bundles
    if [[ -d "$export_dir/outputs/bundles" ]]; then
        info "  Importing user bundles..."
        mkdir -p outputs/bundles
        cp -a "$export_dir/outputs/bundles/." outputs/bundles/
        success "    User bundles imported"
    fi

    # 5. Import dnstt outputs
    if [[ -d "$export_dir/outputs/dnstt" ]]; then
        info "  Importing dnstt outputs..."
        mkdir -p outputs/dnstt
        cp -a "$export_dir/outputs/dnstt/." outputs/dnstt/
        success "    dnstt outputs imported"
    fi

    # 5b. Import slipstream outputs
    if [[ -d "$export_dir/outputs/slipstream" ]]; then
        info "  Importing slipstream outputs..."
        mkdir -p outputs/slipstream
        cp -a "$export_dir/outputs/slipstream/." outputs/slipstream/
        success "    slipstream outputs imported"
    fi

    # Cleanup
    rm -rf "$temp_dir"

    echo ""
    success "Import complete!"
    echo ""

    # Check if IP migration is needed
    local old_ip=$(get_env_val "SERVER_IP" ".env")
    local current_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "")

    if [[ -n "$old_ip" ]] && [[ -n "$current_ip" ]] && [[ "$old_ip" != "$current_ip" ]]; then
        echo ""
        warn "IP address mismatch detected!"
        echo "  Backup IP:  $old_ip"
        echo "  Current IP: $current_ip"
        echo ""
        echo -e "${CYAN}To update to new IP, run:${NC}"
        echo "  moav migrate-ip $current_ip"
        echo ""
    fi

    echo -e "${CYAN}Next steps:${NC}"
    echo "  1. Review .env and update SERVER_IP/DOMAIN if needed"
    echo "  2. Regenerate user configs: moav regenerate-users"
    echo "  3. Run: moav start"
}

cmd_migrate_ip() {
    print_section "Migrate Server IP"

    local new_ip="${1:-}"

    if [[ -z "$new_ip" ]]; then
        # Try to detect current IP
        local detected_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
        if [[ -n "$detected_ip" ]]; then
            echo "Detected current IP: $detected_ip"
            echo ""
        fi
        error "Usage: moav migrate-ip <new-ip>"
        echo ""
        echo "This command updates SERVER_IP and regenerates all client configs."
        exit 1
    fi

    # Validate IP format (basic check)
    if ! echo "$new_ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        error "Invalid IP address format: $new_ip"
        exit 1
    fi

    local old_ip=$(get_env_val "SERVER_IP" ".env")

    # If old_ip is empty (auto-detect mode), try to detect current IP for config updates
    if [[ -z "$old_ip" ]]; then
        info "SERVER_IP not set in .env (auto-detect mode)"
        old_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
        if [[ -z "$old_ip" ]]; then
            warn "Could not detect current IP. Will set new IP but cannot update existing configs."
            echo "  Run user regeneration manually after migration if needed."
            echo ""
        else
            info "Detected current IP: $old_ip"
        fi
    fi

    if [[ "$old_ip" == "$new_ip" ]]; then
        info "IP address is already set to $new_ip"
        exit 0
    fi

    if [[ -n "$old_ip" ]]; then
        info "Migrating from $old_ip to $new_ip"
    else
        info "Setting IP to $new_ip"
    fi
    echo ""

    # Detect IPv6 if available
    local new_ipv6=""
    local old_ipv6=$(get_env_val "SERVER_IPV6" ".env")
    if [[ "$old_ipv6" != "disabled" ]]; then
        new_ipv6=$(curl -6 -s --max-time 3 https://api6.ipify.org 2>/dev/null || echo "")
        if [[ -n "$new_ipv6" ]]; then
            info "Detected IPv6: $new_ipv6"
        fi
    fi

    # 1. Update .env
    info "  Updating .env..."
    sed -i.bak "s/^SERVER_IP=.*/SERVER_IP=\"$new_ip\"/" .env
    rm -f .env.bak
    success "    SERVER_IP updated"

    # Update IPv6 if detected
    if [[ -n "$new_ipv6" ]]; then
        if grep -q "^SERVER_IPV6=" .env; then
            sed -i.bak "s/^SERVER_IPV6=.*/SERVER_IPV6=\"$new_ipv6\"/" .env
        else
            echo "SERVER_IPV6=\"$new_ipv6\"" >> .env
        fi
        rm -f .env.bak
        success "    SERVER_IPV6 updated"
    fi

    # 2. Update WireGuard server config (if exists)
    if [[ -f "configs/wireguard/wg0.conf" ]]; then
        info "  Updating WireGuard config..."
        # WireGuard server config doesn't contain server IP, but let's check
        success "    WireGuard config OK (no changes needed)"
    fi

    # 3. Regenerate user bundles (only if we have old_ip to replace)
    info "  Regenerating user bundles..."
    local users_dir="outputs/bundles"
    if [[ -z "$old_ip" ]]; then
        warn "    Cannot update configs without old IP. Skipping bundle regeneration."
        echo "    Run 'moav user package <username>' to regenerate individual user bundles."
    elif [[ -d "$users_dir" ]]; then
        local regenerated=0
        for user_dir in "$users_dir"/*/; do
            if [[ -d "$user_dir" ]]; then
                local username=$(basename "$user_dir")

                # Skip if it looks like a zip file name pattern
                [[ "$username" == *-configs ]] && continue
                [[ "$username" == *-moav-configs ]] && continue

                # Update Reality config
                if [[ -f "$user_dir/reality.txt" ]]; then
                    sed -i.bak "s/@$old_ip:/@$new_ip:/g" "$user_dir/reality.txt"
                    rm -f "$user_dir/reality.txt.bak"
                fi

                # Update sing-box configs
                for config in "$user_dir"/*-singbox.json; do
                    if [[ -f "$config" ]]; then
                        sed -i.bak "s/\"server\": \"$old_ip\"/\"server\": \"$new_ip\"/g" "$config"
                        rm -f "$config.bak"
                    fi
                done

                # Update Hysteria2 configs
                if [[ -f "$user_dir/hysteria2.txt" ]]; then
                    sed -i.bak "s/@$old_ip:/@$new_ip:/g" "$user_dir/hysteria2.txt"
                    rm -f "$user_dir/hysteria2.txt.bak"
                fi
                if [[ -f "$user_dir/hysteria2.yaml" ]]; then
                    sed -i.bak "s/server: $old_ip:/server: $new_ip:/g" "$user_dir/hysteria2.yaml"
                    rm -f "$user_dir/hysteria2.yaml.bak"
                fi

                # Update Trojan config
                if [[ -f "$user_dir/trojan.txt" ]]; then
                    sed -i.bak "s/@$old_ip:/@$new_ip:/g" "$user_dir/trojan.txt"
                    rm -f "$user_dir/trojan.txt.bak"
                fi

                # Update WireGuard direct config (wstunnel uses localhost, no change needed)
                if [[ -f "$user_dir/wireguard.conf" ]]; then
                    sed -i.bak "s/Endpoint = $old_ip:/Endpoint = $new_ip:/g" "$user_dir/wireguard.conf"
                    rm -f "$user_dir/wireguard.conf.bak"
                fi

                # Update WireGuard IPv6 config if exists
                if [[ -f "$user_dir/wireguard-ipv6.conf" ]] && [[ -n "$new_ipv6" ]]; then
                    # Update IPv6 endpoint (format: [ipv6]:port)
                    if [[ -n "$old_ipv6" ]]; then
                        sed -i.bak "s/Endpoint = \[$old_ipv6\]:/Endpoint = [$new_ipv6]:/g" "$user_dir/wireguard-ipv6.conf"
                    else
                        sed -i.bak "s/Endpoint = \[[^]]*\]:/Endpoint = [$new_ipv6]:/g" "$user_dir/wireguard-ipv6.conf"
                    fi
                    rm -f "$user_dir/wireguard-ipv6.conf.bak"
                fi

                # Update IPv6 link files if they exist
                for ipv6_file in "$user_dir"/*-ipv6.txt; do
                    if [[ -f "$ipv6_file" ]] && [[ -n "$new_ipv6" ]]; then
                        if [[ -n "$old_ipv6" ]]; then
                            sed -i.bak "s/@\[$old_ipv6\]:/@[$new_ipv6]:/g" "$ipv6_file"
                        fi
                        rm -f "$ipv6_file.bak"
                    fi
                done

                # Update dnstt instructions
                if [[ -f "$user_dir/dnstt-instructions.txt" ]]; then
                    sed -i.bak "s/$old_ip/$new_ip/g" "$user_dir/dnstt-instructions.txt"
                    rm -f "$user_dir/dnstt-instructions.txt.bak"
                fi

                # Update slipstream instructions
                if [[ -f "$user_dir/slipstream-instructions.txt" ]]; then
                    sed -i.bak "s/$old_ip/$new_ip/g" "$user_dir/slipstream-instructions.txt"
                    rm -f "$user_dir/slipstream-instructions.txt.bak"
                fi

                # Update AmneziaWG configs
                if [[ -f "$user_dir/amneziawg.conf" ]]; then
                    sed -i.bak "s/Endpoint = $old_ip:/Endpoint = $new_ip:/g" "$user_dir/amneziawg.conf"
                    rm -f "$user_dir/amneziawg.conf.bak"
                fi
                if [[ -f "$user_dir/amneziawg-ipv6.conf" ]] && [[ -n "$new_ipv6" ]]; then
                    if [[ -n "$old_ipv6" ]]; then
                        sed -i.bak "s/Endpoint = \[$old_ipv6\]:/Endpoint = [$new_ipv6]:/g" "$user_dir/amneziawg-ipv6.conf"
                    fi
                    rm -f "$user_dir/amneziawg-ipv6.conf.bak"
                fi

                # Update Telegram MTProxy links
                if [[ -f "$user_dir/telegram-proxy-link.txt" ]]; then
                    sed -i.bak "s/$old_ip/$new_ip/g" "$user_dir/telegram-proxy-link.txt"
                    rm -f "$user_dir/telegram-proxy-link.txt.bak"
                fi
                if [[ -f "$user_dir/telegram-proxy-instructions.txt" ]]; then
                    sed -i.bak "s/$old_ip/$new_ip/g" "$user_dir/telegram-proxy-instructions.txt"
                    rm -f "$user_dir/telegram-proxy-instructions.txt.bak"
                fi

                # Update XHTTP configs
                if [[ -f "$user_dir/xhttp-vless.txt" ]]; then
                    sed -i.bak "s/@$old_ip:/@$new_ip:/g" "$user_dir/xhttp-vless.txt"
                    rm -f "$user_dir/xhttp-vless.txt.bak"
                fi
                if [[ -f "$user_dir/xhttp.txt" ]]; then
                    sed -i.bak "s/$old_ip/$new_ip/g" "$user_dir/xhttp.txt"
                    rm -f "$user_dir/xhttp.txt.bak"
                fi

                # Update CDN VLESS config
                if [[ -f "$user_dir/cdn-vless.txt" ]]; then
                    sed -i.bak "s/$old_ip/$new_ip/g" "$user_dir/cdn-vless.txt"
                    rm -f "$user_dir/cdn-vless.txt.bak"
                fi

                # Update TrustTunnel config
                if [[ -f "$user_dir/trusttunnel.txt" ]]; then
                    sed -i.bak "s/$old_ip/$new_ip/g" "$user_dir/trusttunnel.txt"
                    rm -f "$user_dir/trusttunnel.txt.bak"
                fi

                # Update XDNS configs
                if [[ -f "$user_dir/xdns-direct-config.json" ]]; then
                    sed -i.bak "s/\"address\": \"$old_ip\"/\"address\": \"$new_ip\"/g" "$user_dir/xdns-direct-config.json"
                    rm -f "$user_dir/xdns-direct-config.json.bak"
                fi
                if [[ -f "$user_dir/xdns.txt" ]]; then
                    sed -i.bak "s/$old_ip/$new_ip/g" "$user_dir/xdns.txt"
                    rm -f "$user_dir/xdns.txt.bak"
                fi

                # Update README.html (catch-all for any remaining IPs)
                if [[ -f "$user_dir/README.html" ]]; then
                    sed -i.bak "s/$old_ip/$new_ip/g" "$user_dir/README.html"
                    rm -f "$user_dir/README.html.bak"
                fi

                # Update README
                if [[ -f "$user_dir/README.md" ]]; then
                    sed -i.bak "s/$old_ip/$new_ip/g" "$user_dir/README.md"
                    rm -f "$user_dir/README.md.bak"
                fi

                ((regenerated++)) || true
            fi
        done

        if [[ $regenerated -gt 0 ]]; then
            success "    Updated $regenerated user bundle(s)"
        else
            info "    No user bundles found"
        fi
    fi

    # 4. Regenerate QR codes (optional - requires qrencode)
    # Only regenerate if we updated the configs above
    if [[ -z "$old_ip" ]]; then
        : # Skip QR regeneration since configs weren't updated
    elif command -v qrencode &>/dev/null; then
        info "  Regenerating QR codes..."
        local qr_count=0
        for user_dir in "$users_dir"/*/; do
            if [[ -d "$user_dir" ]]; then
                local username=$(basename "$user_dir")
                [[ "$username" == *-configs ]] && continue

                for txt_file in "$user_dir"/*.txt; do
                    if [[ -f "$txt_file" ]] && [[ "$txt_file" != *instructions* ]]; then
                        local qr_file="${txt_file%.txt}-qr.png"
                        qrencode -o "$qr_file" -s 6 "$(cat "$txt_file")" 2>/dev/null && ((qr_count++)) || true
                    fi
                done

                # WireGuard QR codes
                if [[ -f "$user_dir/wireguard.conf" ]]; then
                    qrencode -o "$user_dir/wireguard-qr.png" -s 6 -r "$user_dir/wireguard.conf" 2>/dev/null && ((qr_count++)) || true
                fi
            fi
        done
        if [[ $qr_count -gt 0 ]]; then
            success "    Regenerated $qr_count QR code(s)"
        fi
    else
        warn "  Skipping QR regeneration (qrencode not installed)"
    fi

    echo ""
    success "Migration complete!"
    echo ""
    echo -e "${CYAN}Summary:${NC}"
    if [[ -n "$old_ip" ]]; then
        echo "  Old IP: $old_ip"
    else
        echo "  Old IP: (was auto-detect)"
    fi
    echo "  New IP: $new_ip"
    echo ""
    echo -e "${CYAN}Next steps:${NC}"
    echo "  1. Restart services: moav restart"
    echo "  2. Re-package user bundles: moav user package <username>"
    echo "  3. Distribute new configs to users"
    echo ""
    echo -e "${YELLOW}Note:${NC} Users will need updated configs to connect via the new IP."
    echo "      Or they can manually update the IP in their client app."
}
