#!/bin/bash
# lib/menu.sh - the interactive TUI (`moav` with no arguments) and the smaller
# commands it fronts: usage text, `moav check`, `moav conduit`, `moav admin`,
# `moav user base64`, `moav test`, `moav client`.
#
# Extracted last, as the plan intended: the menu reaches into nearly every other
# module (service, users, donate, doctor, build, bootstrap), so it is the piece
# most likely to surface a mistake made anywhere else.
#
# Also carries three generic helpers that sit inside this range -- sanitize_domain,
# is_valid_domain and update_env_var. They are not menu-specific and would sit
# more naturally in lib/common.sh; they travel here to keep this a single
# contiguous slice, and can be relocated on their own later.
#
# Sourced by moav.sh after every module it calls into.
#
# Definitions only - nothing here runs at source time.

# =============================================================================
# Main Menu
# =============================================================================

main_menu() {
    while true; do
        print_header

        # Show quick status
        local running=$(get_running_services)
        if [[ -n "$running" ]]; then
            echo -e "  ${GREEN}●${NC} Services running: $(echo $running | wc -w)"
            # Show admin URL if admin is running
            if echo "$running" | grep -q "admin"; then
                echo -e "  ${CYAN}↳${NC} Admin: ${CYAN}$(get_admin_url)${NC}"
            fi
            # Show Grafana URL if grafana is running
            if echo "$running" | grep -q "grafana"; then
                echo -e "  ${CYAN}↳${NC} Grafana: ${CYAN}$(get_grafana_url)${NC}"
            fi
        else
            echo -e "  ${DIM}○ No services running${NC}"
        fi
        echo ""

        echo "  What would you like to do?"
        echo ""
        echo -e "  ${DIM}Services${NC}"
        echo -e "  ${WHITE}1)${NC} Start services"
        echo -e "  ${WHITE}2)${NC} Stop services"
        echo -e "  ${WHITE}3)${NC} Restart services"
        echo -e "  ${WHITE}4)${NC} View status"
        echo -e "  ${WHITE}5)${NC} View logs"
        echo ""
        echo -e "  ${DIM}Users & donations${NC}"
        echo -e "  ${WHITE}6)${NC} User management"
        echo -e "  ${WHITE}7)${NC} Donate configs (MahsaNet, Psiphon, Snowflake)"
        echo ""
        echo -e "  ${DIM}System${NC}"
        echo -e "  ${WHITE}8)${NC}  Doctor — diagnose problems"
        echo -e "  ${WHITE}9)${NC}  Admin password reset"
        echo -e "  ${WHITE}10)${NC} Update MoaV"
        echo -e "  ${WHITE}11)${NC} Build/rebuild services"
        echo -e "  ${WHITE}12)${NC} Export/Import (migration)"
        echo ""
        echo -e "  ${WHITE}0)${NC}  Exit"
        echo ""

        prompt "Choice: "
        read -r choice < /dev/tty 2>/dev/null || choice=""

        case $choice in
            1) r=0; start_services || r=$?; [[ $r -eq 2 ]] || press_enter ;;
            2) r=0; stop_services || r=$?; [[ $r -eq 2 ]] || press_enter ;;
            3) r=0; restart_services || r=$?; [[ $r -eq 2 ]] || press_enter ;;
            4) show_status; press_enter ;;
            5) view_logs ;;  # view_logs has its own loop, no press_enter needed
            6) user_management ;;  # user_management has its own loop
            7) cmd_donate; press_enter ;;
            8) cmd_doctor; press_enter ;;
            9) cmd_admin password; press_enter ;;
            10) cmd_update; press_enter ;;
            11) build_services; press_enter ;;
            12) migration_menu; press_enter ;;
            0|q|Q)
                echo ""
                info "🕊️ Goodbye! ✌️"
                exit 0
                ;;
            *)
                warn "Invalid choice"
                sleep 1
                ;;
        esac
    done
}

# =============================================================================
# Command Line Interface
# =============================================================================

