#!/bin/bash
# lib/common.sh — foundation helpers for the moav CLI: update checks, version
# compare, output/section printing, prompts, service URLs, and the run_command
# wrapper. Sourced FIRST by moav.sh, which sets the globals these rely on
# (colors, SCRIPT_DIR, VERSION, UPDATE_CACHE_FILE) before sourcing. Every other
# lib module may assume these are available.
#
# Definitions only — nothing here runs at source time.

# Check for updates (async, cached for 1 hour)
check_for_updates() {
    local cache_file="$UPDATE_CACHE_FILE"
    local cache_max_age=3600  # 1 hour

    # Only check on main branch
    local branch
    branch=$(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [[ "$branch" != "main" && "$branch" != "master" ]]; then
        return
    fi

    # Check cache
    if [[ -f "$cache_file" ]]; then
        local cache_age
        cache_age=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0) ))
        if [[ $cache_age -lt $cache_max_age ]]; then
            LATEST_VERSION=$(cat "$cache_file" 2>/dev/null)
            return
        fi
    fi

    # Fetch latest release (in background, don't block)
    {
        local latest
        latest=$(curl -s --max-time 3 "https://api.github.com/repos/MotherofallVPNs/moav/releases/latest" 2>/dev/null | grep '"tag_name"' | head -1 | cut -d'"' -f4 | sed 's/^v//')
        if [[ -n "$latest" && "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$latest" > "$cache_file"
        fi
    } &
}

# Read cached update info
get_latest_version() {
    if [[ -f "$UPDATE_CACHE_FILE" ]]; then
        cat "$UPDATE_CACHE_FILE" 2>/dev/null
    fi
}

# Compare semver versions: returns 0 if $1 > $2
version_gt() {
    local v1="$1" v2="$2"
    local IFS=.
    local i v1_parts=($v1) v2_parts=($v2)
    for ((i=0; i<3; i++)); do
        local n1="${v1_parts[i]:-0}"
        local n2="${v2_parts[i]:-0}"
        if ((n1 > n2)); then return 0; fi
        if ((n1 < n2)); then return 1; fi
    done
    return 1
}

# Footer-style community links, shown after `moav start` success and at the
# end of `moav status`. GitHub is included for bug/issue reporting.
print_community_links() {
    echo -e "  ${DIM}Community: https://t.me/motherofallvpns  |  https://x.com/motherofallvpns${NC}"
    echo -e "  ${DIM}Issues/bugs: https://github.com/MotherofallVPNs/MoaV/issues${NC}"
}

print_header() {
    # Only clear when stdout is a TTY (avoids "TERM not set" abort under setsid).
    if [[ -t 1 ]]; then
        clear 2>/dev/null || true
    fi
    # Get current branch
    local branch
    branch=$(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    local version_line="v${VERSION}"
    if [[ -n "$branch" && "$branch" != "main" ]]; then
        version_line="v${VERSION} (${branch})"
    fi

    # Check for update (only on main branch)
    local update_line=""
    local latest
    latest=$(get_latest_version)
    if [[ -n "$latest" ]] && version_gt "$latest" "$VERSION"; then
        update_line="Update available: v${latest} (moav update)"
    fi

    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════════╗"
    echo "║                                                    ║"
    echo "║  ███╗   ███╗ ██████╗  █████╗ ██╗   ██╗             ║"
    echo "║  ████╗ ████║██╔═══██╗██╔══██╗██║   ██║             ║"
    echo "║  ██╔████╔██║██║   ██║███████║██║   ██║             ║"
    echo "║  ██║╚██╔╝██║██║   ██║██╔══██║╚██╗ ██╔╝             ║"
    echo "║  ██║ ╚═╝ ██║╚██████╔╝██║  ██║ ╚████╔╝              ║"
    echo "║  ╚═╝     ╚═╝ ╚═════╝ ╚═╝  ╚═╝  ╚═══╝               ║"
    echo "║                                                    ║"
    echo "║           Mother of all VPNs                       ║"
    echo "║                                                    ║"
    echo "║  Multi-protocol Circumvention Stack                ║"
    printf "║  %-49s ║\n" "$version_line"
    printf "║  %-49s ║\n" "t.me/motherofallvpns"
    if [[ -n "$update_line" ]]; then
        printf "║  ${NC}${YELLOW}%-49s${CYAN} ║\n" "$update_line"
    fi
    echo "╚════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_section() {
    echo ""
    echo -e "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}  $1${NC}"
    echo -e "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

success() {
    echo -e "${GREEN}✓${NC} $1"
}

warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

error() {
    echo -e "${RED}✗${NC} $1"
}

prompt() {
    echo -e "${CYAN}?${NC} $1"
}

confirm() {
    local message="$1"
    local default="${2:-n}"

    if [[ "$default" == "y" ]]; then
        prompt "$message [Y/n]: "
    else
        prompt "$message [y/N]: "
    fi

    # Read single character from /dev/tty to work when stdin is piped
    local response
    if read -n 1 -r response < /dev/tty 2>/dev/null; then
        echo ""  # newline after single-char input
        response=${response:-$default}
    else
        echo ""
        response="$default"
    fi

    # Reject invalid input — only accept y/Y/n/N/empty
    while [[ -n "$response" && ! "$response" =~ ^[YyNn]$ ]]; do
        if [[ "$default" == "y" ]]; then
            prompt "$message [Y/n]: "
        else
            prompt "$message [y/N]: "
        fi
        if read -n 1 -r response < /dev/tty 2>/dev/null; then
            echo ""
            response=${response:-$default}
        else
            echo ""
            response="$default"
        fi
    done

    if [[ "$default" == "y" ]]; then
        # Default yes: return true unless explicitly 'n' or 'N'
        [[ ! "$response" =~ ^[Nn]$ ]]
    else
        # Default no: return true only if 'y' or 'Y'
        [[ "$response" =~ ^[Yy]$ ]]
    fi
}

press_enter() {
    echo ""
    echo -e "${DIM}Press Enter to continue...${NC}"
    read -r < /dev/tty 2>/dev/null || true
}

get_admin_url() {
    # Get admin URL using DOMAIN or SERVER_IP from .env.
    # Use get_env_val (which strips trailing `# comments`) so PORT_ADMIN=9443
    # doesn't render as "https://host:9443      # Admin dashboard".
    local admin_port=$(get_env_val "PORT_ADMIN" .env "9443")
    local domain=$(get_env_val "DOMAIN" .env "")
    local server_ip=$(get_env_val "SERVER_IP" .env "")
    local admin_host="${domain:-${server_ip:-localhost}}"
    echo "https://${admin_host}:${admin_port}"
}

get_grafana_url() {
    # Get Grafana URL using DOMAIN or SERVER_IP from .env (get_env_val strips
    # trailing `# comments` from values like `PORT_GRAFANA=9444  # comment`).
    local grafana_port=$(get_env_val "PORT_GRAFANA" .env "9444")
    local domain=$(get_env_val "DOMAIN" .env "")
    local server_ip=$(get_env_val "SERVER_IP" .env "")
    local grafana_host="${domain:-${server_ip:-localhost}}"
    echo "https://${grafana_host}:${grafana_port}"
}

get_grafana_cdn_url() {
    local grafana_subdomain=$(get_env_val "GRAFANA_SUBDOMAIN" .env "")
    local domain=$(get_env_val "DOMAIN" .env "")
    if [[ -n "$grafana_subdomain" ]] && [[ -n "$domain" ]]; then
        echo "https://${grafana_subdomain}.${domain}:2083"
    fi
}


run_command() {
    local cmd="$1"
    local description="${2:-Running command}"

    echo ""
    echo -e "${DIM}Command:${NC}"
    echo -e "${WHITE}  $cmd${NC}"
    echo ""

    if confirm "Execute this command?" "y"; then
        echo ""
        eval "$cmd"
        return $?
    else
        warn "Command cancelled"
        return 1
    fi
}
