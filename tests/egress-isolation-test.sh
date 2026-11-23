#!/bin/bash
# Egress isolation: tunneled client traffic must never reach private or infra
# networks. Every layer must generate its block rules when EGRESS_ISOLATION is
# unset or on, and none when it is off.
#
# Hermetic: iptables is a recording stub, sing-box/xray rules are checked with
# jq on the rendered templates. No Docker, no root. The sing-box result is also
# run through the real binary when tests/singbox-check-test.sh has cached it.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/scripts/lib/egress-isolation.sh"
pass=0; fail=0
ok()   { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
skip() { printf '  SKIP  %s\n' "$1"; }
check() { if "${@:2}" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

echo "egress isolation"
command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# The ranges the feature promises. Kept here, not read from the lib, so that
# dropping one from the lib fails this test.
V4_REQUIRED="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 127.0.0.0/8 172.33.0.0/16 10.20.0.0/24"
V6_REQUIRED="fc00::/7 fe80::/10 ::1/128"

# Run "$@" with the lib sourced and EGRESS_ISOLATION set to $1 ("<unset>" = unset).
with_mode() {
    local mode="$1"; shift
    (
        unset EGRESS_ISOLATION
        [ "$mode" = "<unset>" ] || export EGRESS_ISOLATION="$mode"
        # shellcheck disable=SC1090
        . "$LIB"
        "$@"
    )
}

# --- the lib itself -----------------------------------------------------------
check "lib parses as POSIX sh" sh -n "$LIB"
if command -v dash >/dev/null 2>&1; then check "lib parses under dash" dash -n "$LIB"; fi

# shellcheck disable=SC1090
. "$LIB"
for c in $V4_REQUIRED; do
    [[ " $EGRESS_BLOCK_V4 " == *" $c "* ]] && ok "v4 list has $c" || bad "v4 list is missing $c"
done
for c in $V6_REQUIRED; do
    [[ " $EGRESS_BLOCK_V6 " == *" $c "* ]] && ok "v6 list has $c" || bad "v6 list is missing $c"
done

# --- the toggle: default on, off only on an explicit opt-out --------------------
for v in "<unset>" "" on ON true 1 typo; do
    with_mode "$v" egress_isolation_enabled \
        && ok "EGRESS_ISOLATION='$v' -> on" || bad "EGRESS_ISOLATION='$v' turned isolation OFF"
done
for v in off OFF false 0 no disabled; do
    with_mode "$v" egress_isolation_enabled \
        && bad "EGRESS_ISOLATION='$v' left isolation on" || ok "EGRESS_ISOLATION='$v' -> off"
done

# --- iptables (WireGuard / AmneziaWG FORWARD, sing-box UDP OUTPUT) ------------
# The stub records calls and keeps just enough state for -N/-C/-D/-F to be honest.
mkdir -p "$work/bin"
cat > "$work/bin/iptables" <<'EOF'
#!/bin/sh
tool=$(basename "$0"); rules="$STUB_STATE/$tool.rules"; : >> "$rules"
echo "$tool $*" >> "$STUB_STATE/calls.log"
op="$1"; chain="${2:-}"; shift; [ $# -gt 0 ] && shift
drop() { grep -vxF "$1" "$rules" > "$rules.tmp"; mv "$rules.tmp" "$rules"; }
case "$op" in
    -N) grep -qxF "chain $chain" "$rules" && exit 1; echo "chain $chain" >> "$rules" ;;
    -F) grep -qxF "chain $chain" "$rules" || exit 1
        grep -v "^rule $chain " "$rules" > "$rules.tmp"; mv "$rules.tmp" "$rules" ;;
    -X) grep -qxF "chain $chain" "$rules" || exit 1; drop "chain $chain" ;;
    -A) [ -n "${STUB_FAIL_APPEND:-}" ] && exit 4; echo "rule $chain $*" >> "$rules" ;;
    -I) shift; echo "rule $chain $*" >> "$rules" ;;
    -C) grep -qxF "rule $chain $*" "$rules" ;;
    -D) grep -qxF "rule $chain $*" "$rules" || exit 1; drop "rule $chain $*" ;;
    -S) exit 0 ;;
esac
EOF
chmod +x "$work/bin/iptables"; cp "$work/bin/iptables" "$work/bin/ip6tables"
printf 'nameserver 127.0.0.11\noptions ndots:0\n' > "$work/resolv.conf"

