#!/bin/bash
# lib/bootstrap.sh — first-run setup from the CLI side: detecting whether a
# deployment has been bootstrapped, driving the bootstrap container, `moav
# bootstrap`, and `moav domainless` (switch a deployment to IP-only operation).
#
# The bootstrap container's own logic lives in scripts/bootstrap.sh; this is the
# host-side wrapper around it. Sourced by moav.sh after lib/common.sh.
#
# Definitions only — nothing here runs at source time.

check_bootstrap() {
    # Check if bootstrap has been run by looking for local outputs
    # This is faster than checking docker volumes
    if [[ -d "outputs/bundles" ]] && [[ -n "$(ls -A outputs/bundles 2>/dev/null)" ]]; then
        return 0  # Bootstrap has been run
    fi

    # Fallback: check docker volume (with timeout)
    if docker volume ls 2>/dev/null | grep -q "moav_moav_state"; then
        # Quick check - just see if volume exists and has data
        # Use timeout to prevent hanging
        local has_keys
        has_keys=$(timeout 3 docker run --rm -v moav_moav_state:/state alpine sh -c "ls /state/keys 2>/dev/null | head -1" 2>/dev/null || echo "")
        if [[ -n "$has_keys" ]]; then
            return 0  # Bootstrap has been run
        fi
    fi
    return 1  # Bootstrap needed
}

run_bootstrap() {
    print_section "First-Time Setup (Bootstrap)"

    local domain=$(get_env_val "DOMAIN" ".env")

    info "Bootstrap will:"
    echo "  • Generate encryption keys and secrets"
    if [[ -n "$domain" ]]; then
        echo "  • Obtain TLS certificate from Let's Encrypt"
    fi
    echo "  • Configure enabled protocols"
    echo "  • Create initial users with connection links"
    echo ""

    if [[ -n "$domain" ]]; then
        warn "Make sure your domain DNS is configured correctly!"
        echo "  Your domain should point to this server's IP address."
        echo ""
    fi

    # Detect and save SERVER_IP to .env if not already set
    local current_ip=$(get_env_val "SERVER_IP" ".env")
    if [[ -z "$current_ip" ]]; then
        info "Detecting server public IP..."
        local detected_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || curl -s --max-time 5 https://ifconfig.me 2>/dev/null || echo "")
        if [[ -n "$detected_ip" ]]; then
            success "Detected IP: $detected_ip"
            # Save to .env for future use
            if grep -q "^SERVER_IP=" .env 2>/dev/null; then
                sed -i "s|^SERVER_IP=.*|SERVER_IP=\"$detected_ip\"|" .env
            else
                echo "SERVER_IP=\"$detected_ip\"" >> .env
            fi
            info "SERVER_IP saved to .env"
        else
            warn "Could not detect server IP - admin URL may show 'localhost'"
        fi
    fi

    # Validate Reality fallback targets resolve in DNS — see issue #115.
    # If a hostname is NXDOMAIN, prompt for a replacement and rewrite .env in
    # place. Cheaper to catch here than at first client connect.
    if ! validate_reality_targets ".env"; then
        error "Reality target validation failed. Edit REALITY_TARGET / XHTTP_REALITY_TARGET in .env and re-run bootstrap."
        return 1
    fi

    # Only build if the bootstrap image doesn't exist yet
    if ! docker image inspect moav-bootstrap >/dev/null 2>&1; then
        info "Building bootstrap container (first time, may take a few minutes)..."
        compose_build --profile setup build bootstrap
    else
        info "Using cached bootstrap container"
    fi

    echo ""
    info "Running bootstrap..."
    if ! docker compose --profile setup run --rm bootstrap; then
        echo ""
        error "Bootstrap failed!"
        echo ""
        echo "Check the error messages above and fix the issues."
        echo "Common fixes:"
        echo "  • Set DOMAIN in .env, or disable TLS protocols"
        echo "  • Ensure DNS is configured correctly"
        echo "  • Check that required ports are available"
        return 1
    fi

    # Download GeoIP database for country-level monitoring (best-effort)
    info "Downloading GeoIP database..."
    docker compose --profile setup run --rm geoip-updater 2>/dev/null && \
        success "GeoIP database ready" || \
        warn "GeoIP download failed (monitoring will work without country data)"

    echo ""
    success "Bootstrap completed!"
    echo ""
    info "User bundles have been created in: outputs/bundles/"
    echo "  Each bundle contains configuration files and QR codes"
    echo "  for connecting to your server."

    # Service selection
    echo ""
    print_section "Service Selection"
    echo "Select which services to build and set as default for 'moav start'."
    echo ""

    if select_profiles "save"; then
        # Check DNS setup if DNS tunnels are selected
        check_dns_for_dnstunnel

        echo ""
        info "Building selected services..."
        compose_build $SELECTED_PROFILE_STRING build

        echo ""
        if confirm "Start services now?" "y"; then
            # Ensure CLASH_API_SECRET is configured for monitoring
            local skip_monitoring=0
            ensure_clash_api_secret "$SELECTED_PROFILE_STRING" || skip_monitoring=1
            if [[ $skip_monitoring -eq 1 ]]; then
                # Remove monitoring from selected profiles
                SELECTED_PROFILE_STRING=$(echo "$SELECTED_PROFILE_STRING" | sed 's/--profile monitoring//g')
            fi

            info "Starting services..."
            docker compose $SELECTED_PROFILE_STRING up -d --remove-orphans
            echo ""
            success "Services started!"

            # Show URLs
            if echo "$SELECTED_PROFILE_STRING" | grep -qE "admin|all"; then
                echo -e "  ${CYAN}Admin Dashboard:${NC} $(get_admin_url)"
            fi
            if echo "$SELECTED_PROFILE_STRING" | grep -qE "monitoring"; then
                echo -e "  ${CYAN}Grafana:${NC}         $(get_grafana_url)"
            fi
            echo ""
        else
            echo ""
            info "You can start services later with: moav start"
        fi
    else
        echo ""
        info "You can select and start services later with: moav start"
    fi
}

