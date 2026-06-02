#!/bin/bash
set -euo pipefail

# =============================================================================
# Revoke an AmneziaWG peer
# Usage: ./scripts/awg-user-revoke.sh <username>
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

source scripts/lib/common.sh

USERNAME="${1:-}"

if [[ -z "$USERNAME" ]]; then
    echo "Usage: $0 <username>"
    exit 1
fi

AWG_CONFIG_FILE="configs/amneziawg/awg0.conf"
STATE_DIR="${STATE_DIR:-./state}"

if [[ ! -f "$AWG_CONFIG_FILE" ]]; then
    log_error "AmneziaWG config not found"
    exit 1
fi

# Check if peer exists
if ! grep -q "# $USERNAME\$" "$AWG_CONFIG_FILE" 2>/dev/null; then
    log_error "AmneziaWG peer '$USERNAME' not found"
    exit 1
fi

# Get the public key before removing (may be empty if peer block is malformed/orphaned)
PUBLIC_KEY=$(grep -A1 "# $USERNAME\$" "$AWG_CONFIG_FILE" | grep "PublicKey" | awk '{print $3}' || true)

log_info "Revoking AmneziaWG peer '$USERNAME'..."
log_info "Public key: $PUBLIC_KEY"

# Remove peer block from config file
# The block starts with [Peer] and # username on next line
TEMP_CONFIG=$(mktemp)
awk -v user="$USERNAME" '
    BEGIN { skip = 0 }
    /^\[Peer\]/ {
        # Save the position, check next line
        peer_line = $0
        if (getline > 0) {
            if ($0 ~ "# " user "$") {
                skip = 1
                next
            } else {
                print peer_line
                print
                next
            }
        }
    }
    skip && /^\[/ { skip = 0 }
    skip { next }
    { print }
' "$AWG_CONFIG_FILE" > "$TEMP_CONFIG"

# Copy content over (not `mv`) so the original file's mode + owner survive.
# `mv -f tmp orig` would swap inodes, leaving awg0.conf owned by whoever ran
# the revoke (root if sudo'd from CLI) with that user's umask — breaking
# the admin container's writeability on the next user-add attempt.
cat "$TEMP_CONFIG" > "$AWG_CONFIG_FILE"
rm -f "$TEMP_CONFIG"

log_info "Removed peer from awg0.conf"

# Remove from running AmneziaWG if available
if docker compose ps amneziawg --status running 2>/dev/null | tail -n +2 | grep -q . && [[ -n "$PUBLIC_KEY" ]]; then
    log_info "Removing peer from running AmneziaWG..."
    if docker compose exec -T amneziawg awg set awg0 peer "$PUBLIC_KEY" remove 2>/dev/null; then
        log_info "Peer removed from running AmneziaWG"
    else
        log_info "Could not hot-remove peer, restart AmneziaWG to apply"
    fi
fi

# Remove user state files
if [[ -f "$STATE_DIR/users/$USERNAME/amneziawg.env" ]]; then
    rm -f "$STATE_DIR/users/$USERNAME/amneziawg.env"
    log_info "Removed AmneziaWG credentials"
fi

log_info "AmneziaWG peer '$USERNAME' revoked"
