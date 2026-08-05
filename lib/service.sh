#!/bin/bash
# lib/service.sh — the service layer: docker-compose profile selection and
# persistence, starting / stopping / restarting the stack, status and version
# reporting, log viewing, and the `moav start|stop|restart|status|logs|profiles`
# commands with their profile/service name resolution.
#
# The densest and most-called part of the old monolith, which is why the plan
# deferred it to the end of the decomposition.
#
# Sourced by moav.sh after lib/common.sh.
#
# Definitions only — nothing here runs at source time.

get_running_services() {
    docker compose ps --services --filter "status=running" 2>/dev/null || echo ""
}

show_versions() {
    local singbox_ver wstunnel_ver conduit_ver snowflake_ver slipstream_ver telemt_ver
    local trusttunnel_ver trusttunnel_client_ver awgtools_ver xray_ver dnstt_ver
    singbox_ver=$(get_component_version "SINGBOX_VERSION" "1.13.12")
    wstunnel_ver=$(get_component_version "WSTUNNEL_VERSION" "10.6.1")
    conduit_ver=$(get_component_version "CONDUIT_VERSION" "1.2.0")
    snowflake_ver=$(get_component_version "SNOWFLAKE_VERSION" "latest")
    slipstream_ver=$(get_component_version "SLIPSTREAM_VERSION" "2026.02.22.1")
    telemt_ver=$(get_component_version "TELEMT_VERSION" "3.4.23")
    trusttunnel_ver=$(get_component_version "TRUSTTUNNEL_VERSION" "")
    trusttunnel_client_ver=$(get_component_version "TRUSTTUNNEL_CLIENT_VERSION" "")
    awgtools_ver=$(get_component_version "AWGTOOLS_VERSION" "")
    xray_ver=$(get_component_version "XRAY_VERSION" "v26.6.27")
    dnstt_ver=$(get_component_version "DNSTT_VERSION" "latest")

    echo ""
    echo -e "${CYAN}MoaV${NC} v${VERSION}"
    echo -e "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${WHITE}Component Versions:${NC}"
    echo ""
    echo -e "  ${CYAN}┌──────────────────┬────────────────┬──────────────────────────────────────────┐${NC}"
    echo -e "  ${CYAN}│${NC} ${WHITE}Component${NC}        ${CYAN}│${NC} ${WHITE}Version${NC}        ${CYAN}│${NC} ${WHITE}Source${NC}                                   ${CYAN}│${NC}"
    echo -e "  ${CYAN}├──────────────────┼────────────────┼──────────────────────────────────────────┤${NC}"
    printf "  ${CYAN}│${NC} %-16s ${CYAN}│${NC} ${GREEN}%-14s${NC} ${CYAN}│${NC} %-40s ${CYAN}│${NC}\n" "sing-box" "$singbox_ver" "github.com/SagerNet/sing-box"
    printf "  ${CYAN}│${NC} %-16s ${CYAN}│${NC} ${GREEN}%-14s${NC} ${CYAN}│${NC} %-40s ${CYAN}│${NC}\n" "wstunnel" "$wstunnel_ver" "github.com/erebe/wstunnel"
    printf "  ${CYAN}│${NC} %-16s ${CYAN}│${NC} ${GREEN}%-14s${NC} ${CYAN}│${NC} %-40s ${CYAN}│${NC}\n" "trusttunnel" "$trusttunnel_ver" "github.com/TrustTunnel/TrustTunnel"
    printf "  ${CYAN}│${NC} %-16s ${CYAN}│${NC} ${GREEN}%-14s${NC} ${CYAN}│${NC} %-40s ${CYAN}│${NC}\n" "trusttunnel-cli" "$trusttunnel_client_ver" "github.com/TrustTunnel/TrustTunnelClient"
    printf "  ${CYAN}│${NC} %-16s ${CYAN}│${NC} ${GREEN}%-14s${NC} ${CYAN}│${NC} %-40s ${CYAN}│${NC}\n" "amneziawg" "$awgtools_ver" "github.com/amnezia-vpn/amneziawg-tools"
    printf "  ${CYAN}│${NC} %-16s ${CYAN}│${NC} ${GREEN}%-14s${NC} ${CYAN}│${NC} %-40s ${CYAN}│${NC}\n" "conduit" "$conduit_ver" "github.com/Psiphon-Inc/conduit"
    printf "  ${CYAN}│${NC} %-16s ${CYAN}│${NC} ${GREEN}%-14s${NC} ${CYAN}│${NC} %-40s ${CYAN}│${NC}\n" "snowflake" "$snowflake_ver" "torproject.org (built from src)"
    printf "  ${CYAN}│${NC} %-16s ${CYAN}│${NC} ${GREEN}%-14s${NC} ${CYAN}│${NC} %-40s ${CYAN}│${NC}\n" "dnstt" "$dnstt_ver" "bamsoftware.com (built from src)"
    printf "  ${CYAN}│${NC} %-16s ${CYAN}│${NC} ${GREEN}%-14s${NC} ${CYAN}│${NC} %-40s ${CYAN}│${NC}\n" "slipstream" "$slipstream_ver" "github.com/Mygod/slipstream-rust"
    printf "  ${CYAN}│${NC} %-16s ${CYAN}│${NC} ${GREEN}%-14s${NC} ${CYAN}│${NC} %-40s ${CYAN}│${NC}\n" "telemt" "$telemt_ver" "github.com/telemt/telemt"
    printf "  ${CYAN}│${NC} %-16s ${CYAN}│${NC} ${GREEN}%-14s${NC} ${CYAN}│${NC} %-40s ${CYAN}│${NC}\n" "xray-core" "$xray_ver" "github.com/XTLS/Xray-core"
    printf "  ${CYAN}│${NC} %-16s ${CYAN}│${NC} ${DIM}%-14s${NC} ${CYAN}│${NC} %-40s ${CYAN}│${NC}\n" "wireguard" "alpine" "wireguard-tools package"
    echo -e "  ${CYAN}└──────────────────┴────────────────┴──────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "  ${DIM}Versions can be changed in .env and rebuilt with: moav build${NC}"
    echo ""
}

