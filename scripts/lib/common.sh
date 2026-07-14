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
