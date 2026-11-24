#!/bin/bash
# lib/dns.sh — DNS for the DNS-tunnel protocols: port-53 conflict detection and
# resolution, the DNS-tunnel registry (declarative metadata for the tunnels that
# share port 53), `moav switch-dns`, `moav setup-dns`, and zone-file generation.
#
# Sourced by moav.sh after lib/common.sh. Callers live in the dispatcher, the
# interactive menu and the start path.
#
# Definitions only — nothing here runs at source time.

port53_conflict_detected() {
    local listeners=""
    listeners=$(ss -H -ulnp 'sport = :53' 2>/dev/null || true)

    if [[ -z "$listeners" ]] && command -v netstat >/dev/null 2>&1; then
        listeners=$(netstat -ulnp 2>/dev/null | awk '$4 ~ /:53$/ {print}' || true)
    fi

    [[ -z "$listeners" ]] && return 1

    # If the current MoaV dns-router is already running, Docker's userland proxy
    # owns host port 53 on its behalf. That is expected during bootstrap/start.
    if echo "$listeners" | grep -q 'docker-proxy'; then
        local dns_router_container
        dns_router_container=$(docker compose -f "$SCRIPT_DIR/docker-compose.yml" ps -q dns-router 2>/dev/null || true)
        if [[ -n "$dns_router_container" ]]; then
            local non_docker_listeners
            non_docker_listeners=$(echo "$listeners" | grep -v 'docker-proxy' || true)
            [[ -z "$non_docker_listeners" ]] && return 1
        fi
    fi

    return 0
}

handle_port53_conflict() {
    echo ""
    warn "Port 53 is in use by another process"
    echo "  DNS tunnels (dnstt/Slipstream/MasterDNS/XDNS) require port 53 to be free."
    echo ""

    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        if confirm "Disable systemd-resolved and configure direct DNS?" "y"; then
            setup_dns_for_dnstt
        else
            warn "DNS tunnels may not work until port 53 is freed."
            echo "  Run 'moav setup-dns' later to fix this."
        fi
    else
        warn "DNS tunnels may not work until port 53 is freed."
        echo "  Stop the service using port 53, then run 'moav start' again."
    fi
}

check_dns_for_dnstunnel() {
    # Check if any DNS tunnel protocol needs port 53
    local needs_port53=false
    local env_file="$SCRIPT_DIR/.env"

    # Check if dnstunnel profile is selected AND dnstt/slipstream are enabled
    local has_dnstunnel=false
    local has_xhttp=false
    for p in "${SELECTED_PROFILES[@]}"; do
        if [[ "$p" == "dnstunnel" || "$p" == "all" ]]; then
            has_dnstunnel=true
        fi
        if [[ "$p" == "xhttp" || "$p" == "all" ]]; then
            has_xhttp=true
        fi
    done

    local dnstt_enabled=$(get_env_val "ENABLE_DNSTT" "$env_file" "true")
    local slip_enabled=$(get_env_val "ENABLE_SLIPSTREAM" "$env_file" "false")
    local xdns_enabled=$(get_env_val "ENABLE_XDNS" "$env_file" "true")
    local masterdns_enabled=$(get_env_val "ENABLE_MASTERDNS" "$env_file" "true")

    # All DNS tunnels now coexist via dns-router on port 53 — no mutual exclusion needed.

    # Determine if port 53 is needed (any tunnel enabled with the dnstunnel profile)
    if $has_dnstunnel && [[ "$dnstt_enabled" == "true" || "$slip_enabled" == "true" || "$masterdns_enabled" == "true" || "$xdns_enabled" == "true" ]]; then
        needs_port53=true
    fi

    if ! $needs_port53; then
        return 0
    fi

    # Check if port 53 is in use by a non-MoaV listener.
    if port53_conflict_detected; then
        handle_port53_conflict
    fi
}

