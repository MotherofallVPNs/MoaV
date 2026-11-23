#!/bin/bash
# TrustTunnel: pinned endpoint <-> pinned official client over HTTP/2 AND HTTP/3,
# and EGRESS_ISOLATION enforced through the real data path (on and off).
# Needs Docker + /dev/net/tun: fatal if missing in CI, SKIPs the live part locally.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKERFILE="$ROOT/dockerfiles/Dockerfile.trusttunnel"
pass=0; fail=0
ok()   { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
skip() { printf '  SKIP  %s\n' "$1"; }
finish() {
    echo ""
    if [ "$fail" -eq 0 ]; then echo "PASSED ($pass checks)"; exit 0; fi
    echo "FAILED ($fail failed, $pass passed)"; exit 1
}

echo "TrustTunnel endpoint: pins, config, HTTP/2 + HTTP/3 interop"

pin() { grep -E "^$1=" "$ROOT/.env.example" | head -1 | cut -d= -f2 | tr -d ' "'; }
VER="$(pin TRUSTTUNNEL_VERSION)"
CVER="$(pin TRUSTTUNNEL_CLIENT_VERSION)"
[ -n "$VER" ] && [ -n "$CVER" ] || { echo "cannot read the TrustTunnel pins from .env.example"; exit 1; }
echo "  pinned endpoint: $VER   pinned client: $CVER"

# --- static: every copy of the pin agrees ------------------------------------
# compose and the Dockerfiles carry fallbacks: what an install without the .env key builds.
same_pin() {  # <label> <value> <expected>
    if [ "$2" = "$3" ]; then ok "$1 = $3"; else bad "$1 is '${2:-<missing>}', .env.example pins $3"; fi
}
same_pin "docker-compose.yml endpoint fallback" \
    "$(grep -oE 'TRUSTTUNNEL_VERSION:-[^}]+' "$ROOT/docker-compose.yml" | head -1 | cut -d- -f2-)" "$VER"
same_pin "Dockerfile.trusttunnel ARG default" \
    "$(grep -E '^ARG TRUSTTUNNEL_VERSION=' "$DOCKERFILE" | head -1 | cut -d= -f2)" "$VER"
same_pin "docker-compose.yml client fallback" \
    "$(grep -oE 'TRUSTTUNNEL_CLIENT_VERSION:-[^}]+' "$ROOT/docker-compose.yml" | head -1 | cut -d- -f2-)" "$CVER"
same_pin "Dockerfile.client ARG default" \
    "$(grep -E '^ARG TRUSTTUNNEL_CLIENT_VERSION=' "$ROOT/dockerfiles/Dockerfile.client" | head -1 | cut -d= -f2)" "$CVER"

# 1.3.1 folded the wizard into the endpoint binary; chmod on the missing file broke the build.
if grep -vE '^\s*#' "$DOCKERFILE" | grep -q 'setup_wizard'; then
    bad "Dockerfile.trusttunnel still references setup_wizard (removed upstream in 1.3.1)"
else
    ok "Dockerfile.trusttunnel names no binary the release tarball lacks"
fi

# Both transports share one port number; losing either mapping drops a transport.
svc="$(awk '/^  trusttunnel:/{f=1;next} f&&/^  [a-z]/{exit} f' "$ROOT/docker-compose.yml")"
for tr in tcp udp; do
    if printf '%s\n' "$svc" | grep -qE ":4443/$tr\""; then ok "compose publishes 4443/$tr"; else bad "compose does not publish 4443/$tr"; fi
done

# A bare `tun` match hits "TRUSTTUNNEL_CLIENT" on every log line, so `moav test`
# read any early client exit (a rejected login too) as "no TUN" and passed.
tunline="$(grep 'Failed to initialize tunnel' "$ROOT/tests/client-test.sh" | grep 'grep ')"
if [ -z "$tunline" ]; then
    bad "client-test.sh no longer detects a missing TUN device"
elif printf '%s\n' "$tunline" | grep -qE 'grep -[a-z]*i|\\\|tun\\\|'; then
    bad "client-test.sh matches a bare 'tun' to detect a missing TUN device (matches every client log line)"
else
    ok "client-test.sh detects a missing TUN device by the client's actual error"
fi

# --- egress isolation: wiring + the runtime rewrite (hermetic) ---------------
# TrustTunnel's own private filter ignored EGRESS_ISOLATION and does not know
# DappNode's 172.33.0.0/16, which is public space to its is_global_ip check.
# shellcheck disable=SC2016  # literal compose text
if printf '%s\n' "$svc" | grep -qF -- '- EGRESS_ISOLATION=${EGRESS_ISOLATION:-on}'; then
    ok "compose passes EGRESS_ISOLATION (default on) to trusttunnel"
else
    bad "compose does not pass EGRESS_ISOLATION=\${EGRESS_ISOLATION:-on} to trusttunnel"
fi
for f in egress-isolation egress-trusttunnel; do
    if grep -qE "^COPY scripts/lib/$f\.sh /$f\.sh" "$DOCKERFILE"; then ok "Dockerfile.trusttunnel copies $f.sh"
    else bad "Dockerfile.trusttunnel does not copy scripts/lib/$f.sh"; fi
done
# shellcheck disable=SC1003  # a regex for the line-continuation backslash
if grep -qE '^[[:space:]]+iptables \\' "$DOCKERFILE"; then ok "Dockerfile.trusttunnel installs iptables"
else bad "Dockerfile.trusttunnel does not install iptables"; fi
ep="$ROOT/scripts/trusttunnel-entrypoint.sh"
# shellcheck disable=SC2016  # literal script text
copy="$(grep -n 'cp "$CONFIG_DIR/vpn.toml" "$RUNTIME_DIR/vpn.toml"' "$ep" | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016  # literal script text
call="$(grep -n '^if ! egress_trusttunnel "$RUNTIME_DIR/vpn.toml"' "$ep" | head -1 | cut -d: -f1)"
start="$(grep -n '^exec ' "$ep" | tail -1 | cut -d: -f1)"
if [ -n "$copy" ] && [ -n "$call" ] && [ -n "$start" ] && [ "$copy" -lt "$call" ] && [ "$call" -lt "$start" ] \
   && sed -n "$call,$((call + 3))p" "$ep" | grep -q 'exit 1'; then
    ok "entrypoint applies egress isolation to the runtime vpn.toml before start, fatal on failure"
else
    bad "entrypoint does not apply egress_trusttunnel to the runtime vpn.toml before start (fatally)"
fi

# Runs egress_trusttunnel against a recording iptables stub. Prints "RC=fail" on
# failure, the resulting allow_private_network_connections line, then the calls.
egress_run() {  # <EGRESS_ISOLATION value | -unset-> <vpn.toml> [stub-fails]
    ( d="$(mktemp -d)"
      for b in iptables ip6tables; do
          cat > "$d/$b" <<EOF
#!/bin/sh
echo "$b \$*" >> "$d/calls"
[ -z "${3:-}" ] || exit 1
case "\$1" in -C|-N) exit 1 ;; esac
exit 0
EOF
          chmod +x "$d/$b"
      done
      printf 'nameserver 127.0.0.11\n' > "$d/resolv.conf"
      cp "$2" "$d/vpn.toml"
      if [ "$1" = "-unset-" ]; then unset EGRESS_ISOLATION; else export EGRESS_ISOLATION="$1"; fi
      PATH="$d:$PATH"
      # shellcheck source=/dev/null
      . "$ROOT/scripts/lib/egress-isolation.sh"
      # shellcheck source=/dev/null
      . "$ROOT/scripts/lib/egress-trusttunnel.sh"
      egress_trusttunnel "$d/vpn.toml" "$d/resolv.conf" >/dev/null 2>&1 || echo "RC=fail"
      grep -E '^[[:space:]]*allow_private_network_connections' "$d/vpn.toml" | tr -d ' '
      if python3 -c 'import tomllib' 2>/dev/null; then
          python3 -c 'import tomllib,sys; tomllib.load(open(sys.argv[1],"rb"))' "$d/vpn.toml" 2>/dev/null \
              || echo "TOML=invalid"
      fi
      cat "$d/calls" 2>/dev/null
      rm -rf "$d" )
}
tt_tmpl="$(mktemp)"
sed 's/\${[A-Z_]*}/x/g' "$ROOT/configs/trusttunnel/vpn.toml.template" > "$tt_tmpl"
v4_all="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 127.0.0.0/8 172.33.0.0/16 10.20.0.0/24"
for v in -unset- "" on ON true 1 yes typo; do
    out="$(egress_run "$v" "$tt_tmpl")"; miss=""
    for c in $v4_all; do
        printf '%s\n' "$out" | grep -qF -- "iptables -A MOAV-EGRESS-OUT -d $c -j DROP" || miss="$miss $c"
    done
    printf '%s\n' "$out" | grep -qF -- "ip6tables -A MOAV-EGRESS-OUT -d fc00::/7 -j DROP" || miss="$miss fc00::/7"
    if printf '%s\n' "$out" | grep -qE '^RC=fail|^TOML='; then
        bad "EGRESS_ISOLATION='$v': egress_trusttunnel failed or broke vpn.toml"
    elif ! printf '%s\n' "$out" | grep -qx 'allow_private_network_connections=false'; then
        bad "EGRESS_ISOLATION='$v' should be on, but the endpoint's private filter is not forced on"
    elif [ -n "$miss" ]; then
        bad "EGRESS_ISOLATION='$v' should be on, but these ranges are not dropped:$miss"
    elif ! printf '%s\n' "$out" | grep -qF -- 'iptables -I OUTPUT 1 -j MOAV-EGRESS-OUT'; then
        bad "EGRESS_ISOLATION='$v': the filter is not hooked at the top of OUTPUT for all protocols"
    else
        ok "EGRESS_ISOLATION='$v' is on: private filter on, 172.33/16 + 10.20/24 + private ranges dropped"
    fi