show_status() {
    # Get all defined services from docker-compose
    local all_services
    all_services=$(docker compose --profile all config --services 2>/dev/null | sort)

    # Get service status from docker compose (including stopped with -a)
    local raw_status json_lines
    raw_status=$(docker compose --profile all ps -a --format json 2>/dev/null)

    # Read ENABLE_* settings to determine which services are disabled
    local env_file="$SCRIPT_DIR/.env"
    declare -A disabled_services

    if [[ -f "$env_file" ]]; then
        local enable_reality=$(get_env_val "ENABLE_REALITY" "$env_file" "true")
        local enable_trojan=$(get_env_val "ENABLE_TROJAN" "$env_file" "true")
        local enable_anytls=$(get_env_val "ENABLE_ANYTLS" "$env_file" "false")
        local enable_hysteria2=$(get_env_val "ENABLE_HYSTERIA2" "$env_file" "true")
        local enable_wireguard=$(get_env_val "ENABLE_WIREGUARD" "$env_file" "true")
        local enable_dnstt=$(get_env_val "ENABLE_DNSTT" "$env_file" "true")
        local enable_admin=$(get_env_val "ENABLE_ADMIN_UI" "$env_file" "true")

        # Mark services as disabled based on ENABLE_* settings
        # sing-box handles Reality, Trojan, AnyTLS, Hysteria2
        if [[ "$enable_reality" != "true" ]] && [[ "$enable_trojan" != "true" ]] && [[ "$enable_anytls" != "true" ]] && [[ "$enable_hysteria2" != "true" ]]; then
            disabled_services["sing-box"]=1
            disabled_services["decoy"]=1
        fi
        [[ "$enable_wireguard" != "true" ]] && disabled_services["wireguard"]=1 && disabled_services["wstunnel"]=1
        local enable_slipstream=$(get_env_val "ENABLE_SLIPSTREAM" "$env_file" "true")
        [[ "$enable_dnstt" != "true" ]] && disabled_services["dnstt"]=1
        [[ "$enable_slipstream" != "true" ]] && disabled_services["slipstream"]=1
        # dns-router is disabled if both dnstt and slipstream are disabled
        if [[ "$enable_dnstt" != "true" ]] && [[ "$enable_slipstream" != "true" ]]; then
            disabled_services["dns-router"]=1
        fi
        [[ "$enable_admin" != "true" ]] && disabled_services["admin"]=1
        local enable_telemt=$(get_env_val "ENABLE_TELEMT" "$env_file" "true")
        [[ "$enable_telemt" != "true" ]] && disabled_services["telemt"]=1
    fi

    print_section "Service Status"
    echo ""
    echo -e "  ${CYAN}┌──────────────────────┬──────────────┬─────────────────────┬──────────────┬─────────────────┐${NC}"
    echo -e "  ${CYAN}│${NC} ${WHITE}Service${NC}              ${CYAN}│${NC} ${WHITE}Status${NC}       ${CYAN}│${NC} ${WHITE}Last Run${NC}            ${CYAN}│${NC} ${WHITE}Uptime${NC}       ${CYAN}│${NC} ${WHITE}Ports${NC}           ${CYAN}│${NC}"
    echo -e "  ${CYAN}├──────────────────────┼──────────────┼─────────────────────┼──────────────┼─────────────────┤${NC}"

    # Track which services we've displayed
    declare -A displayed_services

    # Handle both JSON array format and NDJSON (one object per line)
    if [[ -n "$raw_status" ]] && [[ "$raw_status" != "[]" ]]; then
        if [[ "$raw_status" == "["* ]]; then
            # Convert JSON array to one object per line (split on },{ )
            json_lines=$(echo "$raw_status" | sed 's/^\[//;s/\]$//;s/},{/}\n{/g')
        else
            json_lines="$raw_status"
        fi

        # Parse JSON and display each service (using here-string to avoid subshell)
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue

            local name service state ports health status_str created_at uptime last_run finished_at
            # Parse JSON fields (handle both "Key":"value" and "Key": "value" formats)
            name=$(echo "$line" | grep -oE '"Name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
            service=$(echo "$line" | grep -oE '"Service"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
            state=$(echo "$line" | grep -oE '"State"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
            health=$(echo "$line" | grep -oE '"Health"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
            status_str=$(echo "$line" | grep -oE '"Status"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
            created_at=$(echo "$line" | grep -oE '"CreatedAt"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
            ports=$(echo "$line" | grep -o '"Publishers":\[[^]]*\]' | grep -o '"PublishedPort":[0-9]*' | cut -d':' -f2 | sort -u | grep -v '^0$' | tr '\n' ',' | sed 's/,$//' || true)

            [[ -z "$name" ]] && continue

            # If Service field is missing, try to find matching service from all_services
            if [[ -z "$service" ]]; then
                local stripped="${name#moav-}"
                # Check if any service name contains or matches the stripped container name
                while IFS= read -r candidate; do
                    [[ -z "$candidate" ]] && continue
                    # Match: "psiphon-conduit" contains "conduit", or "sing-box" == "sing-box"
                    if [[ "$candidate" == *"$stripped"* ]] || [[ "$stripped" == "$candidate" ]]; then
                        service="$candidate"
                        break
                    fi
                done <<< "$all_services"
            fi

            # Use service name for display (fall back to stripped container name if still unknown)
            local short_name="${service:-${name#moav-}}"
            # Track by service name to avoid duplicates
            [[ -n "$service" ]] && displayed_services["$service"]=1

            # Format last run datetime
            last_run="-"
            if [[ -n "$created_at" ]]; then
                last_run=$(echo "$created_at" | cut -d' ' -f1,2)
            fi

            # For stopped containers, try to get finished time
            if [[ "$state" == "exited" ]]; then
                # Try to get FinishedAt from docker inspect
                finished_at=$(docker inspect --format '{{.State.FinishedAt}}' "$name" 2>/dev/null | cut -d'T' -f1,2 | tr 'T' ' ' | cut -d'.' -f1)
                if [[ -n "$finished_at" ]] && [[ "$finished_at" != "0001-01-01" ]]; then
                    last_run="$finished_at"
                fi
            fi

            # Parse uptime from Status field
            uptime="-"
            if [[ "$state" == "running" ]] && [[ "$status_str" =~ ^Up[[:space:]]+(.*) ]]; then
                uptime="${BASH_REMATCH[1]}"
                uptime="${uptime%% (*}"
                uptime="${uptime/About an /~1 }"
                uptime="${uptime/About a /~1 }"
                uptime="${uptime/Less than a /< 1 }"
            fi

            local status_display status_color
            if [[ "$state" == "running" ]]; then
                if [[ "$health" == "healthy" ]] || [[ -z "$health" ]]; then
                    status_color="${GREEN}"
                    status_display="● running"
                elif [[ "$health" == "unhealthy" ]]; then
                    status_color="${RED}"
                    status_display="○ unhealthy"
                else
                    status_color="${YELLOW}"
                    status_display="◐ starting"
                fi
            elif [[ "$state" == "exited" ]]; then
                status_color="${DIM}"
                status_display="○ exited "
                uptime="-"
            else
                status_color="${YELLOW}"
                status_display="◐ ${state}"
            fi

            [[ -z "$ports" ]] && ports="-"

            # Check if service is disabled and add indicator
            local display_name="$short_name"
            local name_color=""
            if [[ -n "${disabled_services[$short_name]:-}" ]]; then
                display_name="${short_name}*"
                name_color="${DIM}"
            fi

            # Note: %-14s for status to account for 3-byte Unicode symbols (●○◐) displaying as 1 char
            printf "  ${CYAN}│${NC} ${name_color}%-20s${NC} ${CYAN}│${NC} ${status_color}%-14s${NC} ${CYAN}│${NC} %-19s ${CYAN}│${NC} %-12s ${CYAN}│${NC} %-15s ${CYAN}│${NC}\n" \
                "$display_name" "$status_display" "$last_run" "$uptime" "$ports"
        done <<< "$json_lines"
    fi

    # Show services that have never been started (not in docker ps -a)
    while IFS= read -r service; do
        [[ -z "$service" ]] && continue
        if [[ -z "${displayed_services[$service]:-}" ]]; then
            # Check if service is disabled
            local display_name="$service"
            local name_color="${DIM}"
            if [[ -n "${disabled_services[$service]:-}" ]]; then
                display_name="${service}*"
            fi

            printf "  ${CYAN}│${NC} ${name_color}%-20s${NC} ${CYAN}│${NC} ${DIM}%-12s${NC} ${CYAN}│${NC} %-19s ${CYAN}│${NC} %-12s ${CYAN}│${NC} %-15s ${CYAN}│${NC}\n" \
                "$display_name" "- never" "-" "-" "-"
        fi
    done <<< "$all_services"

    echo -e "  ${CYAN}└──────────────────────┴──────────────┴─────────────────────┴──────────────┴─────────────────┘${NC}"

    # Show legend if there are disabled services
    local has_disabled=false
    for key in "${!disabled_services[@]}"; do
        has_disabled=true
        break
    done
    if [[ "$has_disabled" == "true" ]]; then
        echo -e "  ${DIM}* = disabled in .env (won't start with 'moav start')${NC}"
    fi

    # Explain certbot status (often confusing to users)
    echo ""
    echo -e "  ${DIM}Note: certbot is a one-time service that obtains SSL certificates.${NC}"
    echo -e "  ${DIM}      Status 'Exited (0)' means it completed successfully.${NC}"
    echo ""
    print_community_links
    echo ""
}

# Display service selection menu and populate SELECTED_PROFILES array
# Usage: select_profiles [mode]
#   mode: "save" to update .env, "start" for start menu, "stop" for stop menu
select_profiles() {
    local mode="${1:-}"
    SELECTED_PROFILES=()

    case "$mode" in
        start)   print_section "Start Services" ;;
        stop)    print_section "Stop Services" ;;
        restart) print_section "Restart Services" ;;
        *)       print_section "Select Services" ;;
    esac

    # Read ENABLE_* settings to show disabled status
    local env_file="$SCRIPT_DIR/.env"
    local proxy_enabled=true
    local wg_enabled=true
    local dnstunnel_enabled=true
    local amneziawg_enabled=true
    local trusttunnel_enabled=true
    local xhttp_enabled=false
    local telegram_enabled=true
    local admin_enabled=true

    if [[ -f "$env_file" ]]; then
        local enable_reality=$(get_env_val "ENABLE_REALITY" "$env_file" "true")
        local enable_trojan=$(get_env_val "ENABLE_TROJAN" "$env_file" "true")
        local enable_anytls=$(get_env_val "ENABLE_ANYTLS" "$env_file" "false")
        local enable_hysteria2=$(get_env_val "ENABLE_HYSTERIA2" "$env_file" "true")
        local enable_wireguard=$(get_env_val "ENABLE_WIREGUARD" "$env_file" "true")
        local enable_amneziawg=$(get_env_val "ENABLE_AMNEZIAWG" "$env_file" "true")
        local enable_dnstt=$(get_env_val "ENABLE_DNSTT" "$env_file" "true")
        local enable_slipstream=$(get_env_val "ENABLE_SLIPSTREAM" "$env_file" "true")
        local enable_trusttunnel=$(get_env_val "ENABLE_TRUSTTUNNEL" "$env_file" "true")
        local enable_telemt=$(get_env_val "ENABLE_TELEMT" "$env_file" "true")
        local enable_admin=$(get_env_val "ENABLE_ADMIN_UI" "$env_file" "true")
        local enable_xhttp=$(get_env_val "ENABLE_XHTTP" "$env_file" "true")

        # proxy is disabled if all sing-box protocols are disabled
        if [[ "$enable_reality" != "true" ]] && [[ "$enable_trojan" != "true" ]] && [[ "$enable_anytls" != "true" ]] && [[ "$enable_hysteria2" != "true" ]]; then
            proxy_enabled=false
        fi
        [[ "$enable_wireguard" != "true" ]] && wg_enabled=false
        [[ "$enable_amneziawg" != "true" ]] && amneziawg_enabled=false
        # dnstunnel is disabled if both dnstt and slipstream are disabled
        if [[ "$enable_dnstt" != "true" ]] && [[ "$enable_slipstream" != "true" ]]; then
            dnstunnel_enabled=false
        fi
        [[ "$enable_trusttunnel" != "true" ]] && trusttunnel_enabled=false
        [[ "$enable_xhttp" == "true" ]] && xhttp_enabled=true
        [[ "$enable_telemt" != "true" ]] && telegram_enabled=false
        [[ "$enable_admin" != "true" ]] && admin_enabled=false
    fi

    # Build menu lines with disabled indicators
    local proxy_line wg_line amneziawg_line dnstunnel_line trusttunnel_line xhttp_line telegram_line admin_line

    if [[ "$proxy_enabled" == "true" ]]; then
        proxy_line="  ${CYAN}│${NC}  ${GREEN}1${NC}   proxy        Reality, Trojan, Hysteria2 (v2ray apps)       ${CYAN}│${NC}"
    else
        proxy_line="  ${CYAN}│${NC}  ${DIM}1   proxy        Reality, Trojan, Hysteria2 (disabled)${NC}        ${CYAN}│${NC}"
    fi

    if [[ "$wg_enabled" == "true" ]]; then
        wg_line="  ${CYAN}│${NC}  ${GREEN}2${NC}   wireguard    WireGuard VPN + WebSocket tunnel              ${CYAN}│${NC}"
    else
        wg_line="  ${CYAN}│${NC}  ${DIM}2   wireguard    WireGuard VPN (disabled)${NC}                      ${CYAN}│${NC}"
    fi

    if [[ "$amneziawg_enabled" == "true" ]]; then
        amneziawg_line="  ${CYAN}│${NC}  ${GREEN}3${NC}   amneziawg    AmneziaWG (obfuscated WireGuard)               ${CYAN}│${NC}"
    else
        amneziawg_line="  ${CYAN}│${NC}  ${DIM}3   amneziawg    AmneziaWG (disabled)${NC}                         ${CYAN}│${NC}"
    fi

    if [[ "$dnstunnel_enabled" == "true" ]]; then
        dnstunnel_line="  ${CYAN}│${NC}  ${YELLOW}4${NC}   dnstunnel    DNS tunnels ${DIM}(dnstt + Slipstream)${NC}               ${CYAN}│${NC}"
    else
        dnstunnel_line="  ${CYAN}│${NC}  ${DIM}4   dnstunnel    DNS tunnels (disabled)${NC}                       ${CYAN}│${NC}"
    fi

    if [[ "$trusttunnel_enabled" == "true" ]]; then
        trusttunnel_line="  ${CYAN}│${NC}  ${GREEN}5${NC}   trusttunnel  TrustTunnel VPN (HTTP/2 + QUIC)               ${CYAN}│${NC}"
    else
        trusttunnel_line="  ${CYAN}│${NC}  ${DIM}5   trusttunnel  TrustTunnel VPN (disabled)${NC}                    ${CYAN}│${NC}"
    fi

    if [[ "$xhttp_enabled" == "true" ]]; then
        xhttp_line="  ${CYAN}│${NC}  ${GREEN}6${NC}   xhttp        VLESS+XHTTP+Reality (Xray-core)               ${CYAN}│${NC}"
    else
        xhttp_line="  ${CYAN}│${NC}  ${DIM}6   xhttp        VLESS+XHTTP+Reality (disabled)${NC}                ${CYAN}│${NC}"
    fi

    if [[ "$telegram_enabled" == "true" ]]; then
        telegram_line="  ${CYAN}│${NC}  ${GREEN}7${NC}   telegram     Telegram MTProxy (fake-TLS)                   ${CYAN}│${NC}"
    else
        telegram_line="  ${CYAN}│${NC}  ${DIM}7   telegram     Telegram MTProxy (disabled)${NC}                   ${CYAN}│${NC}"
    fi

    if [[ "$admin_enabled" == "true" ]]; then
        admin_line="  ${CYAN}│${NC}  ${GREEN}8${NC}   admin        Stats dashboard (port 9443)                   ${CYAN}│${NC}"
    else
        admin_line="  ${CYAN}│${NC}  ${DIM}8   admin        Stats dashboard (disabled)${NC}                   ${CYAN}│${NC}"
    fi

    echo ""
    echo -e "  ${CYAN}┌─────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "  ${CYAN}│${NC}  ${WHITE}#${NC}   ${WHITE}Profile${NC}      ${WHITE}Description${NC}                                   ${CYAN}│${NC}"
    echo -e "  ${CYAN}├─────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "$proxy_line"
    echo -e "$wg_line"
    echo -e "$amneziawg_line"
    echo -e "$dnstunnel_line"
    echo -e "$trusttunnel_line"
    echo -e "$xhttp_line"
    echo -e "$telegram_line"
    echo -e "$admin_line"
    echo -e "  ${CYAN}├─────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "  ${CYAN}│${NC}  ${BLUE}9${NC}   conduit      Donate bandwidth via Psiphon                  ${CYAN}│${NC}"
    echo -e "  ${CYAN}│${NC}  ${BLUE}10${NC}  snowflake    Donate bandwidth via Tor                      ${CYAN}│${NC}"
    echo -e "  ${CYAN}├─────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "  ${CYAN}│${NC}  ${BLUE}11${NC}  monitoring   Grafana + Prometheus (requires 2GB RAM)       ${CYAN}│${NC}"
    echo -e "  ${CYAN}├─────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "  ${CYAN}│${NC}  ${GREEN}a${NC}   ${GREEN}ALL${NC}          All services ${GREEN}(Recommended)${NC}                    ${CYAN}│${NC}"
    echo -e "  ${CYAN}│${NC}  ${DIM}0${NC}   ${DIM}Back${NC}         Back to main menu                             ${CYAN}│${NC}"
    echo -e "  ${CYAN}└─────────────────────────────────────────────────────────────────┘${NC}"
    echo ""

    prompt "Enter choices (e.g., 1 2 4 or 1,2,4 or 'a' for all): "
    read -r choices < /dev/tty 2>/dev/null || choices=""

    if [[ "$choices" == "0" || -z "$choices" ]]; then
        return 2  # Return 2 to signal "go back" vs 1 for error
    fi

    # Support both space and comma separators
    choices="${choices//,/ }"

    if [[ "$choices" == "a" || "$choices" == "A" ]]; then
        # Build profile list based on ENABLE_* settings in .env
        # This way "all" means "all enabled services", not literally everything
        local env_file="$SCRIPT_DIR/.env"

        # Check which protocols are enabled
        local enable_reality=$(get_env_val "ENABLE_REALITY" "$env_file" "true")
        local enable_trojan=$(get_env_val "ENABLE_TROJAN" "$env_file" "true")
        local enable_anytls=$(get_env_val "ENABLE_ANYTLS" "$env_file" "false")
        local enable_hysteria2=$(get_env_val "ENABLE_HYSTERIA2" "$env_file" "true")
        local enable_wireguard=$(get_env_val "ENABLE_WIREGUARD" "$env_file" "true")
        local enable_amneziawg=$(get_env_val "ENABLE_AMNEZIAWG" "$env_file" "true")
        local enable_dnstt=$(get_env_val "ENABLE_DNSTT" "$env_file" "true")
        local enable_slipstream=$(get_env_val "ENABLE_SLIPSTREAM" "$env_file" "true")
        local enable_trusttunnel=$(get_env_val "ENABLE_TRUSTTUNNEL" "$env_file" "true")
        local enable_telemt=$(get_env_val "ENABLE_TELEMT" "$env_file" "true")
        local enable_admin=$(get_env_val "ENABLE_ADMIN_UI" "$env_file" "true")
        local enable_xhttp=$(get_env_val "ENABLE_XHTTP" "$env_file" "true")

        # Build profiles list based on enabled services
        SELECTED_PROFILES=()

        # proxy profile (Reality, Trojan, AnyTLS, Hysteria2)
        if [[ "$enable_reality" == "true" ]] || [[ "$enable_trojan" == "true" ]] || [[ "$enable_anytls" == "true" ]] || [[ "$enable_hysteria2" == "true" ]]; then
            SELECTED_PROFILES+=("proxy")
        fi

        # wireguard profile
        if [[ "$enable_wireguard" == "true" ]]; then
            SELECTED_PROFILES+=("wireguard")
        fi

        # amneziawg profile
        if [[ "$enable_amneziawg" == "true" ]]; then
            SELECTED_PROFILES+=("amneziawg")
        fi

        # dnstunnel profile (dnstt + Slipstream)
        if [[ "$enable_dnstt" == "true" ]] || [[ "$enable_slipstream" == "true" ]]; then
            SELECTED_PROFILES+=("dnstunnel")
        fi

        # trusttunnel profile
        if [[ "$enable_trusttunnel" == "true" ]]; then
            SELECTED_PROFILES+=("trusttunnel")
        fi

        # xhttp profile (Xray-core VLESS+XHTTP+Reality)
        if [[ "$enable_xhttp" == "true" ]]; then
            SELECTED_PROFILES+=("xhttp")
        fi

        # telegram profile (Telegram MTProxy)
        if [[ "$enable_telemt" == "true" ]]; then
            SELECTED_PROFILES+=("telegram")
        fi

        # admin profile
        if [[ "$enable_admin" == "true" ]]; then
            SELECTED_PROFILES+=("admin")
        fi

        # Donation services follow their ENABLE_* flags too (issue #106).
        # Pre-#106 these were appended unconditionally on the "all" path —
        # which started conduit/snowflake even when ENABLE_CONDUIT=false /
        # ENABLE_SNOWFLAKE=false was set in .env.
        local enable_conduit=$(get_env_val "ENABLE_CONDUIT" "$env_file" "true")
        local enable_snowflake=$(get_env_val "ENABLE_SNOWFLAKE" "$env_file" "true")
        local enable_gooserelay=$(get_env_val "ENABLE_GOOSERELAY" "$env_file" "false")
        [[ "$enable_conduit"    == "true" ]] && SELECTED_PROFILES+=("conduit")
        [[ "$enable_snowflake"  == "true" ]] && SELECTED_PROFILES+=("snowflake")
        [[ "$enable_gooserelay" == "true" ]] && SELECTED_PROFILES+=("gooserelay")

        # Check if monitoring should be included
        local enable_monitoring=$(get_env_val "ENABLE_MONITORING" "$env_file" "")
        if [[ "$enable_monitoring" == "true" ]]; then
            SELECTED_PROFILES+=("monitoring")
        elif [[ "$enable_monitoring" != "false" ]]; then
            # Not explicitly set - ask user
            echo ""
            warn "Monitoring stack (Grafana + Prometheus) requires at least 2GB RAM."
            if confirm "Enable monitoring?" "$(monitoring_default_for_ram)"; then
                update_env_var "$env_file" "ENABLE_MONITORING" "true"
                SELECTED_PROFILES+=("monitoring")
                success "Monitoring enabled"
            else
                # Explicitly disable to avoid asking again
                update_env_var "$env_file" "ENABLE_MONITORING" "false"
                info "Monitoring skipped. Enable later with: moav start monitoring"
            fi
        fi
        # If explicitly false, don't include monitoring

        # If nothing enabled, error out — auto-forcing donation services
        # on (pre-#106 behavior: SELECTED_PROFILES=("conduit" "snowflake")) is
        # exactly the bug the issue describes. The operator should pick
        # something or flip an ENABLE_* flag.
        if [[ ${#SELECTED_PROFILES[@]} -eq 0 ]]; then
            warn "No services are enabled in .env (every ENABLE_* is false)."
            echo "  Set at least one ENABLE_*=true in .env, or pick a specific profile."
            return 1
        fi

        # Show what "all enabled" actually means
        echo ""
        info "Selected profiles based on your configuration: ${SELECTED_PROFILES[*]}"
    else
        for choice in $choices; do
            case $choice in
                1) SELECTED_PROFILES+=("proxy") ;;
                2) SELECTED_PROFILES+=("wireguard") ;;
                3) SELECTED_PROFILES+=("amneziawg") ;;
                4) SELECTED_PROFILES+=("dnstunnel") ;;
                5) SELECTED_PROFILES+=("trusttunnel") ;;
                6) SELECTED_PROFILES+=("xhttp") ;;
                7) SELECTED_PROFILES+=("telegram") ;;
                8) SELECTED_PROFILES+=("admin") ;;
                9) SELECTED_PROFILES+=("conduit") ;;
                10) SELECTED_PROFILES+=("snowflake") ;;
                11) SELECTED_PROFILES+=("monitoring") ;;
            esac
        done
    fi

    # DNS tunnels require sing-box (proxy profile) to forward traffic
    # Auto-add proxy if dnstunnel is selected but proxy isn't (only for start operations)
    if [[ "$mode" != "stop" ]] && [[ "$mode" != "restart" ]]; then
        local has_dnstunnel=false has_proxy=false
        for p in "${SELECTED_PROFILES[@]}"; do
            [[ "$p" == "dnstunnel" ]] && has_dnstunnel=true
            [[ "$p" == "proxy" ]] && has_proxy=true
        done
        if [[ "$has_dnstunnel" == "true" ]] && [[ "$has_proxy" == "false" ]]; then
            info "DNS tunnels require proxy services - auto-adding proxy profile"
            SELECTED_PROFILES+=("proxy")
        fi
    fi

    if [[ ${#SELECTED_PROFILES[@]} -eq 0 ]]; then
        warn "No profiles selected"
        return 1
    fi

    # Build profile string for docker compose
    SELECTED_PROFILE_STRING=""
    for p in "${SELECTED_PROFILES[@]}"; do
        SELECTED_PROFILE_STRING+="--profile $p "
    done

    # Save to .env if requested
    if [[ "$mode" == "save" ]]; then
        save_default_profiles
    fi

    return 0
}

# Save selected profiles to .env
save_default_profiles() {
    local profiles_str="${SELECTED_PROFILES[*]}"
    local env_file="$SCRIPT_DIR/.env"

    if [[ ! -f "$env_file" ]]; then
        warn "No .env file found, cannot save defaults"
        return 1
    fi

    # Update or add DEFAULT_PROFILES in .env (with quotes to handle spaces)
    if grep -q "^DEFAULT_PROFILES=" "$env_file" 2>/dev/null; then
        # Update existing line
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s/^DEFAULT_PROFILES=.*/DEFAULT_PROFILES=\"$profiles_str\"/" "$env_file"
        else
            sed -i "s/^DEFAULT_PROFILES=.*/DEFAULT_PROFILES=\"$profiles_str\"/" "$env_file"
        fi
    else
        # Add new line
        echo "" >> "$env_file"
        echo "# Default profiles for 'moav start'" >> "$env_file"
        echo "DEFAULT_PROFILES=\"$profiles_str\"" >> "$env_file"
    fi

    success "Saved default profiles: $profiles_str"
}

# Get default profiles from .env
get_default_profiles() {
    get_env_val "DEFAULT_PROFILES" "$SCRIPT_DIR/.env"
}

# Profile ↔ ENABLE_* mapping (issue #106) — Compose profiles don't know
# about MoaV's ENABLE_* flags. These helpers are the bridge.

# Is <profile> enabled in .env? Multi-flag profiles survive if any flag is on.
profile_enabled() {
    local profile="$1" env_file="${2:-$SCRIPT_DIR/.env}"
    case "$profile" in
        proxy)
            local _r _t _a _h _s
            _r=$(get_env_val "ENABLE_REALITY"   "$env_file" "true")
            _t=$(get_env_val "ENABLE_TROJAN"    "$env_file" "true")
            _a=$(get_env_val "ENABLE_ANYTLS"    "$env_file" "false")
            _h=$(get_env_val "ENABLE_HYSTERIA2" "$env_file" "true")
            _s=$(get_env_val "ENABLE_SS"        "$env_file" "true")
            [[ "$_r" == "true" || "$_t" == "true" || "$_a" == "true" || "$_h" == "true" || "$_s" == "true" ]] \
                && echo true || echo false ;;
        wireguard)   [[ "$(get_env_val "ENABLE_WIREGUARD"   "$env_file" "true")"  == "true" ]] && echo true || echo false ;;
        amneziawg)   [[ "$(get_env_val "ENABLE_AMNEZIAWG"   "$env_file" "true")"  == "true" ]] && echo true || echo false ;;
        dnstunnel)
            local _d _s _m _x
            _d=$(get_env_val "ENABLE_DNSTT"     "$env_file" "true")
            _s=$(get_env_val "ENABLE_SLIPSTREAM" "$env_file" "true")
            _m=$(get_env_val "ENABLE_MASTERDNS" "$env_file" "true")
            _x=$(get_env_val "ENABLE_XDNS"      "$env_file" "true")
            [[ "$_d" == "true" || "$_s" == "true" || "$_m" == "true" || "$_x" == "true" ]] \
                && echo true || echo false ;;
        trusttunnel) [[ "$(get_env_val "ENABLE_TRUSTTUNNEL" "$env_file" "true")"  == "true" ]] && echo true || echo false ;;
        xhttp)       [[ "$(get_env_val "ENABLE_XHTTP"       "$env_file" "true")"  == "true" ]] && echo true || echo false ;;
        telegram)    [[ "$(get_env_val "ENABLE_TELEMT"      "$env_file" "true")"  == "true" ]] && echo true || echo false ;;
        admin)       [[ "$(get_env_val "ENABLE_ADMIN_UI"    "$env_file" "true")"  == "true" ]] && echo true || echo false ;;
        conduit)     [[ "$(get_env_val "ENABLE_CONDUIT"     "$env_file" "true")"  == "true" ]] && echo true || echo false ;;
        snowflake)   [[ "$(get_env_val "ENABLE_SNOWFLAKE"   "$env_file" "true")"  == "true" ]] && echo true || echo false ;;
        gooserelay)  [[ "$(get_env_val "ENABLE_GOOSERELAY"  "$env_file" "false")" == "true" ]] && echo true || echo false ;;
        monitoring)
            # Opt-in via interactive prompt; explicit false drops, anything else passes.
            local _m=$(get_env_val "ENABLE_MONITORING" "$env_file" "")
            [[ "$_m" == "false" ]] && echo false || echo true ;;
        *) echo true ;;   # setup, client, all, unknown — pass through.
    esac
}