# =============================================================================
# DNS Tunnel Registry
# =============================================================================
# Declarative metadata for DNS tunnels sharing port 53. Used by:
#   - cmd_switch_dns      (enable/disable individual tunnel daemons)
#   - cmd_start           (port 53 availability check)
#   - doctor_check_conflicts  (detect runtime anomalies)
# To add a new DNS tunnel: append its name here + add a case branch in dns_tunnel_field.

DNS_TUNNELS=("xdns" "dnstt" "slipstream" "masterdns")

# Field lookup: dns_tunnel_field <name> <field>
# Fields: enable_var, port_var, default_port, services, profile, port_group, desc
# port_group: tunnels in the SAME group can coexist on port 53 (e.g. via dns-router
# multiplexing). All four tunnels are now in the "dns-router" group, meaning they
# can all run simultaneously — dns-router fans queries by subdomain suffix.
dns_tunnel_field() {
    local name="$1" field="$2"
    case "$name:$field" in
        xdns:enable_var)    echo "ENABLE_XDNS" ;;
        xdns:port_var)      echo "PORT_XDNS" ;;
        xdns:default_port)  echo "5356" ;;
        xdns:services)      echo "xray dns-router" ;;
        xdns:profile)       echo "dnstunnel" ;;
        xdns:port_group)    echo "dns-router" ;;
        xdns:shared_service) echo "true" ;;  # xray also serves XHTTP
        xdns:desc)          echo "VLESS+mKCP+FinalMask via Xray (per-user auth; via dns-router on port 53)" ;;
        dnstt:enable_var)   echo "ENABLE_DNSTT" ;;
        dnstt:port_var)     echo "PORT_DNS" ;;
        dnstt:default_port) echo "53" ;;
        dnstt:services)     echo "dnstt dns-router" ;;
        dnstt:profile)      echo "dnstunnel" ;;
        dnstt:port_group)   echo "dns-router" ;;
        dnstt:shared_service) echo "false" ;;
        dnstt:desc)         echo "KCP+Noise DNS tunnel (stable, slow)" ;;
        slipstream:enable_var)   echo "ENABLE_SLIPSTREAM" ;;
        slipstream:port_var)     echo "PORT_DNS" ;;
        slipstream:default_port) echo "53" ;;
        slipstream:services)     echo "slipstream dns-router" ;;
        slipstream:profile)      echo "dnstunnel" ;;
        slipstream:port_group)   echo "dns-router" ;;
        slipstream:shared_service) echo "false" ;;
        slipstream:desc)         echo "DEPRECATED, not routed by dns-router; use masterdns or dnstt" ;;
        masterdns:enable_var)    echo "ENABLE_MASTERDNS" ;;
        masterdns:port_var)      echo "PORT_DNS" ;;
        masterdns:default_port)  echo "53" ;;
        masterdns:services)      echo "masterdns dns-router" ;;
        masterdns:profile)       echo "dnstunnel" ;;
        masterdns:port_group)    echo "dns-router" ;;
        masterdns:shared_service) echo "false" ;;
        masterdns:desc)          echo "ARQ DNS tunnel (up to 9× dnstt, MahsaNG v16 native)" ;;
        *) return 1 ;;
    esac
}

# Which tunnels are enabled in .env (returns space-separated names)
dns_tunnels_enabled() {
    local env_file="$SCRIPT_DIR/.env"
    local out=""
    for t in "${DNS_TUNNELS[@]}"; do
        local var default
        var=$(dns_tunnel_field "$t" enable_var)
        default="true"
        [[ "$t" == "xdns" ]] && default="true"
        [[ "$(get_env_val "$var" "$env_file" "$default")" == "true" ]] && out+="$t "
    done
    echo "${out% }"
}

