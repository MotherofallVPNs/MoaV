#!/bin/bash
# =============================================================================
# MoaV Management Script
# Interactive CLI for managing the MoaV circumvention stack
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
DIM='\033[2m'
NC='\033[0m'

# Get script directory (resolve symlinks)
# Save original working directory before changing to script dir
ORIGINAL_PWD="$PWD"

SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    # If relative symlink, resolve relative to symlink directory
    [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
cd "$SCRIPT_DIR"

# Version
VERSION=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "dev")

# Component versions (read from .env or use defaults)
get_component_version() {
    local var_name="$1"
    local default="$2"
    local env_file="$SCRIPT_DIR/.env"
    if [[ -f "$env_file" ]]; then
        local val
        val=$(grep "^${var_name}=" "$env_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'")
        [[ -n "$val" ]] && echo "$val" && return
    fi
    echo "$default"
}

# State file for persistent checks
PREREQS_FILE="$SCRIPT_DIR/.moav_prereqs_ok"
UPDATE_CACHE_FILE="/tmp/.moav_update_check"
LATEST_VERSION=""

# Handle Ctrl+C gracefully
goodbye() {
    echo ""
    echo -e "${CYAN}Goodbye! Stay safe out there.${NC}"
    echo ""
    exit 0
}
trap goodbye SIGINT

# -----------------------------------------------------------------------------
# Library modules. Sourced (not sub-shelled) so the dispatch `case` and every
# command function keep working unchanged. `common` must come first — it holds
# the foundation helpers the rest depend on. The globals above (colors,
# SCRIPT_DIR, VERSION, state files) are deliberately set BEFORE this point.
# -----------------------------------------------------------------------------
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/nettune.sh"   # before doctor: doctor_check_net calls nt_*
source "$SCRIPT_DIR/lib/peers.sh"     # doctor_check_peers + the --fix repair
source "$SCRIPT_DIR/lib/donate.sh"
source "$SCRIPT_DIR/lib/cert.sh"
source "$SCRIPT_DIR/lib/migrate.sh"
source "$SCRIPT_DIR/lib/dns.sh"
source "$SCRIPT_DIR/lib/update.sh"
source "$SCRIPT_DIR/lib/install.sh"
source "$SCRIPT_DIR/lib/bootstrap.sh"
source "$SCRIPT_DIR/lib/users.sh"
source "$SCRIPT_DIR/lib/build.sh"
source "$SCRIPT_DIR/lib/doctor.sh"   # after nettune + peers: their checks live there
source "$SCRIPT_DIR/lib/service.sh"

# =============================================================================
# Prerequisite Checks
# =============================================================================

detect_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [[ -f /etc/debian_version ]]; then
        echo "debian"
    elif [[ -f /etc/redhat-release ]] || [[ -f /etc/fedora-release ]]; then
        echo "rhel"
    elif [[ -f /etc/alpine-release ]]; then
        echo "alpine"
    else
        echo "unknown"
    fi
}

install_docker() {
    local os_type=$(detect_os)

    case "$os_type" in
        debian|rhel)
            info "Installing Docker using official install script..."
            echo ""
            curl -fsSL https://get.docker.com | sh

            # Add current user to docker group
            sudo usermod -aG docker "$(whoami)" 2>/dev/null || true

            # Start and enable Docker
            sudo systemctl start docker 2>/dev/null || sudo service docker start 2>/dev/null || true
            sudo systemctl enable docker 2>/dev/null || true

            success "Docker installed"
            echo ""
            warn "You may need to log out and back in for docker group permissions."
            warn "Or run: newgrp docker"
            return 0
            ;;
        macos)
            error "Please install Docker Desktop from: https://www.docker.com/products/docker-desktop"
            echo "After installing, run this script again."
            return 1
            ;;
        alpine)
            info "Installing Docker via apk..."
            sudo apk add docker docker-compose
            sudo rc-update add docker boot
            sudo service docker start
            success "Docker installed"
            return 0
            ;;
        *)
            error "Cannot auto-install Docker on this OS."
            echo "Please install from: https://docs.docker.com/engine/install/"
            return 1
            ;;
    esac
}

