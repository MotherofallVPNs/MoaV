#!/bin/bash
# lib/users.sh — user lifecycle from the CLI: the interactive user menu, listing,
# add / revoke / package, the `moav user` and `moav users` commands, and
# `moav regenerate-users` (rebuild every bundle from current state and reconcile
# the server configs, via lib/provision.sh inside the container).
#
# The provisioning itself lives in scripts/ (user-add.sh on the host,
# generate-user.sh in the container); this is the CLI surface over it.
#
# Sourced by moav.sh after lib/common.sh.
#
# Definitions only — nothing here runs at source time.

user_management() {
    while true; do
        print_section "User Management"

        echo "User management options:"
        echo ""
        echo -e "  ${WHITE}1)${NC} List all users"
        echo -e "  ${WHITE}2)${NC} Add new user"
        echo -e "  ${WHITE}3)${NC} Revoke user"
        echo -e "  ${WHITE}4)${NC} Package user (create zip)"
        echo -e "  ${WHITE}0)${NC} Back to main menu"
        echo ""

        prompt "Choice: "
        read -r choice < /dev/tty 2>/dev/null || choice=""

        case $choice in
            1)
                list_users
                ;;
            2)
                add_user
                press_enter
                ;;
            3)
                revoke_user
                press_enter
                ;;
            4)
                package_user
                press_enter
                ;;
            0|q|Q)
                return 0
                ;;
            *)
                ;;
        esac
    done
}

migration_menu() {
    print_section "Export/Import (Migration)"

    echo "Migration options:"
    echo ""
    echo -e "  ${WHITE}1)${NC} Export configuration backup"
    echo -e "  ${WHITE}2)${NC} Import configuration backup"
    echo -e "  ${WHITE}3)${NC} Migrate to new IP address"
    echo -e "  ${WHITE}4)${NC} Regenerate all user bundles"
    echo -e "  ${WHITE}0)${NC} Back to main menu"
    echo ""

    prompt "Choice: "
    read -r choice < /dev/tty 2>/dev/null || choice=""

    case $choice in
        1)
            echo ""
            local default_file="moav-backup-$(date +%Y%m%d_%H%M%S).tar.gz"
            prompt "Output file [$default_file]: "
            read -r output_file < /dev/tty 2>/dev/null || output_file=""
            [[ -z "$output_file" ]] && output_file="$default_file"
            cmd_export "$output_file"
            ;;
        2)
            echo ""
            prompt "Backup file to import: "
            read -r input_file < /dev/tty 2>/dev/null || input_file=""
            if [[ -n "$input_file" ]]; then
                cmd_import "$input_file"
            else
                warn "No file specified"
            fi
            ;;
        3)
            echo ""
            local current_ip=$(get_env_val "SERVER_IP" ".env")
            local current_ipv6=$(get_env_val "SERVER_IPV6" ".env")
            local detected_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
            local detected_ipv6=$(curl -6 -s --max-time 3 https://api6.ipify.org 2>/dev/null || echo "")
            [[ -n "$current_ip" ]] && echo "Current IP in .env: $current_ip"
            [[ -n "$current_ipv6" ]] && echo "Current IPv6 in .env: $current_ipv6"
            [[ -n "$detected_ip" ]] && echo "Detected server IP: $detected_ip"
            [[ -n "$detected_ipv6" ]] && echo "Detected server IPv6: $detected_ipv6"
            echo ""
            prompt "New IP address: "
            read -r new_ip < /dev/tty 2>/dev/null || new_ip=""
            if [[ -n "$new_ip" ]]; then
                cmd_migrate_ip "$new_ip"
            else
                warn "No IP specified"
            fi
            ;;
        4)
            cmd_regenerate_users
            ;;
        0|*)
            return 0
            ;;
    esac
}