show_usage() {
    echo "MoaV v${VERSION} - Multi-protocol Circumvention Stack"
    echo ""
    echo "Usage: moav [command] [options]"
    echo ""
    echo "Setup & Maintenance:"
    echo "  install               Install 'moav' command globally"
    echo "  uninstall [--wipe] [--yes] [--remove-images]  Remove containers + command"
    echo "                        (--wipe removes all data; --yes skips prompts; --remove-images also deletes images)"
    echo "  update [-b BRANCH]    Update MoaV (git pull + rebuild)"
    echo "  bootstrap [--yes]     First-time setup (keys, configs, service selection);"
    echo "                        --yes re-runs non-interactively (idempotent)"
    echo "  domainless            Enable domainless mode"
    echo "  check                 Run prerequisites check"
    echo "  doctor [CHECK]        Run diagnostics (e.g. 'doctor dns', 'doctor ports')"
    echo ""
    echo "Services:"
    echo "  start [PROFILE...]    Start services (default: saved profiles from .env)"
    echo "  stop [SERVICE...] [-r] Stop services (-r removes containers)"
    echo "  restart [SERVICE...]  Restart services"
    echo "  status                Show service status"
    echo "  logs [SERVICE...] [-n] View logs (follow mode, -n for snapshot)"
    echo "  profiles              Change default services for 'moav start'"
    echo "  build [SVC|PROFILE] [--no-cache]  Build services or profile"
    echo "  build --local [SVC|all]            Build locally (for blocked registries)"
    echo ""
    echo "Users:"
    echo "  users / user list     List all users"
    echo "  user add NAME [...] [-p]           Add user(s) (--package creates zip)"
    echo "  user add --batch N [--prefix P]    Batch create (user01, user02...)"
    echo "  user revoke NAME      Revoke a user"
    echo "  user package NAME     Create zip bundle for existing user"
    echo "  user base64 NAME      Base64 text-only bundle (for e2e / quick import)"
    echo "  admin password        Reset admin dashboard password"
    echo ""
    echo "Donate & Test:"
    echo "  donate                Donate VPN configs to MahsaNet/Psiphon/Snowflake"
    echo "  conduit [link|status] Psiphon Conduit claim link, QR & sharing guide"
    echo "  test USERNAME [-v]    Test connectivity for a user"
    echo "  client connect USER   Client mode (connect as user, exposes local proxy)"
    echo ""
    echo "Backup & Migration:"
    echo "  export [FILE]         Export config backup (keys, users, .env)"
    echo "  import FILE           Import config backup"
    echo "  migrate-ip NEW_IP     Update SERVER_IP and regenerate all configs"
    echo "  regenerate-users      Regenerate all user bundles with current .env"
    echo "  conduit-offsets CMD   Manage Conduit lifetime-offset auto-updater (install/uninstall/status)"
    echo "  cert [CMD]            TLS certificate status/renew + auto-renewal timer (install/uninstall)"
    echo "  setup-dns             Free port 53 for DNS tunnels (disables systemd-resolved)"
    echo "  switch-dns [NAME|off] Enable/disable DNS tunnel daemons (dnstt/slipstream/masterdns/xdns)"
    echo ""
    echo "Profiles: proxy, wireguard, amneziawg, dnstunnel, trusttunnel, xhttp, telegram,"
    echo "          admin, conduit, snowflake, monitoring, client, all"
    echo "Aliases:  wg→wireguard, awg→amneziawg, tg→telegram, conduit→psiphon-conduit"
    echo ""
    echo "Examples:"
    echo "  moav                                 # Interactive menu"
    echo "  moav start                           # Start default services"
    echo "  moav start proxy admin               # Start specific profiles"
    echo "  moav user add alice bob --package     # Add users with zip bundles"
    echo "  moav user add --batch 10 --prefix vip # Batch create vip01..vip10"
    echo "  moav donate                          # Donate configs to MahsaNet"
    echo "  moav doctor dns                      # Check DNS configuration"
    echo "  moav export                          # Backup to moav-backup-TIMESTAMP.tar.gz"
    echo "  moav migrate-ip 1.2.3.4              # Update to new server IP"
    echo ""
    echo "Community & support:"
    echo "  Telegram:  https://t.me/motherofallvpns"
    echo "  Twitter/X: https://x.com/motherofallvpns"
    echo "  Docs:      https://moav.sh/docs"
}

cmd_check() {
    print_header
    check_prerequisites
}