stubbed() { # <mode> <function> [args] -> runs it against the stub
    PATH="$work/bin:$PATH" STUB_STATE="$work/state" with_mode "$@" >/dev/null 2>&1
}
reset_state() { rm -rf "$work/state"; mkdir -p "$work/state"; }
has_rule()   { grep -qxF "rule $2" "$work/state/$1.rules" 2>/dev/null; }
count_rule() { grep -cxF "rule $2" "$work/state/$1.rules" 2>/dev/null || true; }

for mode in "<unset>" on; do
    reset_state
    stubbed "$mode" egress_firewall wg0 && ok "[$mode] egress_firewall succeeds" || bad "[$mode] egress_firewall failed"
    missing=""
    for c in $V4_REQUIRED; do has_rule iptables "MOAV-EGRESS -d $c -j DROP" || missing="$missing $c"; done
    for c in $V6_REQUIRED; do has_rule ip6tables "MOAV-EGRESS -d $c -j DROP" || missing="$missing $c"; done
    [ -z "$missing" ] && ok "[$mode] FORWARD DROP generated for every v4 + v6 range" \
                      || bad "[$mode] no FORWARD DROP for:$missing"
    for t in iptables ip6tables; do
        grep -qxF "$t -I FORWARD 1 -i wg0 -j MOAV-EGRESS" "$work/state/calls.log" \
            && ok "[$mode] $t hook is inserted at the TOP of FORWARD, scoped to the tunnel iface" \
            || bad "[$mode] $t hook is not 'FORWARD 1 -i wg0' (must precede the ACCEPT; -i keeps replies flowing)"
    done
done

# Idempotent: a second apply must not duplicate anything.
stubbed on egress_firewall wg0
[ "$(count_rule iptables "MOAV-EGRESS -d 10.0.0.0/8 -j DROP")" = "1" ] \
    && [ "$(count_rule iptables "FORWARD -i wg0 -j MOAV-EGRESS")" = "1" ] \
    && [ "$(count_rule ip6tables "FORWARD -i wg0 -j MOAV-EGRESS")" = "1" ] \
    && ok "re-applying is idempotent (one hook, one DROP per range)" \
    || bad "re-applying duplicated rules"

# Turning it off removes what an earlier start installed...
stubbed off egress_firewall wg0
if grep -q "MOAV-EGRESS" "$work/state/iptables.rules" "$work/state/ip6tables.rules"; then
    bad "EGRESS_ISOLATION=off left MOAV-EGRESS rules behind"
else
    ok "EGRESS_ISOLATION=off clears previously installed rules"
fi
# ...and on a fresh start generates none at all.
reset_state
stubbed off egress_firewall wg0 && ok "[off] egress_firewall succeeds" || bad "[off] egress_firewall failed"
grep -qE -- "-j DROP|-I FORWARD" "$work/state/calls.log" \
    && bad "[off] block rules were generated" || ok "[off] no FORWARD block rules generated"

# Fail closed: an exit must not come up unfiltered because a rule did not load.
reset_state
STUB_FAIL_APPEND=1 stubbed on egress_firewall wg0 \
    && bad "egress_firewall reported success although iptables failed" \
    || ok "egress_firewall fails when a rule cannot be installed"

reset_state
stubbed "<unset>" egress_udp_backstop "$work/resolv.conf" && ok "[<unset>] egress_udp_backstop succeeds" || bad "[<unset>] egress_udp_backstop failed"
missing=""
for c in $V4_REQUIRED; do has_rule iptables "MOAV-EGRESS-OUT -d $c -j DROP" || missing="$missing $c"; done
[ -z "$missing" ] && ok "sing-box UDP backstop drops every v4 range" || bad "UDP backstop is missing:$missing"
grep -qxF "iptables -I OUTPUT 1 -p udp -j MOAV-EGRESS-OUT" "$work/state/calls.log" \
    && ok "UDP backstop hooks OUTPUT for UDP only (TCP fallback to the decoy is untouched)" \
    || bad "UDP backstop hook is not 'OUTPUT 1 -p udp'"
line_of() { grep -nxF "rule $1" "$work/state/iptables.rules" | head -1 | cut -d: -f1; }
ct=$(line_of "MOAV-EGRESS-OUT -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN")
ns=$(line_of "MOAV-EGRESS-OUT -d 127.0.0.11 -j RETURN")
lo=$(line_of "MOAV-EGRESS-OUT -d 127.0.0.0/8 -j DROP")
[ -n "$ct" ] && [ -n "$ns" ] && [ -n "$lo" ] && [ "$ct" -lt "$lo" ] && [ "$ns" -lt "$lo" ] \
    && ok "client replies + the container's resolver are allowed BEFORE the drops" \
    || bad "UDP backstop would drop client replies or DNS (conntrack=$ct resolver=$ns loopback-drop=$lo)"