done
# Replies to clients and Docker's resolver must pass before any drop.
out="$(egress_run on "$tt_tmpl")"
first_drop="$(printf '%s\n' "$out" | grep -n -- '-j DROP' | head -1 | cut -d: -f1)"
est="$(printf '%s\n' "$out" | grep -n -- '^iptables -A MOAV-EGRESS-OUT -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN' | cut -d: -f1)"
dns="$(printf '%s\n' "$out" | grep -n -- '^iptables -A MOAV-EGRESS-OUT -d 127.0.0.11 -j RETURN' | cut -d: -f1)"
if [ -n "$est" ] && [ -n "$dns" ] && [ "$est" -lt "$first_drop" ] && [ "$dns" -lt "$first_drop" ]; then
    ok "replies to clients and the container resolver are allowed ahead of the drops"
else
    bad "the egress filter does not let replies / the resolver through before dropping"
fi
for v in off OFF false 0 no disabled; do
    out="$(egress_run "$v" "$tt_tmpl")"
    if printf '%s\n' "$out" | grep -qE '^RC=fail|^TOML='; then
        bad "EGRESS_ISOLATION='$v': egress_trusttunnel failed or broke vpn.toml"
    elif ! printf '%s\n' "$out" | grep -qx 'allow_private_network_connections=true'; then
        bad "EGRESS_ISOLATION='$v' is off, but the endpoint still refuses private networks"
    elif printf '%s\n' "$out" | grep -qE -- '-j DROP|-I OUTPUT'; then
        bad "EGRESS_ISOLATION='$v' is off, but egress drop rules were installed"
    else
        ok "EGRESS_ISOLATION='$v' is off: private filter lifted, no drop rules"
    fi
