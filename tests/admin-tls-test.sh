#!/bin/bash
# The admin panel must never serve plain HTTP.
#
# It accepts an HTTP-Basic credential (the same secret as the Grafana password)
# and manages user provisioning, on a port published to the internet. It used to
# print "WARNING: No SSL certificates found, running without HTTPS" and start
# anyway -- which happened on any install where certbot had not yet succeeded,
# i.e. every fresh install for its first minutes.
#
# Three layers, all required:
#   1. bootstrap generates a self-signed fallback in EVERY mode (it used to do so
#      only in domainless mode, so domain installs had no cert at all)
#   2. the admin entrypoint mints a last-resort cert into /tmp/certs if none
#      arrived, so failing closed can never mean "no dashboard"
#   3. main.py exits rather than binding without TLS
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "admin TLS enforcement"

# --- 3. fail closed -----------------------------------------------------------
if grep -q 'running without HTTPS' "$ROOT/admin/main.py"; then
    bad "main.py still starts without HTTPS"
else
    ok "main.py no longer has a plaintext fallback"
fi
grep -q 'refusing to start without TLS' "$ROOT/admin/main.py" \
    && ok "main.py fails closed with an actionable message" \
    || bad "main.py does not fail closed when no cert is present"

# --- 1. self-signed generated in every mode -----------------------------------
# It must NOT be nested inside the `if [[ -z "${DOMAIN:-}" ]]` domainless block.
if awk '
    /if \[\[ -z "\$\{DOMAIN:-\}" \]\]; then/ {depth=1; next}
    depth==1 && /^fi$/ {depth=0; next}
    depth==1 && /Generating self-signed certificate for admin/ {found=1}
    END {exit !found}
' "$ROOT/scripts/bootstrap.sh"; then
    bad "self-signed generation is still inside the domainless branch — domain installs get no fallback cert"
else
    ok "self-signed generation is outside the domainless branch (all modes)"
fi

# --- 2. last-resort generation in the entrypoint ------------------------------
grep -q 'last-resort self-signed cert' "$ROOT/scripts/admin-entrypoint.sh" \
    && ok "admin entrypoint mints a last-resort cert (failing closed cannot lock you out)" \
    || bad "no last-resort cert generation — an empty certs volume would mean no dashboard"

# --- Let's Encrypt must still be PREFERRED ------------------------------------
# The short-circuit that skips the LE wait must key on DOMAIN, not on "a
# self-signed cert exists" -- that proxy became always-true once layer 1 landed,
# which would make every domain install bind the self-signed cert.
if grep -q 'if has_selfsigned and waited >= 15' "$ROOT/admin/main.py"; then
    bad "LE wait short-circuits on cert presence — domain installs would use the self-signed cert"
else
    ok "LE wait does not short-circuit merely because a self-signed cert exists"
fi
grep -q 'if not DOMAIN and has_selfsigned and waited >= 15' "$ROOT/admin/main.py" \
    && ok "LE wait short-circuit is keyed on DOMAIN (the real domainless signal)" \
    || bad "LE wait short-circuit is not keyed on DOMAIN"

echo
echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]
