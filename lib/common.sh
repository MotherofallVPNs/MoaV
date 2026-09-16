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

# The project's links, defined once. Five surfaces print them in two shapes.
MOAV_URL_SITE="https://moav.sh"
MOAV_URL_DOCS="https://moav.sh/docs"
MOAV_URL_TG="https://t.me/motherofallvpns"
MOAV_URL_X="https://x.com/motherofallvpns"
MOAV_URL_GH="https://github.com/MotherofallVPNs/MoaV"

# Compact footer: after `moav start` and at the end of `moav status`.
print_community_links() {
    echo -e "  ${DIM}Community: ${MOAV_URL_TG}  |  ${MOAV_URL_X}${NC}"
    echo -e "  ${DIM}Issues/bugs: ${MOAV_URL_GH}/issues${NC}"
}

# Without a DOMAIN the admin/Grafana TLS cert is self-signed, so browsers show
# "not secure" / ERR_CERT_AUTHORITY_INVALID on first visit. That's expected on a
# fresh install, not a bug — spell it out next to the URLs so operators don't
# think something broke. No-op once a DOMAIN (browser-trusted cert) is set.
print_tls_selfsigned_note() {
    [[ -z "$(get_env_val "DOMAIN" .env "")" ]] || return 0
    echo -e "  ${YELLOW}Note:${NC} the admin/Grafana cert is self-signed (no DOMAIN set), so your browser"
    echo -e "        will warn \"not secure\" / ERR_CERT_AUTHORITY_INVALID on first visit — that's"
    echo -e "        expected; click Advanced → Proceed. Set a DOMAIN for a trusted Let's Encrypt cert."
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
    printf "║  %-49s ║\n" "moav.sh  ·  t.me/motherofallvpns"
    if [[ -n "$update_line" ]]; then
        printf "║  ${NC}${YELLOW}%-49s${CYAN} ║\n" "$update_line"
    fi
    echo "╚════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# One row of the profile-selection box, padded to the box width. Colour wraps
# the padded field, never sits inside it -- ANSI occupies no columns.
PROFILE_ROW_W=65
profile_row() {
    local num="$1" name="$2" desc="$3" color="${4:-}"
    local text
    text=$(printf '  %s   %-13s%s' "$num" "$name" "$desc")
    printf '  %s│%s%s%-*s%s%s│%s' \
        "$CYAN" "$NC" "$color" "$PROFILE_ROW_W" "$text" "$NC" "$CYAN" "$NC"
}

# Full list: `moav help` footer, TUI exit, Ctrl+C goodbye. $1 = line prefix.
community_links() {
    local p="${1:-  }"
    echo -e "${p}Website:   ${MOAV_URL_SITE}"
    echo -e "${p}Telegram:  ${MOAV_URL_TG}"
    echo -e "${p}Twitter/X: ${MOAV_URL_X}"
    echo -e "${p}GitHub:    ${MOAV_URL_GH}"
    echo -e "${p}Docs:      ${MOAV_URL_DOCS}"
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

    # MOAV_NONINTERACTIVE=1 (install.sh answers/env mode, `--json` commands):
    # take the default without touching /dev/tty, so a prompt can never block
    # automation or leak into a JSON stream.
    if [[ "${MOAV_NONINTERACTIVE:-0}" == "1" ]]; then
        [[ "$default" == "y" ]]
        return
    fi

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


# -----------------------------------------------------------------------------
# JSON output helpers (`--json` on status / doctor / user list|add|remove).
# Pure bash: no jq dependency on the emitting side. Everything that reaches a
# JSON stream must be secret-free — the mobile app parses and may log it — so
# free-text details go through json_redact before json_escape.
# -----------------------------------------------------------------------------

# json_escape <string> — the string's body as a JSON string literal (no quotes).
# Backslash first, then quotes, then control characters.
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    # Remaining C0 controls (incl. ESC from stray colour codes) -> \u00XX.
    if [[ "$s" == *[$'\x01'-$'\x1f']* ]]; then
        local out="" i c
        for ((i = 0; i < ${#s}; i++)); do
            c="${s:i:1}"
            if [[ "$c" == [$'\x01'-$'\x1f'] ]]; then
                printf -v c '\\u%04x' "'$c"
            fi
            out+="$c"
        done
        s="$out"
    fi
    printf '%s' "$s"
}

# json_str <string> — a quoted JSON string literal.
json_str() {
    printf '"%s"' "$(json_escape "$1")"
}

# json_bool <true|false|0|1|yes|no> — a JSON boolean.
json_bool() {
    case "${1:-}" in
        true|1|yes|y|on) printf 'true' ;;
        *)               printf 'false' ;;
    esac
}

# json_str_array <item>... — ["a","b"] (empty -> []).
json_str_array() {
    local out="[" first=true item
    for item in "$@"; do
        [[ "$first" == "true" ]] || out+=","
        first=false
        out+="$(json_str "$item")"
    done
    printf '%s]' "$out"
}

# strip_ansi — remove SGR colour codes from stdin (doctor output is coloured).
strip_ansi() {
    sed -E "s/$(printf '\033')\\[[0-9;]*[A-Za-z]//g"
}

# json_redact — mask anything secret-shaped in free text on stdin, for details
# that are captured from human-oriented output rather than built up from known-
# safe fields: server IPs (v4 + v6), URLs / share-links (scheme://...), and
# long hex/base64-looking tokens (keys, UUIDs, passwords, short_ids). The IPv6
# rule runs twice: a match consumes its trailing delimiter, which would hide an
# adjacent address from a single pass.
# Over-redacting a docs hint is fine; leaking one address to a phone log is not.
json_redact() {
    sed -E \
        -e 's#[A-Za-z][A-Za-z0-9+.-]*://[^[:space:]"]+#[redacted-link]#g' \
        -e 's/(^|[^0-9.])[0-9]{1,3}(\.[0-9]{1,3}){3}(\/[0-9]{1,2})?/\1[redacted-ip]/g' \
        -e 's/(^|[^0-9A-Za-z:])([0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{1,4}(\/[0-9]{1,3})?([^0-9A-Za-z:]|$)/\1[redacted-ip]\4/g' \
        -e 's/(^|[^0-9A-Za-z:])([0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{1,4}(\/[0-9]{1,3})?([^0-9A-Za-z:]|$)/\1[redacted-ip]\4/g' \
        -e 's/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/[redacted]/g' \
        -e 's/[A-Za-z0-9+\/_=-]{20,}/[redacted]/g'
}

# json_detail — one-line, ANSI-free, redacted, JSON-escaped body from stdin
# (used for doctor check details). Lines joined with "; ", whitespace squeezed.
json_detail() {
    local text
    text=$(strip_ansi | json_redact | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g' | grep -v '^$' | awk 'BEGIN { ORS = "" } NR > 1 { print "; " } { print }')
    json_escape "$text"
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