done
# The toggle wins over the file, and a vpn.toml without the key gets it at top level.
sed 's/^allow_private_network_connections = false$/allow_private_network_connections = true/' "$tt_tmpl" > "$tt_tmpl.on"
grep -v '^allow_private_network_connections' "$tt_tmpl" > "$tt_tmpl.nokey"
if egress_run on "$tt_tmpl.on" | grep -qx 'allow_private_network_connections=false' \
   && [ "$(egress_run on "$tt_tmpl.nokey" | grep -c '^allow_private_network_connections=false$')" = 1 ] \
   && ! egress_run on "$tt_tmpl.nokey" | grep -q '^TOML=' \
   && [ "$(egress_run off "$tt_tmpl.nokey" | grep -c '^allow_private_network_connections=true$')" = 1 ]; then
    ok "the toggle overrides a hand-set key and fills in a missing one"
else
    bad "the toggle does not override allow_private_network_connections in every vpn.toml shape"
fi
if egress_run on "$tt_tmpl" fail | grep -q '^RC=fail'; then
    ok "isolation on + iptables unusable fails closed (the entrypoint exits)"
else
    bad "isolation on + iptables unusable still reports success (the endpoint would start unfiltered)"
fi
rm -f "$tt_tmpl" "$tt_tmpl.on" "$tt_tmpl.nokey"