_conduit_sharing_explainer() {
    echo ""
    echo -e "  ${WHITE}How your Conduit helps people in Iran${NC}"
    echo ""
    echo "  1. Public pool (automatic — nothing to share)"
    echo "     While Conduit runs, it donates bandwidth to the Psiphon network."
    echo "     Psiphon app users worldwide — including in Iran — are brokered"
    echo "     through your server automatically. No link, no setup for them."
    echo ""
    echo "  2. Personal Pairing (share a private path with specific people)"
    echo "     Psiphon's Conduit lets you give friends/family a private, direct"
    echo "     path through your station. To do this:"
    echo "       a. Install the Ryve app (Psiphon's Conduit manager) on your phone."
    echo "       b. Import this station using the claim link below."
    echo "       c. In Ryve, enable Personal Pairing and generate a pairing link."
    echo "       d. Send that pairing link to people in Iran; they paste it into"
    echo "          the Psiphon app's \"pairing URL\" field to route through you."
    echo ""
    echo -e "  ${YELLOW}⚠ Security:${NC} the claim link / QR below embeds this Conduit's"
    echo -e "  ${YELLOW}  private key${NC} — it imports the station into YOUR OWN phone."
    echo "  Treat it like a password. Do NOT post it publicly: anyone with it"
    echo "  can take over your station. The public-safe link you share with"
    echo "  users is the Personal Pairing link generated inside Ryve (step c),"
    echo "  not this one. (Pairing-URL export lives in the Conduit/Ryve app; see"
    echo "  github.com/Psiphon-Inc/conduit/issues/205 for its status.)"
    echo ""
}

cmd_conduit() {
    local action="${1:-}"

    case "$action" in
        ""|link|--link|info|--info|show)
            print_section "Psiphon Conduit"
            _conduit_sharing_explainer
            cmd_donate_conduit_info
            ;;
        status|--status)
            local env_file="$SCRIPT_DIR/.env"
            print_section "Psiphon Conduit Status"
            echo ""
            local conduit_enabled
            conduit_enabled=$(get_env_val "ENABLE_CONDUIT" "$env_file" "true")
            if [[ "$conduit_enabled" != "true" ]]; then
                echo -e "  ${DIM}○ Disabled — enable in .env: ENABLE_CONDUIT=true${NC}"
                return 0
            fi
            local conduit_running=""
            docker compose ps psiphon-conduit --status running 2>/dev/null | tail -n +2 | grep -q . && conduit_running="yes"
            if [[ -n "$conduit_running" ]]; then
                local conduit_bw conduit_clients
                conduit_bw=$(get_env_val "CONDUIT_BANDWIDTH" "$env_file" "100")
                conduit_clients=$(get_env_val "CONDUIT_MAX_COMMON_CLIENTS" "$env_file" "200")
                echo -e "  ${GREEN}✓${NC} Running — ${conduit_bw} Mbps, ${conduit_clients} max clients"
                local cm
                cm=$(_query_conduit_metrics 2>/dev/null)
                if [[ -n "$cm" ]]; then
                    local c_conn c_up c_down
                    c_conn=$(echo "$cm" | awk '{print $1}')
                    c_up=$(echo "$cm" | awk '{print $2}')
                    c_down=$(echo "$cm" | awk '{print $3}')
                    echo -e "  Connected: ${CYAN}${c_conn}${NC} clients | Bandwidth: $(_format_bytes_sh "$c_up") ↑ / $(_format_bytes_sh "$c_down") ↓"
                fi
                echo -e "  ${DIM}Claim link: moav conduit link${NC}"
            else
                echo -e "  ${YELLOW}○${NC} Enabled but not running — start with: moav start conduit"
            fi
            ;;
        help|--help|-h)
            echo "Usage: moav conduit [command]"
            echo ""
            echo "Psiphon Conduit donates bandwidth to help people bypass censorship."
            echo ""
            echo "Commands:"
            echo "  link       Show the Ryve claim link + QR and how to share (default)"
            echo "  status     Show whether Conduit is running and live stats"
            echo "  help       Show this help"
            echo ""
            echo "Notes:"
            echo "  • Running Conduit already serves Psiphon users in Iran via the"
            echo "    public pool — no link needs to be shared for that."
            echo "  • The claim link embeds the private key (for your own phone's"
            echo "    Ryve app). Share with users only via Personal Pairing in Ryve."
            echo "  • Bandwidth/clients: moav donate setup. Status of all donation"
            echo "    services: moav donate status."
            ;;
        *)
            error "Unknown conduit command: $action"
            echo "Run 'moav conduit help' for usage."
            exit 1
            ;;
    esac
}

