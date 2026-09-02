#!/bin/bash
# Integration test for the Snell protocol (a sing-box inbound). Snell is
# SHARED-KEY / single-user: sing-box's multi-user snell needs a per-user key no
# standard client (Surge/Mihomo/Stash) can send, so every user connects with the
# one server PSK — like dnstt. This test pins that design so we don't regress to
# the broken per-user form. The sing-box config itself is validated by the real
# 1.14 binary in singbox-check-test.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
has() { grep -q "$1" "$ROOT/$2" 2>/dev/null; }

echo "snell: shared-key inbound + bundle wiring"

# --- 1. sing-box inbound: shared-key (psk + obfs, NO users[]) -----------------
tmpl="configs/sing-box/config.json.template"
if has '"tag": "snell-in"' "$tmpl" && has '"version": 5' "$tmpl" \
   && has 'SNELL_SERVER_PSK' "$tmpl" && has 'obfs_mode' "$tmpl"; then
    ok "template has the snell-in inbound (v5, psk, obfs_mode)"
else
    bad "template snell-in inbound missing or incomplete"
fi
if has 'SNELL_USERS_JSON' "$tmpl" || grep -A8 'snell-in' "$ROOT/$tmpl" | grep -q '"users"'; then
    bad "snell-in still has a users[] array — that is the broken multi-user form"
else
    ok "snell-in is shared-key (no users[] array)"
fi

# --- 2. bootstrap: shared server PSK, NO per-user snell key -------------------
bs="scripts/bootstrap.sh"
has 'snell-server.psk' "$bs" && ok "bootstrap generates the shared Snell PSK" || bad "bootstrap missing snell-server.psk gen"
has 'select(.tag == "snell-in")' "$bs" && ok "bootstrap enable-gates the snell-in inbound" || bad "bootstrap missing snell-in gating"
if has 'snell.env' "$bs" || has 'SNELL_USERS_JSON' "$bs"; then
    bad "bootstrap still creates per-user snell keys (should be shared-key only)"
else
    ok "bootstrap has no per-user snell key (shared-key)"
fi

# --- 3. singbox_add_user must NOT touch snell (shared-key, not per-user) ------
if has 'snell-in' "scripts/lib/sing-box.sh"; then
    bad "singbox_add_user references snell-in — snell is shared-key, not per-user"
else
    ok "singbox_add_user does not add per-user snell entries"
fi

# --- 4. env + compose --------------------------------------------------------
has '^ENABLE_SNELL='  ".env.example" && has '^PORT_SNELL='  ".env.example" \
    && ok ".env.example has ENABLE_SNELL + PORT_SNELL" || bad ".env.example missing Snell knobs"
grep -q '^ENABLE_SNELL=false' "$ROOT/.env.example" && ok "ENABLE_SNELL defaults off" || bad "ENABLE_SNELL should default off"
has 'PORT_SNELL' "docker-compose.yml" && has 'ENABLE_SNELL' "docker-compose.yml" \
    && ok "docker-compose exposes the port + passes ENABLE_SNELL to bootstrap" || bad "docker-compose missing Snell wiring"

# --- 5. bundle: both generators emit snell.txt using the SHARED psk ----------
for gen in scripts/generate-user.sh scripts/singbox-user-add.sh; do
    if has 'snell.txt' "$gen" && grep -q 'snell-server.psk\|SNELL_SERVER_PSK' "$ROOT/$gen"; then
        ok "$(basename "$gen") emits snell.txt from the shared PSK"
    else
        bad "$(basename "$gen") missing snell bundle or not using the shared PSK"
    fi
    if grep -q 'SNELL_USER_KEY' "$ROOT/$gen"; then
        bad "$(basename "$gen") still references a per-user SNELL_USER_KEY"
    fi
done

# --- 6. readme placeholders + guide + roster + client-test + service ---------
if has 'CONFIG_SNELL' "scripts/lib/bundle_readme.py" && has 'SNELL_DISPLAY' "scripts/lib/bundle_readme.py" \
   && has 'QR_SNELL' "scripts/lib/bundle_readme.py"; then
    ok "bundle_readme.py maps CONFIG_SNELL / SNELL_DISPLAY / QR_SNELL"
else
    bad "bundle_readme.py missing Snell placeholders"
fi
has 'snell-en' "templates/client-guide-template.html" && has 'snell-fa' "templates/client-guide-template.html" \
    && ok "client guide has EN + FA Snell sections" || bad "client guide missing a Snell section (en/fa)"
has '"id": "snell"' "data/protocols.json" && ok "protocols.json roster has snell" || bad "snell missing from protocols.json"
has 'test_snell' "tests/client-test.sh" && ok "client-test.sh has a Snell reachability test" || bad "client-test.sh missing test_snell"
has 'snell)' "lib/service.sh" && ok "service.sh resolves 'snell' to sing-box" || bad "service.sh missing snell resolver"

echo ""
if [ "$fail" -gt 0 ]; then echo "FAILED ($fail failed, $pass passed)"; exit 1; fi
echo "PASSED ($pass checks)"
