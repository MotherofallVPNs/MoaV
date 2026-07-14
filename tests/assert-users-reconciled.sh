#!/bin/bash
# assert-users-reconciled.sh — regression guard for the "unknown UUID after
# update/bootstrap" orphan bug.
#
# Bootstrap regenerates the sing-box + xray configs from templates (envsubst),
# which drops the per-user entries `moav user add` inserts incrementally. The
# reconcile (lib/sync.sh) must re-insert EVERY user from state. This asserts
# that invariant: every user in state must appear in the generated proxy
# configs. Run it after a (re-)bootstrap — a missing user means an operator
# would see `unknown UUID` and that user's already-distributed bundle is dead.
#
# Usage: assert-users-reconciled.sh [sing-box-config] [xray-config] [state-users-dir]
set -euo pipefail

SB="${1:-configs/sing-box/config.json}"
XR="${2:-configs/xray/config.json}"
STATE="${3:-state/users}"

[ -f "$SB" ]   || { echo "SKIP: $SB not found (sing-box not generated)"; exit 0; }
[ -d "$STATE" ] || { echo "SKIP: $STATE not found (no user state)"; exit 0; }

fail=0
checked=0
for d in "$STATE"/*/; do
    [ -d "$d" ] || continue
    u=$(basename "$d")
    [ -f "${d}credentials.env" ] || continue
    uuid=$(grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "${d}credentials.env" | head -1)
    [ -n "$uuid" ] || continue
    checked=$((checked + 1))
    if ! grep -q "$uuid" "$SB"; then
        echo "::error::user '$u' ($uuid) MISSING from sing-box config — orphaned"
        fail=1
    fi
    if [ -f "$XR" ] && ! grep -q "$uuid" "$XR"; then
        echo "::error::user '$u' ($uuid) MISSING from xray config — orphaned"
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "FAIL: one or more users are orphaned from the proxy configs after bootstrap"
    exit 1
fi
echo "OK: all $checked state user(s) present in the proxy config(s)"
