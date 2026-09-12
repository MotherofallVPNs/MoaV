#!/bin/bash
# Regression: the generated XDNS client configs must not dial a VLESS outbound
# that has no TLS/encryption to a bare public IP.
#
# The bug (found by the v2.3.0-rc.3 e2e after bumping Xray v26.7.28 -> v26.9.9):
# Xray >= 26.9 rejects "vless without TLS or other encryption ... unless the
# server address is a private IP or domain". Both xdns configs used a bare IP as
# the VLESS vnext address (8.8.8.8 for the via-DNS variant, SERVER_IP for direct),
# so xray refused to start and xdns failed. The real routing IPs live as literals
# inside finalmask.resolvers; the vnext address is only nominal, so it is now a
# domain form (dns.google / ${DOMAIN}) which satisfies the rule.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
F="$ROOT/scripts/lib/xray.sh"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "xdns: VLESS-no-TLS address is Xray >= 26.9 compliant"

# The two xdns VLESS outbounds live on single heredoc lines. Extract the vnext
# address from each VLESS outbound that carries encryption:none. (No mapfile —
# keep it portable to macOS bash 3.2.)
addrs=()
while IFS= read -r a; do [ -n "$a" ] && addrs+=("$a"); done < <(
    grep -oE '"protocol": "vless".*"address": "[^"]+"' "$F" \
    | grep -oE '"address": "[^"]+"' | sed -E 's/.*"address": "([^"]+)".*/\1/')

if [ "${#addrs[@]}" -lt 2 ]; then
    bad "expected >= 2 VLESS xdns outbounds, found ${#addrs[@]}"
else
    ok "found ${#addrs[@]} VLESS xdns outbound address(es)"
fi

# None may be a bare IPv4 literal (Xray rejects VLESS-no-TLS to a public IP; we
# use domains so the invariant is simply: no bare IP here).
ip_re='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
for a in ${addrs[@]+"${addrs[@]}"}; do
    if [[ "$a" =~ $ip_re ]]; then
        bad "VLESS xdns address is a bare IP ('$a') — Xray >= 26.9 will reject it"
    else
        ok "VLESS xdns address '$a' is a domain form (accepted by Xray >= 26.9)"
    fi
done

# The real DNS-tunnel routing must still target literal resolver/server IPs via
# finalmask (so a domain vnext does not add a DNS-bootstrap dependency).
if grep -q 'fmd=$(xray_xdns_finalmask direct .* "${SERVER_IP}:${port}")' "$F"; then
    ok "direct finalmask still targets the literal SERVER_IP:port"
else
    bad "direct finalmask no longer targets SERVER_IP:port — routing may have changed"
fi

echo ""
if [ "$fail" -gt 0 ]; then echo "FAILED ($fail failed, $pass passed)"; exit 1; fi
echo "PASSED ($pass checks)"