# --- render the shipped templates -------------------------------------------
work="$(mktemp -d)"
TAG="moav-tt-test-$$"
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
    docker rm -f "$TAG-endpoint" "$TAG-target" >/dev/null 2>&1
    docker network rm "$TAG" "$TAG-dncore" "$TAG-dnpriv" >/dev/null 2>&1
    docker rmi -f "$TAG-endpoint" "$TAG-client" >/dev/null 2>&1
    rm -rf "$work"
}
trap cleanup EXIT

export DOMAIN="tt.moav.test"
TT_USER="e2e-user"; TT_PASS="e2e-pass-1234"
export TRUSTTUNNEL_CREDENTIALS="[[client]]
username = \"$TT_USER\"
password = \"$TT_PASS\""
render() {  # <template> <out>
    if command -v envsubst >/dev/null 2>&1; then
        envsubst < "$1" > "$2"
    else
        python3 -c 'import os,re,sys; s=open(sys.argv[1]).read(); open(sys.argv[2],"w").write(re.sub(r"\$\{([A-Z0-9_]+)\}", lambda m: os.environ.get(m.group(1),""), s))' "$1" "$2"
    fi
}
mkdir -p "$work/stock" "$work/certs/live/$DOMAIN" "$work/bundle"
for f in vpn hosts credentials; do
    render "$ROOT/configs/trusttunnel/$f.toml.template" "$work/stock/$f.toml"
done
if python3 -c 'import tomllib' 2>/dev/null; then
    for f in vpn hosts credentials; do
        if python3 -c 'import tomllib,sys; tomllib.load(open(sys.argv[1],"rb"))' "$work/stock/$f.toml" 2>/dev/null; then
            ok "$f.toml renders to valid TOML"
        else
            bad "$f.toml.template does not render to valid TOML"
        fi
    done
fi
# The entrypoint sets this key from EGRESS_ISOLATION; the template stays safe on its own.
if grep -qx 'allow_private_network_connections = false' "$work/stock/vpn.toml"; then
    ok "stock vpn.toml refuses private-network destinations"
else
    bad "vpn.toml.template no longer sets allow_private_network_connections = false"
fi
# The endpoint runs as a non-root user and reads these through a bind mount.
chmod 755 "$work" "$work/stock" "$work/certs" "$work/certs/live" "$work/certs/live/$DOMAIN"
chmod 644 "$work/stock/"*.toml

# --- live part: prerequisites -----------------------------------------------
need() {  # CI must not quietly lose this coverage.
    if [ -n "${CI:-}" ]; then bad "$1"; finish; fi
    skip "$1 (live H2/H3 checks not run)"; finish
}
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then need "docker is not available"; fi
if ! command -v openssl >/dev/null 2>&1; then need "openssl is not available"; fi

openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$DOMAIN" \
    -addext "subjectAltName=DNS:$DOMAIN" \
    -keyout "$work/certs/live/$DOMAIN/privkey.pem" \
    -out "$work/certs/live/$DOMAIN/fullchain.pem" >/dev/null 2>&1
chmod 644 "$work/certs/live/$DOMAIN/"*.pem

# --- build the endpoint image exactly as compose does -----------------------
if docker build -q -f "$DOCKERFILE" --build-arg "TRUSTTUNNEL_VERSION=$VER" \
        -t "$TAG-endpoint" "$ROOT" >"$work/build.log" 2>&1; then
    ok "Dockerfile.trusttunnel builds with TrustTunnel $VER"
else
    bad "Dockerfile.trusttunnel does not build with TrustTunnel $VER:"
    tail -15 "$work/build.log" | sed 's/^/        /'
    finish
fi
# The binary carries file capabilities, so exec needs them in the bounding set.
BIN=(--entrypoint /opt/trusttunnel/trusttunnel_endpoint --cap-add NET_ADMIN --cap-add NET_BIND_SERVICE)
got="$(docker run --rm "${BIN[@]}" "$TAG-endpoint" --version 2>/dev/null | tr -d '\r')"
if [ "$got" = "$VER" ]; then ok "image runs trusttunnel_endpoint $VER"; else bad "image reports version '${got}', expected $VER"; fi