# Canonical space-separated list to write into DEFAULT_PROFILES.
derive_enabled_profiles() {
    local env_file="${1:-$SCRIPT_DIR/.env}"
    local out=()
    local p
    for p in proxy xhttp wireguard amneziawg dnstunnel trusttunnel telegram admin conduit snowflake gooserelay; do
        [[ "$(profile_enabled "$p" "$env_file")" == "true" ]] && out+=("$p")
    done
    echo "${out[*]}"
}

# Drop disabled profiles from $1; print one info line if anything dropped.
filter_disabled_profiles() {
    local profiles="$1" env_file="${2:-$SCRIPT_DIR/.env}"
    local kept=() dropped=()
    local p
    for p in $profiles; do
        if [[ "$(profile_enabled "$p" "$env_file")" == "true" ]]; then
            kept+=("$p")
        else
            dropped+=("$p")
        fi
    done
    if [[ ${#dropped[@]} -gt 0 ]]; then
        info "Skipping disabled profiles (set ENABLE_*=true in .env to enable): ${dropped[*]}" >&2
    fi
    echo "${kept[*]}"
}

# 3-option prompt for explicit `moav start <name>` when ENABLE_* is false.
# Echoes: start-and-enable | skip | start-once
confirm_disabled_profile() {
    local profile="$1" env_file="${2:-$SCRIPT_DIR/.env}"
    # Single-flag profiles can be auto-flipped; multi-flag (proxy/dnstunnel)
    # need the operator to pick which sub-flag to enable.
    local enable_var="" multi_flag_hint=""
    case "$profile" in
        wireguard)   enable_var="ENABLE_WIREGUARD" ;;
        amneziawg)   enable_var="ENABLE_AMNEZIAWG" ;;
        trusttunnel) enable_var="ENABLE_TRUSTTUNNEL" ;;
        xhttp)       enable_var="ENABLE_XHTTP" ;;
        telegram)    enable_var="ENABLE_TELEMT" ;;
        admin)       enable_var="ENABLE_ADMIN_UI" ;;
        conduit)     enable_var="ENABLE_CONDUIT" ;;
        snowflake)   enable_var="ENABLE_SNOWFLAKE" ;;
        gooserelay)  enable_var="ENABLE_GOOSERELAY" ;;
        monitoring)  enable_var="ENABLE_MONITORING" ;;
        proxy)       multi_flag_hint="ENABLE_REALITY, ENABLE_TROJAN, ENABLE_ANYTLS, ENABLE_HYSTERIA2, ENABLE_SS" ;;
        dnstunnel)   multi_flag_hint="ENABLE_DNSTT, ENABLE_SLIPSTREAM, ENABLE_MASTERDNS, ENABLE_XDNS" ;;
    esac

    echo "" >&2
    warn "Profile '$profile' is disabled in .env." >&2
    echo "" >&2
    echo -e "  ${WHITE}What would you like to do?${NC}" >&2
    if [[ -n "$enable_var" ]]; then
        echo "    1) Enable + start  — set ${enable_var}=true in .env and start now (persists)" >&2
    else
        echo "    1) Enable manually — '$profile' covers $multi_flag_hint;" >&2
        echo "                          set one to true in .env, then re-run" >&2
    fi
    echo "    2) Skip            — don't start; leave .env unchanged" >&2
    echo "    3) Start once      — start now without touching .env (won't auto-start next time)" >&2
    echo "" >&2

    local choice=""
    if [[ ! -t 0 ]]; then
        info "Non-interactive shell, skipping '$profile'." >&2
        echo "skip"
        return 0
    fi
    read -p "  Choice [1/2/3] (default 2): " choice >&2
    case "$choice" in
        1)
            if [[ -z "$enable_var" ]]; then
                # Multi-flag — can't auto-flip. Direct the operator and skip
                # (don't silently fall through to start-once; they explicitly
                # asked for the persistent path).
                warn "Skipping — flip one of [$multi_flag_hint] in .env, then re-run." >&2
                echo "skip"
                return 0
            fi
            update_env_var "$env_file" "$enable_var" "true"
            success "Set ${enable_var}=true in .env" >&2
            echo "start-and-enable"
            ;;
        3)
            echo "start-once"
            ;;
        *)
            echo "skip"
            ;;
    esac
}

