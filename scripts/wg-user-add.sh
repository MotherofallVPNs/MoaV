#!/bin/bash
set -euo pipefail

# =============================================================================
# Add a new WireGuard peer
# Usage: ./scripts/wg-user-add.sh <username> [--no-reload]
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

source scripts/lib/common.sh
source scripts/lib/keys.sh
source scripts/lib/wireguard.sh   # WG_CONFIG_DIR is re-set to the host path below

# Parse arguments
USERNAME=""
NO_RELOAD=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-reload)
            NO_RELOAD=true
            shift
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            USERNAME="$1"
            shift
            ;;
    esac
done

if [[ -z "$USERNAME" ]]; then
    echo "Usage: $0 <username> [--no-reload]"
    echo "Example: $0 john"
    exit 1
fi

# Validate username
if [[ ! "$USERNAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    log_error "Invalid username. Use only letters, numbers, underscores, and hyphens."
    exit 1
fi

# Load environment
if [[ -f .env ]]; then
    set -a
    source .env
    set +a
fi

WG_CONFIG_DIR="configs/wireguard"
STATE_DIR="${STATE_DIR:-./state}"
OUTPUT_DIR="outputs/bundles/$USERNAME"
WG_NETWORK="10.66.66.0/24"
WG_NETWORK_V6="fd00:cafe:beef::/64"

# Check if WireGuard config exists
if [[ ! -f "$WG_CONFIG_DIR/wg0.conf" ]]; then
    log_error "WireGuard config not found. Run bootstrap first or enable WireGuard."
    exit 1
fi

# Create directories
mkdir -p "$OUTPUT_DIR"
mkdir -p "$STATE_DIR/users/$USERNAME"

log_info "Adding WireGuard peer '$USERNAME'..."

# IPv6 autodetect must happen before the lib call — wireguard_add_peer assigns
# a v6 address only when SERVER_IPV6 is set.
if [[ -z "${SERVER_IPV6:-}" ]] && [[ "${SERVER_IPV6:-}" != "disabled" ]]; then
    SERVER_IPV6=$(curl -6 -s --max-time 3 https://api6.ipify.org 2>/dev/null || echo "")
fi
[[ "${SERVER_IPV6:-}" == "disabled" ]] && SERVER_IPV6=""

# Scrape the running interface's in-use octets so a config/runtime drift can't
# hand out a colliding address (the lib merges these with its config scan).
# compose_timeout: a wedged container must not hang user provisioning (#220).
RUNNING_IPS=""
if compose_timeout ps wireguard --status running 2>/dev/null | tail -n +2 | grep -q .; then
    RUNNING_IPS=$(compose_timeout exec -T wireguard wg show wg0 allowed-ips 2>/dev/null | grep '10\.66\.66\.' | sed 's/.*10\.66\.66\.\([0-9]*\).*/\1/' || echo "")
fi

# Keygen, IP allocation, state write and wg0.conf append all live in the shared
# lib — the same code the container path runs. This was an inline copy that had
# drifted: it hard-errored on an existing peer instead of reusing state (the
# lib re-issues the bundle idempotently), always minted fresh keys, and lacked
# the incomplete-state-file and third-state guards.
# shellcheck disable=SC2086  # word-splitting is intended: one arg per octet
rc=0
wireguard_add_peer "$USERNAME" $RUNNING_IPS || rc=$?
if [[ $rc -eq 2 ]]; then
    # Server has a peer but state has no keys — unrecoverable without revoke.
    exit 1
elif [[ $rc -ne 0 ]]; then
    log_error "Failed to add WireGuard peer for $USERNAME"
    exit 1
fi

# Read back what the lib allocated (or reused) for the hot-add and summary.
# shellcheck source=/dev/null
source "$STATE_DIR/users/$USERNAME/wireguard.env"
CLIENT_PUBLIC_KEY="$WG_PUBLIC_KEY"
CLIENT_IP="$WG_CLIENT_IP"
CLIENT_IP_V6="${WG_CLIENT_IP_V6:-}"

# Get server public key - prefer from running WireGuard, fallback to file
SERVER_PUBLIC_KEY=""

# If WireGuard is running, get the actual public key and sync it
if compose_timeout ps wireguard --status running 2>/dev/null | tail -n +2 | grep -q .; then
    SERVER_PUBLIC_KEY=$(compose_timeout exec -T wireguard wg show wg0 public-key 2>/dev/null | tr -d '\r\n')
    if [[ -n "$SERVER_PUBLIC_KEY" ]]; then
        # Best-effort sync to server.pub. If the caller (e.g. the admin container
        # running as uid 1000) only has read perms on configs/ — set by bootstrap
        # via `chown -R 0:1000` + `chmod -R g+r` — the write fails and we proceed
        # with the in-memory key, which is already authoritative.
        if echo "$SERVER_PUBLIC_KEY" > "$WG_CONFIG_DIR/server.pub" 2>/dev/null; then
            log_info "Synced server public key from running WireGuard"
        else
            log_info "Could not write $WG_CONFIG_DIR/server.pub (read-only); using in-memory key"
        fi
    fi
fi

# Fallback to file if not running or couldn't get key
if [[ -z "$SERVER_PUBLIC_KEY" ]]; then
    SERVER_PUBLIC_KEY=$(cat "$WG_CONFIG_DIR/server.pub" 2>/dev/null | tr -d '\r\n')
fi

if [[ -z "$SERVER_PUBLIC_KEY" ]]; then
    log_error "Server public key not found. Is WireGuard configured?"
    exit 1
fi

log_info "Using server public key: $SERVER_PUBLIC_KEY"

# Get server IP
SERVER_IP="${SERVER_IP:-$(curl -s --max-time 5 https://api.ipify.org || echo "YOUR_SERVER_IP")}"

# Build AllowedIPs (IPv4 + optional IPv6) — the wg0.conf append itself already
# happened inside wireguard_add_peer.
ALLOWED_IPS="$CLIENT_IP/32"
if [[ -n "$CLIENT_IP_V6" ]]; then
    ALLOWED_IPS="$CLIENT_IP/32, $CLIENT_IP_V6/128"
fi

# Generate the client configs (direct + optional IPv6 + wstunnel) via the shared
# lib, so host and container WireGuard bundles are byte-identical. It reads the
# private key + client IPs from wireguard.env (written above) and the server key
# from $WG_CONFIG_DIR/server.pub (synced above); honors SERVER_IPV6 + PORT_WIREGUARD.
wireguard_generate_client_config "$USERNAME" "$OUTPUT_DIR"

# wstunnel client command — shown in the terminal summary below. The full
# wstunnel setup guide (download, run, connect) lives in README.html.
WSTUNNEL_CMD="$(wstunnel_client_cmd)"

# Hot-add peer to running WireGuard if available (unless --no-reload)
if [[ "$NO_RELOAD" != "true" ]]; then
    if compose_timeout ps wireguard --status running 2>/dev/null | tail -n +2 | grep -q .; then
        log_info "Adding peer to running WireGuard..."

        # Use wg set to add peer dynamically
        if compose_timeout exec -T wireguard wg set wg0 peer "$CLIENT_PUBLIC_KEY" allowed-ips "$ALLOWED_IPS" 2>/dev/null; then
            log_info "Peer added to running WireGuard (hot reload)"
        else
            log_info "Hot reload failed, you may need to restart WireGuard"
            log_info "Run: docker compose --profile wireguard restart wireguard"
        fi
    else
        log_info "WireGuard not running, config will apply on next start"
    fi
fi

# Display results
echo ""
log_info "=== WireGuard peer '$USERNAME' created ==="
echo ""
echo "Client IP: $CLIENT_IP"
if [[ -n "$CLIENT_IP_V6" ]]; then
    echo "Client IPv6: $CLIENT_IP_V6"
fi
echo ""
echo "Configs generated:"
echo "  - wireguard.conf          (direct mode - IPv4 endpoint)"
if [[ -n "$SERVER_IPV6" ]]; then
    echo "  - wireguard-ipv6.conf     (direct mode - IPv6 endpoint)"
fi
echo "  - wireguard-wstunnel.conf (wstunnel mode - for restrictive networks)"
echo ""

# Generate QR images for user bundle
if command -v qrencode &>/dev/null; then
    qrencode -o "$OUTPUT_DIR/wireguard-qr.png" -s 6 -r "$OUTPUT_DIR/wireguard.conf" 2>/dev/null && \
        log_info "QR image saved to: $OUTPUT_DIR/wireguard-qr.png"

    # IPv6 QR code
    if [[ -n "$SERVER_IPV6" ]]; then
        qrencode -o "$OUTPUT_DIR/wireguard-ipv6-qr.png" -s 6 -r "$OUTPUT_DIR/wireguard-ipv6.conf" 2>/dev/null && \
            log_info "IPv6 QR image saved to: $OUTPUT_DIR/wireguard-ipv6-qr.png"
    fi

    # wstunnel QR code
    qrencode -o "$OUTPUT_DIR/wireguard-wstunnel-qr.png" -s 6 -r "$OUTPUT_DIR/wireguard-wstunnel.conf" 2>/dev/null && \
        log_info "wstunnel QR image saved to: $OUTPUT_DIR/wireguard-wstunnel-qr.png"
fi

echo ""
echo "=== Direct Config (use this for mobile) ==="
cat "$OUTPUT_DIR/wireguard.conf"
echo ""
echo "=== wstunnel Mode (for restrictive networks) ==="
echo "Run wstunnel first:"
echo "  ${WSTUNNEL_CMD}"
echo "Then use wireguard-wstunnel.conf"
