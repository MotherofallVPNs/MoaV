#!/bin/bash
# Regression test for #73: the user-bundle README shows only the protocols the
# user actually has, instead of "No X config available" null sections.
#
# The renderer keys each section (and its TOC entry) on the protocol's real
# per-user artifact in the bundle dir — the same signal the CONFIG_* values
# read. Absent artifact => section + TOC entry get style="display:none".
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "bundle enabled-only (#73) tests"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# A bundle with ONLY reality + wireguard artifacts.
echo 'vless://reality-link' > "$TMP/reality.txt"
printf '[Interface]\nPrivateKey = x\n' > "$TMP/wireguard.conf"

RB_USERNAME=t RB_OUTPUT_DIR="$TMP" RB_TEMPLATE="$ROOT/templates/client-guide-template.html" \
RB_OUTPUT_HTML="$TMP/README.html" RB_CONTEXT=container RB_SERVER_IP=192.0.2.1 RB_DOMAIN=example.com \
python3 "$ROOT/scripts/lib/bundle_readme.py" >/dev/null 2>&1 \
    && ok "renderer runs" || { bad "renderer failed"; echo "  $pass/$fail"; exit 1; }

html="$TMP/README.html"

# Present protocols: section visible in BOTH languages.
for id in reality-en reality-fa wireguard-en wireguard-fa; do
    if grep -qE "id=\"$id\" style=\"\"" "$html"; then
        ok "$id visible (artifact present)"
    else
        bad "$id hidden or missing despite artifact present"
    fi
done

# Absent protocols: section hidden in BOTH languages.
for id in trojan-en trojan-fa anytls-en anytls-fa telemt-en telemt-fa \
          hysteria2-en hysteria2-fa shadowsocks-en shadowsocks-fa \
          xhttp-en xhttp-fa amneziawg-en amneziawg-fa \
          trusttunnel-en trusttunnel-fa dns-tunnel-en dns-tunnel-fa; do
    if grep -qE "id=\"$id\" style=\"display:none\"" "$html"; then
        ok "$id hidden (no artifact)"
    else
        bad "$id shows a null section — the #73 complaint"
    fi
done

# TOC entries follow their sections: hidden protocols leave no visible TOC link.
if grep -E "<li style=\"display:none\">.*scrollToSection\('trojan-en'\)" "$html" >/dev/null; then
    ok "TOC entry hides with its section"
else
    bad "TOC still lists a hidden protocol"
fi

# No unreplaced *_DISPLAY placeholders may survive the render.
left=$(grep -oE '\{\{[A-Z_]+_DISPLAY\}\}' "$html" | sort -u | tr '\n' ' ')
[[ -z "$left" ]] && ok "no leftover _DISPLAY placeholders" \
                 || bad "unreplaced placeholders: $left"

# subscription.txt stays unconditional (moav-client parses it — shape unchanged).
[[ -f "$TMP/subscription.txt" ]] && ok "subscription.txt still written unconditionally" \
                                 || bad "subscription.txt missing — moav-client contract broken"

# moav update must flag bundle-template/renderer changes for regenerate-users.
grep -q 'POST_UPDATE_REGEN_BUNDLES' "$ROOT/lib/update.sh" \
    && ok "moav update flags bundle-guide changes for regenerate-users" \
    || bad "update.sh does not flag bundle changes — operators never learn to refresh bundles"

echo ""
echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]