# Ensure CLASH_API_SECRET is set in .env for monitoring
# This is needed for clash-exporter to authenticate with sing-box Clash API
# Returns: 0 = continue, 1 = skip monitoring (user declined when using 'all' profile)
# Materialize the Conduit lifetime recording-rules file before Prometheus
# bind-mounts it. The live file is gitignored and runtime-rewritten by
# update-conduit-offsets.sh (it bakes in the per-install OFFSET values), so the
# repo ships a committed `.template` (offsets at 0) and we copy it into place on
# first monitoring start. Never clobber an existing file — it holds the
# operator's banked offsets.
ensure_conduit_lifetime_rules() {
    local rules="$SCRIPT_DIR/configs/monitoring/conduit_lifetime.rules.yml"
    local template="${rules}.template"
    if [[ ! -f "$rules" && -f "$template" ]]; then
        cp "$template" "$rules"
    fi
}

# Same reachability story for the bind-mounted bundle tree: the admin
# entrypoint repairs it on every admin restart, but installs without a running
# admin keep 777 bundles from the old chmod. Host-side, effective as root; a
# non-root operator's silent failure is fine (the admin entrypoint covers it).
# Inlined rather than shared with scripts/lib/common.sh grant_admin_rw -- the
# host CLI and the container provisioning tree are deliberately separate.
repair_bundle_perms() {
    local p
    for p in "$SCRIPT_DIR/outputs/bundles" "$SCRIPT_DIR/state/users"; do
        [[ -d "$p" ]] || continue
        chown -R 2000:2000 "$p" 2>/dev/null || true
        chmod -R ug+rwX,o-rwx "$p" 2>/dev/null || true
    done
    # configs: owner root — wireguard/amneziawg/telemt/xray run cap_drop ALL
    # without DAC_OVERRIDE, so their in-container root reads only as owner; the
    # admin app writes via group 2000. Running this before compose up closes
    # the window where a container reads its config before the admin
    # entrypoint's own repair lands.
    # wireguard/amneziawg: container-root consumers, fully locked. sing-box,
    # xray, telemt, trusttunnel run non-root daemons that must keep world-read.
    for p in wireguard amneziawg; do
        [[ -d "$SCRIPT_DIR/configs/$p" ]] || continue
        chown -R 0:2000 "$SCRIPT_DIR/configs/$p" 2>/dev/null || true
        chmod -R ug+rwX,o-rwx "$SCRIPT_DIR/configs/$p" 2>/dev/null || true
    done
    for p in sing-box xray trusttunnel telemt; do
        [[ -d "$SCRIPT_DIR/configs/$p" ]] || continue
        chown -R 0:2000 "$SCRIPT_DIR/configs/$p" 2>/dev/null || true
        chmod -R ug+rwX,o+rX,o-w "$SCRIPT_DIR/configs/$p" 2>/dev/null || true
    done
}

