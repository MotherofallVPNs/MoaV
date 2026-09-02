#!/bin/bash
# sing-box config validity + 1.14-compatibility gate.
#
# Renders configs/sing-box/config.json.template with representative values,
# asserts it is valid JSON, and asserts none of the constructs sing-box 1.14
# REJECTS or removed are present. This is a fast static gate: a 1.14-incompatible
# edit fails CI *before* it reaches the sing-box entrypoint's runtime
# `sing-box check` — which, if it fails in production, takes the proxy down.
#
# It also guards the client-side WireGuard migration (outbound -> endpoint).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$ROOT/configs/sing-box/config.json.template"
CLIENT="$ROOT/scripts/client-connect.sh"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "sing-box config: valid JSON + 1.14 compatibility"

# Representative render values (JSON user arrays kept empty — we validate shape,
# not sing-box semantics).
export ANYTLS_USERS_JSON='[]' REALITY_USERS_JSON='[]' SHADOWSOCKS_USERS_JSON='[]' \
       TROJAN_USERS_JSON='[]' VLESS_WS_USERS_JSON='[]' HYSTERIA2_USERS_JSON='[]' \
       HYSTERIA2_OBFS_PASSWORD='obfspw' HYSTERIA2_OBFS_TYPE='salamander' HYSTERIA2_BBR_LINE='' \
       CDN_TRANSPORT='ws' CDN_WS_PATH='/ws' CLASH_API_SECRET='testsecret' \
       DOMAIN='example.com' LOG_LEVEL='info' PORT_ANYTLS='8445' PORT_SS='8388' \
       REALITY_PRIVATE_KEY='k' REALITY_SERVER_NAME='www.microsoft.com' \
       REALITY_SHORT_ID='0123abcd' REALITY_TARGET_HOST='www.microsoft.com' \
       REALITY_TARGET_PORT='443' SS_METHOD='2022-blake3-aes-128-gcm' SS_SERVER_PSK='psk' \
       PORT_SNELL='8389' SNELL_SERVER_PSK='snellpsk123456' SNELL_OBFS='http' SNELL_USERS_JSON='[]'

# Render (envsubst if present, else a Python fallback so the test runs anywhere).
if command -v envsubst >/dev/null 2>&1; then
    rendered="$(envsubst < "$TEMPLATE")"
else
    rendered="$(python3 -c 'import os,re,sys; s=open(sys.argv[1]).read(); print(re.sub(r"\$\{([A-Z0-9_]+)\}", lambda m: os.environ.get(m.group(1),""), s))' "$TEMPLATE")"
fi

# 1. Valid JSON after render.
if printf '%s' "$rendered" | python3 -m json.tool >/dev/null 2>&1; then
    ok "rendered config is valid JSON"
else
    bad "rendered config is NOT valid JSON"
fi

# 2. None of the constructs sing-box 1.14 rejects/removed.
assert_absent() { # <regex> <label>
    if printf '%s' "$rendered" | grep -qE "$1"; then bad "$2"; else ok "$2"; fi
}
assert_absent '"acme"'                                        'no inline tls.acme (1.14 rejects it -> certificate_provider)'
assert_absent '"type"[[:space:]]*:[[:space:]]*"block"'        'no legacy block outbound (use reject action)'
assert_absent '"type"[[:space:]]*:[[:space:]]*"dns"'          'no legacy dns outbound (use hijack-dns action)'
assert_absent '"type"[[:space:]]*:[[:space:]]*"wireguard"'    'no wireguard outbound (endpoints only in 1.14)'
assert_absent '"geoip"|"geosite"'                             'no legacy geoip/geosite (use rule-sets)'
assert_absent '"sniff"[[:space:]]*:'                          'no inbound-level sniff field (use route action)'
assert_absent '"domain_strategy"[[:space:]]*:'               'no inbound-level domain_strategy (use domain_resolver)'
assert_absent '"address"[[:space:]]*:[[:space:]]*"[0-9]'      'no legacy address:-form DNS server (use typed server:)'

# 3. Client no longer emits the removed WireGuard OUTBOUND JSON keys. Match the
# quoted JSON keys, not the shell variables ($peer_public_key still feeds the
# endpoint's "public_key").
if grep -qE '"local_address"|"peer_public_key"' "$CLIENT"; then
    bad "client-connect.sh still emits the removed WG outbound keys (local_address/peer_public_key)"
else
    ok "client WireGuard uses the 1.14 endpoint form (address/peers[])"
fi

echo ""
if [[ $fail -eq 0 ]]; then
    echo "PASSED ($pass checks)"
else
    echo "FAILED ($fail failed, $pass passed)"
    exit 1
fi
