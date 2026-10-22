#!/bin/bash
# Regression: XDNS must carry VLESS Encryption so it works on Xray >= 26.9, and
# the finalmask settings must use the Xray >= v26.9.30 object schema.
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

# 5. Finalmask must use the Xray >= v26.9.30 object schema; the legacy
#    "domain+udp://ip:port" resolver strings make v26.10.x refuse to start.
if grep -vE '^\s*#' "$XRAY" | grep -q '+udp://'; then
    bad "xdns client finalmask still emits the pre-v26.9.30 'domain+udp://ip:port' resolver strings"
else
    ok "xdns client finalmask no longer emits legacy 'udp://' resolver strings"
fi
if grep -q "'domains': \[{'names': \['\$xdns_domain'\]}\]" "$BOOT"; then
    ok "server xdns inbound uses the object form domains:[{names:[...]}]"
else
    bad "server xdns inbound is not on the v26.9.30+ domains:[{names:[...]}] form"
fi
if command -v python3 >/dev/null 2>&1; then
    for m in txt aaaa; do
        out=$( source "$XRAY" 2>/dev/null; xray_xdns_finalmask dns x.example.com "1.1.1.1,8.8.8.8" "$m" "" )
        want=16; [ "$m" = aaaa ] && want=28
        if printf '%s' "$out" | python3 -I -c "
import json,sys
d=json.load(sys.stdin)
assert d['domains']==[{'names':['x.example.com'],'types':[$want]}], d
assert d['resolvers']==[{'addrs':['1.1.1.1:53','8.8.8.8:53']}], d
" 2>/dev/null; then
            ok "client finalmask (dns, method=$m) renders domains/types=[$want] + resolvers/addrs"
        else
            bad "client finalmask (dns, method=$m) has an unexpected shape: $out"
        fi
    done
    out=$( source "$XRAY" 2>/dev/null; xray_xdns_finalmask direct x.example.com "" txt "203.0.113.5:5356" )
    if printf '%s' "$out" | python3 -I -c "
import json,sys
d=json.load(sys.stdin)
assert d['resolvers']==[{'addrs':['203.0.113.5:5356']}], d
assert d['domains'][0]['names']==['x.example.com'], d
" 2>/dev/null; then
        ok "client finalmask (direct) targets the server XDNS port via resolvers/addrs"
    else
        bad "client finalmask (direct) has an unexpected shape: $out"
    fi
else
    printf '  SKIP  python3 unavailable for the finalmask render check\n'
fi

# 6. Server-side (return path) mKCP MTU must fit ONE DNS reply. Xray >= v26.9.30
#    no longer fragments a server packet across records; with edns0=0 the reply is
#    512 bytes, so the payload cap is ~215 (TXT) / ~117 (AAAA, CNAME) / ~39 (A).
#    The old 'mtu': 900 config-checks fine on v26.10.21 but passes ZERO traffic
#    (every packet is dropped with "xdns: err size 900") — found on loopback with
#    the real v26.10.21 binary in the 2026-10 bump; <= v26.9.9 moved 100 KB in 3s
#    on the same 900, v26.10.21 moved nothing until the MTU was lowered.
if grep -qE "^\s*'mtu': *900," "$BOOT"; then
    bad "server xdns inbound still hardcodes kcp mtu 900 (drops every reply on Xray >= v26.9.30)"
else
    ok "server xdns inbound no longer hardcodes kcp mtu 900"
fi
if grep -q "'mtu': \$xdns_server_mtu," "$BOOT"; then
    ok "server xdns inbound takes its kcp mtu from xdns_server_mtu"
else
    bad "server xdns inbound does not render \$xdns_server_mtu"
fi
# Replay the method -> server-mtu table from bootstrap.sh and bound every value
# by the Xray finalmask per-reply capacity for that record type.
mtu_block=$(awk '/case "\$\{XDNS_METHOD:-txt\}" in/,/esac/' "$BOOT")
for pair in txt:215 aaaa:117 cname:117 a:39; do
    m=${pair%%:*}; cap=${pair##*:}
    v=$(XDNS_METHOD="$m" bash -c "$mtu_block; printf '%s' \"\$xdns_server_mtu\"" 2>/dev/null)
    if [ -n "$v" ] && [ "$v" -ge 17 ] && [ "$v" -le "$cap" ]; then
        ok "server xdns mtu for method=$m is $v (<= per-reply cap $cap)"
    else
        bad "server xdns mtu for method=$m is '$v' (must be 17..$cap)"
    fi
done

echo ""
if [ "$fail" -gt 0 ]; then echo "FAILED ($fail failed, $pass passed)"; exit 1; fi
echo "PASSED ($pass checks)"