list_users() {
    print_section "User List"

    if [[ -x "./scripts/user-list.sh" ]]; then
        ./scripts/user-list.sh
    else
        # Fallback: list from outputs/bundles
        if [[ -d "outputs/bundles" ]]; then
            echo "Users with bundles:"
            ls -1 outputs/bundles/ 2>/dev/null || echo "  No users found"
        else
            warn "No users found. Run bootstrap first."
        fi
    fi
}

add_user() {
    print_section "Add New User"

    prompt "Enter username for new user: "
    read -r username < /dev/tty 2>/dev/null || username=""

    if [[ -z "$username" ]]; then
        warn "Username cannot be empty"
        return 1
    fi

    # Validate username (alphanumeric and underscore only)
    if [[ ! "$username" =~ ^[a-zA-Z0-9_]+$ ]]; then
        error "Username can only contain letters, numbers, and underscores"
        return 1
    fi

    echo ""
    echo "This will add '$username' to all enabled services:"
    echo "  • Proxies — Reality, Trojan, Hysteria2, Shadowsocks-2022, XHTTP, CDN VLESS+WS"
    echo "  • VPN — WireGuard (direct + wstunnel), AmneziaWG, TrustTunnel"
    echo "  • DNS tunnels — dnstt, Slipstream, MasterDNS, XDNS"
    echo "  • Telegram MTProxy"
    echo "  • GooseRelay (if ENABLE_GOOSERELAY=true)"
    echo ""
    echo "  Bundle: outputs/bundles/$username/  (~40 files: configs, QR codes,"
    echo "  V2Ray subscription, README.html)"
    echo ""

    if [[ -x "./scripts/user-add.sh" ]]; then
        run_command "./scripts/user-add.sh $username" "Adding user $username"

        if [[ $? -eq 0 ]]; then
            echo ""
            success "User '$username' created!"
            echo ""
            info "Bundle location: outputs/bundles/$username/"
            echo "  Share this bundle securely with the user."
        fi
    else
        error "User add script not found: ./scripts/user-add.sh"
        return 1
    fi
}

revoke_user() {
    print_section "Revoke User"

    echo "Current users:"
    list_users
    echo ""

    prompt "Enter username to revoke: "
    read -r username < /dev/tty 2>/dev/null || username=""

    if [[ -z "$username" ]]; then
        warn "Username cannot be empty"
        return 1
    fi

    echo ""
    warn "This will revoke '$username' from ALL services!"
    echo ""

    if [[ -x "./scripts/user-revoke.sh" ]]; then
        if confirm "Are you sure you want to revoke '$username'?"; then
            run_command "./scripts/user-revoke.sh $username" "Revoking user $username"

            if [[ $? -eq 0 ]]; then
                echo ""
                success "User '$username' revoked!"
            fi
        fi
    else
        error "User revoke script not found: ./scripts/user-revoke.sh"
        return 1
    fi
}

package_user() {
    print_section "Package User"

    echo "Current users:"
    list_users
    echo ""

    prompt "Enter username to package: "
    read -r username < /dev/tty 2>/dev/null || username=""

    if [[ -z "$username" ]]; then
        warn "Username cannot be empty"
        return 1
    fi

    local bundle_dir="outputs/bundles/$username"
    if [[ ! -d "$bundle_dir" ]]; then
        error "User bundle not found: $bundle_dir"
        return 1
    fi

    local zip_file="outputs/bundles/${username}-configs.zip"

    # Check for zip command
    if ! command -v zip &>/dev/null; then
        error "zip command not found. Install with: apt install zip"
        return 1
    fi

    info "Creating package for $username..."

    # Create zip from bundle directory
    (cd outputs/bundles && zip -r "${username}-configs.zip" "$username" -x "*.DS_Store")

    if [[ -f "$zip_file" ]]; then
        local size=$(du -h "$zip_file" | cut -f1)
        success "Package created: $zip_file ($size)"
    else
        error "Failed to create package"
        return 1
    fi
}

cmd_users() {
    list_users
}