reset_state
stubbed off egress_udp_backstop "$work/resolv.conf"
grep -q -- "-j DROP" "$work/state/calls.log" \
    && bad "[off] UDP backstop rules were generated" || ok "[off] no UDP backstop rules generated"

# --- sing-box route rules -----------------------------------------------------
render() { # <template> <out>
    if command -v envsubst >/dev/null 2>&1; then envsubst < "$1" > "$2"
    else python3 -c 'import os,re,sys; s=open(sys.argv[1]).read(); open(sys.argv[2],"w").write(re.sub(r"\$\{([A-Z0-9_]+)\}", lambda m: os.environ.get(m.group(1),""), s))' "$1" "$2"
    fi
}
# Real-shaped fixtures so the same render can go through `sing-box check` below.
os="$(uname -s | tr '[:upper:]' '[:lower:]')"; arch="$(uname -m)"
case "$arch" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; esac
sbver="$(grep -E '^SINGBOX_VERSION=' "$ROOT/.env.example" | head -1 | cut -d= -f2 | tr -d ' ')"
sbbin="${SINGBOX_BIN_CACHE:-/tmp/singbox-bin-cache}/sing-box-${sbver}-${os}-${arch}"
rkey=""; [ -x "$sbbin" ] && rkey="$("$sbbin" generate reality-keypair 2>/dev/null | awk '/PrivateKey/{print $2}')"
ss_psk="$(printf '1234567890123456' | base64)"
export ANYTLS_USERS_JSON='[]' REALITY_USERS_JSON='[]' SHADOWSOCKS_USERS_JSON='[]' \
       TROJAN_USERS_JSON='[]' VLESS_WS_USERS_JSON='[]' HYSTERIA2_USERS_JSON='[]' \
       HYSTERIA2_OBFS_PASSWORD='obfspw' HYSTERIA2_OBFS_TYPE='salamander' \
       CDN_TRANSPORT='ws' CDN_WS_PATH='/ws' CLASH_API_SECRET='testsecret' \
       DOMAIN='example.com' LOG_LEVEL='info' PORT_ANYTLS='8445' PORT_SS='8388' \
       REALITY_PRIVATE_KEY="${rkey:-wJ7dEpZ6gTfQ0nQb3l2xk9m8yq1sVd4uHc5rNpA6oXk}" \
       REALITY_SERVER_NAME='www.example.org' REALITY_SHORT_ID='0123abcd' \
       REALITY_TARGET_HOST='www.example.org' REALITY_TARGET_PORT='443' \
       SS_METHOD='2022-blake3-aes-128-gcm' SS_SERVER_PSK="$ss_psk" \
       PORT_SNELL='8389' SNELL_SERVER_PSK='snellpsk123456' SNELL_OBFS='http' \
       XRAY_USERS_JSON='' PORT_XHTTP='2096' \
       XHTTP_REALITY_TARGET='www.example.org:443' XHTTP_REALITY_TARGET_HOST='www.example.org'

sb="$work/sing-box.json"
render "$ROOT/configs/sing-box/config.json.template" "$sb"
jq -e . "$sb" >/dev/null 2>&1 || { bad "sing-box template did not render to JSON"; }

for mode in "<unset>" on; do
    cp "$sb" "$work/sb-on.json"
    with_mode "$mode" egress_singbox "$work/sb-on.json" >/dev/null 2>&1 \
        && ok "[$mode] egress_singbox succeeds" || bad "[$mode] egress_singbox failed"
    missing=""
    for c in $V4_REQUIRED $V6_REQUIRED; do
        jq -e --arg c "$c" 'any(.route.rules[]; .action == "reject" and (.ip_cidr | index($c) != null))' \
            "$work/sb-on.json" >/dev/null 2>&1 || missing="$missing $c"
    done
    [ -z "$missing" ] && ok "[$mode] sing-box reject rule covers every range" \
                      || bad "[$mode] sing-box reject rule is missing:$missing"
done
on="$work/sb-on.json"
check "reject comes after hijack-dns and resolve (a private-IP resolver keeps working; names are resolved before the check)" \
    jq -e '[.route.rules[].action] as $a | ($a | index("reject")) as $r
           | ($a | index("hijack-dns")) < $r and ($a | index("resolve")) < $r' "$on"
check "reject precedes every route rule except the fallback allowance (i.e. the default outbound)" \
    jq -e '([.route.rules[].action] | index("reject")) as $r
           | [.route.rules | to_entries[] | select(.value.action == "route" and .value.domain != ["decoy"]) | .key]
           | length > 0 and all(.[]; . > $r)' "$on"
