#!/bin/bash
# Integration test for the Snell protocol (a sing-box inbound, added like
# Shadowsocks). Asserts the wiring is complete end-to-end and functionally tests
# the runtime add-user mutation. The sing-box config itself is validated by the
# real 1.14 binary in singbox-check-test.sh; this pins the MoaV plumbing around it.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
has() { grep -q "$1" "$ROOT/$2" 2>/dev/null; }

echo "snell: end-to-end wiring + runtime add-user"

# --- 1. sing-box inbound in the template -------------------------------------
tmpl="configs/sing-box/config.json.template"
if has '"tag": "snell-in"' "$tmpl" && has '"version": 5' "$tmpl" \
   && has 'SNELL_SERVER_PSK' "$tmpl" && has 'SNELL_USERS_JSON' "$tmpl" \
   && has 'obfs_mode' "$tmpl"; then
    ok "template has the snell-in inbound (v5, psk, users, obfs_mode)"
else
    bad "template snell-in inbound missing or incomplete"
fi

# --- 2. bootstrap wiring ------------------------------------------------------
bs="scripts/bootstrap.sh"
has 'snell-server.psk'        "$bs" && ok "bootstrap generates the Snell server PSK" || bad "bootstrap missing snell-server.psk gen"
has 'SNELL_USERS_JSON+='      "$bs" && ok "bootstrap accumulates per-user Snell keys" || bad "bootstrap missing SNELL_USERS_JSON accumulation"
has 'snell.env'               "$bs" && ok "bootstrap persists per-user Snell key (snell.env)" || bad "bootstrap missing per-user snell.env"
has 'select(.tag == "snell-in")' "$bs" && ok "bootstrap enable-gates the snell-in inbound" || bad "bootstrap missing snell-in gating"

# --- 3. env + compose --------------------------------------------------------
has '^ENABLE_SNELL='  ".env.example" && has '^PORT_SNELL='  ".env.example" \
    && ok ".env.example has ENABLE_SNELL + PORT_SNELL" || bad ".env.example missing Snell knobs"
has 'PORT_SNELL' "docker-compose.yml" && has 'ENABLE_SNELL' "docker-compose.yml" \
    && ok "docker-compose exposes the port + passes ENABLE_SNELL to bootstrap" || bad "docker-compose missing Snell wiring"

# --- 4. bundle generation (both paths) + readme placeholders -----------------
has 'snell.txt' "scripts/generate-user.sh"   && ok "generate-user.sh emits snell.txt"   || bad "generate-user.sh missing snell bundle"
has 'snell.txt' "scripts/singbox-user-add.sh" && ok "singbox-user-add.sh emits snell.txt" || bad "singbox-user-add.sh missing snell bundle"
if has 'CONFIG_SNELL' "scripts/lib/bundle_readme.py" && has 'SNELL_DISPLAY' "scripts/lib/bundle_readme.py" \
   && has 'QR_SNELL' "scripts/lib/bundle_readme.py"; then
    ok "bundle_readme.py maps CONFIG_SNELL / SNELL_DISPLAY / QR_SNELL"
else
    bad "bundle_readme.py missing Snell placeholders"
fi
if has 'snell-en' "templates/client-guide-template.html" && has 'snell-fa' "templates/client-guide-template.html"; then
    ok "client guide has EN + FA Snell sections"
else
    bad "client guide missing a Snell section (en/fa)"
fi

# --- 5. roster + client-test + service resolver ------------------------------
has '"id": "snell"' "data/protocols.json" && ok "protocols.json roster has snell" || bad "snell missing from protocols.json"
has 'test_snell'    "tests/client-test.sh" && ok "client-test.sh has a Snell reachability test" || bad "client-test.sh missing test_snell"
has 'snell)' "lib/service.sh" && ok "service.sh resolves 'snell' to sing-box" || bad "service.sh missing snell resolver"

# --- 6. functional: singbox_add_user places the user in snell-in --------------
if command -v jq >/dev/null 2>&1; then
    tmp="$(mktemp -d)"; cfg="$tmp/config.json"
    cat > "$cfg" <<'JSON'
{"inbounds":[{"type":"snell","tag":"snell-in","version":5,"psk":"srv","users":[]},{"type":"shadowsocks","tag":"shadowsocks-in","users":[]}]}
JSON
    ( # shellcheck source=/dev/null
      source "$ROOT/scripts/lib/sing-box.sh" >/dev/null 2>&1
      singbox_add_user "$cfg" alice UUID-A pass-A "" "aliceUserKey" ) >/dev/null 2>&1
    got=$(jq -r '.inbounds[] | select(.tag=="snell-in") | .users[0].userkey // ""' "$cfg" 2>/dev/null)
    [[ "$got" == "aliceUserKey" ]] && ok "singbox_add_user adds the user to snell-in (userkey)" \
                                   || bad "snell user not added by singbox_add_user (got: '$got')"
    ss_n=$(jq -r '.inbounds[] | select(.tag=="shadowsocks-in") | .users | length' "$cfg" 2>/dev/null)
    [[ "$ss_n" == "0" ]] && ok "empty ss arg leaves other inbounds untouched" || bad "snell add leaked into ss inbound ($ss_n users)"
    rm -rf "$tmp"
else
    printf '  SKIP  jq unavailable for the add-user unit test\n'
fi

echo ""
if [ "$fail" -gt 0 ]; then echo "FAILED ($fail failed, $pass passed)"; exit 1; fi
echo "PASSED ($pass checks)"
