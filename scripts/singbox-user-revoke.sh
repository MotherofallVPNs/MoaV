#!/bin/bash
set -euo pipefail

# =============================================================================
# Revoke a user from sing-box (Reality, Trojan, AnyTLS, Hysteria2)
# Usage: ./scripts/singbox-user-revoke.sh <username>
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

source scripts/lib/common.sh

USERNAME="${1:-}"

if [[ -z "$USERNAME" ]]; then
    echo "Usage: $0 <username>"
    exit 1
fi

CONFIG_FILE="configs/sing-box/config.json"

if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "sing-box config not found"
    exit 1
fi

# Check if user exists (use jq so we don't trip on JSON-formatting whitespace —
# `jq -S` emits "name": "X" with a space, the grep version required "name":"X").
if ! jq -e --arg n "$USERNAME" \
        '.inbounds[]? | select(.users != null) | .users[]? | select(.name == $n)' \
        "$CONFIG_FILE" >/dev/null 2>&1; then
    log_error "User '$USERNAME' not found in sing-box config"
    exit 1
fi

log_info "Revoking user '$USERNAME' from sing-box..."

# Remove user from all inbounds using jq
TEMP_CONFIG=$(mktemp)

# Remove from Reality (vless)
jq --arg name "$USERNAME" \
    '.inbounds |= map(if .users then .users |= map(select(.name != $name)) else . end)' \
    "$CONFIG_FILE" > "$TEMP_CONFIG"

# Validate
if ! jq empty "$TEMP_CONFIG" 2>/dev/null; then
    log_error "Failed to generate valid config"
    rm -f "$TEMP_CONFIG"
    exit 1
fi

# Preserve original file's inode/mode/owner (mv -f would replace them — see
# wg-user-revoke.sh history). Especially matters when CLI revoke runs as root
# (sudo) while the admin container is non-root: a swapped inode would lock the
# dashboard out of the next user-add.
cat "$TEMP_CONFIG" > "$CONFIG_FILE"
rm -f "$TEMP_CONFIG"

log_info "Removed $USERNAME from sing-box config"

# Remove from TrustTunnel (if config exists)
TRUSTTUNNEL_CREDS="configs/trusttunnel/credentials.toml"
if [[ -f "$TRUSTTUNNEL_CREDS" ]]; then
    if grep -q "username = \"$USERNAME\"" "$TRUSTTUNNEL_CREDS" 2>/dev/null; then
        log_info "Removing $USERNAME from TrustTunnel..."

        # Use awk to remove the credential block for the user
        # The block starts with [[client]] followed by username and password
        awk -v user="$USERNAME" '
        BEGIN { skip=0; in_block=0; buffer="" }
        /^\[\[client\]\]/ {
            if (in_block && !skip) { print buffer }
            in_block=1; skip=0; buffer=$0 "\n"; next
        }
        in_block {
            buffer = buffer $0 "\n"
            if (/^username = /) {
                if (index($0, "\"" user "\"") > 0) { skip=1 }
            }
            if (/^$/ || /^\[/) {
                if (!skip) { print buffer }
                in_block=0; buffer=""
                if (/^\[/) { print }
            }
            next
        }
        { print }
        END { if (in_block && !skip) { printf "%s", buffer } }
        ' "$TRUSTTUNNEL_CREDS" > "${TRUSTTUNNEL_CREDS}.tmp"
        # Preserve original perms/owner (cat-overwrite, not mv-replace).
        cat "${TRUSTTUNNEL_CREDS}.tmp" > "$TRUSTTUNNEL_CREDS"
        rm -f "${TRUSTTUNNEL_CREDS}.tmp"

        log_info "Removed $USERNAME from TrustTunnel credentials"
    fi
fi

# Remove from Xray (XHTTP + XDNS inbounds — vless-xhttp-reality, vless-xdns)
# Xray's v26.5.9 schema rename made `users` and `clients` aliases (#6083), so
# users may live in either array depending on which write path created them
# (bootstrap → settings.users via template; legacy add → settings.clients).
# Match + delete from BOTH so revoke is complete regardless.
XRAY_CONFIG="configs/xray/config.json"
if [[ -f "$XRAY_CONFIG" ]]; then
    if jq -e --arg email "${USERNAME}@moav" '
            .inbounds[]? |
            (.settings.clients[]?, .settings.users[]?) |
            select(.email == $email)
        ' "$XRAY_CONFIG" >/dev/null 2>&1; then
        log_info "Removing $USERNAME from Xray (XHTTP + XDNS)..."
        XRAY_TMP=$(mktemp)
        jq --arg email "${USERNAME}@moav" '
            .inbounds |= map(
                if .settings.clients then .settings.clients |= map(select(.email != $email)) else . end |
                if .settings.users   then .settings.users   |= map(select(.email != $email)) else . end
            )
        ' "$XRAY_CONFIG" > "$XRAY_TMP"
        if jq empty "$XRAY_TMP" 2>/dev/null; then
            cat "$XRAY_TMP" > "$XRAY_CONFIG"
            log_info "Removed $USERNAME from Xray config"
        else
            log_error "Failed to generate valid Xray config — skipping Xray revoke"
        fi
        rm -f "$XRAY_TMP"
    fi
fi

# Remove from telemt (if config exists)
TELEMT_CONFIG="configs/telemt/config.toml"
if [[ -f "$TELEMT_CONFIG" ]]; then
    if grep -q "^${USERNAME} = " "$TELEMT_CONFIG" 2>/dev/null; then
        log_info "Removing $USERNAME from telemt..."

        # Remove user from all three sections:
        # [access.users]: username = "secret"
        # [access.user_max_tcp_conns]: username = N
        # [access.user_max_unique_ips]: username = N
        sed -i "/^${USERNAME} = /d" "$TELEMT_CONFIG"

        log_info "Removed $USERNAME from telemt config"
    fi
fi

# Reload sing-box
if docker compose ps sing-box --status running 2>/dev/null | tail -n +2 | grep -q .; then
    log_info "Reloading sing-box..."
    if docker compose exec -T sing-box sing-box reload 2>/dev/null; then
        log_info "sing-box reloaded"
    else
        docker compose restart sing-box
    fi
fi

# Reload Xray (XHTTP + XDNS — picks up the revoked-user removal)
if [[ -f "$XRAY_CONFIG" ]]; then
    if docker compose --profile xhttp ps xray --status running 2>/dev/null | tail -n +2 | grep -q .; then
        log_info "Restarting Xray..."
        docker compose --profile xhttp restart xray
    fi
fi

# Reload TrustTunnel (if running)
if [[ -f "$TRUSTTUNNEL_CREDS" ]]; then
    if docker compose ps trusttunnel --status running 2>/dev/null | tail -n +2 | grep -q .; then
        log_info "Restarting TrustTunnel..."
        docker compose restart trusttunnel
    fi
fi

# Reload telemt (if running)
if [[ -f "$TELEMT_CONFIG" ]]; then
    if docker compose --profile telegram ps telemt --status running 2>/dev/null | tail -n +2 | grep -q .; then
        log_info "Restarting telemt..."
        docker compose --profile telegram restart telemt
    fi
fi

log_info "User '$USERNAME' revoked"