install_qrencode() {
    local os_type=$(detect_os)
    local pkg_manager=""

    # Detect package manager
    case "$os_type" in
        macos)
            if command -v brew &>/dev/null; then
                pkg_manager="brew"
            fi
            ;;
        debian)
            pkg_manager="apt"
            ;;
        rhel)
            if command -v dnf &>/dev/null; then
                pkg_manager="dnf"
            elif command -v yum &>/dev/null; then
                pkg_manager="yum"
            fi
            ;;
        alpine)
            pkg_manager="apk"
            ;;
    esac

    case "$pkg_manager" in
        brew)
            info "Installing qrencode via Homebrew..."
            brew install qrencode
            ;;
        apt)
            info "Installing qrencode via apt..."
            sudo apt update && sudo apt install -y qrencode
            ;;
        dnf)
            info "Installing qrencode via dnf..."
            sudo dnf install -y qrencode
            ;;
        yum)
            info "Installing qrencode via yum..."
            sudo yum install -y qrencode
            ;;
        apk)
            info "Installing qrencode via apk..."
            sudo apk add libqrencode-tools
            ;;
        *)
            error "Could not detect package manager"
            echo "  Please install qrencode manually:"
            echo "    Linux (Debian/Ubuntu): sudo apt install qrencode"
            echo "    Linux (RHEL/Fedora):   sudo dnf install qrencode"
            echo "    macOS:                 brew install qrencode"
            return 1
            ;;
    esac

    if command -v qrencode &>/dev/null; then
        success "qrencode installed successfully"
    else
        error "qrencode installation failed"
        return 1
    fi
}

# Read a value from .env file — handles duplicates (last wins), inline comments, and quotes
# Usage: val=$(get_env_val "ENABLE_XHTTP" "$env_file" "true")
get_env_val() {
    local key="$1" file="$2" default="${3:-}"
    local val
    val=$(grep "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d'=' -f2- | sed 's/#.*//' | tr -d '"' | tr -d "'" | xargs) || true
    echo "${val:-$default}"
}

# Reality fallback target — vetted lists + DNS validation (#115).
# NXDOMAIN target → every TLS hello RSTs, bundle silently breaks.
REALITY_TARGETS_GLOBAL=(
    "www.cloudflare.com:443"
    "www.apple.com:443"
    "cdn.kernel.org:443"
    "www.microsoft.com:443"
)
# SNI cover for clients inside Iran.
REALITY_TARGETS_IRAN=(
    "www.aparat.com:443"
    "digikala.com:443"
    "taghche.com:443"
)

# 0 if host has A/AAAA. Tries getent → host → nslookup. Empty host → fail.
reality_target_resolves() {
    local host="$1"
    [[ -n "$host" ]] || return 1
    if command -v getent >/dev/null 2>&1; then
        getent hosts "$host" >/dev/null 2>&1 && return 0
    fi
    if command -v host >/dev/null 2>&1; then
        host -W 4 "$host" >/dev/null 2>&1 && return 0
    fi
    if command -v nslookup >/dev/null 2>&1; then
        nslookup -timeout=4 "$host" >/dev/null 2>&1 && return 0
    fi
    return 1
}

show_vetted_reality_targets() {
    echo "  Vetted Reality fallback targets:"
    echo ""
    echo "    Global (real TLS 1.3, stable, won't go dark):"
    for t in "${REALITY_TARGETS_GLOBAL[@]}"; do
        echo "      • $t"
    done
    echo ""
    echo "    Iran-friendly (better SNI cover for clients inside Iran):"
    for t in "${REALITY_TARGETS_IRAN[@]}"; do
        echo "      • $t"
    done
}

# Validate REALITY_TARGET / XHTTP_REALITY_TARGET resolve. NXDOMAIN → re-prompt
# (≤3) and rewrite .env. Returns 1 if still invalid after retries.
validate_reality_targets() {
    local env_file="${1:-.env}"
    [[ -f "$env_file" ]] || return 0  # nothing to validate yet

    local enable_reality enable_xhttp
    enable_reality=$(get_env_val "ENABLE_REALITY" "$env_file" "true")
    enable_xhttp=$(get_env_val "ENABLE_XHTTP" "$env_file" "true")

    local key host_port host default new_target new_host attempt failed=0
    for key in REALITY_TARGET XHTTP_REALITY_TARGET; do
        case "$key" in
            REALITY_TARGET)        [[ "$enable_reality" == "true" ]] || continue ;;
            XHTTP_REALITY_TARGET)  [[ "$enable_xhttp"    == "true" ]] || continue ;;
        esac

        host_port=$(get_env_val "$key" "$env_file" "www.cloudflare.com:443")
        host="${host_port%%:*}"

        if reality_target_resolves "$host"; then
            info "$key host '$host' resolves ✓"
            continue
        fi

        warn "$key host '$host' does NOT resolve (NXDOMAIN)"
        echo "    Reality's fallback dial will fail for every TLS hello it can't auth,"
        echo "    so the inbound RSTs every probe and every legitimate client (issue #115)."
        echo ""
        show_vetted_reality_targets
        echo ""

        default="www.cloudflare.com:443"
        for attempt in 1 2 3; do
            prompt "Enter a new $key (host:port) or press Enter for $default:"
            if ! read -r new_target < /dev/tty 2>/dev/null; then
                # Non-interactive run — accept the default and move on.
                new_target=""
            fi
            new_target="${new_target:-$default}"
            new_host="${new_target%%:*}"
            if reality_target_resolves "$new_host"; then
                if grep -qE "^${key}=" "$env_file" 2>/dev/null; then
                    sed -i.bak "s|^${key}=.*|${key}=${new_target}|" "$env_file" && rm -f "${env_file}.bak"
                else
                    echo "${key}=${new_target}" >> "$env_file"
                fi
                success "$key set to $new_target"
                break
            fi
            warn "'$new_host' also does not resolve."
            if [[ "$attempt" == "3" ]]; then
                error "$key still invalid after 3 attempts — bootstrap will fail until fixed."
                failed=$((failed + 1))
            fi
        done
    done

    [[ "$failed" -eq 0 ]]
}

