#!/bin/bash
set -euo pipefail

# =============================================================================
# List all users across services
# Usage: ./scripts/user-list.sh
# =============================================================================

cd "$(dirname "$0")/.."

echo "========================================"
echo "         MoaV User List"
echo "========================================"
echo ""

# -----------------------------------------------------------------------------
# sing-box users (Reality, Trojan, Hysteria2)
# -----------------------------------------------------------------------------
echo "=== sing-box Users (Reality/Trojan/Hysteria2) ==="
if [[ -f configs/sing-box/config.json ]]; then
    SINGBOX_USERS=$(jq -r '.inbounds[] | select(.users != null) | .users[].name' configs/sing-box/config.json 2>/dev/null | sort | uniq)
    if [[ -n "$SINGBOX_USERS" ]]; then
        echo "$SINGBOX_USERS" | while read -r user; do
            bundle_status=""
            if [[ -d "outputs/bundles/$user" ]]; then
                bundle_status=" [bundle ready]"
            fi
            echo "  • $user$bundle_status"
        done
        SINGBOX_COUNT=$(echo "$SINGBOX_USERS" | wc -l | tr -d ' ')
        echo ""
        echo "  Total: $SINGBOX_COUNT users"
    else
        echo "  (no users)"
    fi
else
    echo "  (not configured - run bootstrap)"
fi

echo ""

# -----------------------------------------------------------------------------
# WireGuard peers
# -----------------------------------------------------------------------------
echo "=== WireGuard Peers ==="
if [[ -f configs/wireguard/wg0.conf ]]; then
    # Extract peer names: look for comments after [Peer] blocks
    WG_PEERS=$(awk '/^\[Peer\]/{getline; if(/^# /){sub(/^# /,""); print}}' configs/wireguard/wg0.conf 2>/dev/null || true)
    if [[ -n "$WG_PEERS" ]]; then
        WG_COUNT=0
        # Get IPs for each peer
        while IFS= read -r peer; do
            [[ -z "$peer" ]] && continue
            IP=$(grep -A2 "# $peer\$" configs/wireguard/wg0.conf 2>/dev/null | grep "AllowedIPs" | awk '{print $3}' | sed 's/\/32//' || echo "")
            if [[ -n "$IP" ]]; then
                echo "  • $peer ($IP)"
            else
                echo "  • $peer (no IP found)"
            fi
            ((WG_COUNT++)) || true
        done <<< "$WG_PEERS"
        echo ""
        echo "  Total: $WG_COUNT peers"
    else
        echo "  (no peers)"
    fi
else
    echo "  (not configured)"
fi

echo ""

# -----------------------------------------------------------------------------
# AmneziaWG peers
# -----------------------------------------------------------------------------
echo "=== AmneziaWG Peers ==="
if [[ -f configs/amneziawg/awg0.conf ]]; then
    AWG_PEERS=$(awk '/^\[Peer\]/{getline; if(/^# /){sub(/^# /,""); print}}' configs/amneziawg/awg0.conf 2>/dev/null || true)
    if [[ -n "$AWG_PEERS" ]]; then
        AWG_COUNT=0
        while IFS= read -r peer; do
            [[ -z "$peer" ]] && continue
            IP=$(grep -A2 "# $peer\$" configs/amneziawg/awg0.conf 2>/dev/null | grep "AllowedIPs" | awk '{print $3}' | sed 's/\/32//' || echo "")
            if [[ -n "$IP" ]]; then
                echo "  • $peer ($IP)"
            else
                echo "  • $peer (no IP found)"
            fi
            ((AWG_COUNT++)) || true
        done <<< "$AWG_PEERS"
        echo ""
        echo "  Total: $AWG_COUNT peers"
    else
        echo "  (no peers)"
    fi
else
    echo "  (not configured)"
fi

echo ""

# -----------------------------------------------------------------------------
# Xray users (XHTTP + XDNS)
# -----------------------------------------------------------------------------
echo "=== Xray Users (XHTTP + XDNS) ==="
if [[ -f configs/xray/config.json ]]; then
    # Xray uses email "USERNAME@moav" as the per-user identifier across inbounds.
    XRAY_USERS=$(jq -r '.inbounds[]? | select(.settings.clients != null) | .settings.clients[]?.email' configs/xray/config.json 2>/dev/null | sed 's/@moav$//' | sort -u | grep -v '^$' || true)
    if [[ -n "$XRAY_USERS" ]]; then
        echo "$XRAY_USERS" | while read -r user; do
            echo "  • $user"
        done
        XRAY_COUNT=$(echo "$XRAY_USERS" | wc -l | tr -d ' ')
        echo ""
        echo "  Total: $XRAY_COUNT users"
    else
        echo "  (no users)"
    fi
else
    echo "  (not configured)"
fi

echo ""

# -----------------------------------------------------------------------------
# TrustTunnel users
# -----------------------------------------------------------------------------
echo "=== TrustTunnel Users ==="
if [[ -f configs/trusttunnel/credentials.toml ]]; then
    # Each user is a [[client]] block with `username = "X"`. Extract the X's.
    TT_USERS=$(grep -E '^username = ' configs/trusttunnel/credentials.toml 2>/dev/null | sed -E 's/^username = "([^"]*)".*/\1/' | sort -u || true)
    if [[ -n "$TT_USERS" ]]; then
        echo "$TT_USERS" | while read -r user; do
            echo "  • $user"
        done
        TT_COUNT=$(echo "$TT_USERS" | wc -l | tr -d ' ')
        echo ""
        echo "  Total: $TT_COUNT users"
    else
        echo "  (no users)"
    fi
else
    echo "  (not configured)"
fi

echo ""

# -----------------------------------------------------------------------------
# Telegram MTProxy (telemt) users
# -----------------------------------------------------------------------------
echo "=== Telegram MTProxy Users ==="
if [[ -f configs/telemt/config.toml ]]; then
    # Users live under [access.users] as: username = "secret_hex"
    # Skip the section header itself + comment lines + empty lines.
    TELEMT_USERS=$(awk '
        /^\[access\.users\]/ { flag=1; next }
        /^\[/                { flag=0 }
        flag && /^[A-Za-z0-9_-]+ *= */ { print $1 }
    ' configs/telemt/config.toml 2>/dev/null | sort -u || true)
    if [[ -n "$TELEMT_USERS" ]]; then
        echo "$TELEMT_USERS" | while read -r user; do
            echo "  • $user"
        done
        TELEMT_COUNT=$(echo "$TELEMT_USERS" | wc -l | tr -d ' ')
        echo ""
        echo "  Total: $TELEMT_COUNT users"
    else
        echo "  (no users)"
    fi
else
    echo "  (not configured)"
fi

echo ""

# -----------------------------------------------------------------------------
# User bundles
# -----------------------------------------------------------------------------
echo "=== User Bundles ==="
if [[ -d outputs/bundles ]] && [[ "$(ls -A outputs/bundles 2>/dev/null)" ]]; then
    for bundle in outputs/bundles/*/; do
        username=$(basename "$bundle")
        files=$(ls "$bundle" 2>/dev/null | wc -l | tr -d ' ')
        echo "  • $username ($files files)"
    done
else
    echo "  (none)"
fi

echo ""
echo "========================================"
