#!/bin/bash
# TrustTunnel: pinned endpoint <-> pinned official client over HTTP/2 AND HTTP/3.
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

# --- render the shipped templates -------------------------------------------
work="$(mktemp -d)"
TAG="moav-tt-test-$$"
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
    docker rm -f "$TAG-endpoint" "$TAG-target" >/dev/null 2>&1
    docker network rm "$TAG" >/dev/null 2>&1
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
mkdir -p "$work/stock" "$work/private" "$work/certs/live/$DOMAIN" "$work/bundle"
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
# One key differs: the tunnel target is on a Docker bridge, which stock refuses to reach.
cp "$work/stock/"*.toml "$work/private/"
sed -i.bak 's/^allow_private_network_connections = false$/allow_private_network_connections = true/' "$work/private/vpn.toml"
rm -f "$work/private/vpn.toml.bak"
if cmp -s "$work/stock/vpn.toml" "$work/private/vpn.toml"; then
    bad "vpn.toml.template no longer sets allow_private_network_connections = false"
else
    ok "stock vpn.toml refuses private-network destinations"
fi
# The endpoint runs as a non-root user and reads these through a bind mount.
chmod 755 "$work" "$work/stock" "$work/private" "$work/certs" "$work/certs/live" "$work/certs/live/$DOMAIN"
chmod 644 "$work/stock/"*.toml "$work/private/"*.toml

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
ip_of() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1" 2>/dev/null; }

# Replies with the caller's address: the endpoint's IP if tunneled, the client's if direct.
docker run -d --name "$TAG-target" --network "$TAG" "$TAG-client" \
    socat TCP-LISTEN:8080,fork,reuseaddr \
        SYSTEM:'echo HTTP/1.0 200 OK; echo; echo $SOCAT_PEERADDR' >/dev/null
TIP="$(ip_of "$TAG-target")"

# Same hardening as the `trusttunnel` service in docker-compose.yml.
start_endpoint() {  # <config dir>
    docker rm -f "$TAG-endpoint" >/dev/null 2>&1
    docker run -d --name "$TAG-endpoint" --network "$TAG" \
        --read-only --tmpfs /tmp:rw,size=50m --memory 256m \
        --cap-drop ALL --cap-add NET_ADMIN --cap-add NET_BIND_SERVICE --cap-add SETUID \
        --cap-add SETGID --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
        -e "DOMAIN=$DOMAIN" -e LOG_LEVEL=info \
        -v "$1:/etc/trusttunnel:ro" -v "$work/certs:/certs:ro" \
        "$TAG-endpoint" >/dev/null 2>&1 || return 1
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
client_config() {  # <proto> <password>
    ( # shellcheck source=/dev/null
      . "$ROOT/scripts/lib/trusttunnel.sh"
      SERVER_IP="$EIP" SERVER_IPV6="" trusttunnel_write_client_bundle "$work/bundle" "$TT_USER" "$2" )
    sed -e "s|^upstream_protocol = .*|upstream_protocol = \"$1\"|" \
        -e 's|^upstream_fallback_protocol = .*|upstream_fallback_protocol = ""|' \
        -e 's|^skip_verification = .*|skip_verification = true|' \
        -e "s|^included_routes = .*|included_routes = [\"$TIP/32\"]|" \
        -e 's|^excluded_routes = .*|excluded_routes = []|' \
        "$work/bundle/trusttunnel.toml"
}

# Prints "tunneled", "direct", or "none" for one client run.
run_client() {  # <proto> <password> <wait seconds>
    client_config "$1" "$2" > "$work/client.toml"
    chmod 644 "$work/client.toml"
    docker run --rm -i --network "$TAG" --cap-add NET_ADMIN --device /dev/net/tun \
        -v "$work/client.toml:/client.toml:ro" "$TAG-client" \
        bash -s -- "$1" "$EIP" "$TIP" "$3" 2>"$work/client.err" <<'EOF'
proto=$1; eip=$2; tip=$3; wait=$4
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
    seen="$(curl -s -m 3 "http://$tip:8080/" | tr -d '\r\n')"
    [ "$seen" = "$eip" ] && { echo "tunneled"; exit 0; }
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

# --- phase A: the stock config, unmodified -----------------------------------
if start_endpoint "$work/stock"; then
    ok "endpoint $VER stays up on the stock config in the hardened container"
else
    bad "endpoint $VER did not stay up on the stock config:"
    docker logs "$TAG-endpoint" 2>&1 | tail -15 | sed 's/^/        /'
    finish
fi
if [ "$UNAUTH" = "2 407" ]; then
    ok "HTTP/2 negotiated; unauthenticated request refused with 407"
else
    bad "unauthenticated HTTP/2 probe returned '${UNAUTH}', expected '2 407'"
fi
for proto in http2 http3; do
    r="$(run_client "$proto" "$TT_PASS" 10)"
    probe_failed "stock/$proto" "$r" && continue
    if [ "$r" = "tunneled" ]; then
        bad "stock config tunneled to a private address over $proto (allow_private_network_connections = false is not enforced)"
    else
        ok "stock config refuses a private destination over $proto"
    fi
done

# --- phase B: same config, private targets allowed -> real data path --------
if start_endpoint "$work/private"; then
    for proto in http2 http3; do
        r="$(run_client "$proto" "$TT_PASS" 25)"
        probe_failed "tunnel/$proto" "$r" && continue
        if [ "$r" = "tunneled" ]; then
            ok "client $CVER -> endpoint $VER carries traffic over $proto"
        else
            bad "client $CVER -> endpoint $VER carried no traffic over $proto (result: $r)"
            tail -12 "$work/client.err" | sed 's/^/        /'
            docker logs "$TAG-endpoint" 2>&1 | tail -8 | sed 's/^/        /'
        fi
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
    bad "endpoint $VER did not stay up with private destinations allowed:"
    docker logs "$TAG-endpoint" 2>&1 | tail -15 | sed 's/^/        /'
fi

finish