# Monitoring opt-in default: N below 2 GB (hang risk), Y otherwise.
monitoring_default_for_ram() {
    local total_mb
    total_mb=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    if [[ "$total_mb" -gt 0 && "$total_mb" -lt 2048 ]]; then
        echo "n"
    else
        echo "y"
    fi
}

ensure_admin_password() {
    # Check if admin password is unset, empty, or still the insecure default
    local current_password=""
    if [[ -f ".env" ]]; then
        current_password=$(grep -E "^ADMIN_PASSWORD=" .env 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'")
    fi

    if [[ -z "$current_password" || "$current_password" == "change_me_to_something_secure" || "$current_password" == "admin" ]]; then
        echo ""
        echo -e "${WHITE}Admin dashboard password${NC}"
        echo "  Press Enter to generate a random password, or type your own"
        printf "  Password: "
        input_password=""
        read -r input_password || true   # EOF on closed stdin → fall through to auto-gen
        if [[ -z "$input_password" ]]; then
            input_password=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
        fi

        if grep -q "^ADMIN_PASSWORD=" .env 2>/dev/null; then
            sed -i "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=\"$input_password\"|" .env
        else
            echo "ADMIN_PASSWORD=\"$input_password\"" >> .env
        fi
        success "Admin password configured"
        echo ""

        # Show password prominently
        echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
        echo -e "  ${WHITE}Admin Password:${NC} ${CYAN}$input_password${NC}"
        echo ""
        echo -e "  ${YELLOW}⚠ IMPORTANT: Save this password! It's also stored in .env${NC}"
        echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
        echo ""
        return 0
    fi
    return 0  # already set — no-op, not an error (returning 1 here aborts under `set -e`)
}

check_prerequisites() {
    local missing=0

    print_section "Checking Prerequisites"

    # Check Docker
    if command -v docker &> /dev/null; then
        success "Docker is installed"
    else
        warn "Docker is not installed"
        if confirm "Install Docker now?"; then
            if install_docker; then
                success "Docker installed"
            else
                missing=1
            fi
        else
            error "Docker is required"
            echo "  Install from: https://docs.docker.com/get-docker/"
            missing=1
        fi
    fi

    # Check Docker Compose (only if Docker is installed)
    if command -v docker &> /dev/null; then
        if docker compose version &> /dev/null; then
            success "Docker Compose is installed"
        else
            warn "Docker Compose is not installed"
            echo "  Docker Compose plugin is usually included with Docker."
            echo "  If you installed Docker manually, install Compose from:"
            echo "  https://docs.docker.com/compose/install/"
            missing=1
        fi
    fi

    # Check .env file
    if [[ -f ".env" ]]; then
        success ".env file exists"
        # Validate critical fields — covers the case where a previous
        # interactive bootstrap was aborted mid-prompt (e.g. user typed
        # DOMAIN, Ctrl-C'd before ACME_EMAIL / ADMIN_PASSWORD). Without
        # this we'd silently skip every missing field on the next run.
        local _existing_domain
        _existing_domain=$(get_env_val "DOMAIN" ".env" "")
        if [[ -n "$_existing_domain" ]]; then
            # Auto-clean a malformed DOMAIN (e.g. "https://t7d.my/" → "t7d.my").
            if [[ "$_existing_domain" =~ ^https?:// ]] || [[ "$_existing_domain" == */* ]] || [[ "$_existing_domain" == *:* ]]; then
                local _cleaned
                _cleaned=$(sanitize_domain "$_existing_domain")
                if is_valid_domain "$_cleaned"; then
                    warn "DOMAIN in .env was malformed: '$_existing_domain' → cleaning to '$_cleaned'"
                    update_env_var ".env" "DOMAIN" "\"$_cleaned\""
                    _existing_domain="$_cleaned"
                else
                    warn "DOMAIN in .env looks invalid: '$_existing_domain' — edit .env or re-run with an empty .env to re-prompt."
                fi
            fi
            # DOMAIN set → ACME_EMAIL is needed for Let's Encrypt.
            local _existing_email
            _existing_email=$(get_env_val "ACME_EMAIL" ".env" "")
            if [[ -z "$_existing_email" ]]; then
                echo ""
                warn "ACME_EMAIL is not set (required for Let's Encrypt TLS certificate)."
                echo -e "${WHITE}Email address${NC} (for Let's Encrypt TLS certificate)"
                printf "  Email: "
                local input_email_resume=""
                read -r -e input_email_resume
                if [[ -n "$input_email_resume" ]]; then
                    update_env_var ".env" "ACME_EMAIL" "\"$input_email_resume\""
                    success "Email set to: $input_email_resume"
                else
                    warn "No email set — edit .env later or run bootstrap again."
                fi
            fi
        fi
        # Always check admin password (idempotent — no-op if already set securely).
        ensure_admin_password
    else
        warn ".env file not found"
        if [[ -f ".env.example" ]]; then
            if confirm "Copy .env.example to .env?" "y"; then
                cp .env.example .env
                success "Created .env from .env.example"
                echo ""
                echo -e "${CYAN}Configure your MoaV installation:${NC}"
                echo ""

                # Ask for domain — loop until valid hostname, empty (domainless),
                # or 3 invalid tries.
                echo -e "${WHITE}Domain name${NC} (required for TLS-based protocols)"
                echo "  Example: vpn.example.com"
                echo "  Leave empty to run only domainless services"

                local input_domain="" _attempts=0
                while true; do
                    printf "  Domain: "
                    read -r -e input_domain
                    [[ -z "$input_domain" ]] && break    # empty = domainless

                    local raw_domain="$input_domain"
                    input_domain=$(sanitize_domain "$input_domain")
                    if [[ "$input_domain" != "$raw_domain" ]]; then
                        info "Cleaned input: '$raw_domain' → '$input_domain'"
                    fi
                    if is_valid_domain "$input_domain"; then
                        break
                    fi
                    _attempts=$((_attempts + 1))
                    warn "'$raw_domain' isn't a valid hostname (need at least one dot, only letters/digits/dots/hyphens, no spaces or special chars)."
                    if [[ $_attempts -ge 3 ]]; then
                        echo ""
                        warn "Three invalid tries — saving the last value as-is. Edit .env manually if needed."
                        break
                    fi
                    echo "  Please try again, or leave empty for domainless mode."
                done

                local domainless_mode=false
                if [[ -n "$input_domain" ]]; then
                    update_env_var ".env" "DOMAIN" "\"$input_domain\""
                    success "Domain set to: $input_domain"
                    echo ""

                    # Ask for email (only if domain is set)
                    echo -e "${WHITE}Email address${NC} (for Let's Encrypt TLS certificate)"
                    printf "  Email: "
                    read -r -e input_email
                    if [[ -n "$input_email" ]]; then
                        update_env_var ".env" "ACME_EMAIL" "\"$input_email\""
                        success "Email set to: $input_email"
                    else
                        warn "No email set - you can edit .env later"
                    fi

                    # Detect server IP and show DNS template
                    echo ""
                    info "Detecting server IP..."
                    local detected_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || curl -s --max-time 5 https://ifconfig.me 2>/dev/null || echo "YOUR_SERVER_IP")
                    if [[ "$detected_ip" != "YOUR_SERVER_IP" ]]; then
                        success "Detected IP: $detected_ip"
                        # Save to .env
                        if grep -q "^SERVER_IP=" .env 2>/dev/null; then
                            sed -i "s|^SERVER_IP=.*|SERVER_IP=\"$detected_ip\"|" .env
                        else
                            echo "SERVER_IP=\"$detected_ip\"" >> .env
                        fi
                    fi
                    echo ""

                    # Show DNS configuration template
                    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
                    echo -e "${WHITE}  DNS Configuration Required${NC}"
                    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
                    echo ""
                    echo "  Add these DNS records in your DNS provider (e.g., Cloudflare):"
                    echo ""
                    echo -e "  ${WHITE}Required Records:${NC}"
                    printf "  %-6s %-12s %-20s %-18s %s\n" "Type" "Name" "Value" "Proxy" "Used by"
                    printf "  %-6s %-12s %-20s %-18s %s\n" "────" "────" "─────" "────" "───────"
                    printf "  %-6s %-12s %-20s %-18s %s\n" "A" "@" "$detected_ip" "DNS only (gray)" "Reality, Trojan, Hysteria2, XHTTP, WG"
                    echo ""
                    echo -e "  ${WHITE}For DNS Tunnels (dnstt, Slipstream, MasterDNS, XDNS):${NC}"
                    printf "  %-6s %-12s %-20s %-18s %s\n" "A" "dns" "$detected_ip" "DNS only (gray)" "NS delegation target"
                    printf "  %-6s %-12s %-20s %-18s %s\n" "NS" "t" "dns.$input_domain" "-" "dnstt"
                    printf "  %-6s %-12s %-20s %-18s %s\n" "NS" "s" "dns.$input_domain" "-" "Slipstream"
                    printf "  %-6s %-12s %-20s %-18s %s\n" "NS" "m" "dns.$input_domain" "-" "MasterDNS"
                    printf "  %-6s %-12s %-20s %-18s %s\n" "NS" "x" "dns.$input_domain" "-" "XDNS"
                    echo ""
                    echo -e "  ${WHITE}Optional - CDN Mode (Cloudflare proxied):${NC}"
                    printf "  %-6s %-12s %-20s %-18s %s\n" "A" "cdn" "$detected_ip" "Proxied (orange)" "CDN VLESS"
                    printf "  %-6s %-12s %-20s %-18s %s\n" "A" "grafana" "$detected_ip" "Proxied (orange)" "Grafana dashboard"
                    echo ""
                    echo -e "  ${YELLOW}⚠ CDN Mode requires an Origin Rule in Cloudflare:${NC}"
                    echo "    Rules → Origin Rules → Create rule"
                    echo "    • Match: Hostname equals cdn.$input_domain"
                    echo "    • Action: Destination Port → Rewrite to 2082"
                    echo ""
                    echo -e "  See https://moav.sh/docs/DNS for detailed instructions."
                    echo ""
                    echo -e "  ${DIM}A BIND-format zone file is saved to outputs/dns-records.txt${NC}"
                    echo -e "  ${DIM}Import it in Cloudflare: DNS > Records > Import and Upload${NC}"
                    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
                    echo ""

                    # Ask user to confirm DNS is configured
                    if ! confirm "Have you configured DNS records (or will do so now)?" "y"; then
                        echo ""
                        warn "DNS must be configured before services will work properly."
                        echo "  You can configure DNS later and run 'moav bootstrap' again."
                        echo ""
                    fi
                else
                    # No domain - warn about disabled services
                    echo ""
                    warn "No domain provided!"
                    echo ""
                    echo -e "  ${YELLOW}Services that require a domain (will be disabled):${NC}"
                    echo "    • Trojan, AnyTLS, Hysteria2, CDN VLESS (need TLS certificates)"
                    echo "    • TrustTunnel"
                    echo "    • DNS tunnels (dnstt, Slipstream, MasterDNS, XDNS)"
                    echo ""
                    echo -e "  ${GREEN}Services that work without a domain:${NC}"
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

                    if confirm "Continue with domainless mode?" "y"; then
                        domainless_mode=true
                        # Disable cert-needing protocols. The TROJAN/HYSTERIA2/DNSTT/
                        # SLIPSTREAM/MASTERDNS/TRUSTTUNNEL set must match bootstrap.sh:
                        # 41-46. XDNS is added here so dns-router (in the dnstunnel
                        # profile) doesn't fight systemd-resolved for port 53 with
                        # nothing to route; direct-mode XDNS can be re-enabled manually.
                        for var in ENABLE_TROJAN ENABLE_ANYTLS ENABLE_HYSTERIA2 ENABLE_DNSTT ENABLE_SLIPSTREAM ENABLE_MASTERDNS ENABLE_XDNS ENABLE_TRUSTTUNNEL; do
                            update_env_var ".env" "$var" "false"
                        done
                        # Derive DEFAULT_PROFILES from the mutated ENABLE_* set (issue #106).
                        local _dl_profiles
                        _dl_profiles=$(derive_enabled_profiles ".env")
                        sed -i "s|^DEFAULT_PROFILES=.*|DEFAULT_PROFILES=\"${_dl_profiles}\"|" .env
                        success "Domain-less mode enabled"
                        info "Reality, XHTTP, Shadowsocks-2022, WireGuard, AmneziaWG, Telegram MTProxy, Admin, Conduit, and Snowflake will be available"
                    else
                        echo ""
                        info "Please enter a domain to use all services."
                        echo "  You can edit .env later and run 'moav bootstrap' again."
                        return 1
                    fi
                fi
                echo ""

                # Generate or ask for admin password
                if [[ "$domainless_mode" == "true" ]]; then
                    echo ""
                    echo "  (Admin will use self-signed certificate in domainless mode)"
                fi
                ensure_admin_password
            else
                missing=1
            fi
        else
            error ".env.example not found"
            missing=1
        fi
    fi

    # Check if Docker is running
    if command -v docker &> /dev/null; then
        if docker info &> /dev/null; then
            success "Docker daemon is running"
        else
            warn "Docker daemon is not running"
            if confirm "Start Docker now?"; then
                info "Starting Docker..."
                sudo systemctl start docker 2>/dev/null || sudo service docker start 2>/dev/null || true
                sleep 2
                if docker info &> /dev/null; then
                    success "Docker daemon started"
                else
                    error "Failed to start Docker daemon"
                    echo "  You may need to:"
                    echo "    1. Log out and back in (for group permissions)"
                    echo "    2. Run: sudo systemctl start docker"
                    missing=1
                fi
            else
                error "Docker daemon is required"
                echo "  Start with: sudo systemctl start docker"
                missing=1
            fi
        fi
    fi

    # Check optional dependencies
    if command -v qrencode &> /dev/null; then
        success "qrencode is installed (for QR codes)"
    else
        warn "qrencode not installed (needed for QR codes in user packages)"
        if confirm "Install qrencode now?"; then
            install_qrencode
        else
            echo "  You can install later with:"
            echo "    Linux (Debian/Ubuntu): sudo apt install qrencode"
            echo "    Linux (RHEL/Fedora):   sudo dnf install qrencode"
            echo "    macOS:                 brew install qrencode"
        fi
    fi

    if [[ $missing -eq 1 ]]; then
        echo ""
        error "Prerequisites check failed. Please fix the issues above."
        rm -f "$PREREQS_FILE" 2>/dev/null
        exit 1
    fi

    success "All prerequisites met!"
    # Mark prerequisites as checked
    touch "$PREREQS_FILE"

    # Offer to install globally if not already installed
    if ! is_installed; then
        echo ""
        if confirm "Install 'moav' command globally? (run from anywhere)" "y"; then
            do_install
        fi
    fi
}

prereqs_already_checked() {
    # Prerequisites must be re-checked if .env is missing
    [[ -f "$PREREQS_FILE" ]] && [[ -f ".env" ]]
}







# =============================================================================
# Service Management
# =============================================================================


# =============================================================================
# User Management
# =============================================================================


# =============================================================================
# Build Management
# =============================================================================


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

    # Run test (mount bundle + dnstt/slipstream outputs)
    docker run --rm \
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
                local env_socks=$(grep -E "^CLIENT_SOCKS_PORT=" .env 2>/dev/null | cut -d= -f2 | tr -d ' "')
                local env_http=$(grep -E "^CLIENT_HTTP_PORT=" .env 2>/dev/null | cut -d= -f2 | tr -d ' "')
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



# =============================================================================
# Conduit lifetime-offset auto-updater (systemd watcher)
# =============================================================================
# conduit_bytes_* gauges reset on every Conduit restart; update-conduit-offsets.sh
# banks the ended session into a persistent offset so the *_lifetime totals
# survive restarts — but only if run promptly after each restart. This installs a
# systemd service (scripts/conduit-offsets-watch.sh) that reacts to Conduit
# `start` events and runs the updater automatically.

CONDUIT_OFFSETS_UNIT="moav-conduit-offsets.service"
CONDUIT_OFFSETS_UNIT_PATH="/etc/systemd/system/${CONDUIT_OFFSETS_UNIT}"

# Is systemd actually the init system here? (false in many containers / WSL)
_has_systemd() {
    [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1
}

# Prefix for privileged writes (empty when already root).
_root_prefix() {
    if [[ $EUID -eq 0 ]]; then
        echo ""
    elif command -v sudo >/dev/null 2>&1; then
        echo "sudo"
    else
        echo ""  # caller will fail loudly on the privileged op
    fi
}

conduit_offsets_install() {
    local quiet="${1:-}"
    if ! _has_systemd; then
        [[ "$quiet" == "--quiet" ]] && return 0
        error "systemd not detected — cannot install the auto-updater service."
        echo "  Run scripts/update-conduit-offsets.sh manually after each Conduit restart,"
        echo "  or add it to cron. (This host isn't running systemd as init.)"
        return 1
    fi

    local sudo_prefix; sudo_prefix=$(_root_prefix)
    if [[ $EUID -ne 0 && -z "$sudo_prefix" ]]; then
        error "Need root (or sudo) to install ${CONDUIT_OFFSETS_UNIT}."
        return 1
    fi

    # Write the unit, pinned to this install's absolute path.
    $sudo_prefix tee "$CONDUIT_OFFSETS_UNIT_PATH" >/dev/null <<UNIT
[Unit]
Description=MoaV Conduit lifetime bandwidth offset auto-updater
Documentation=https://github.com/MotherofallVPNs/moav
After=docker.service
Requires=docker.service

[Service]
Type=simple
WorkingDirectory=${SCRIPT_DIR}
ExecStart=/bin/bash ${SCRIPT_DIR}/scripts/conduit-offsets-watch.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT

    $sudo_prefix systemctl daemon-reload
    if $sudo_prefix systemctl enable --now "$CONDUIT_OFFSETS_UNIT" >/dev/null 2>&1; then
        [[ "$quiet" == "--quiet" ]] || success "Installed and started ${CONDUIT_OFFSETS_UNIT}"
        [[ "$quiet" == "--quiet" ]] && info "Conduit lifetime offsets will now auto-update on each restart (${CONDUIT_OFFSETS_UNIT})"
        return 0
    else
        error "Failed to enable ${CONDUIT_OFFSETS_UNIT}. Check: systemctl status ${CONDUIT_OFFSETS_UNIT}"
        return 1
    fi
}

conduit_offsets_uninstall() {
    if ! _has_systemd; then
        warn "systemd not detected — nothing to uninstall."
        return 0
    fi
    local sudo_prefix; sudo_prefix=$(_root_prefix)
    $sudo_prefix systemctl disable --now "$CONDUIT_OFFSETS_UNIT" >/dev/null 2>&1 || true
    $sudo_prefix rm -f "$CONDUIT_OFFSETS_UNIT_PATH"
    $sudo_prefix systemctl daemon-reload
    success "Removed ${CONDUIT_OFFSETS_UNIT} (offsets are no longer auto-updated; run scripts/update-conduit-offsets.sh manually if needed)"
}

conduit_offsets_status() {
    if ! _has_systemd; then
        info "systemd not detected on this host."
        return 0
    fi
    if [[ -f "$CONDUIT_OFFSETS_UNIT_PATH" ]]; then
        systemctl status "$CONDUIT_OFFSETS_UNIT" --no-pager 2>/dev/null || true
    else
        info "${CONDUIT_OFFSETS_UNIT} is not installed. Install with: moav conduit-offsets install"
    fi
}

cmd_conduit_offsets() {
    case "${1:-status}" in
        install)   conduit_offsets_install ;;
        uninstall|remove) conduit_offsets_uninstall ;;
        status)    conduit_offsets_status ;;
        *)
            echo "Usage: moav conduit-offsets {install|uninstall|status}"
            echo ""
            echo "  install    Install a systemd watcher that re-banks Conduit lifetime"
            echo "             offsets automatically on every Conduit restart."
            echo "  uninstall  Remove the watcher (back to manual updates)."
            echo "  status     Show the watcher service status."
            return 1
            ;;
    esac
}