# Tighten private key material in the state volume to 0600. The equivalent call
# in bootstrap.sh is unreachable for already-bootstrapped installs (the
# .bootstrapped guard exits first), so upgrades never got the rc.2 perms repair.
# Runs on every start: idempotent, one alpine one-shot, mirrors
# secure_state_keys' public-file skips.
repair_state_key_perms() {
    # Ownership too, not just mode: live installs carry keys owned by old
    # per-container uids (999 from the v1 dnstt image on a real server), which
    # a cap_drop-ALL container root cannot read once 0600. The three keys read
    # directly by non-root daemons (dnstt/masterdns/slipstream run USER moav)
    # stay 644 — inside the volume, the mount boundary is the control.
    docker run --rm -v moav_moav_state:/state alpine sh -c '
        [ -d /state/keys ] || exit 0
        chown 0:0 /state/keys 2>/dev/null || true
        cd /state/keys 2>/dev/null || exit 0
        for f in *; do
            [ -f "$f" ] || continue
            chown 0:0 "$f" 2>/dev/null || true
            case "$f" in
                *.pub|*.pub.hex|*-cert.pem|*.crt|*.csr) chmod 644 "$f"; continue ;;
                dnstt-server.key.hex|masterdns-encrypt.key|slipstream-key.pem) chmod 644 "$f"; continue ;;
            esac
            chmod 600 "$f"
        done' 2>/dev/null || true
}

