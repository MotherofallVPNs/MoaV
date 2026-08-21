#!/bin/bash
# Golden test for the moav:// bundle emitter (scripts/lib/moav-bundle.sh):
# enabled protocols become p= records, disabled ones don't, credentials go in
# shared params, and base64 values (reality pbk) are percent-encoded. The
# round-trip (moav-client ParseMoaVBundle) is pinned in the moav-client repo.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
has()  { case "$1" in *"$2"*) ok "$3";; *) bad "$3 (missing: $2)";; esac; }
lacks(){ case "$1" in *"$2"*) bad "$3 (unexpected: $2)";; *) ok "$3";; esac; }

moav_name_prefix() { echo "MoaV-test-"; }
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/moav-bundle.sh"

# Common credentials for all cases.
setup_creds() {
    export USER_UUID="a3fcdcc0-5751-4b76-b45c-e38d8f0693ed" USER_PASSWORD="pw123"
    export REALITY_PUBLIC_KEY="RmVQ0abc+Def/Ghi=" REALITY_SHORT_ID="deadbeef" REALITY_TARGET_HOST="update.example.com"
    export DOMAIN="vpn.example.com" HYSTERIA2_OBFS_PASSWORD="obfspw"
    export PORT_XHTTP=2096 XHTTP_REALITY_TARGET="dl.google.com:443" PORT_ANYTLS=8445 SS_PORT=8388
    export SS_SERVER_PSK_LOCAL="srvpsk" SS_USER_PSK="userpsk" SS_METHOD_LOCAL="2022-blake3-aes-128-gcm"
}
disable_all() { for v in REALITY XHTTP CDN TROJAN ANYTLS HYSTERIA2 SS; do export "ENABLE_$v=false"; done; }

echo "moav:// emitter: enabled -> p= records, base64 pbk encoded, disabled omitted"

# --- all proxies enabled ---
setup_creds; disable_all
export ENABLE_REALITY=true ENABLE_XHTTP=true ENABLE_TROJAN=true ENABLE_ANYTLS=true ENABLE_HYSTERIA2=true ENABLE_SS=true
export ENABLE_CDN=true CDN_ADDRESS="cdn.example.com" CDN_TRANSPORT=httpupgrade CDN_WS_PATH="/ws" CDN_SNI="cdn.example.com"
url=$(moav_bundle_link "alice" "203.0.113.9")
has "$url" "moav://a3fcdcc0-5751-4b76-b45c-e38d8f0693ed@203.0.113.9?" "starts with uuid@host"
has "$url" "pbk=RmVQ0abc%2BDef%2FGhi%3D"       "reality pbk is percent-encoded"
has "$url" "p=reality,443,sni=update.example.com,flow=xtls-rprx-vision" "reality record"
has "$url" "p=vless-xhttp,2096,sni=dl.google.com,fp=chrome" "xhttp record"
has "$url" "p=vless-httpupgrade,443,host=cdn.example.com" "CDN httpupgrade record"
has "$url" "p=trojan,8443"  "trojan record"
has "$url" "p=anytls,8445"  "anytls record"
has "$url" "p=hy2,443,obfs=salamander" "hy2 record"
has "$url" "p=ss,8388"      "ss record"
has "$url" "#MoaV-test-alice" "label fragment"

# --- CDN over ws -> vless-ws (not httpupgrade) ---
export CDN_TRANSPORT=ws
url=$(moav_bundle_link "alice" "203.0.113.9")
has   "$url" "p=vless-ws,443,host=cdn.example.com" "CDN ws record"
lacks "$url" "p=vless-httpupgrade" "no httpupgrade record when transport=ws"

# --- only reality + trojan ---
setup_creds; disable_all; export ENABLE_REALITY=true ENABLE_TROJAN=true
url=$(moav_bundle_link "bob" "198.51.100.7")
has   "$url" "p=reality,443" "reality present"
has   "$url" "p=trojan,8443" "trojan present"
lacks "$url" "p=hy2"         "hy2 omitted when disabled"
lacks "$url" "p=ss,"         "ss omitted when disabled"
lacks "$url" "p=vless-xhttp" "xhttp omitted when disabled"

# --- no proxies enabled -> empty ---
setup_creds; disable_all
url=$(moav_bundle_link "nobody" "203.0.113.9")
[ -z "$url" ] && ok "emits nothing when no proxy is enabled" || bad "expected empty, got: $url"

echo ""
if [ "$fail" -gt 0 ]; then echo "FAILED ($fail failed, $pass passed)"; exit 1; fi
echo "PASSED ($pass checks)"