# Called at the end of `moav start`: auto-install the watcher the first time
# Conduit + monitoring are both running, so lifetime offsets stay accurate
# without the operator remembering to run the script. No-op if already
# installed, opted out (CONDUIT_OFFSETS_AUTOUPDATE=false), or no systemd.
auto_setup_conduit_offsets() {
    [[ "$(get_env_val "CONDUIT_OFFSETS_AUTOUPDATE" "$SCRIPT_DIR/.env" "true")" == "true" ]] || return 0
    _has_systemd || return 0
    [[ -f "$CONDUIT_OFFSETS_UNIT_PATH" ]] && return 0
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^moav-conduit$'    || return 0
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^moav-prometheus$' || return 0
    echo ""
    info "Conduit + monitoring detected — installing the lifetime-offset auto-updater..."
    conduit_offsets_install --quiet || \
        warn "Auto-install failed; run 'moav conduit-offsets install' manually (or set CONDUIT_OFFSETS_AUTOUPDATE=false to silence)."
}


# =============================================================================
# Entry Point
# =============================================================================

main_interactive() {
    # Start async update check (won't block, results cached for next header display)
    check_for_updates

    # Check prerequisites only if not already verified
    # Also re-check if .env is missing (user may have deleted it)
    if ! prereqs_already_checked; then
        print_header
        # Clear stale prereqs flag if .env is missing
        if [[ -f "$PREREQS_FILE" ]] && [[ ! -f ".env" ]]; then
            rm -f "$PREREQS_FILE"
        fi
        echo -e "${DIM}First run - checking prerequisites...${NC}"
        echo ""
        check_prerequisites
        echo ""
        sleep 1
    fi

    # Check if bootstrap needed
    if ! check_bootstrap; then
        warn "Bootstrap has not been run yet!"
        echo ""
        info "Bootstrap is required for first-time setup."
        echo "  It generates keys, obtains TLS certificates, and creates users."
        echo ""

        if confirm "Run bootstrap now?" "y"; then
            run_bootstrap || exit 1
            press_enter
        else
            warn "You can run bootstrap later from the main menu"
            warn "or manually with: docker compose --profile setup run --rm bootstrap"
            press_enter
        fi
    fi

    # Show main menu
    main_menu
}