# Which tunnels are currently "active on port 53" (not just container alive).
# For tunnels on shared containers (e.g. xray serves both XDNS and XHTTP),
# we additionally require the enable flag — otherwise xray-running-for-XHTTP
# would be reported as xdns-running.
dns_tunnels_running() {
    local env_file="$SCRIPT_DIR/.env"
    local running
    running=$(docker compose ps --services --filter "status=running" 2>/dev/null || echo "")
    local out=""
    for t in "${DNS_TUNNELS[@]}"; do
        local svcs shared any_up=false
        svcs=$(dns_tunnel_field "$t" services)
        shared=$(dns_tunnel_field "$t" shared_service)
        for s in $svcs; do
            if echo "$running" | grep -qw "$s"; then
                any_up=true
                break
            fi
        done
        $any_up || continue

        # Shared-service tunnels: only "running" if enable flag says so
        if [[ "$shared" == "true" ]]; then
            local var default enabled
            var=$(dns_tunnel_field "$t" enable_var)
            default="true"
            [[ "$t" == "xdns" ]] && default="true"
            enabled=$(get_env_val "$var" "$env_file" "$default")
            [[ "$enabled" != "true" ]] && continue
        fi
        out+="$t "
    done
    echo "${out% }"
}

cmd_switch_dns() {
    local env_file="$SCRIPT_DIR/.env"
    local target="${1:-}"

    case "$target" in
        ""|list|--list|-l)
            print_section "DNS Tunnels"
            local enabled running
            enabled=$(dns_tunnels_enabled)
            running=$(dns_tunnels_running)
            printf "  %-12s %-10s %-8s %-8s %s\n" "NAME" "GROUP" "ENABLED" "RUNNING" "DESCRIPTION"
            for t in "${DNS_TUNNELS[@]}"; do
                local en="no" ru="no"
                echo "$enabled" | grep -qw "$t" && en="yes"
                echo "$running" | grep -qw "$t" && ru="yes"
                printf "  %-12s %-10s %-8s %-8s %s\n" "$t" "$(dns_tunnel_field "$t" port_group)" "$en" "$ru" "$(dns_tunnel_field "$t" desc)"
            done
            echo ""
            echo "All DNS tunnels share the same group (dns-router) and can run together."
            echo "dns-router fans queries by subdomain suffix — no port 53 conflicts."
            echo ""
            echo "Usage: moav switch-dns <name>[+<name>...] | off"
            echo "  moav switch-dns dnstt+masterdns+xdns  # all supported tunnels"
            echo "  moav switch-dns dnstt+masterdns     # classic pair"
            echo "  moav switch-dns xdns                # XDNS only (via dns-router)"
            echo "  moav switch-dns off                 # disable all DNS tunnels"
            return 0
            ;;
        help|--help|-h)
            echo "Usage: moav switch-dns [<name>[+<name>...]|off|list]"
            echo ""
            echo "Enable one or more DNS tunnels on port 53. All tunnels share the"
            echo "dns-router group and can run simultaneously — dns-router fans queries"
            echo "by subdomain suffix (t→dnstt, m→masterdns, x→xdns). Slipstream is"
            echo "deprecated and no longer routed."
            echo ""
            echo "Available tunnels:"
            for t in "${DNS_TUNNELS[@]}"; do
                printf "  %-12s [group: %-10s] %s\n" "$t" "$(dns_tunnel_field "$t" port_group)" "$(dns_tunnel_field "$t" desc)"
            done
            echo "  off          Disable all DNS tunnels"
            echo "  list         Show current state (default with no args)"
            echo ""
            echo "Examples:"
            echo "  moav switch-dns dnstt+masterdns+xdns  # all supported"
            echo "  moav switch-dns dnstt+masterdns    # classic pair"
            echo "  moav switch-dns xdns               # XDNS only via dns-router"
            return 0
            ;;
    esac

    # Parse target: single name, "+"-joined combo, or "off"
    local requested=()
    if [[ "$target" != "off" ]]; then
        IFS='+' read -ra requested <<< "$target"
        # Validate each name
        for req in "${requested[@]}"; do
            local valid=false
            for t in "${DNS_TUNNELS[@]}"; do
                [[ "$t" == "$req" ]] && valid=true && break
            done
            if ! $valid; then
                error "Unknown DNS tunnel: $req"
                echo "Available: ${DNS_TUNNELS[*]} off"
                return 1
            fi
        done
    fi

    print_section "Switch DNS Tunnel → $target"

    for req in "${requested[@]}"; do
        if [[ "$req" == "slipstream" ]]; then
            warn "Slipstream is deprecated and no longer routed by dns-router; clients cannot reach it. Use masterdns or dnstt."
        fi
    done

    # Determine enable/disable lists
    local to_enable=("${requested[@]}")
    local to_disable=()
    for t in "${DNS_TUNNELS[@]}"; do
        local keep=false
        for r in "${to_enable[@]}"; do
            [[ "$t" == "$r" ]] && keep=true && break
        done
        $keep || to_disable+=("$t")
    done

    info "Updating .env..."
    for t in "${to_disable[@]}"; do
        local var
        var=$(dns_tunnel_field "$t" enable_var)
        update_env_var "$env_file" "$var" "false"
        echo "  $var=false"
    done
    for t in "${to_enable[@]}"; do
        local var
        var=$(dns_tunnel_field "$t" enable_var)
        update_env_var "$env_file" "$var" "true"
        echo "  $var=true"
    done

    # Port assignment: dns-router owns public port 53; xray XDNS is secondary.
    # All tunnels are now in the dns-router group, so this is always dns-router mode.
    if [[ ${#to_enable[@]} -gt 0 ]]; then
        update_env_var "$env_file" "PORT_DNS" "53"
        update_env_var "$env_file" "PORT_XDNS" "5356"
        echo "  PORT_DNS=53 (dns-router), PORT_XDNS=5356 (xray secondary)"
    fi
    echo ""

    # Stop services of disabled tunnels — but only services that aren't also
    # used by an enabled tunnel (e.g. dns-router stays up if either dnstt or
    # slipstream is still enabled).
    local keep_services=""
    for t in "${to_enable[@]}"; do
        keep_services+="$(dns_tunnel_field "$t" services) "
    done
    local stop_list=""
    for t in "${to_disable[@]}"; do
        for svc in $(dns_tunnel_field "$t" services); do
            if ! echo " $keep_services " | grep -q " $svc "; then
                stop_list+="$svc "
            fi
        done
    done
    # Deduplicate stop_list
    local stop_unique=""
    for s in $stop_list; do
        echo " $stop_unique " | grep -q " $s " || stop_unique+="$s "
    done
    if [[ -n "$stop_unique" ]]; then
        info "Stopping: $stop_unique"
        docker compose stop $stop_unique 2>/dev/null || true
        docker compose rm -f $stop_unique 2>/dev/null || true
    fi

    if [[ "$target" == "off" ]]; then
        success "All DNS tunnels disabled."
        echo ""
        echo "Port 53 is now free. Other MoaV services are unaffected."
        return 0
    fi

    # Pre-flight: check state keys exist for tunnels we're enabling.
    # dnstt needs dnstt-server.key.hex/pub.hex; slipstream needs cert/key PEMs.
    # Without these, containers crash-loop silently.
    local needs_bootstrap=false
    for t in "${to_enable[@]}"; do
        local key_paths=""
        case "$t" in
            dnstt)      key_paths="/state/keys/dnstt-server.key.hex /state/keys/dnstt-server.pub.hex" ;;
            slipstream) key_paths="/state/keys/slipstream-cert.pem /state/keys/slipstream-key.pem" ;;
        esac
        [[ -z "$key_paths" ]] && continue
        for p in $key_paths; do
            if ! docker run --rm -v moav_moav_state:/state alpine:3.24 test -f "$p" 2>/dev/null; then
                warn "$t is missing key file: ${p##*/}"
                needs_bootstrap=true
            fi
        done
    done

    if $needs_bootstrap; then
        echo ""
        info "Keys for newly-enabled tunnels don't exist yet (never bootstrapped for them)."
        if confirm "Run bootstrap now to generate missing keys?" "y"; then
            run_bootstrap || { error "Bootstrap failed — aborting switch."; return 1; }
            echo ""
        else
            error "Cannot start: $t would crash-loop waiting for key files."
            echo "  Run 'moav bootstrap' manually, then retry 'moav switch-dns $target'."
            return 1
        fi
    fi

    # Start target profile(s) — deduplicate since xdns+xhttp share profile,
    # dnstt+slipstream share dnstunnel
    local profiles_unique=""
    for t in "${to_enable[@]}"; do
        local p
        p=$(dns_tunnel_field "$t" profile)
        echo " $profiles_unique " | grep -q " $p " || profiles_unique+="$p "
    done
    local profile_args=""
    for p in $profiles_unique; do profile_args+="--profile $p "; done

    info "Starting profiles: $profiles_unique"
    compose_up_enabled "$profile_args"
    echo ""
    success "Switched to: ${to_enable[*]}"
    echo ""
    echo "Verify with: moav doctor conflicts"
}

