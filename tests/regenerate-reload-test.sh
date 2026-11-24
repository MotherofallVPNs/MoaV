#!/bin/bash
# Regression test: `moav regenerate-users` must reload the running WireGuard and
# AmneziaWG servers, not just sing-box + xray.
#
# The bug (found live): regenerate rebuilds wg0.conf/awg0.conf on disk, but the
# reload step only restarted `sing-box xray`. The WG/AWG containers kept their
# old peer lists, so a freshly regenerated user's key was on disk yet unknown to
# the running server — the tunnel handshook but the peer was never loaded.
# `moav user add` already reloads WG/AWG; regenerate-users was the gap.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "regenerate-users: reloads WG + AWG so regenerated peers take effect"

USERS="$ROOT/lib/users.sh"

# The reload block: from the sing-box/xray restart down to the closing echo "".
block=$(awk '/docker compose restart sing-box xray/,/^    echo ""$/' "$USERS")
if [ -z "$block" ]; then
    bad "could not locate the reload block in cmd_regenerate_users"
else
    if printf '%s' "$block" | grep -q 'moav-wireguard'; then
        ok "WireGuard is reloaded (wg syncconf / restart)"
    else
        bad "WireGuard is NOT reloaded — regenerated WG peers stay stale on the running server"
    fi
    if printf '%s' "$block" | grep -q 'wg syncconf wg0'; then
        ok "WireGuard peers are hot-synced (non-disruptive), not just restarted"
    else
        bad "no wg syncconf — existing WG tunnels would be dropped on every regenerate"
    fi
    if printf '%s' "$block" | grep -q 'moav-amneziawg'; then
        ok "AmneziaWG is reloaded"
    else
        bad "AmneziaWG is NOT reloaded — regenerated AWG peers stay stale"
    fi
    # An empty stripped config fed to `wg syncconf` would wipe every peer; the
    # code must guard against that and fall back to a restart.
    if printf '%s' "$block" | grep -q 'if \[\[ -n "\$wg_stripped" \]\]'; then
        ok "guards against an empty strip wiping all peers"
    else
        bad "no empty-config guard — a failed strip could remove every WG peer"
    fi
fi

# Without STATE_DIR the run's generate_amneziawg_config reads /keys, misses the
# real key and rotates the AWG server key + obfuscation params on every call.
if grep -q "bootstrap -c 'export STATE_DIR=/state;" "$USERS"; then
    ok "provisioning run uses /state (AWG server key is not rotated)"
else
    bad "provisioning run does not set STATE_DIR=/state — regenerate rotates the AWG server key"
fi

echo ""
if [ "$fail" -gt 0 ]; then
    echo "FAILED ($fail failed, $pass passed)"
    exit 1
fi
echo "PASSED ($pass checks)"