cmd_domainless() {
    print_header
    print_section "Enable Domainless Mode"

    echo ""
    info "Domain-less mode disables TLS-based protocols that require a domain."
    echo ""
    echo -e "  ${YELLOW}Will be disabled:${NC}"
    echo "    • Trojan, Hysteria2, CDN VLESS (need TLS certificates)"
    echo "    • TrustTunnel"
    echo "    • DNS tunnels (dnstt, Slipstream, MasterDNS, XDNS)"
    echo ""
    echo -e "  ${GREEN}Will remain available:${NC}"
    echo "    • Reality (VLESS) — uses dl.google.com for TLS camouflage"
    echo "    • XHTTP (VLESS+Reality)"
    echo "    • Shadowsocks-2022"
    echo "    • WireGuard (direct UDP)"
    echo "    • AmneziaWG (DPI-resistant WireGuard)"
    echo "    • Telegram MTProxy (fake-TLS, IP only)"
    echo "    • Admin dashboard (self-signed certificate)"
    echo "    • Psiphon Conduit (bandwidth donation)"
    echo "    • Tor Snowflake (bandwidth donation)"
    echo ""

    if ! confirm "Enable domainless mode?" "y"; then
        info "Cancelled."
        return 0
    fi

    # Check if .env exists
    if [[ ! -f ".env" ]]; then
        if [[ -f ".env.example" ]]; then
            cp .env.example .env
            # .env holds ADMIN_PASSWORD, REALITY_PRIVATE_KEY, CLASH_API_SECRET and the
            # Hysteria2 obfs password. It is never bind-mounted into a container and
            # compose reads it as the invoking (host) user, so 0600 costs nothing.
            chmod 600 .env 2>/dev/null || true
            success "Created .env from .env.example"
        else
            error ".env file not found"
            return 1
        fi
    fi

    # Disable cert-needing protocols. TROJAN..TRUSTTUNNEL must match
    # bootstrap.sh:41-46; XDNS is added to keep dns-router off port 53 in
    # domainless mode (direct-mode XDNS can be re-enabled manually).
    for var in ENABLE_TROJAN ENABLE_ANYTLS ENABLE_HYSTERIA2 ENABLE_DNSTT ENABLE_SLIPSTREAM ENABLE_MASTERDNS ENABLE_XDNS ENABLE_TRUSTTUNNEL; do
        update_env_var ".env" "$var" "false"
    done

    # Clear DOMAIN (add if not present)
    if grep -q "^DOMAIN=" .env; then
        sed -i 's/^DOMAIN=.*/DOMAIN=/' .env
    else
        echo "DOMAIN=" >> .env
    fi

    # Derive DEFAULT_PROFILES from the mutated ENABLE_* set (issue #106).
    local _dl_profiles
    _dl_profiles=$(derive_enabled_profiles ".env")
    if grep -q "^DEFAULT_PROFILES=" .env; then
        sed -i "s|^DEFAULT_PROFILES=.*|DEFAULT_PROFILES=\"${_dl_profiles}\"|" .env
    else
        echo "DEFAULT_PROFILES=\"${_dl_profiles}\"" >> .env
    fi

    # Ensure admin password is set (not the insecure default)
    ensure_admin_password

    echo ""
    success "Domain-less mode enabled!"
    echo ""

    # Verify changes in .env
    info "Settings in .env:"
    grep -E "^(DOMAIN|ENABLE_|DEFAULT_PROFILES)=" .env | head -15
    echo ""

    # Verify docker-compose sees them correctly
    info "Verifying docker-compose reads these values..."
    local compose_check
    compose_check=$(docker compose --profile setup config 2>/dev/null | grep -E "ENABLE_REALITY|ENABLE_TROJAN" | head -2)
    if echo "$compose_check" | grep -q "false"; then
        success "Docker compose sees the correct values"
    else
        warn "Docker compose may not be reading .env correctly!"
        echo "  Docker compose sees:"
        echo "$compose_check"
        echo ""
        echo "  Try running: docker compose --profile setup config | grep ENABLE"
    fi
    echo ""

    # Clear bootstrap flag if exists
    if check_bootstrap; then
        info "Clearing previous bootstrap to regenerate configs..."
        docker run --rm -v moav_moav_state:/state alpine rm -f /state/.bootstrapped 2>/dev/null || true
    fi

    echo ""
    if confirm "Run bootstrap now to generate WireGuard configs?" "y"; then
        run_bootstrap
    else
        info "Run 'moav bootstrap' when ready."
    fi
}

