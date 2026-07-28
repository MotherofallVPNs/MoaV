#!/bin/bash
# Common utility functions

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Generate a random password
generate_password() {
    local length="${1:-24}"
    pwgen -s "$length" 1
}

# Generate UUID
generate_uuid() {
    sing-box generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen
}

# Check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Create directory if it doesn't exist
ensure_dir() {
    mkdir -p "$1"
}

# Build the wstunnel client command for WireGuard-over-WebSocket bundles.
# wss:// when a domain (hence a TLS cert) is configured, else plain ws://.
# The per-install path secret (state/keys/wstunnel-path.secret, shared with the
# server) becomes an HTTP-upgrade path prefix so scanners can't complete the
# upgrade blind. Reads DOMAIN/SERVER_IP from the caller's environment.
wstunnel_client_cmd() {
    local state_dir="${1:-${STATE_DIR:-./state}}"
    local secret="" pathopt="" url
    [[ -f "$state_dir/keys/wstunnel-path.secret" ]] && \
        secret=$(cat "$state_dir/keys/wstunnel-path.secret" 2>/dev/null)
    [[ -n "$secret" ]] && pathopt="--http-upgrade-path-prefix $secret "
    if [[ -n "${DOMAIN:-}" && "$DOMAIN" != "YOUR_DOMAIN" ]]; then
        url="wss://${DOMAIN}:8080"
    else
        url="ws://${SERVER_IP:-YOUR_SERVER_IP}:8080"
    fi
    echo "wstunnel client -L udp://127.0.0.1:51820:moav-wireguard:51820 ${pathopt}${url}"
}

# -----------------------------------------------------------------------------
# net_next_free_octet <config_file> <subnet_prefix> [extra_used_octet ...]
# Next free host octet (2..254) in a /24 for a wg/awg peer. Scans <config_file>
# for "AllowedIPs = <prefix>.N" and merges any extra octets (e.g. scraped from a
# live `wg/awg show <if> allowed-ips` on the host). Picks max-used + 1 so it is
# collision-safe across revoked-user gaps. Echoes the octet, or returns 1 (full).
# -----------------------------------------------------------------------------
net_next_free_octet() {
    local config_file="$1"; local prefix="$2"; shift 2
    local used="$*"
    local esc="${prefix//./\\.}"
    if [[ -f "$config_file" ]]; then
        used+=" $(grep "AllowedIPs = ${esc}\." "$config_file" 2>/dev/null \
            | sed "s|.*${esc}\.\([0-9]*\).*|\1|" | tr '\n' ' ')"
    fi
    local next=2 o
    for o in $used; do
        [[ "$o" =~ ^[0-9]+$ ]] || continue
        (( o >= next )) && next=$((o + 1))
    done
    (( next > 254 )) && return 1
    printf '%s\n' "$next"
}

# Secret material under state/keys must not be world-readable.
#
# Files created with `(umask 077 && ...)` came out 0600 correctly, but everything
# written via `cat > … <<EOF` or `echo … >` inherited umask 022 and landed 0644 —
# world-readable. On a live server that left REALITY_PRIVATE_KEY (reality.env),
# the Clash API secret and Hysteria2 obfs password (clash-api.env), the
# Shadowsocks PSK, the MasterDNS/GooseRelay keys and the wstunnel path secret all
# at 0644, while the raw *.key files beside them were correctly 0600.
#
# Idempotent: safe to call on every bootstrap, and it repairs existing installs.
# Public counterparts (*.pub, certs) are skipped — other parties must read those.
# Every container that mounts the state volume runs as root, so tightening the
# mode cannot lock a service out of its own key material.
secure_state_keys() {
    local keys_dir="${1:-$STATE_DIR/keys}"
    [[ -d "$keys_dir" ]] || return 0
    local f base fixed=0
    for f in "$keys_dir"/*; do
        [[ -f "$f" ]] || continue
        base="$(basename "$f")"
        case "$base" in
            *.pub|*.pub.hex|*-cert.pem|*.crt|*.csr) continue ;;   # public by design
            # EXCEPTION -- clash-api.env must stay group/world readable.
            # admin/main.py reads it directly, and the admin container drops to a
            # NON-root user (`exec su-exec moav …`, uid 100 / gid 101 on
            # python:3.12-alpine), so 0600 root-owned locks it out and the
            # container crash-loops with PermissionError. bootstrap's
            # `chown -R 0:1000` never applied to it either -- /configs and
            # /outputs only work for admin because they are world-readable.
            # Tracked: admin should get this secret without a world-readable file.
            #
            # Actively RESTORE readability rather than merely skipping: an
            # earlier build of this function already tightened the file, and the
            # state volume persists across upgrades, so a plain `continue` would
            # leave those installs permanently broken. Repair must be
            # bidirectional to be a repair at all.
            clash-api.env)
                chmod 644 "$f" 2>/dev/null || true
                continue
                ;;
        esac
        # Only touch what is actually loose, so the log stays meaningful.
        #
        # `find -perm /077` is GNU-only: BSD/macOS find rejects it, the test
        # yields nothing, and this function then silently chmods NOTHING. In
        # production it runs on Linux so it worked, but a helper that no-ops on
        # a whole platform -- and a test that fails only there -- teaches people
        # to ignore red output. Read the mode directly instead, GNU form first
        # then BSD.
        local mode
        mode=$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null || echo "")
        # Pad to 3 digits so 640 and 40 do not compare alike.
        while [[ -n "$mode" && ${#mode} -lt 3 ]]; do mode="0$mode"; done
        # Loose = any group or other bit set.
        if [[ -n "$mode" && "${mode:1}" != "00" ]]; then
            chmod 600 "$f" 2>/dev/null && fixed=$((fixed + 1))
        fi
    done
    [[ $fixed -gt 0 ]] && log_info "Secured $fixed key file(s) in $keys_dir (0600)"
    return 0
}

# Read a value from a .env-style file — handles duplicates (last wins), inline
# comments, and quotes.
#   val=$(get_env_val "ENABLE_XHTTP" "$env_file" "true")
#
# DELIBERATE DUPLICATE of the definition in moav.sh. The host CLI (lib/) and the
# provisioning tree (scripts/lib/, mounted into containers as /app/lib) are
# separate source trees — the container never sees moav.sh, and the CLI should
# not pull in 15 protocol generators just to read a variable. The bodies are held
# byte-identical by tests/env-resolution-test.sh, so the two cannot drift; that
# check is what makes the duplication safe rather than a second implementation.
#
# Note `cut -d'=' -f2-`, not -f2: values legitimately contain '=' (base64
# padding), and cutting at the first one silently truncates credentials.
get_env_val() {
    local key="$1" file="$2" default="${3:-}"
    local val
    val=$(grep "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d'=' -f2- | sed 's/#.*//' | tr -d '"' | tr -d "'" | xargs) || true
    echo "${val:-$default}"
}