cmd_user() {
    local action="${1:-}"
    shift 1 2>/dev/null || shift $# # Shift past action to get remaining args
    local username="${1:-}"

    case "$action" in
        list|ls)
            list_users
            ;;
        add)
            # Check for batch mode or multiple usernames
            if [[ "${1:-}" == "--batch" ]] || [[ "${1:-}" == "-b" ]]; then
                # Batch mode - pass all args to script
                if [[ -x "./scripts/user-add.sh" ]]; then
                    ./scripts/user-add.sh "$@"
                else
                    error "User add script not found"
                    exit 1
                fi
            elif [[ -z "${1:-}" ]]; then
                error "Usage: moav user add USERNAME [USERNAME2...] [--package]"
                error "       moav user add --batch N [--prefix NAME] [--package]"
                exit 1
            else
                # Single or multiple usernames - validate each, then pass all to script
                local usernames=()
                local flags=()
                for arg in "$@"; do
                    if [[ "$arg" == --* ]] || [[ "$arg" == -* ]]; then
                        flags+=("$arg")
                    else
                        if [[ ! "$arg" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                            error "Invalid username '$arg'. Use only letters, numbers, underscores, and hyphens"
                            exit 1
                        fi
                        usernames+=("$arg")
                    fi
                done
                if [[ ${#usernames[@]} -eq 0 ]]; then
                    error "No usernames provided"
                    exit 1
                fi
                if [[ -x "./scripts/user-add.sh" ]]; then
                    ./scripts/user-add.sh "${usernames[@]}" "${flags[@]}"
                else
                    error "User add script not found"
                    exit 1
                fi
            fi
            ;;
        revoke|rm|remove|delete)
            if [[ -z "${1:-}" ]]; then
                error "Usage: moav user revoke USERNAME [USERNAME2...]"
                exit 1
            fi
            if [[ ! -x "./scripts/user-revoke.sh" ]]; then
                error "User revoke script not found"
                exit 1
            fi
            for u in "$@"; do
                ./scripts/user-revoke.sh "$u" || true
            done
            ;;
        package|pkg)
            if [[ -z "$username" ]]; then
                error "Usage: moav user package USERNAME"
                exit 1
            fi
            if [[ -x "./scripts/user-package.sh" ]]; then
                ./scripts/user-package.sh "$username"
            else
                error "User package script not found"
                exit 1
            fi
            ;;
        base64|b64)
            cmd_user_base64 "$username"
            ;;
        *)
            error "Usage: moav user [list|add|revoke|package|base64] [USERNAME]"
            exit 1
            ;;
    esac
}