cmd_bootstrap() {
    local assume_yes=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes|-y) assume_yes=true ;;
            *) warn "Unknown bootstrap option: $1" ;;
        esac
        shift
    done

    print_header
    check_prerequisites
    echo ""

    # Check if already bootstrapped
    if check_bootstrap; then
        warn "Bootstrap has already been run!"
        echo ""
        info "Running bootstrap again will:"
        echo "  • Preserve existing keys and secrets (only generate missing ones)"
        echo "  • Preserve existing user credentials (UUIDs, passwords)"
        echo "  • Regenerate config files (sing-box, WireGuard, AmneziaWG)"
        echo "  • Generate configs for any newly enabled protocols"
        echo "  • Obtain TLS certificates if missing"
        echo ""
        info "Existing client configurations will remain valid."
        echo ""
        if [[ "$assume_yes" == "true" ]]; then
            info "Re-running bootstrap non-interactively (--yes)"
        elif ! confirm "Are you sure you want to re-run bootstrap?" "n"; then
            info "Bootstrap cancelled."
            return 0
        fi
        # Clear the bootstrapped flag so bootstrap.sh doesn't exit early
        info "Clearing bootstrap flag..."
        docker run --rm -v moav_moav_state:/state alpine rm -f /state/.bootstrapped
    else
        local domain=$(get_env_val "DOMAIN" ".env")
        info "Bootstrap will perform first-time setup:"
        echo "  • Generate encryption keys and secrets"
        if [[ -n "$domain" ]]; then
            echo "  • Obtain TLS certificate from Let's Encrypt"
        fi
        echo "  • Configure enabled protocols"
        echo "  • Create initial users with connection links"
        echo ""
        if [[ "$assume_yes" != "true" ]] && ! confirm "Continue with bootstrap?" "y"; then
            info "Bootstrap cancelled."
            return 0
        fi
    fi

    echo ""
    run_bootstrap
}