cmd_admin() {
    local action="${1:-}"

    case "$action" in
        password|reset-password|passwd)
            if [[ ! -f ".env" ]]; then
                error ".env file not found. Run 'moav setup' first."
                return 1
            fi

            echo ""
            echo -e "${WHITE}Reset admin dashboard password${NC}"
            echo "  Press Enter to generate a random password, or type your own"
            printf "  New password: "
            read -r new_password
            if [[ -z "$new_password" ]]; then
                new_password=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
            fi

            if grep -q "^ADMIN_PASSWORD=" .env 2>/dev/null; then
                sed -i "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=\"$new_password\"|" .env
            else
                echo "ADMIN_PASSWORD=\"$new_password\"" >> .env
            fi

            echo ""
            echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
            echo -e "  ${WHITE}New Admin Password:${NC} ${CYAN}$new_password${NC}"
            echo ""
            echo -e "  ${YELLOW}⚠ IMPORTANT: Save this password! It's also stored in .env${NC}"
            echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
            echo ""

            # Recreate admin container if running (restart won't pick up .env changes)
            if docker ps --filter "name=moav-admin" --filter "status=running" -q 2>/dev/null | grep -q .; then
                info "Recreating admin container to apply new password..."
                docker compose --profile admin up -d admin
                success "Admin container recreated with new password"
            else
                info "Admin container is not running. New password will take effect on next start."
            fi

            # Update Grafana password if running (Grafana stores password in its DB, env var is only used on first boot)
            if docker ps --filter "name=moav-grafana" --filter "status=running" -q 2>/dev/null | grep -q .; then
                info "Updating Grafana admin password..."
                if docker compose --profile monitoring exec -T grafana grafana cli admin reset-admin-password "$new_password" &>/dev/null; then
                    success "Grafana password updated"
                else
                    warn "Could not update Grafana password. You may need to reset it manually."
                fi
            fi
            ;;
        *)
            echo "Usage: moav admin <command>"
            echo ""
            echo "Commands:"
            echo "  password    Reset admin dashboard password"
            echo ""
            echo "Examples:"
            echo "  moav admin password           # Generate random password"
            ;;
    esac
}




# Build via docker compose with RAM-aware concurrency. Docker's bake builder
# fans every image out in parallel, which OOMs / trips BuildKit's solve deadline
# ("context deadline exceeded") on low-RAM hosts (e.g. a 2GB VPS building ~19
# images at once). Tier the concurrency to MemTotal so small boxes build
# serially and reliably while big boxes stay fast. Pass everything that would
# follow `docker compose` (e.g. `--profile all build foo`).
#
# Override the auto-tier with MOAV_BUILD_PARALLEL=N (1 = serial, 0 = leave
# Docker's default/unbounded behavior).

# Strip scheme / user@ / path / port / whitespace from a domain input; lowercase.
# Echoes the bare hostname (or "" if nothing usable remains).
sanitize_domain() {
    local d="$1"
    # Scheme
    d="${d#http://}"; d="${d#https://}"
    d="${d#HTTP://}"; d="${d#HTTPS://}"
    # user@host
    d="${d##*@}"
    # /path
    d="${d%%/*}"
    # :port
    d="${d%%:*}"
    # Strip all whitespace (hostnames have none).
    d="${d// /}"
    d="${d//$'\t'/}"
    # lowercase
    echo "$d" | tr '[:upper:]' '[:lower:]'
}

# True if $1 looks like a hostname (has a dot, only [a-z0-9.-], no leading/
# trailing punctuation, no consecutive dots).
is_valid_domain() {
    local d="$1"
    [[ -n "$d" ]] || return 1
    [[ "$d" == *.* ]] || return 1
    [[ "$d" =~ ^[a-z0-9.-]+$ ]] || return 1
    [[ "$d" != *..* ]] || return 1
    [[ "${d:0:1}" =~ [a-z0-9] ]] || return 1
    [[ "${d: -1}" =~ [a-z0-9] ]] || return 1
    return 0
}