check "trojan fallback to the decoy is allowed, pinned to inbound + host + port, ahead of sniff" \
    jq -e '.route.rules[0] | .action == "route" and .inbound == ["trojan-tls-in"]
           and .domain == ["decoy"] and .port == [80]' "$on"

# bootstrap adds `resolve prefer_ipv4` on v4-only servers: keep it, do not add a second.
jq '(.route.rules | map(.action == "hijack-dns") | index(true)) as $i
    | .route.rules |= (.[0:$i+1] + [{"action":"resolve","strategy":"prefer_ipv4"}] + .[$i+1:])' "$sb" > "$work/sb-v4.json"
with_mode on egress_singbox "$work/sb-v4.json" >/dev/null 2>&1
check "an existing resolve rule is reused, not duplicated" \
    jq -e '[.route.rules[] | select(.action == "resolve")] | length == 1 and .[0].strategy == "prefer_ipv4"' "$work/sb-v4.json"

cp "$sb" "$work/sb-off.json"
with_mode off egress_singbox "$work/sb-off.json" >/dev/null 2>&1 && ok "[off] egress_singbox succeeds" || bad "[off] egress_singbox failed"
cmp -s "$sb" "$work/sb-off.json" && ok "[off] sing-box config is untouched (no block rules)" \
                                 || bad "[off] sing-box config was modified"

if [ -x "$sbbin" ] && [ -n "$rkey" ] && command -v openssl >/dev/null 2>&1; then
    mkdir -p "$work/certs/live/$DOMAIN"
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/certs/live/$DOMAIN/privkey.pem" \
        -out "$work/certs/live/$DOMAIN/fullchain.pem" -days 1 -subj "/CN=$DOMAIN" >/dev/null 2>&1
    sed "s#/certs/#$work/certs/#g" "$on" > "$work/sb-check.json"
    "$sbbin" check -c "$work/sb-check.json" 2>"$work/check.err" \
        && ok "sing-box $sbver accepts the isolated config" \
        || { bad "sing-box $sbver rejects the isolated config:"; sed 's/^/        /' "$work/check.err"; }
else
    skip "real sing-box check (binary not cached; run tests/singbox-check-test.sh first)"
fi

# --- xray routing + freedom finalRules --------------------------------------
xr="$work/xray.json"
render "$ROOT/configs/xray/config.json.template" "$xr"
for mode in "<unset>" on; do
    with_mode "$mode" egress_xray "$xr" "$work/xr-on.json" >/dev/null 2>&1 \
        && ok "[$mode] egress_xray succeeds" || bad "[$mode] egress_xray failed"
    missing=""
    for c in $V4_REQUIRED $V6_REQUIRED; do
        jq -e --arg c "$c" '
            any(.routing.rules[]; .outboundTag == "egress-block" and (.ip | index($c) != null))
            and any(.outbounds[]; .protocol == "freedom"
                    and .settings.finalRules[0].action == "block"
                    and (.settings.finalRules[0].ip | index($c) != null))' \
            "$work/xr-on.json" >/dev/null 2>&1 || missing="$missing $c"
    done
    [ -z "$missing" ] && ok "[$mode] xray routing rule + freedom finalRules cover every range" \
                      || bad "[$mode] xray rules are missing:$missing"
done
check "xray block rule sits after the stats-API rule and before the catch-all direct" \
    jq -e '[.routing.rules[].outboundTag] as $t
           | ($t | index("api")) < ($t | index("egress-block"))
           and ($t | index("egress-block")) < ($t | index("direct"))' "$work/xr-on.json"
check "xray has a blackhole outbound for the block rule" \
    jq -e 'any(.outbounds[]; .tag == "egress-block" and .protocol == "blackhole")' "$work/xr-on.json"
check "xray default outbound is still freedom/direct" \
    jq -e '.outbounds[0] | .protocol == "freedom" and .tag == "direct"' "$work/xr-on.json"
with_mode off egress_xray "$xr" "$work/xr-off.json" >/dev/null 2>&1 && ok "[off] egress_xray succeeds" || bad "[off] egress_xray failed"
cmp -s "$xr" "$work/xr-off.json" && ok "[off] xray config is copied verbatim (no block rules)" \
                                 || bad "[off] xray config was modified"