# Exporting a client config makes the endpoint parse all three files, then exit.
if docker run --rm "${BIN[@]}" \
        -v "$work/stock:/etc/trusttunnel:ro" -v "$work/certs:/certs:ro" "$TAG-endpoint" \
        /etc/trusttunnel/vpn.toml /etc/trusttunnel/hosts.toml \
        -c "$TT_USER" -a "203.0.113.10:4443" -f toml >"$work/export.toml" 2>"$work/export.err" \
   && grep -q "$TT_USER" "$work/export.toml"; then
    ok "endpoint $VER parses the rendered config (client export works)"
else
    bad "endpoint $VER rejects the rendered config:"
    tail -10 "$work/export.err" | sed 's/^/        /'
fi

# --- helper image: official client + a target that reports who called it ----
if docker build -q -t "$TAG-client" --build-arg "CVER=$CVER" - >"$work/build-client.log" 2>&1 <<'EOF'
FROM debian:bookworm-slim
ARG CVER
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl iproute2 iptables socat && rm -rf /var/lib/apt/lists/*
RUN case "$(dpkg --print-architecture)" in arm64) A=aarch64 ;; *) A=x86_64 ;; esac && \
    curl -fsSL --retry 3 "https://github.com/TrustTunnel/TrustTunnelClient/releases/download/v${CVER}/trusttunnel_client-v${CVER}-linux-${A}.tar.gz" \
        | tar -xz --strip-components=1 -C /usr/local/bin && \
    chmod +x /usr/local/bin/trusttunnel_client
EOF
then
    ok "trusttunnel_client $CVER helper image builds"
else
    bad "could not build the trusttunnel_client $CVER helper image:"
    tail -15 "$work/build-client.log" | sed 's/^/        /'
    finish
fi

docker network create "$TAG" >/dev/null 2>&1 || { bad "could not create a docker network"; finish; }
# DappNode's dncore and dnprivate ranges: the endpoint and the target sit on both.
DN_CORE=172.33.0.10; DN_PRIV=10.20.0.10
if ! docker network create --subnet 172.33.0.0/16 "$TAG-dncore" >/dev/null 2>&1 \
   || ! docker network create --subnet 10.20.0.0/24 "$TAG-dnpriv" >/dev/null 2>&1; then
    bad "could not create docker networks on 172.33.0.0/16 and 10.20.0.0/24 (in use here?)"; finish
fi
ip_of() { docker inspect -f "{{(index .NetworkSettings.Networks \"$TAG\").IPAddress}}" "$1" 2>/dev/null; }

# Replies with the caller's address: an endpoint IP if tunneled, the client's if direct.
docker run -d --name "$TAG-target" --network "$TAG" "$TAG-client" \
    socat TCP-LISTEN:8080,fork,reuseaddr \
        SYSTEM:'echo HTTP/1.0 200 OK; echo; echo $SOCAT_PEERADDR' >/dev/null
if ! docker network connect --ip "$DN_CORE" "$TAG-dncore" "$TAG-target" \
   || ! docker network connect --ip "$DN_PRIV" "$TAG-dnpriv" "$TAG-target"; then
    bad "could not attach the target to the DappNode-range networks"; finish
fi
TIP="$(ip_of "$TAG-target")"

# Same hardening as the `trusttunnel` service in docker-compose.yml.
start_endpoint() {  # <config dir> <EGRESS_ISOLATION value>
    docker rm -f "$TAG-endpoint" >/dev/null 2>&1
    docker create --name "$TAG-endpoint" --network "$TAG" \
        --read-only --tmpfs /tmp:rw,size=50m --memory 256m \
        --cap-drop ALL --cap-add NET_ADMIN --cap-add NET_BIND_SERVICE --cap-add SETUID \
        --cap-add SETGID --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
        -e "DOMAIN=$DOMAIN" -e LOG_LEVEL=info -e "EGRESS_ISOLATION=$2" \
        -v "$1:/etc/trusttunnel:ro" -v "$work/certs:/certs:ro" \
        "$TAG-endpoint" >/dev/null 2>&1 || return 1
    docker network connect "$TAG-dncore" "$TAG-endpoint" >/dev/null 2>&1 || return 1
    docker network connect "$TAG-dnpriv" "$TAG-endpoint" >/dev/null 2>&1 || return 1
    docker start "$TAG-endpoint" >/dev/null 2>&1 || return 1
    EIP="$(ip_of "$TAG-endpoint")"
    local i=0 out=""
    while [ $i -lt 20 ]; do
        out="$(docker run --rm --network "$TAG" "$TAG-client" curl -sk -m 3 -o /dev/null \
            -w '%{http_version} %{http_code}' --http2 --resolve "$DOMAIN:4443:$EIP" "https://$DOMAIN:4443/" 2>/dev/null)"
        [ -n "$out" ] && [ "$out" != "0 000" ] && break
        [ "$(docker inspect -f '{{.State.Running}}' "$TAG-endpoint" 2>/dev/null)" = "true" ] || break
        sleep 1; i=$((i+1))
    done
    UNAUTH="$out"
    [ "$(docker inspect -f '{{.State.Running}}' "$TAG-endpoint" 2>/dev/null)" = "true" ]
}

# The client config MoaV ships (scripts/lib/trusttunnel.sh); only test plumbing is rewritten.
client_config() {  # <proto> <password> <destination ip>
    ( # shellcheck source=/dev/null
      . "$ROOT/scripts/lib/trusttunnel.sh"
      SERVER_IP="$EIP" SERVER_IPV6="" trusttunnel_write_client_bundle "$work/bundle" "$TT_USER" "$2" )
    sed -e "s|^upstream_protocol = .*|upstream_protocol = \"$1\"|" \
        -e 's|^upstream_fallback_protocol = .*|upstream_fallback_protocol = ""|' \
        -e 's|^skip_verification = .*|skip_verification = true|' \
        -e "s|^included_routes = .*|included_routes = [\"$3/32\"]|" \
        -e 's|^excluded_routes = .*|excluded_routes = []|' \
        "$work/bundle/trusttunnel.toml"
}

# Prints "tunneled", "direct", or "none" for one client run. The client sits on
# the test network only, so the DappNode-range addresses answer only via the tunnel.
run_client() {  # <proto> <password> <wait seconds> [destination ip, default the target's]
    local dest="${4:-$TIP}"
    client_config "$1" "$2" "$dest" > "$work/client.toml"
    chmod 644 "$work/client.toml"
    docker run --rm -i --network "$TAG" --cap-add NET_ADMIN --device /dev/net/tun \
        -v "$work/client.toml:/client.toml:ro" "$TAG-client" \
        bash -s -- "$1" "$EIP" "$TIP" "$3" "$dest" 2>"$work/client.err" <<'EOF'
proto=$1; eip=$2; tip=$3; wait=$4; dest=$5
# Take the other transport away so a pass can only mean this one worked.
case "$proto" in
    http2) iptables -A OUTPUT -d "$eip" -p udp --dport 4443 -j DROP   || { echo "nofirewall"; exit 0; } ;;
    http3) iptables -A OUTPUT -d "$eip" -p tcp --dport 4443 -j REJECT || { echo "nofirewall"; exit 0; } ;;
esac
me="$(curl -s -m 5 "http://$tip:8080/" | tr -d '\r\n')"
[ -n "$me" ] || { echo "notarget"; exit 0; }
trusttunnel_client --config /client.toml >/tmp/client.log 2>&1 &
seen=""; i=0
while [ "$i" -lt "$wait" ]; do
    seen="$(curl -s -m 3 "http://$dest:8080/" | tr -d '\r\n')"
    # Any answer that is not our own address came back through the endpoint.
    [ -n "$seen" ] && [ "$seen" != "$me" ] && { echo "tunneled"; exit 0; }
    sleep 1; i=$((i+1))
done
tail -25 /tmp/client.log >&2
if [ -n "$seen" ]; then echo "direct"; else echo "none"; fi
EOF
}
probe_failed() {  # <label> <result>
    case "$2" in
        nofirewall) need "iptables is unusable in containers here" ;;
        notarget)   bad "$1: the test target is unreachable (harness problem)" ;;
        "")         if grep -qiE 'tun|device' "$work/client.err" 2>/dev/null; then need "/dev/net/tun is not available to containers"; fi
                    bad "$1: client container did not run"; sed 's/^/        /' "$work/client.err" | tail -8 ;;
        *)          return 1 ;;
    esac
}

# Destinations, each paired with how it is checked. Over the tunnel the endpoint
# dials the address itself, so the transport only matters for the target probe.
DESTS="target:$TIP:http2,http3 dncore:$DN_CORE:http2,http3 dnprivate:$DN_PRIV:http2"
dest_label() { case "$1" in target) echo "a private Docker address" ;; dncore) echo "DappNode dncore 172.33.0.0/16" ;; *) echo "DappNode dnprivate 10.20.0.0/24" ;; esac; }

# --- phase A: stock config, EGRESS_ISOLATION=on -------------------------------
if start_endpoint "$work/stock" on; then
    ok "endpoint $VER stays up on the stock config in the hardened container (isolation on)"
else
    bad "endpoint $VER did not stay up on the stock config with EGRESS_ISOLATION=on:"
    docker logs "$TAG-endpoint" 2>&1 | tail -15 | sed 's/^/        /'
    finish
fi
if [ "$UNAUTH" = "2 407" ]; then
    ok "HTTP/2 negotiated; unauthenticated request refused with 407"
else
    bad "unauthenticated HTTP/2 probe returned '${UNAUTH}', expected '2 407'"
fi
rules="$(docker exec "$TAG-endpoint" iptables -S MOAV-EGRESS-OUT 2>&1)"
if printf '%s\n' "$rules" | grep -qF -- '-d 172.33.0.0/16 -j DROP' \
   && printf '%s\n' "$rules" | grep -qF -- '-d 10.20.0.0/24 -j DROP' \
   && docker exec "$TAG-endpoint" iptables -S OUTPUT 2>/dev/null | grep -qF -- '-A OUTPUT -j MOAV-EGRESS-OUT' \
   && docker exec "$TAG-endpoint" grep -qx 'allow_private_network_connections = false' /tmp/trusttunnel/vpn.toml; then
    ok "isolation on: the real container installs the egress filter and keeps the endpoint's private filter on"
else
    bad "isolation on: egress filter / private filter not in place in the real container:"
    printf '%s\n' "$rules" | tail -6 | sed 's/^/        /'
fi
for d in $DESTS; do
    name="${d%%:*}"; rest="${d#*:}"; ip="${rest%%:*}"; protos="${rest#*:}"
    for proto in ${protos//,/ }; do
        r="$(run_client "$proto" "$TT_PASS" 10 "$ip")"
        probe_failed "on/$name/$proto" "$r" && continue
        if [ "$r" = "tunneled" ]; then
            bad "isolation on: tunneled to $(dest_label "$name") ($ip) over $proto"
        else
            ok "isolation on: $(dest_label "$name") ($ip) is refused over $proto"
        fi
    done
done

# --- phase B: same config, EGRESS_ISOLATION=off -> real data path ------------
if start_endpoint "$work/stock" off; then
    if docker exec "$TAG-endpoint" grep -qx 'allow_private_network_connections = true' /tmp/trusttunnel/vpn.toml \
       && ! docker exec "$TAG-endpoint" iptables -S OUTPUT 2>/dev/null | grep -q 'MOAV-EGRESS-OUT'; then
        ok "isolation off: the real container lifts the private filter and installs no egress filter"
    else
        bad "isolation off: the real container still filters private destinations"
    fi
    for d in $DESTS; do
        name="${d%%:*}"; rest="${d#*:}"; ip="${rest%%:*}"; protos="${rest#*:}"
        for proto in ${protos//,/ }; do
            r="$(run_client "$proto" "$TT_PASS" 25 "$ip")"
            probe_failed "off/$name/$proto" "$r" && continue
            if [ "$r" = "tunneled" ]; then
                ok "isolation off: client $CVER -> endpoint $VER reaches $(dest_label "$name") ($ip) over $proto"
            else
                bad "isolation off: client $CVER -> endpoint $VER did not reach $(dest_label "$name") ($ip) over $proto (result: $r)"
                tail -12 "$work/client.err" | sed 's/^/        /'
                docker logs "$TAG-endpoint" 2>&1 | tail -8 | sed 's/^/        /'
            fi
        done
    done
    for proto in http2 http3; do
        r="$(run_client "$proto" "wrong-password" 10)"
        probe_failed "auth/$proto" "$r" && continue
        if [ "$r" = "tunneled" ]; then
            bad "a wrong password was accepted over $proto"
        else
            ok "a wrong password is refused over $proto"
        fi
    done
else
    bad "endpoint $VER did not stay up with EGRESS_ISOLATION=off:"
    docker logs "$TAG-endpoint" 2>&1 | tail -15 | sed 's/^/        /'
fi

finish