# Helper: set <var>=<value> in .env. Prefers replacing an existing line
# (active or commented `#X=` / `# X=`); appends only if neither exists.
update_env_var() {
    local env_file="$1"
    local var_name="$2"
    local var_value="$3"

    if grep -q "^${var_name}=" "$env_file" 2>/dev/null; then
        sed -i.bak "s|^${var_name}=.*|${var_name}=${var_value}|" "$env_file"
    elif grep -qE "^#[[:space:]]*${var_name}=" "$env_file" 2>/dev/null; then
        # Uncomment + set — .env.example has both "#X=" and "# X=" styles.
        sed -i.bak "s|^#[[:space:]]*${var_name}=.*|${var_name}=${var_value}|" "$env_file"
    else
        echo "${var_name}=${var_value}" >> "$env_file"
    fi
    rm -f "$env_file.bak"
}

# =============================================================================
# Client Commands
# =============================================================================

# `moav user base64 <user>` — emit base64 of a text-only bundle (the config text
# files + subscription.txt; excludes the QR PNGs and README.html, which are the
# bulk). Paste it into moav-client's e2e `bundle_b64` input, or use it for a
# quick client import:  moav user base64 alice | pbcopy
cmd_user_base64() {
    local user="${1:-}"
    if [[ -z "$user" ]]; then
        error "Usage: moav user base64 USERNAME"
        {
            echo ""
            echo "Emits base64 of a text-only bundle (configs + subscription.txt; no QR PNGs / README)."
            echo "Paste into moav-client's e2e 'bundle_b64' input, or:  moav user base64 alice | pbcopy"
            echo ""
            echo "Available users:"
            ls -1 outputs/bundles/ 2>/dev/null || echo "  No users found"
        } >&2
        exit 1
    fi
    local bundle="outputs/bundles/$user"
    [[ -d "$bundle" ]] || { error "User bundle not found: $bundle"; exit 1; }
    command -v zip >/dev/null 2>&1 || { error "zip is required for 'moav user base64'"; exit 1; }

    local tmp zip b64 size
    tmp="$(mktemp -d)"
    zip="$tmp/${user}.zip"
    # Keep everything except the QR images and the rendered guide — i.e. the
    # text/config files a client actually imports.
    if ! ( cd outputs/bundles && zip -q -r "$zip" "$user" \
             -x "*.png" -x "*/README.html" -x "*.DS_Store" ); then
        rm -rf "$tmp"; error "failed to build text-only bundle zip"; exit 1
    fi
    # Read from stdin (both GNU and BSD base64 do) and strip any line wrapping —
    # portable across Linux servers and macOS dev boxes.
    b64="$(base64 < "$zip" | tr -d '\n')"
    size="$(wc -c < "$zip" | tr -d ' ')"
    rm -rf "$tmp"
    echo "[moav] text-only bundle for '$user': ${size}B zipped -> ${#b64} base64 chars" >&2
    printf '%s\n' "$b64"
}

cmd_test() {
    local user=""
    local json_flag=""
    local verbose_flag=""

    # Parse flags
    for arg in "$@"; do
        case "$arg" in
            --json) json_flag="--json" ;;
            -v|--verbose) verbose_flag="--verbose" ;;
            -*) error "Unknown flag: $arg"; exit 1 ;;
            *) [[ -z "$user" ]] && user="$arg" ;;
        esac
    done

    if [[ -z "$user" ]]; then
        error "Usage: moav test USERNAME [--json] [-v|--verbose]"
        echo ""
        echo "Available users:"
        ls -1 outputs/bundles/ 2>/dev/null || echo "  No users found"
        exit 1
    fi

    local bundle_path="outputs/bundles/$user"
    if [[ ! -d "$bundle_path" ]]; then
        error "User bundle not found: $bundle_path"
        exit 1
    fi

    info "Testing connectivity for user: $user"

    # Always (re)build the client image. Docker's layer cache makes this a
    # near-noop when nothing changed, but a plain "skip if it exists" check
    # silently reused a stale image — so `moav test` missed client Dockerfile /
    # pinned-version changes (e.g. a new sing-box after `moav update`).
    info "Building client image (cached if unchanged)..."
    compose_build --profile client build client

    # TUN + NET_ADMIN let the WireGuard/AmneziaWG tests bring up a real tunnel
    # inside the test container (its own netns — host routing untouched). The
    # image has wg-quick/awg-quick; without the device those tests can only
    # degrade to config checks, which is how WG "passed" on a DNS resolve for
    # months. Conditional so `moav test` still runs on TUN-less hosts.
    local tun_flags=()
    [[ -c /dev/net/tun ]] && tun_flags=(--cap-add=NET_ADMIN --device=/dev/net/tun)

    # Run test (mount bundle + dnstt/slipstream outputs)
    docker run --rm \
        ${tun_flags[@]+"${tun_flags[@]}"} \
        -v "$(pwd)/$bundle_path:/config:ro" \
        -v "$(pwd)/outputs/dnstt:/dnstt:ro" \
        -v "$(pwd)/outputs/slipstream:/slipstream:ro" \
        -e ENABLE_DEPRECATED_WIREGUARD_OUTBOUND=true \
        moav-client --test $json_flag $verbose_flag
}

