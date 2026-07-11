#!/bin/bash
# Golden test for the sing-box share-link builders in lib/sing-box.sh.
# Locks their output to the exact strings the inline code produced before the
# refactor, so an extraction can be proven byte-identical. Pure string
# functions — no server, no Docker. Run: bash scripts/lib/test-singbox-links.sh
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/sing-box.sh"

# Fixed inputs
export USER_UUID="11111111-2222-3333-4444-555555555555"
export USER_PASSWORD="s3cr3t-pass"
export SERVER_IP="203.0.113.9"
export SERVER_IPV6="2001:db8::1"
export DOMAIN="vpn.example.com"
export REALITY_TARGET_HOST="www.cloudflare.com"
export REALITY_PUBLIC_KEY="PUBKEYbase64xyz"
export REALITY_SHORT_ID="a1b2c3d4"
export HYSTERIA2_OBFS_PASSWORD="obfs-pw"
export PORT_ANYTLS="8445"
export CDN_ADDRESS="cdn.example.net"
export CDN_TRANSPORT="ws"
export CDN_WS_PATH="/moav"
export CDN_SNI="cdn.example.net"
export CDN_DOMAIN="cdn.example.net"

fail=0
check() {
    local name="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        echo "ok   $name"
    else
        echo "FAIL $name"
        echo "  want: $want"
        echo "  got:  $got"
        fail=1
    fi
}

U=alice
check reality-v4  "$(singbox_reality_link "$U" "$SERVER_IP")" \
  "vless://${USER_UUID}@203.0.113.9:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.cloudflare.com&fp=random&pbk=PUBKEYbase64xyz&sid=a1b2c3d4&type=tcp#MoaV-Reality-alice"
check reality-v6  "$(singbox_reality_link "${U}-IPv6" "[${SERVER_IPV6}]")" \
  "vless://${USER_UUID}@[2001:db8::1]:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.cloudflare.com&fp=random&pbk=PUBKEYbase64xyz&sid=a1b2c3d4&type=tcp#MoaV-Reality-alice-IPv6"
check trojan-v4   "$(singbox_trojan_link "$U" "$SERVER_IP")" \
  "trojan://s3cr3t-pass@203.0.113.9:8443?security=tls&sni=vpn.example.com&type=tcp#MoaV-Trojan-alice"
check trojan-v6   "$(singbox_trojan_link "${U}-IPv6" "[${SERVER_IPV6}]")" \
  "trojan://s3cr3t-pass@[2001:db8::1]:8443?security=tls&sni=vpn.example.com&type=tcp#MoaV-Trojan-alice-IPv6"
check anytls-v4   "$(singbox_anytls_link "$U" "$SERVER_IP")" \
  "anytls://s3cr3t-pass@203.0.113.9:8445?sni=vpn.example.com&insecure=0#MoaV-AnyTLS-alice"
check anytls-v6   "$(singbox_anytls_link "${U}-IPv6" "[${SERVER_IPV6}]")" \
  "anytls://s3cr3t-pass@[2001:db8::1]:8445?sni=vpn.example.com&insecure=0#MoaV-AnyTLS-alice-IPv6"
check hy2-v4      "$(singbox_hysteria2_link "$U" "$SERVER_IP")" \
  "hysteria2://s3cr3t-pass@203.0.113.9:443?sni=vpn.example.com&obfs=salamander&obfs-password=obfs-pw#MoaV-Hysteria2-alice"
check hy2-v6      "$(singbox_hysteria2_link "${U}-IPv6" "[${SERVER_IPV6}]")" \
  "hysteria2://s3cr3t-pass@[2001:db8::1]:443?sni=vpn.example.com&obfs=salamander&obfs-password=obfs-pw#MoaV-Hysteria2-alice-IPv6"
check cdn         "$(singbox_cdn_link "$U")" \
  "vless://${USER_UUID}@cdn.example.net:443?security=tls&type=ws&path=/moav&sni=cdn.example.net&host=cdn.example.net&fp=random&alpn=http/1.1#MoaV-CDN-alice"

if [[ $fail -eq 0 ]]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
