#!/bin/bash
set -euo pipefail

# =============================================================================
# Revoke a user from ALL services
# Usage: ./scripts/user-revoke.sh <username>
#
# This is the master script that calls individual service scripts:
#   - singbox-user-revoke.sh
#   - wg-user-revoke.sh
#   - awg-user-revoke.sh
#
# For individual services, use the specific scripts directly.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

source scripts/lib/common.sh

USERNAME="${1:-}"
KEEP_BUNDLE="${2:-}"

if [[ -z "$USERNAME" ]]; then
    echo "Usage: $0 <username> [--keep-bundle]"
    echo ""
    echo "This revokes a user from ALL services."
    echo ""
    echo "Options:"
    echo "  --keep-bundle    Don't delete the user's bundle folder"
    echo ""
    echo "For individual services:"
    echo "  ./scripts/singbox-user-revoke.sh <username>  # sing-box"
    echo "  ./scripts/wg-user-revoke.sh <username>       # WireGuard"
    echo "  ./scripts/awg-user-revoke.sh <username>      # AmneziaWG"
    exit 1
fi

# Load environment
if [[ -f .env ]]; then
    set -a
    source .env
    set +a
fi

STATE_DIR="${STATE_DIR:-./state}"
OUTPUT_DIR="outputs/bundles/$USERNAME"

log_info "========================================"
log_info "Revoking user '$USERNAME' from all services"
log_info "========================================"
echo ""

REVOKED=false

# -----------------------------------------------------------------------------
# Revoke from sing-box
# -----------------------------------------------------------------------------
if [[ -f "configs/sing-box/config.json" ]] && jq -e --arg n "$USERNAME" \
        '.inbounds[]? | select(.users != null) | .users[]? | select(.name == $n)' \
        "configs/sing-box/config.json" >/dev/null 2>&1; then
    log_info "[1/3] Revoking from sing-box..."
    if "$SCRIPT_DIR/singbox-user-revoke.sh" "$USERNAME"; then
        log_info "✓ Revoked from sing-box"
        REVOKED=true
    else
        log_error "✗ Failed to revoke from sing-box"
    fi
else
    log_info "[1/3] User not found in sing-box (skipping)"
fi

echo ""

# -----------------------------------------------------------------------------
# Revoke from WireGuard
# -----------------------------------------------------------------------------
if [[ -f "configs/wireguard/wg0.conf" ]] && grep -q "# $USERNAME\$" "configs/wireguard/wg0.conf" 2>/dev/null; then
    log_info "[2/3] Revoking from WireGuard..."
    if "$SCRIPT_DIR/wg-user-revoke.sh" "$USERNAME"; then
        log_info "✓ Revoked from WireGuard"
        REVOKED=true
    else
        log_error "✗ Failed to revoke from WireGuard"
    fi
else
    log_info "[2/3] User not found in WireGuard (skipping)"
fi

echo ""

# -----------------------------------------------------------------------------
# Revoke from AmneziaWG
# -----------------------------------------------------------------------------
if [[ -f "configs/amneziawg/awg0.conf" ]] && grep -q "# $USERNAME\$" "configs/amneziawg/awg0.conf" 2>/dev/null; then
    log_info "[3/3] Revoking from AmneziaWG..."
    if "$SCRIPT_DIR/awg-user-revoke.sh" "$USERNAME"; then
        log_info "✓ Revoked from AmneziaWG"
        REVOKED=true
    else
        log_error "✗ Failed to revoke from AmneziaWG"
    fi
else
    log_info "[3/3] User not found in AmneziaWG (skipping)"
fi

echo ""

# -----------------------------------------------------------------------------
# Clean up user files. Removing bundle/state counts as "something was revoked"
# — otherwise a user whose service entries were already gone (e.g. cleaned up
# in a prior partial revoke) would be reported as a failure even though we
# successfully scrubbed their files.
# -----------------------------------------------------------------------------
CLEANED_FILES=false
if [[ "$KEEP_BUNDLE" != "--keep-bundle" ]] && [[ -d "$OUTPUT_DIR" ]]; then
    log_info "Removing user bundle: $OUTPUT_DIR"
    rm -rf "$OUTPUT_DIR"
    CLEANED_FILES=true
fi

if [[ -d "$STATE_DIR/users/$USERNAME" ]]; then
    log_info "Removing user state: $STATE_DIR/users/$USERNAME"
    rm -rf "$STATE_DIR/users/$USERNAME"
    CLEANED_FILES=true
fi

# Also try docker volume path
if docker run --rm -v moav_moav_state:/state alpine sh -c "[ -d /state/users/$USERNAME ] && rm -rf /state/users/$USERNAME" 2>/dev/null; then
    CLEANED_FILES=true
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
if [[ "$REVOKED" == "true" ]] || [[ "$CLEANED_FILES" == "true" ]]; then
    log_info "========================================"
    if [[ "$REVOKED" == "true" ]]; then
        log_info "User '$USERNAME' has been revoked"
    else
        log_info "User '$USERNAME' files cleaned up (no active service entries)"
    fi
    log_info "========================================"
else
    log_error "User '$USERNAME' not found — nothing to revoke (no service entries, no files)"
    exit 1
fi
