#!/bin/bash
# Regression: XDNS must carry VLESS Encryption so it works on Xray >= 26.9.
#
# The bug (found by the v2.3.0-rc.3 e2e after bumping Xray v26.7.28 -> v26.9.9):
# Xray >= 26.9 rejects "vless without TLS or other encryption ... unless the
# server address is a private IP or domain" — and verified against the real
# binary, only a *private IP* actually passes (a domain is resolved and re-checked,
# an mKCP seed does not count). xdns dials a public resolver/server over mKCP (the
# vnext address is the real dial target, not nominal), so the fix is to carry
# encryption at the VLESS layer: a server-wide keypair (openssl X25519, formatted
# as Xray's compact mlkem768x25519plus strings) minted at bootstrap — decryption
# on the server xdns inbound, encryption in every client bundle.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XRAY="$ROOT/scripts/lib/xray.sh"
BOOT="$ROOT/scripts/bootstrap.sh"
KEYS="$ROOT/scripts/lib/keys.sh"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "xdns: VLESS Encryption wired for Xray >= 26.9"

# 1. Client xdns configs carry encryption (not "none").
enc_count=$(grep -c '"encryption": "${XDNS_VLESS_ENCRYPTION}"' "$XRAY" || true)
if [ "${enc_count:-0}" -ge 2 ]; then
    ok "both xdns client VLESS outbounds use \${XDNS_VLESS_ENCRYPTION}"
else
    bad "xdns client configs are missing VLESS encryption (found $enc_count of 2)"
fi
if grep -qE '"protocol": "vless".*"encryption": "none"' "$XRAY"; then
    bad "an xdns client VLESS outbound still has encryption:\"none\" (Xray >= 26.9 rejects it)"
else
    ok "no xdns client VLESS outbound left on encryption:\"none\""
fi

# 2. Server xdns inbound carries the matching decryption (not 'none').
if grep -q "'decryption': '\$XDNS_VLESS_DECRYPTION'" "$BOOT"; then
    ok "server xdns inbound uses \$XDNS_VLESS_DECRYPTION"
else
    bad "server xdns inbound is not wired to XDNS_VLESS_DECRYPTION"
fi

# 3. The keypair generator exists and emits the Xray format.
if grep -q 'keys_xdns_vless_pair()' "$KEYS"; then
    ok "keys.sh defines keys_xdns_vless_pair"
else
    bad "keys.sh has no keys_xdns_vless_pair generator"
fi

# 4. Functional: the generator emits a well-formed decryption/encryption pair.
if command -v openssl >/dev/null 2>&1; then
    out=$( source "$KEYS" 2>/dev/null; keys_xdns_vless_pair 2>/dev/null )
    dec=$(printf '%s\n' "$out" | grep '^XDNS_VLESS_DECRYPTION=' | cut -d= -f2-)
    enc=$(printf '%s\n' "$out" | grep '^XDNS_VLESS_ENCRYPTION=' | cut -d= -f2-)
    # prefix (31 chars) + base64url key (43 chars) = 74
    if [ "${dec#mlkem768x25519plus.native.600s.}" != "$dec" ] && [ "${#dec}" -eq 74 ]; then
        ok "decryption is mlkem768x25519plus...600s + 43-char key"
    else
        bad "decryption has an unexpected shape: '${dec:0:48}...' (len ${#dec})"
    fi
    if [ "${enc#mlkem768x25519plus.native.0rtt.}" != "$enc" ] && [ "${#enc}" -eq 74 ]; then
        ok "encryption is mlkem768x25519plus...0rtt + 43-char key"
    else
        bad "encryption has an unexpected shape: '${enc:0:48}...' (len ${#enc})"
    fi
else
    printf '  SKIP  openssl unavailable for the functional keygen check\n'
fi

echo ""
if [ "$fail" -gt 0 ]; then echo "FAILED ($fail failed, $pass passed)"; exit 1; fi
echo "PASSED ($pass checks)"
