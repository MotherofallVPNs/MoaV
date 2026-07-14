#!/bin/bash
# assert-users-reconciled.sh — regression guard for the "unknown UUID / invalid
# request after update/bootstrap" orphan bugs.
#
# Bootstrap regenerates the sing-box + xray configs from templates (envsubst),
# dropping the per-user entries `moav user add` inserts incrementally. The
# reconcile (lib/sync.sh) must re-insert EVERY user into EVERY enabled inbound.
# A UUID-only check is not enough: SS/Trojan/AnyTLS/Hysteria2 entries carry a
# password, not the UUID, so a user can be present in the Reality inbound yet
# missing from the password inbounds (the SS "invalid request" bug). This
# asserts per-inbound presence by name for sing-box, and by id for xray.
#
# Usage: assert-users-reconciled.sh [sing-box-config] [xray-config] [state-users-dir]
set -euo pipefail

SB="${1:-configs/sing-box/config.json}"
XR="${2:-configs/xray/config.json}"
STATE="${3:-state/users}"

# inbound tags whose users[] must contain every state user (when the inbound exists)
SB_TAG_RE='vless-reality-in|trojan-tls-in|anytls-in|hysteria2-in|vless-ws-in|shadowsocks-in'

[ -f "$SB" ]    || { echo "SKIP: $SB not found (sing-box not generated)"; exit 0; }
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

    # sing-box: user's name must be in every present inbound of a known tag
    missing=$(jq -r --arg n "$u" --arg re "$SB_TAG_RE" '
        [ .inbounds[]
          | select((.tag // "") | test($re))
          | select(has("users") and (.users | type == "array"))
          | select((any(.users[]?; .name == $n)) | not)
          | .tag ] | join(", ")' "$SB")
    if [ -n "$missing" ]; then
        echo "::error::user '$u' MISSING from sing-box inbound(s): $missing"
        fail=1
    fi

    # xray: user's UUID must be in every vless inbound (clients or users field)
    if [ -f "$XR" ]; then
        xmissing=$(jq -r --arg id "$uuid" '
            [ .inbounds[]
              | select(.protocol == "vless" and ((.tag // "") | startswith("vless-")))
              | select(((.settings.clients // .settings.users // []) | any(.id == $id)) | not)
              | (.tag // "vless") ] | join(", ")' "$XR")
        if [ -n "$xmissing" ]; then
            echo "::error::user '$u' ($uuid) MISSING from xray inbound(s): $xmissing"
            fail=1
        fi
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "FAIL: one or more users are orphaned from an enabled inbound after bootstrap"
    exit 1
fi
echo "OK: all $checked state user(s) present in every enabled sing-box/xray inbound"