setup_dns_for_dnstt() {
    info "Setting up DNS for DNS tunnels..."

    # Check if systemd-resolved is running
    if systemctl is-active systemd-resolved &>/dev/null; then
        info "  Stopping systemd-resolved..."
        sudo systemctl stop systemd-resolved 2>/dev/null || true
        sudo systemctl disable systemd-resolved 2>/dev/null || true
        success "    systemd-resolved stopped and disabled"
    fi

    # Check if /etc/resolv.conf is a symlink (common with systemd-resolved)
    if [[ -L /etc/resolv.conf ]]; then
        info "  Removing resolv.conf symlink..."
        sudo rm -f /etc/resolv.conf
    fi

    # Set up direct DNS resolution
    info "  Configuring direct DNS resolution..."
    echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" | sudo tee /etc/resolv.conf > /dev/null
    success "    DNS configured (1.1.1.1, 8.8.8.8)"

    echo ""
    success "DNS setup complete. Port 53 is now available for DNS tunnels."
}

cmd_setup_dns() {
    print_section "Setup DNS for DNS Tunnels"

    info "This will:"
    echo "  • Stop and disable systemd-resolved"
    echo "  • Configure direct DNS resolution (1.1.1.1, 8.8.8.8)"
    echo "  • Free port 53 for DNS tunnels (XDNS, dnstt, Slipstream)"
    echo ""

    if ! confirm "Continue?" "y"; then
        info "Cancelled."
        exit 0
    fi

    echo ""
    setup_dns_for_dnstt
}