cmd_regenerate_users() {
    print_section "Regenerate User Bundles"

    info "This will regenerate all user config bundles using current .env settings."
    echo "  - Credentials (UUIDs, passwords, keys) remain unchanged"
    echo "  - IP and domain will be updated from .env"
    echo ""

    # Check if bootstrap has been run
    if ! check_bootstrap; then
        error "Bootstrap has not been run. Run 'moav bootstrap' first."
        exit 1
    fi

    # Load current settings
    local server_ip=$(get_env_val "SERVER_IP" ".env")
    local server_ipv6=$(get_env_val "SERVER_IPV6" ".env")
    local domain=$(get_env_val "DOMAIN" ".env")

    # Auto-detect IP if not set
    if [[ -z "$server_ip" ]]; then
        server_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
        if [[ -n "$server_ip" ]]; then
            info "SERVER_IP not set, using detected IP: $server_ip"
        else
            error "Could not determine server IP. Set SERVER_IP in .env"
            exit 1
        fi
    fi

    # Auto-detect IPv6 if not set or disabled
    if [[ -z "$server_ipv6" ]] && [[ "$server_ipv6" != "disabled" ]]; then
        server_ipv6=$(curl -6 -s --max-time 3 https://api6.ipify.org 2>/dev/null || echo "")
    fi
    [[ "$server_ipv6" == "disabled" ]] && server_ipv6=""

    echo -e "  Server IP:   ${CYAN}$server_ip${NC}"
    if [[ -n "$server_ipv6" ]]; then
        echo -e "  Server IPv6: ${CYAN}$server_ipv6${NC}"
    fi
    echo -e "  Domain:      ${CYAN}${domain:-not set}${NC}"

    # Show CDN domain if configured
    local cdn_subdomain_preview=$(get_env_val "CDN_SUBDOMAIN" ".env")
    if [[ -n "$cdn_subdomain_preview" && -n "$domain" ]]; then
        echo -e "  CDN Domain:  ${CYAN}${cdn_subdomain_preview}.${domain}${NC}"
    fi
    echo ""

    if ! confirm "Regenerate all user bundles?" "y"; then
        info "Cancelled."
        exit 0
    fi

    echo ""

    # Find existing users from bundles directory
    info "Finding existing users..."

    local user_count=0
    local users_found=""

    # List users from the outputs/bundles directory (the authoritative source)
    if [[ -d "outputs/bundles" ]]; then
        for user_dir in outputs/bundles/*/; do
            if [[ -d "$user_dir" ]]; then
                local username=$(basename "$user_dir")
                # Skip zip file extractions and temp directories
                [[ "$username" == *-configs ]] && continue
                [[ "$username" == *-moav-configs ]] && continue
                [[ "$username" == "." ]] && continue
                users_found="$users_found $username"
            fi
        done
        users_found=$(echo "$users_found" | xargs)  # Trim whitespace
    fi

    if [[ -z "$users_found" ]]; then
        warn "No users found in outputs/bundles/."
        echo "  Users are created during bootstrap or with 'moav user add'"
        exit 0
    fi

    echo "  Found users: $users_found"
    echo ""

    info "Regenerating bundles..."

    # Construct CDN_DOMAIN from CDN_SUBDOMAIN + DOMAIN if not explicitly set
    local cdn_domain=$(get_env_val "CDN_DOMAIN" ".env")
    local cdn_subdomain=$(get_env_val "CDN_SUBDOMAIN" ".env")
    if [[ -z "$cdn_domain" && -n "$cdn_subdomain" && -n "$domain" ]]; then
        cdn_domain="${cdn_subdomain}.${domain}"
    fi
    local cdn_ws_path=$(get_env_val "CDN_WS_PATH" ".env")
    # Fall back to bootstrap-generated path from state
    if [[ -z "$cdn_ws_path" ]]; then
        cdn_ws_path=$(docker run --rm -v moav_moav_state:/state alpine cat /state/keys/cdn.env 2>/dev/null | grep '^CDN_WS_PATH=' | cut -d= -f2 || true)
    fi
    cdn_ws_path="${cdn_ws_path:-/ws}"
    local cdn_transport=$(get_env_val "CDN_TRANSPORT" ".env")
    cdn_transport="${cdn_transport:-httpupgrade}"
    local cdn_sni=$(get_env_val "CDN_SNI" ".env")
    cdn_sni="${cdn_sni:-${domain}}"
    local cdn_address=$(get_env_val "CDN_ADDRESS" ".env")
    cdn_address="${cdn_address:-${cdn_domain}}"

    # Load ENABLE_* settings from .env
    local enable_reality=$(get_env_val "ENABLE_REALITY" .env "true")
    local enable_trojan=$(get_env_val "ENABLE_TROJAN" .env "true")
    local enable_anytls=$(get_env_val "ENABLE_ANYTLS" .env "false")
    local port_anytls=$(get_env_val "PORT_ANYTLS" .env "8445")
    local enable_hysteria2=$(get_env_val "ENABLE_HYSTERIA2" .env "true")
    local enable_wireguard=$(get_env_val "ENABLE_WIREGUARD" .env "true")
    local enable_amneziawg=$(get_env_val "ENABLE_AMNEZIAWG" .env "true")
    local enable_dnstt=$(get_env_val "ENABLE_DNSTT" .env "true")
    local enable_slipstream=$(get_env_val "ENABLE_SLIPSTREAM" .env "true")
    local slipstream_subdomain=$(get_env_val "SLIPSTREAM_SUBDOMAIN" .env "s")
    local enable_masterdns=$(get_env_val "ENABLE_MASTERDNS" .env "true")
    local masterdns_subdomain=$(get_env_val "MASTERDNS_SUBDOMAIN" .env "m")
    local masterdns_public_subdomain=$(get_env_val "MASTERDNS_PUBLIC_SUBDOMAIN" .env "")
    local enable_gooserelay=$(get_env_val "ENABLE_GOOSERELAY" .env "false")
    local port_goose=$(get_env_val "PORT_GOOSE" .env "8444")
    local enable_trusttunnel=$(get_env_val "ENABLE_TRUSTTUNNEL" .env "true")
    local enable_xhttp=$(get_env_val "ENABLE_XHTTP" .env "true")
    local port_xhttp=$(get_env_val "PORT_XHTTP" .env "2096")
    local xhttp_reality_target=$(get_env_val "XHTTP_REALITY_TARGET" .env "dl.google.com:443")
    local enable_telemt=$(get_env_val "ENABLE_TELEMT" .env "true")
    local telemt_tls_domain=$(get_env_val "TELEMT_TLS_DOMAIN" .env "dl.google.com")
    local telemt_max_tcp_conns=$(get_env_val "TELEMT_MAX_TCP_CONNS" .env "100")
    local telemt_max_unique_ips=$(get_env_val "TELEMT_MAX_UNIQUE_IPS" .env "10")
    local port_telemt=$(get_env_val "PORT_TELEMT" .env "993")
    local enable_ss=$(get_env_val "ENABLE_SS" .env "false")
    local port_ss=$(get_env_val "PORT_SS" .env "8388")
    local ss_method=$(get_env_val "SS_METHOD" .env "2022-blake3-aes-128-gcm")
    # DNS-tunnel subdomain/port fields — without these, regenerated bundles fall
    # back to defaults (t/x/53) and drift from the active .env (issue #98)
    local dnstt_subdomain=$(get_env_val "DNSTT_SUBDOMAIN" .env "t")
    local enable_xdns=$(get_env_val "ENABLE_XDNS" .env "false")
    local xdns_subdomain=$(get_env_val "XDNS_SUBDOMAIN" .env "x")
    local xdns_mtu=$(get_env_val "XDNS_MTU" .env "35")
    local xdns_resolvers=$(get_env_val "XDNS_RESOLVERS" .env "1.1.1.1,8.8.8.8")
    local port_dns=$(get_env_val "PORT_DNS" .env "53")
    local port_xdns=$(get_env_val "PORT_XDNS" .env "53")

    # ONE container run for the whole job, via the shared provisioning path
    # (lib/provision.sh `provision_all_users force`) — the SAME implementation
    # bootstrap.sh uses, so the two can no longer drift. This replaces a
    # per-user `docker compose run` (which re-passed ~50 -e vars for every
    # user) plus a second, separate run for the reconcile whose shell lacked
    # `set -e` while bootstrap's had it — exactly the divergence that made
    # "regenerate-users works but bootstrap aborts" possible.
    echo "  Regenerating bundles + reconciling server configs..."
    if docker compose run --rm -T \
            -e "SERVER_IP=$server_ip" \
            -e "SERVER_IPV6=$server_ipv6" \
            -e "DOMAIN=$domain" \
            -e "CDN_SUBDOMAIN=$cdn_subdomain" \
            -e "CDN_DOMAIN=$cdn_domain" \
            -e "CDN_WS_PATH=$cdn_ws_path" \
            -e "CDN_TRANSPORT=$cdn_transport" \
            -e "CDN_SNI=$cdn_sni" \
            -e "CDN_ADDRESS=$cdn_address" \
            -e "ENABLE_REALITY=${enable_reality:-true}" \
            -e "ENABLE_TROJAN=${enable_trojan:-true}" \
            -e "ENABLE_ANYTLS=${enable_anytls:-false}" \
            -e "PORT_ANYTLS=${port_anytls:-8445}" \
            -e "ENABLE_HYSTERIA2=${enable_hysteria2:-true}" \
            -e "ENABLE_WIREGUARD=${enable_wireguard:-true}" \
            -e "ENABLE_AMNEZIAWG=${enable_amneziawg:-true}" \
            -e "ENABLE_DNSTT=${enable_dnstt:-false}" \
            -e "ENABLE_SLIPSTREAM=${enable_slipstream:-false}" \
            -e "SLIPSTREAM_SUBDOMAIN=${slipstream_subdomain:-s}" \
            -e "ENABLE_MASTERDNS=${enable_masterdns:-true}" \
            -e "MASTERDNS_SUBDOMAIN=${masterdns_subdomain:-m}" \
            -e "MASTERDNS_PUBLIC_SUBDOMAIN=${masterdns_public_subdomain:-}" \
            -e "ENABLE_GOOSERELAY=${enable_gooserelay:-false}" \
            -e "PORT_GOOSE=${port_goose:-8444}" \
            -e "ENABLE_TRUSTTUNNEL=${enable_trusttunnel:-true}" \
            -e "ENABLE_XHTTP=${enable_xhttp:-true}" \
            -e "PORT_XHTTP=${port_xhttp:-2096}" \
            -e "XHTTP_REALITY_TARGET=${xhttp_reality_target:-dl.google.com:443}" \
            -e "ENABLE_TELEMT=${enable_telemt:-true}" \
            -e "TELEMT_TLS_DOMAIN=${telemt_tls_domain:-dl.google.com}" \
            -e "TELEMT_MAX_TCP_CONNS=${telemt_max_tcp_conns:-100}" \
            -e "TELEMT_MAX_UNIQUE_IPS=${telemt_max_unique_ips:-10}" \
            -e "PORT_TELEMT=${port_telemt:-993}" \
            -e "ENABLE_SS=${enable_ss:-false}" \
            -e "PORT_SS=${port_ss:-8388}" \
            -e "SS_METHOD=${ss_method:-2022-blake3-aes-128-gcm}" \
            -e "DNSTT_SUBDOMAIN=${dnstt_subdomain:-t}" \
            -e "ENABLE_XDNS=${enable_xdns:-false}" \
            -e "XDNS_SUBDOMAIN=${xdns_subdomain:-x}" \
            -e "XDNS_MTU=${xdns_mtu:-35}" \
            -e "XDNS_RESOLVERS=${xdns_resolvers:-1.1.1.1,8.8.8.8}" \
            -e "PORT_DNS=${port_dns:-53}" \
            -e "PORT_XDNS=${port_xdns:-53}" \
        --entrypoint /bin/bash \
        bootstrap -c 'source /app/lib/common.sh; source /app/lib/sing-box.sh; source /app/lib/xray.sh; source /app/lib/sync.sh; source /app/lib/provision.sh; provision_all_users force'; then
        user_count=$(echo "$users_found" | wc -w | tr -d ' ')
        echo -e "  ${GREEN}✓${NC} provisioning run finished"
    else
        echo -e "  ${RED}✗${NC} provisioning run failed"
        warn "    See the output above for the failing user(s)"
    fi

    echo ""

    # The reconcile happened inside the run above (provision_all_users does
    # bundles THEN sync_server_users, always reaching the reconcile even if a
    # bundle failed). Reload the proxies so the re-inserted users take effect.
    docker compose restart sing-box xray >/dev/null 2>&1 || true
    echo ""

    if [[ $user_count -gt 0 ]]; then
        success "Regenerated $user_count user bundle(s)"
        echo ""
        echo -e "${CYAN}Bundles location:${NC} outputs/bundles/"
        echo ""
        echo -e "${CYAN}Next steps:${NC}"
        echo "  1. Distribute new configs to users"
        echo "  2. Or create zip packages: moav user package <username>"
        echo ""
        echo -e "${YELLOW}Note:${NC} Users can also manually update the IP in their client app"
        echo "      since credentials haven't changed."
    else
        warn "No bundles were regenerated."
    fi
}
