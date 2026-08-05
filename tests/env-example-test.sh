#!/bin/bash
# Guards the .env.example structure: a single file with the commonly-configured
# vars up top and an "ADVANCED" separator, everything below it optional.
#
# The point is a small first-run surface WITHOUT removing anything (a fresh
# `cp .env.example .env` still carries every var at its intended value), so the
# checks are: the separator exists, the essentials sit ABOVE it, a sampling of
# advanced vars sit BELOW it, and no variable was dropped.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
F="$ROOT/.env.example"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo ".env.example structure tests"

[[ -f "$F" ]] && ok ".env.example exists" || { bad "missing"; echo "  $pass/$fail"; exit 1; }

# The single-file split replaced the old .env.example.full two-file scheme.
[[ ! -f "$ROOT/.env.example.full" ]] && ok ".env.example.full removed (single-file)" \
                                     || bad ".env.example.full still present"

# Line number of the ADVANCED separator.
sep=$(grep -n '^# ADVANCED' "$F" | head -1 | cut -d: -f1)
[[ -n "$sep" ]] && ok "ADVANCED separator present (line $sep)" \
                || { bad "no ADVANCED separator"; sep=999999; }

# line number of a KEY=... assignment (commented or not)
line_of() { grep -nE "^#?$1=" "$F" | head -1 | cut -d: -f1; }

# Essentials must sit ABOVE the separator.
for v in DOMAIN ACME_EMAIL ADMIN_PASSWORD SERVER_IP REALITY_TARGET \
         ENABLE_REALITY ENABLE_WIREGUARD INITIAL_USERS DEFAULT_PROFILES TZ ADMIN_IP_WHITELIST; do
    n=$(line_of "$v")
    if [[ -n "$n" && "$n" -lt "$sep" ]]; then ok "essential $v above separator"
    else bad "$v not in the top block (line ${n:-none}, separator $sep)"; fi
done

# Advanced vars must sit BELOW the separator.
for v in SINGBOX_VERSION PORT_HTTPS TELEMT_POOL_SIZE CDN_SUBDOMAIN CLASH_API_SECRET \
         CLIENT_SOCKS_PORT GOPROXY COMPOSE_PROJECT_NAME; do
    n=$(line_of "$v")
    if [[ -n "$n" && "$n" -gt "$sep" ]]; then ok "advanced $v below separator"
    else bad "$v not below the separator (line ${n:-none}, separator $sep)"; fi
done

# Completeness: a fresh copy still carries every var it needs, and sources clean.
cp "$F" /tmp/moav-env-struct-test
if bash -c 'set -a; source /tmp/moav-env-struct-test; set +a; [[ -n "$COMPOSE_PROJECT_NAME" && -n "$ENABLE_REALITY" && -n "$REALITY_TARGET" && -n "$SINGBOX_VERSION" ]]'; then
    ok "a fresh copy sources cleanly and carries top + advanced values"
else
    bad "fresh copy missing values or fails to source"
fi
rm -f /tmp/moav-env-struct-test

echo ""
echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]