cmd_client() {
    local action="${1:-}"
    shift || true

    case "$action" in
        test)
            cmd_test "$@"
            ;;
        connect)
            local user=""
            local protocol="auto"

            # Parse arguments
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --protocol|-p)
                        protocol="${2:-auto}"
                        shift 2
                        ;;
                    --*)
                        error "Unknown option: $1"
                        exit 1
                        ;;
                    *)
                        [[ -z "$user" ]] && user="$1"
                        shift
                        ;;
                esac
            done

            if [[ -z "$user" ]]; then
                error "Usage: moav client connect USERNAME [--protocol PROTOCOL]"
                echo ""
                echo "Protocols: auto, reality, trojan, hysteria2, wireguard, psiphon, tor, dnstt, slipstream"
                echo ""
                echo "Available users:"
                ls -1 outputs/bundles/ 2>/dev/null || echo "  No users found"
                exit 1
            fi

            local bundle_path="outputs/bundles/$user"
            if [[ ! -d "$bundle_path" ]]; then
                error "User bundle not found: $bundle_path"
                exit 1
            fi

            # Read ports from .env or use alternative defaults (to avoid server conflicts)
            local socks_port="10800"
            local http_port="18080"

            if [[ -f ".env" ]]; then
                local env_socks=$(get_env_val "CLIENT_SOCKS_PORT" ".env")
                local env_http=$(get_env_val "CLIENT_HTTP_PORT" ".env")
                [[ -n "$env_socks" ]] && socks_port="$env_socks"
                [[ -n "$env_http" ]] && http_port="$env_http"
            fi

            info "Connecting as user: $user (protocol: $protocol)"
            info "SOCKS5 proxy will be available at localhost:$socks_port"
            info "HTTP proxy will be available at localhost:$http_port"

            # Build client image if needed
            if ! docker images --format "{{.Repository}}" 2>/dev/null | grep -q "^moav-client$"; then
                info "Building client image..."
                compose_build --profile client build client
            fi

            # Run client in foreground (mount bundle + dnstt/slipstream outputs)
            docker run --rm -it \
                -p "$socks_port:1080" \
                -p "$http_port:8080" \
                -v "$(pwd)/$bundle_path:/config:ro" \
                -v "$(pwd)/outputs/dnstt:/dnstt:ro" \
                -v "$(pwd)/outputs/slipstream:/slipstream:ro" \
                -e ENABLE_DEPRECATED_WIREGUARD_OUTBOUND=true \
                moav-client --connect -p "$protocol"
            ;;
        build)
            info "Building client image..."
            compose_build --profile client build client
            success "Client image built!"
            ;;
        *)
            echo "Usage: moav client <command> [options]"
            echo ""
            echo "Commands:"
            echo "  test USERNAME [--json]        Test connectivity for a user"
            echo "  connect USERNAME [PROTOCOL]   Connect and expose local proxy"
            echo "  build                         Build the client image"
            echo ""
            echo "Protocols: auto, reality, trojan, hysteria2, wireguard, psiphon, tor, dnstt"
            echo ""
            echo "Examples:"
            echo "  moav client test joe              # Test all protocols for user joe"
            echo "  moav client test joe --json       # Output results as JSON"
            echo "  moav client connect joe           # Connect using auto-detection"
            echo "  moav client connect joe reality   # Connect using Reality protocol"
            ;;
    esac
}