main() {
    local cmd="${1:-}"

    case "$cmd" in
        "")
            main_interactive
            ;;
        help|--help|-h)
            show_usage
            ;;
        version|--version|-v)
            show_versions
            ;;
        install)
            do_install
            ;;
        uninstall)
            shift
            do_uninstall "$@"
            ;;
        update)
            shift
            cmd_update "$@"
            ;;
        _post-update)
            # Internal: re-exec target after self-update pulls new code.
            # $2 = short commit before the pull (for config-template diffing).
            check_component_versions
            check_source_rebuilds "${2:-}"
            migrate_dns_tunnel_state
            check_env_additions
            check_config_template_changes "${2:-}"
            print_post_update_apply_steps
            ;;
        check)
            cmd_check
            ;;
        doctor)
            shift
            cmd_doctor "$@"
            ;;
        bootstrap)
            cmd_bootstrap "$@"
            ;;
        domainless|domain-less|no-domain)
            cmd_domainless
            ;;
        admin)
            shift
            cmd_admin "$@"
            ;;
        profiles)
            cmd_profiles
            ;;
        start)
            shift
            cmd_start "$@"
            ;;
        stop)
            shift
            cmd_stop "$@"
            ;;
        restart)
            shift
            cmd_restart "$@"
            ;;
        status)
            cmd_status
            ;;
        logs)
            shift
            cmd_logs "$@"
            ;;
        users)
            cmd_users
            ;;
        user)
            shift
            cmd_user "$@"
            ;;
        build)
            shift
            cmd_build "$@"
            ;;
        test)
            shift
            cmd_test "$@"
            ;;
        client)
            shift
            cmd_client "$@"
            ;;
        export)
            shift
            cmd_export "$@"
            ;;
        import)
            shift
            cmd_import "$@"
            ;;
        migrate-ip|migrate_ip|migrateip)
            shift
            cmd_migrate_ip "$@"
            ;;
        regenerate-users|regenerate_users|regen-users)
            cmd_regenerate_users
            ;;
        net|net-tuning|sysctl)
            shift
            cmd_net "$@"
            ;;
        conduit-offsets|conduit_offsets|conduit-lifetime)
            shift
            cmd_conduit_offsets "$@"
            ;;
        cert|certs|certificate)
            shift
            cmd_cert "$@"
            ;;
        setup-dns|setup_dns|dns-setup)
            cmd_setup_dns
            ;;
        switch-dns|switch_dns|dns-switch|dnsswitch)
            shift
            cmd_switch_dns "$@"
            ;;
        donate)
            shift
            cmd_donate "$@"
            ;;
        conduit)
            shift
            cmd_conduit "$@"
            ;;
        *)
            error "Unknown command: $cmd"
            echo ""
            show_usage
            exit 1
            ;;
    esac
}

# Run main
main "$@"