# --- wiring: the rules above only matter if every layer actually calls them ----
svc_block() { awk -v svc="  $1:" '$0==svc {f=1; next} f && /^  [a-z0-9_-]+:$/ {exit} f' "$ROOT/docker-compose.yml"; }
before() { # <file> <pattern-a> <pattern-b> -> true if a's first line precedes b's
    local a b
    a=$(grep -nF -- "$2" "$1" | head -1 | cut -d: -f1); b=$(grep -nF -- "$3" "$1" | head -1 | cut -d: -f1)
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}
for svc in sing-box xray wireguard amneziawg trusttunnel; do
    svc_block "$svc" | grep -qF 'EGRESS_ISOLATION=${EGRESS_ISOLATION:-on}' \
        && ok "compose passes EGRESS_ISOLATION (default on) to $svc" \
        || bad "compose does not pass EGRESS_ISOLATION=\${EGRESS_ISOLATION:-on} to $svc"
    check "Dockerfile.$svc ships the lib" grep -qF "COPY scripts/lib/egress-isolation.sh /egress-isolation.sh" "$ROOT/dockerfiles/Dockerfile.$svc"
    check "$svc entrypoint sources the lib" grep -qxF ". /egress-isolation.sh" "$ROOT/scripts/$svc-entrypoint.sh"
done
for svc in wireguard amneziawg; do
    e="$ROOT/scripts/$svc-entrypoint.sh"
    check "$svc: isolation is installed before the FORWARD ACCEPT" \
        before "$e" 'egress_firewall "$INTERFACE"' 'iptables -A FORWARD -i "$INTERFACE" -j ACCEPT'
    check "$svc: isolation is installed before the interface comes up" \
        before "$e" 'egress_firewall "$INTERFACE"' 'ip link set "$INTERFACE" up'
    check "$svc: a failed install is fatal" grep -qE 'egress_firewall "\$INTERFACE" \|\| \{.*exit 1' "$e"
done
e="$ROOT/scripts/sing-box-entrypoint.sh"
check "sing-box: isolation is applied before the config is validated and run" \
    before "$e" 'egress_singbox "$RUNTIME_CONFIG"' 'sing-box check -c "$RUNTIME_CONFIG"'
check "sing-box: installs the UDP backstop" grep -qF "egress_udp_backstop" "$e"
check "Dockerfile.sing-box installs jq + iptables" \
    sh -c "grep -qE '^ +jq ' '$ROOT/dockerfiles/Dockerfile.sing-box' && grep -qE '^ +iptables ' '$ROOT/dockerfiles/Dockerfile.sing-box'"
e="$ROOT/scripts/xray-entrypoint.sh"
check "xray: runs the isolated runtime config, not the raw one" grep -qxF 'exec xray run -c "$RUNTIME_CONFIG"' "$e"
check "xray: isolation is applied before xray starts" before "$e" 'egress_xray "$CONFIG_FILE" "$RUNTIME_CONFIG"' 'exec xray run'
check "Dockerfile.xray installs jq" grep -qE "apk add .*\bjq\b" "$ROOT/dockerfiles/Dockerfile.xray"

check ".env.example documents EGRESS_ISOLATION, default on" grep -qxF "EGRESS_ISOLATION=on" "$ROOT/.env.example"
check "moav update rebuilds the images that bake the lib in" \
    grep -qE 'scripts/lib/egress-isolation\.sh\).*sing-box xray wireguard amneziawg trusttunnel' "$ROOT/lib/update.sh"

# Layers that isolate by other means: guard those too, they are part of the promise.
check "wstunnel can only reach its --restrict-to target (the WireGuard endpoint)" \
    grep -qF 'set -- server --restrict-to "$WSTUNNEL_RESTRICT"' "$ROOT/scripts/wstunnel-entrypoint.sh"
check "trusttunnel keeps private-network connections disabled in the template" \
    grep -qxF "allow_private_network_connections = false" "$ROOT/configs/trusttunnel/vpn.toml.template"
e="$ROOT/scripts/trusttunnel-entrypoint.sh"
check "trusttunnel: isolation is applied to the runtime config before the endpoint starts" \
    before "$e" 'egress_trusttunnel "$RUNTIME_DIR/vpn.toml"' 'exec setpriv'
check "Dockerfile.trusttunnel ships its own lib and iptables" \
    sh -c "grep -qF 'COPY scripts/lib/egress-trusttunnel.sh /egress-trusttunnel.sh' '$ROOT/dockerfiles/Dockerfile.trusttunnel' && grep -qE '^ +iptables ' '$ROOT/dockerfiles/Dockerfile.trusttunnel'"

echo ""
if [ $fail -eq 0 ]; then echo "PASSED ($pass checks)"; else echo "FAILED ($fail failed, $pass passed)"; exit 1; fi