generate_dns_zone_file() {
    local env_file="$SCRIPT_DIR/.env"
    local domain
    domain=$(get_env_val "DOMAIN" "$env_file" "")
    local server_ip
    server_ip=$(get_env_val "SERVER_IP" "$env_file" "")
    local output_file="$SCRIPT_DIR/outputs/dns-records.txt"

    if [[ -z "$domain" ]]; then
        warn "DOMAIN not set in .env — cannot generate zone file"
        return 1
    fi
    if [[ -z "$server_ip" ]]; then
        warn "SERVER_IP not set in .env — cannot generate zone file"
        return 1
    fi

    mkdir -p "$SCRIPT_DIR/outputs"

    cat > "$output_file" << ZONEOF
;;
;; MoaV DNS Records for ${domain}
;; Generated: $(date -u +%Y-%m-%d\ %H:%M:%S\ UTC)
;;
;; Import into Cloudflare: DNS > Records > Import and Upload
;; Or manually create these records at your DNS provider.
;;

;; Main domain — points to your server (DNS only, NOT proxied)
${domain}.	1	IN	A	${server_ip}
ZONEOF

    # DNS tunnel nameserver (needed for dnstt/MasterDNS/XDNS)
    local dnstt_enabled slipstream_enabled masterdns_enabled xdns_enabled
    dnstt_enabled=$(get_env_val "ENABLE_DNSTT" "$env_file" "true")
    slipstream_enabled=$(get_env_val "ENABLE_SLIPSTREAM" "$env_file" "false")
    masterdns_enabled=$(get_env_val "ENABLE_MASTERDNS" "$env_file" "true")
    xdns_enabled=$(get_env_val "ENABLE_XDNS" "$env_file" "true")

    # Always include DNS tunnel records (user can decide which to enable later)
    local dnstt_sub slip_sub masterdns_sub masterdns_public_sub xdns_sub
    dnstt_sub=$(get_env_val "DNSTT_SUBDOMAIN" "$env_file" "t")
    slip_sub=$(get_env_val "SLIPSTREAM_SUBDOMAIN" "$env_file" "s")
    masterdns_sub=$(get_env_val "MASTERDNS_SUBDOMAIN" "$env_file" "m")
    masterdns_public_sub=$(get_env_val "MASTERDNS_PUBLIC_SUBDOMAIN" "$env_file" "")
    xdns_sub=$(get_env_val "XDNS_SUBDOMAIN" "$env_file" "x")

    local dnstt_status="enabled" slip_status="enabled" masterdns_status="enabled" xdns_status="disabled"
    [[ "$dnstt_enabled" != "true" ]] && dnstt_status="disabled"
    [[ "$slipstream_enabled" != "true" ]] && slip_status="disabled"
    [[ "$masterdns_enabled" != "true" ]] && masterdns_status="disabled"
    [[ "$xdns_enabled" == "true" ]] && xdns_status="enabled"

    cat >> "$output_file" << ZONEOF

;; DNS tunnel nameserver — required for NS delegation (DNS only, NOT proxied)
dns.${domain}.	1	IN	A	${server_ip}

;; DNS tunnel NS delegations
;; DNS tunnels share port 53 via dns-router (dnstt/MasterDNS/XDNS)
;; dnstt KCP+Noise DNS tunnel (currently ${dnstt_status})
${dnstt_sub}.${domain}.	1	IN	NS	dns.${domain}.
;; Slipstream: DEPRECATED, no longer routed by dns-router; record can be removed (currently ${slip_status})
${slip_sub}.${domain}.	1	IN	NS	dns.${domain}.
;; MasterDNS ARQ DNS tunnel — MahsaNG v16 native (currently ${masterdns_status})
${masterdns_sub}.${domain}.	1	IN	NS	dns.${domain}.
ZONEOF

    if [[ -n "$masterdns_public_sub" && "$masterdns_public_sub" != "$masterdns_sub" ]]; then
        cat >> "$output_file" << ZONEOF
;; MasterDNS public delegation domain (currently ${masterdns_status})
${masterdns_public_sub}.${domain}.	1	IN	NS	dns.${domain}.
ZONEOF
    fi

    cat >> "$output_file" << ZONEOF
;; XDNS mKCP DNS tunnel — opt-in, shares port 53 via dns-router (currently ${xdns_status})
${xdns_sub}.${domain}.	1	IN	NS	dns.${domain}.
ZONEOF

    # CDN subdomain
    local cdn_sub
    cdn_sub=$(get_env_val "CDN_SUBDOMAIN" "$env_file" "")
    if [[ -n "$cdn_sub" ]]; then
        cat >> "$output_file" << ZONEOF

;; CDN mode (Cloudflare proxied — orange cloud)
${cdn_sub}.${domain}.	1	IN	A	${server_ip}
ZONEOF
    fi

    # Grafana CDN subdomain
    local grafana_sub
    grafana_sub=$(get_env_val "GRAFANA_SUBDOMAIN" "$env_file" "")
    if [[ -n "$grafana_sub" ]]; then
        cat >> "$output_file" << ZONEOF

;; Grafana CDN (Cloudflare proxied — orange cloud)
${grafana_sub}.${domain}.	1	IN	A	${server_ip}
ZONEOF
    fi

    echo "$output_file"
}
