#!/bin/bash
set -euo pipefail

# =============================================================================
# Reload/restart the proxy services after user config changes.
#
# Split out of singbox-user-revoke.sh so a BATCH revoke can reload once at the
# end instead of once per user (see `moav user revoke` in lib/users.sh and the
# `--no-reload` flag on user-revoke.sh / singbox-user-revoke.sh). Reloading
# sing-box and restarting xray/trusttunnel per user is what made revoking many
# users slow.
#
# No arguments; each service is only touched if its config exists and it is
# actually running.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

source scripts/lib/common.sh

XRAY_CONFIG="configs/xray/config.json"
TRUSTTUNNEL_CREDS="configs/trusttunnel/credentials.toml"
TELEMT_CONFIG="configs/telemt/config.toml"

# sing-box (Reality, Trojan, AnyTLS, Hysteria2, Shadowsocks)
if docker compose ps sing-box --status running 2>/dev/null | tail -n +2 | grep -q .; then
    log_info "Reloading sing-box..."
    if docker compose exec -T sing-box sing-box reload 2>/dev/null; then
        log_info "sing-box reloaded"
    else
        docker compose restart sing-box
    fi
fi

# Xray (XHTTP + XDNS)
if [[ -f "$XRAY_CONFIG" ]] && docker compose --profile xhttp ps xray --status running 2>/dev/null | tail -n +2 | grep -q .; then
    log_info "Restarting Xray..."
    docker compose --profile xhttp restart xray
fi

# TrustTunnel
if [[ -f "$TRUSTTUNNEL_CREDS" ]] && docker compose ps trusttunnel --status running 2>/dev/null | tail -n +2 | grep -q .; then
    log_info "Restarting TrustTunnel..."
    docker compose restart trusttunnel
fi

# telemt (Telegram MTProxy)
if [[ -f "$TELEMT_CONFIG" ]] && docker compose --profile telegram ps telemt --status running 2>/dev/null | tail -n +2 | grep -q .; then
    log_info "Restarting telemt..."
    docker compose --profile telegram restart telemt
fi