ensure_clash_api_secret() {
    local profiles="$1"
    local env_file="$SCRIPT_DIR/.env"

    # Only needed if monitoring or all profile is being started
    if ! echo "$profiles" | grep -qE "monitoring|all"; then
        return 0
    fi

    # Make sure Prometheus has its Conduit rules file to mount (gitignored +
    # runtime-generated, so it may be absent on a fresh checkout).
    ensure_conduit_lifetime_rules

    # Check if ENABLE_MONITORING is explicitly set to false
    local enable_monitoring
    enable_monitoring=$(get_env_val "ENABLE_MONITORING" "$env_file" "")
    if [[ "$enable_monitoring" == "false" ]]; then
        echo ""
        warn "Monitoring is currently disabled in .env (ENABLE_MONITORING=false)"
        if confirm "Enable monitoring?" "$(monitoring_default_for_ram)"; then
            update_env_var "$env_file" "ENABLE_MONITORING" "true"
            success "ENABLE_MONITORING set to true"
        else
            info "Skipping monitoring. Starting other services..."
            return 1  # Signal caller to skip monitoring
        fi
    fi

    # Check if CLASH_API_SECRET is already set in .env (non-empty)
    # get_env_val keeps a secret containing '=' intact (cut -f2- vs -f2).
    local current_secret
    current_secret=$(get_env_val "CLASH_API_SECRET" "$env_file")

    # Get the authoritative secret from state volume (source of truth from bootstrap)
    local state_secret
    state_secret=$(docker run --rm -v moav_moav_state:/state alpine cat /state/keys/clash-api.env 2>/dev/null | grep "^CLASH_API_SECRET=" | cut -d'=' -f2 || true)

    # If .env matches state, we're good
    if [[ -n "$current_secret" ]] && [[ "$current_secret" == "$state_secret" ]]; then
        return 0  # Already configured and in sync
    fi

    # If .env has a value but it doesn't match state, it's stale
    if [[ -n "$current_secret" ]] && [[ -n "$state_secret" ]] && [[ "$current_secret" != "$state_secret" ]]; then
        warn "CLASH_API_SECRET in .env doesn't match state volume (stale after re-bootstrap)"
        info "Syncing CLASH_API_SECRET from state volume..."
        sed -i.bak "s/^CLASH_API_SECRET=.*/CLASH_API_SECRET=$state_secret/" "$env_file"
        rm -f "$env_file.bak"
        success "CLASH_API_SECRET synced"
        return 0
    fi

    # .env is empty — first-time monitoring setup
    # If using 'all' profile, ask user if they want to enable monitoring (requires 2GB RAM)
    # Skip if user already confirmed monitoring above (ENABLE_MONITORING was false -> set to true)
    if [[ -z "$current_secret" ]] && [[ "$enable_monitoring" != "false" ]]; then
        if echo "$profiles" | grep -qE "\ball\b|--profile all"; then
            echo ""
            warn "Monitoring requires at least 2GB RAM to run properly."
            echo "  The monitoring stack includes Grafana, Prometheus, and exporters."
            echo ""
            if ! confirm "Enable monitoring? (You can start it later with 'moav start monitoring')" "n"; then
                info "Skipping monitoring. Starting other services..."
                return 1  # Signal caller to skip monitoring
            fi
        fi
    fi

    # Try to use state secret, fall back to sing-box config
    local secret="$state_secret"
    if [[ -z "$secret" ]]; then
        # Try to extract from existing sing-box config.json
        if [[ -f "$SCRIPT_DIR/configs/sing-box/config.json" ]]; then
            secret=$(grep -o '"secret"[[:space:]]*:[[:space:]]*"[^"]*"' "$SCRIPT_DIR/configs/sing-box/config.json" 2>/dev/null | head -1 | sed 's/.*"\([^"]*\)"$/\1/' || true)
        fi
    fi

    if [[ -n "$secret" ]]; then
        info "Configuring CLASH_API_SECRET for monitoring..."
        # Update .env file
        if grep -q "^CLASH_API_SECRET=" "$env_file" 2>/dev/null; then
            sed -i.bak "s/^CLASH_API_SECRET=.*/CLASH_API_SECRET=$secret/" "$env_file"
            rm -f "$env_file.bak"
        else
            # Append to file
            echo "" >> "$env_file"
            echo "# Clash API secret for monitoring (auto-configured)" >> "$env_file"
            echo "CLASH_API_SECRET=$secret" >> "$env_file"
        fi
        success "CLASH_API_SECRET configured"
    else
        warn "Could not find CLASH_API_SECRET. Clash exporter may not authenticate properly."
        echo "  If sing-box metrics show empty, run: moav bootstrap"
    fi
    return 0
}

start_services() {
    # Use the unified service selection menu
    SELECTED_PROFILE_STRING=""
    local ret=0
    select_profiles "start" || ret=$?
    [[ $ret -eq 2 ]] && return 2  # User chose "Back"
    [[ $ret -ne 0 ]] && return 1

    local profiles="$SELECTED_PROFILE_STRING"
    if [[ -z "$profiles" ]]; then
        warn "No profiles selected"
        return 1
    fi

    # Check if bootstrap has been run
    if ! check_bootstrap; then
        warn "Bootstrap has not been run yet!"
        echo ""
        info "Bootstrap is required for first-time setup."
        echo ""

        if confirm "Run bootstrap now?" "y"; then
            run_bootstrap || return 1
            echo ""
        else
            warn "Cannot start services without bootstrap."
            return 1
        fi
    fi

    repair_state_key_perms
    repair_bundle_perms

    # Ensure CLASH_API_SECRET is configured for monitoring
    # Returns 1 if user declined monitoring when using 'all' profile
    local skip_monitoring=0
    ensure_clash_api_secret "$profiles" || skip_monitoring=1
    if [[ $skip_monitoring -eq 1 ]]; then
        # User declined monitoring — replace 'all' with derived enabled set (issue #106).
        local _enabled
        _enabled=$(derive_enabled_profiles "$SCRIPT_DIR/.env")
        profiles=""
        local _p
        for _p in $_enabled; do
            profiles+="--profile $_p "
        done
    fi

    echo ""
    info "Building containers (if needed)..."

    local cmd="docker compose $profiles up -d --remove-orphans"

    if run_command "$cmd" "Starting services"; then
        echo ""
        success "Services started!"
        echo ""
        # Show admin URL if admin was started
        if echo "$profiles" | grep -qE "admin|all"; then
            echo -e "  ${CYAN}Admin Dashboard:${NC} $(get_admin_url)"
        fi
        # Show Grafana URL if monitoring was started
        if echo "$profiles" | grep -qE "monitoring|all"; then
            echo -e "  ${CYAN}Grafana:${NC}         $(get_grafana_url)"
            local grafana_cdn=$(get_grafana_cdn_url)
            if [[ -n "$grafana_cdn" ]]; then
                echo -e "  ${CYAN}Grafana (CDN):${NC}   $grafana_cdn"
            fi
        fi

        if echo "$profiles" | grep -qE "admin|monitoring|all"; then
            echo ""
        fi
        show_log_help
        echo ""
        print_community_links
    fi
}

stop_services() {
    # Check if any services are running
    local running_services
    running_services=$(docker compose ps --services --filter "status=running" 2>/dev/null | sort)

    if [[ -z "$running_services" ]]; then
        print_section "Stop Services"
        warn "No services are currently running"
        return 0
    fi

    # Use the unified service selection menu
    SELECTED_PROFILE_STRING=""
    local ret=0
    select_profiles "stop" || ret=$?
    [[ $ret -eq 2 ]] && return 2  # User chose "Back"
    [[ $ret -ne 0 ]] && return 1

    local profiles="$SELECTED_PROFILE_STRING"
    if [[ -z "$profiles" ]]; then
        warn "No profiles selected"
        return 1
    fi

    echo ""
    info "Stopping services..."

    if [[ "$profiles" == "--profile all" ]]; then
        docker compose --profile all stop
    else
        # Stop each selected profile
        docker compose $profiles stop
    fi

    success "Services stopped!"
}

restart_services() {
    # Check if any services are running
    local running_services
    running_services=$(docker compose ps --services --filter "status=running" 2>/dev/null | sort)

    if [[ -z "$running_services" ]]; then
        print_section "Restart Services"
        warn "No services are currently running"
        return 0
    fi

    # Use the unified service selection menu
    SELECTED_PROFILE_STRING=""
    local ret=0
    select_profiles "restart" || ret=$?
    [[ $ret -eq 2 ]] && return 2  # User chose "Back"
    [[ $ret -ne 0 ]] && return 1

    local profiles="$SELECTED_PROFILE_STRING"
    if [[ -z "$profiles" ]]; then
        warn "No profiles selected"
        return 1
    fi

    echo ""
    info "Restarting services..."

    if [[ "$profiles" == "--profile all" ]]; then
        docker compose --profile all restart
    else
        docker compose $profiles restart
    fi

    success "Services restarted!"
}

# Format Docker timestamps from ISO to readable format
# 2026-02-04T20:17:10.426340440Z -> 2026-02-04 20:17:10
format_log_timestamps() {
    sed -u 's/\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)T\([0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}\)\.[0-9]*Z/\1 \2/g'
}

view_logs() {
    local log_interrupted=false

    while true; do
        log_interrupted=false
        print_section "View Logs"

        # Get all services (running or not)
        local all_services
        all_services=$(docker compose ps --services -a 2>/dev/null | sort)

        echo "Options:"
        echo ""
        echo -e "  ${WHITE}a)${NC} All services (follow)"
        echo -e "  ${WHITE}t)${NC} Last 100 lines + follow (all services)"

        if [[ -n "$all_services" ]]; then
            echo ""
            local i=1
            local services_array=()
            while IFS= read -r svc; do
                [[ -z "$svc" ]] && continue
                services_array+=("$svc")
                echo -e "  ${WHITE}$i)${NC} $svc"
                ((i++))
            done <<< "$all_services"
        fi

        echo ""
        echo -e "  ${WHITE}0)${NC} Back to main menu"
        echo ""

        prompt "Choice: "
        read -r choice < /dev/tty 2>/dev/null || choice=""

        case $choice in
            a|A)
                echo ""
                info "Showing logs for all services. Press Ctrl+C to return to menu."
                echo ""
                # Trap SIGINT to return to menu instead of exiting
                trap 'log_interrupted=true' INT
                docker compose --ansi always --profile all logs -t -f 2>/dev/null | format_log_timestamps || true
                trap - INT
                [[ "$log_interrupted" == "true" ]] && echo "" && info "Returning to log menu..."
                ;;
            t|T)
                echo ""
                info "Showing last 100 lines + follow. Press Ctrl+C to return to menu."
                echo ""
                trap 'log_interrupted=true' INT
                docker compose --ansi always --profile all logs -t --tail=100 -f 2>/dev/null | format_log_timestamps || true
                trap - INT
                [[ "$log_interrupted" == "true" ]] && echo "" && info "Returning to log menu..."
                ;;
            0|"")
                return 0
                ;;
            [1-9]*)
                local idx=$((choice - 1))
                if [[ $idx -ge 0 && $idx -lt ${#services_array[@]} ]]; then
                    local service="${services_array[$idx]}"
                    echo ""
                    info "Showing logs for $service. Press Ctrl+C to return to menu."
                    echo ""
                    # Trap SIGINT to return to menu instead of exiting
                    trap 'log_interrupted=true' INT
                    docker compose --ansi always logs -t -f "$service" 2>/dev/null | format_log_timestamps || true
                    trap - INT
                    [[ "$log_interrupted" == "true" ]] && echo "" && info "Returning to log menu..."
                else
                    warn "Invalid choice"
                fi
                ;;
            *)
                warn "Invalid choice"
                ;;
        esac
    done
}

show_log_help() {
    echo -e "${CYAN}Log Commands:${NC}"
    echo "  • View all logs:      docker compose logs -t -f"
    echo "  • View service logs:  docker compose logs -t -f sing-box"
    echo "  • Last 100 lines:     docker compose logs -t --tail=100"
    echo ""
    echo -e "${CYAN}Useful Commands:${NC}"
    echo "  • Check status:       docker compose ps"
    echo "  • Stop all:           docker compose --profile all stop"
    echo "  • Restart service:    docker compose restart sing-box"
}

cmd_profiles() {
    print_header

    print_section "Default Profiles"

    local current
    current=$(get_default_profiles)

    echo ""
    if [[ -n "$current" ]]; then
        echo -e "  Current defaults: ${GREEN}${current}${NC}"
        echo ""
        echo -e "  These profiles will start when you run ${CYAN}moav start${NC} without arguments."
    else
        echo -e "  ${YELLOW}No default profiles set${NC}"
        echo ""
        echo -e "  Running ${CYAN}moav start${NC} will start ${WHITE}all${NC} services."
    fi
    echo ""

    if confirm "Change default profiles?" "y"; then
        echo ""
        if select_profiles "save"; then
            echo ""
            if confirm "Build selected services now?" "n"; then
                info "Building..."
                compose_build $SELECTED_PROFILE_STRING build
                success "Build complete!"
            fi
        fi
    fi
}

cmd_start() {
    local profiles=""
    local valid_profiles="proxy wireguard amneziawg dnstunnel trusttunnel xhttp telegram admin conduit snowflake gooserelay monitoring client all setup"
    local force=false
    local args=()
    for arg in "$@"; do
        case "$arg" in
            --force|-f) force=true ;;
            *) args+=("$arg") ;;
        esac
    done
    set -- "${args[@]}"

    if [[ $# -eq 0 ]]; then
        # No arguments - check for DEFAULT_PROFILES in .env
        local defaults
        defaults=$(get_default_profiles)
        if [[ -n "$defaults" ]]; then
            # Drop stale entries whose ENABLE_* has since been flipped off (issue #106).
            local _filtered
            _filtered=$(filter_disabled_profiles "$defaults")
            if [[ "$_filtered" != "$defaults" ]]; then
                info "Using default profiles from .env: $_filtered"
            else
                info "Using default profiles from .env: $defaults"
            fi
            if [[ -z "$_filtered" ]]; then
                error "Every profile in DEFAULT_PROFILES is disabled in .env. Set at least one ENABLE_*=true or edit DEFAULT_PROFILES."
                return 1
            fi
            for p in $_filtered; do
                profiles+="--profile $p "
            done
        else
            # No defaults set - show interactive menu
            select_profiles "start"
            if [[ ${#SELECTED_PROFILES[@]} -eq 0 ]]; then
                info "No services selected"
                return 0
            fi
            for p in "${SELECTED_PROFILES[@]}"; do
                profiles+="--profile $p "
            done
        fi
    else
        local individual_services=""
        for p in "$@"; do
            # Resolve profile aliases (e.g., sing-box -> proxy)
            local resolved
            resolved=$(resolve_profile "$p")

            # `all` → expand to the ENABLE_*-derived enabled set (issue #106);
            # the `all` profile membership stays for build/logs/down enumeration.
            if [[ "$resolved" == "all" ]]; then
                local _all_expanded
                _all_expanded=$(derive_enabled_profiles "$SCRIPT_DIR/.env")
                if [[ -z "$_all_expanded" ]]; then
                    error "'all' resolved to an empty profile list — every ENABLE_* is false in .env."
                    return 1
                fi
                info "Expanding 'all' to enabled profiles: $_all_expanded"
                local _ap
                for _ap in $_all_expanded; do
                    profiles+="--profile $_ap "
                done
                continue
            fi

            # Check if it's a valid profile
            if echo "$valid_profiles" | grep -qw "$resolved"; then
                # Explicit name + ENABLE_*=false → 3-option prompt (--force bypasses).
                if ! $force && [[ "$(profile_enabled "$resolved" "$SCRIPT_DIR/.env")" != "true" ]]; then
                    local _decision
                    _decision=$(confirm_disabled_profile "$resolved" "$SCRIPT_DIR/.env")
                    case "$_decision" in
                        skip)
                            info "Skipped: $resolved"
                            continue
                            ;;
                        start-once|start-and-enable) ;;
                    esac
                fi
                profiles+="--profile $resolved "
            else
                # Try resolving as individual service name
                local svc
                svc=$(resolve_service "$p")
                individual_services+="$svc "
            fi
        done

        # If we have individual services but no profiles, figure out which profiles they need
        if [[ -n "$individual_services" ]] && [[ -z "$profiles" ]]; then
            info "Starting individual services: $individual_services"
            docker compose --profile all up -d $individual_services
            success "Services started!"
            auto_setup_conduit_offsets
            auto_setup_cert_renew
            echo ""
            print_community_links
            return 0
        elif [[ -n "$individual_services" ]]; then
            warn "Ignoring individual services ($individual_services) when mixed with profiles"
        fi
    fi

    if [[ -z "$profiles" ]]; then
        error "No service selected"
        echo "Valid profiles: $valid_profiles"
        echo "Aliases: sing-box/singbox/reality/trojan/hysteria→proxy, wg→wireguard, awg→amneziawg, dns/dnstt/slip→dnstunnel, grafana/prometheus→monitoring"
        exit 1
    fi

    # Check if bootstrap has been run (skip for setup profile)
    if [[ ! "$profiles" =~ "setup" ]] && ! check_bootstrap; then
        warn "Bootstrap has not been run yet!"
        echo ""
        info "Bootstrap is required for first-time setup."
        echo "  It generates keys, obtains TLS certificates, and creates users."
        echo ""

        if confirm "Run bootstrap now?" "y"; then
            run_bootstrap || exit 1
            echo ""
        else
            error "Cannot start services without bootstrap."
            echo "  Run 'moav bootstrap' first, or use 'moav' for interactive setup."
            exit 1
        fi
    fi

    repair_state_key_perms
    repair_bundle_perms

    # Ensure CLASH_API_SECRET is configured for monitoring
    # Returns 1 if user declined monitoring when using 'all' profile
    local skip_monitoring=0
    ensure_clash_api_secret "$profiles" || skip_monitoring=1
    if [[ $skip_monitoring -eq 1 ]]; then
        # User declined monitoring — replace 'all' with derived enabled set (issue #106).
        local _enabled_s
        _enabled_s=$(derive_enabled_profiles "$SCRIPT_DIR/.env")
        profiles=""
        local _ps
        for _ps in $_enabled_s; do
            profiles+="--profile $_ps "
        done
    fi

    # Check port 53 conflicts for DNS tunnels
    local dnstt_enabled
    dnstt_enabled=$(get_env_val "ENABLE_DNSTT" "$SCRIPT_DIR/.env" "true")
    local slipstream_enabled
    slipstream_enabled=$(get_env_val "ENABLE_SLIPSTREAM" "$SCRIPT_DIR/.env" "true")
    local xdns_start_enabled
    xdns_start_enabled=$(get_env_val "ENABLE_XDNS" "$SCRIPT_DIR/.env" "true")

    # Check if any DNS tunnel needs port 53 (all go through dns-router now)
    local needs_port53=false
    local masterdns_start_enabled
    masterdns_start_enabled=$(get_env_val "ENABLE_MASTERDNS" "$SCRIPT_DIR/.env" "true")
    if echo "$profiles" | grep -qE "dnstunnel|all" && \
       [[ "$dnstt_enabled" == "true" || "$slipstream_enabled" == "true" || \
          "$masterdns_start_enabled" == "true" || "$xdns_start_enabled" == "true" ]]; then
        needs_port53=true
    fi

    if $needs_port53; then
        if port53_conflict_detected; then
            handle_port53_conflict
        fi
    fi

    info "Starting services..."
    docker compose $profiles up -d --remove-orphans
    success "Services started!"
    echo ""
    # Show admin URL if admin was started
    if echo "$profiles" | grep -qE "admin|all"; then
        echo -e "  ${CYAN}Admin Dashboard:${NC} $(get_admin_url)"
    fi
    # Show Grafana URL if monitoring was started
    if echo "$profiles" | grep -qE "monitoring|all"; then
        echo -e "  ${CYAN}Grafana:${NC}         $(get_grafana_url)"
        local grafana_cdn=$(get_grafana_cdn_url)
        if [[ -n "$grafana_cdn" ]]; then
            echo -e "  ${CYAN}Grafana (CDN):${NC}   $grafana_cdn"
        fi
    fi
    # Show Conduit sharing hint if conduit was started
    if echo "$profiles" | grep -qE "conduit|all"; then
        echo -e "  ${CYAN}Psiphon Conduit:${NC} claim link, QR & sharing guide: moav conduit link"
    fi

    if echo "$profiles" | grep -qE "admin|monitoring|proxy|all"; then
        echo ""
    fi
    print_community_links
    auto_setup_conduit_offsets
    auto_setup_cert_renew
}

# Resolve profile name aliases to actual docker-compose profile names
resolve_profile() {
    local profile="$1"
    case "$profile" in
        sing-box|singbox|sing|reality|trojan|hysteria|hysteria2|hy2)
            echo "proxy" ;;
        wg)
            echo "wireguard" ;;
        awg)
            echo "amneziawg" ;;
        dns|dnstt|slip|slipstream)
            echo "dnstunnel" ;;
        tg|mtproxy|telemt)
            echo "telegram" ;;
        xh|xray)
            echo "xhttp" ;;
        psiphon)
            echo "conduit" ;;
        grafana|grafana-proxy|grafana-cdn|prometheus|metrics)
            echo "monitoring" ;;
        *)
            echo "$profile" ;;
    esac
}

# Resolve service name aliases to actual docker-compose service names
resolve_service() {
    local svc="$1"
    case "$svc" in
        conduit|psiphon)              echo "psiphon-conduit" ;;
        singbox|sing|proxy|reality)   echo "sing-box" ;;
        ss|shadowsocks|outline)       echo "sing-box" ;;
        wg)                           echo "wireguard" ;;
        ws|tunnel)                    echo "wstunnel" ;;
        dns)                          echo "dnstt" ;;
        slip)                         echo "slipstream" ;;
        mdns|masterdns)               echo "masterdns" ;;
        goose|gooserelay|relay)       echo "gooserelay" ;;
        dns-router|dnsrouter)         echo "dns-router" ;;
        tg|mtproxy|telegram)          echo "telemt" ;;
        snow|tor)                     echo "snowflake" ;;
        # Monitoring services (pass through or resolve aliases)
        grafana-cdn)                  echo "grafana-proxy" ;;
        grafana|grafana-proxy|prometheus|cadvisor|node-exporter|clash-exporter|wireguard-exporter|snowflake-exporter|singbox-exporter)
            echo "$svc" ;;
        *)                            echo "$svc" ;;
    esac
}

# Resolve multiple service arguments
resolve_services() {
    local resolved=()
    for svc in "$@"; do
        resolved+=("$(resolve_service "$svc")")
    done
    echo "${resolved[@]}"
}

cmd_stop() {
    local remove_containers=false
    local args=()

    # Parse flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --remove|-r)
                remove_containers=true
                shift
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done

    if [[ ${#args[@]} -eq 0 ]] || [[ "${args[0]}" == "all" ]]; then
        if [[ "$remove_containers" == "true" ]]; then
            info "Stopping and removing all containers..."
            docker compose --profile all down
            success "All services stopped and removed!"
        else
            info "Stopping all services..."
            docker compose --profile all stop
            success "All services stopped!"
        fi
    else
        # Only treat as profile if it's an exact profile name
        # Service names like "grafana", "prometheus" stop just that service
        local profiles="proxy wireguard amneziawg dnstunnel trusttunnel admin conduit snowflake monitoring telegram"
        local profile_match=""
        for p in $profiles; do
            if [[ "${args[0]}" == "$p" ]]; then
                profile_match="$p"
                break
            fi
        done

        if [[ -n "$profile_match" ]]; then
            if [[ "$remove_containers" == "true" ]]; then
                info "Stopping and removing $profile_match profile..."
                docker compose --profile "$profile_match" down
            else
                info "Stopping $profile_match profile..."
                docker compose --profile "$profile_match" stop
            fi
            success "Profile $profile_match stopped!"
        else
            local services
            services=$(resolve_services "${args[@]}")
            if [[ -z "$services" ]]; then
                error "No valid services to stop"
                return 1
            fi
            if [[ "$remove_containers" == "true" ]]; then
                info "Stopping and removing: $services"
                docker compose rm -sf $services
            else
                info "Stopping: $services"
                docker compose stop $services
            fi
            success "Services stopped!"
        fi
    fi
}

cmd_restart() {
    if [[ $# -eq 0 ]] || [[ "$1" == "all" ]]; then
        info "Restarting all services..."
        docker compose --profile all restart
        success "All services restarted!"
    elif [[ $# -eq 1 ]]; then
        # Single argument - only treat as profile if it's an exact profile name
        # Service names like "grafana", "prometheus", "telemt" restart just that service
        local profiles="proxy wireguard amneziawg dnstunnel trusttunnel admin conduit snowflake monitoring telegram"
        local profile_match=""
        for p in $profiles; do
            if [[ "$1" == "$p" ]]; then
                profile_match="$p"
                break
            fi
        done

        if [[ -n "$profile_match" ]]; then
            info "Restarting $profile_match profile services..."
            docker compose --profile "$profile_match" restart
            success "Profile $profile_match restarted!"
        else
            local services
            services=$(resolve_services "$@")
            if [[ -z "$services" ]]; then
                error "No valid services to restart"
                return 1
            fi
            info "Restarting: $services"
            docker compose restart $services
            success "Services restarted!"
        fi
    else
        # Multiple arguments - resolve all as service names
        local services
        services=$(resolve_services "$@")
        if [[ -z "$services" ]]; then
            error "No valid services to restart"
            return 1
        fi
        info "Restarting: $services"
        docker compose restart $services
        success "Services restarted!"
    fi
}

cmd_status() {
    # Simple header without clearing terminal
    local singbox_ver wstunnel_ver conduit_ver branch
    singbox_ver=$(get_component_version "SINGBOX_VERSION" "1.13.12")
    wstunnel_ver=$(get_component_version "WSTUNNEL_VERSION" "10.6.1")
    conduit_ver=$(get_component_version "CONDUIT_VERSION" "1.2.0")
    branch=$(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

    local version_str="v${VERSION}"
    if [[ -n "$branch" && "$branch" != "main" ]]; then
        version_str="v${VERSION} (${branch})"
    fi

    echo ""
    echo -e "${CYAN}MoaV${NC} ${version_str}  ${DIM}│${NC}  ${DIM}sing-box ${singbox_ver}  wstunnel ${wstunnel_ver}  conduit ${conduit_ver}${NC}"
    echo -e "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    show_status

    # Show admin and grafana URLs if running
    local running=$(get_running_services)
    local show_urls=0
    if echo "$running" | grep -q "admin"; then
        [[ $show_urls -eq 0 ]] && echo ""
        echo -e "  ${CYAN}Admin Dashboard:${NC} $(get_admin_url)"
        show_urls=1
    fi
    if echo "$running" | grep -q "grafana"; then
        [[ $show_urls -eq 0 ]] && echo ""
        echo -e "  ${CYAN}Grafana:${NC}         $(get_grafana_url)"
        local grafana_cdn=$(get_grafana_cdn_url)
        if [[ -n "$grafana_cdn" ]]; then
            echo -e "  ${CYAN}Grafana (CDN):${NC}   $grafana_cdn"
        fi
        show_urls=1
    fi


    # Show default profiles
    local defaults
    defaults=$(get_default_profiles)
    if [[ -n "$defaults" ]]; then
        info "Default profiles: ${WHITE}$defaults${NC}"
    fi
    echo ""
    echo -e "  ${CYAN}Commands:${NC} moav logs [service] | moav stop | moav restart | moav version"
}

cmd_logs() {
    local follow=true
    local tail_lines=100
    local services_to_log=""
    local profile_flags=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-follow|-n)
                follow=false
                shift
                ;;
            --tail=*)
                tail_lines="${1#*=}"
                shift
                ;;
            --tail)
                # Without the guard, `moav logs --tail` (no value) dies on the
                # bare "$2" with "$2: unbound variable" and no usage hint.
                if [[ $# -lt 2 ]]; then
                    error "--tail requires a value (e.g. --tail 100)"
                    return 1
                fi
                tail_lines="$2"
                shift 2
                ;;
            all)
                profile_flags="--profile all"
                shift
                ;;
            *)
                # Check if it's an exact profile name first
                local valid_profiles="proxy wireguard amneziawg dnstunnel trusttunnel xhttp telegram admin conduit snowflake gooserelay monitoring client all setup"
                if echo "$valid_profiles" | grep -qw "$1"; then
                    profile_flags="$profile_flags --profile $1"
                else
                    # Treat as service name (resolve aliases like slip → slipstream, tg → telemt)
                    local resolved_svc
                    resolved_svc=$(resolve_service "$1")
                    services_to_log="${services_to_log:+$services_to_log }$resolved_svc"
                fi
                shift
                ;;
        esac
    done

    # Build docker compose command
    local cmd="docker compose --ansi always"
    if [[ -z "$services_to_log" && -z "$profile_flags" ]]; then
        cmd="$cmd --profile all"
    elif [[ -n "$profile_flags" ]]; then
        cmd="$cmd $profile_flags"
    fi
    cmd="$cmd logs -t --tail $tail_lines"

    if [[ "$follow" == "true" ]]; then
        echo -e "${CYAN}Following logs (Ctrl+C to exit)...${NC}"
        echo ""
        $cmd -f $services_to_log | format_log_timestamps
    else
        $cmd $services_to_log | format_log_timestamps
    fi
}
