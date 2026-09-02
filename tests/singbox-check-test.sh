#!/bin/bash
# Extended gate: validate the rendered sing-box config with the REAL sing-box
# binary (the exact version pinned in .env.example) via `sing-box check` +
# `sing-box format`.
#
# This complements the static tests/singbox-config-valid-test.sh: the static one
# is a fast grep/JSON gate that runs everywhere; THIS one downloads sing-box and
# runs its own parser — the same check the entrypoint runs at container start,
# but pre-merge, so a schema-incompatible edit (e.g. a bad 1.14 field) fails CI
# instead of taking the proxy down in production.
#
# Downloads the binary once (cached). In CI a download failure is fatal; run
# locally without network it SKIPs (the static test still covers you).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$ROOT/configs/sing-box/config.json.template"
pass=0; fail=0
ok()   { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
skip() { printf '  SKIP  %s\n' "$1"; }

echo "sing-box config: real-binary check + format"

# Pin to whatever .env.example declares, so this test tracks the bump.
VER="$(grep -E '^SINGBOX_VERSION=' "$ROOT/.env.example" | head -1 | cut -d= -f2 | tr -d ' ')"
[ -n "$VER" ] || { echo "cannot read SINGBOX_VERSION from .env.example"; exit 1; }
echo "  pinned sing-box: $VER"

os="$(uname -s | tr '[:upper:]' '[:lower:]')"; arch="$(uname -m)"
case "$arch" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) skip "unsupported arch $arch"; echo "PASSED (skipped)"; exit 0 ;; esac
case "$os" in linux|darwin) : ;; *) skip "unsupported os $os"; echo "PASSED (skipped)"; exit 0 ;; esac
asset="sing-box-${VER}-${os}-${arch}.tar.gz"
url="https://github.com/SagerNet/sing-box/releases/download/v${VER}/${asset}"

cache="${SINGBOX_BIN_CACHE:-/tmp/singbox-bin-cache}"; mkdir -p "$cache"
bin="$cache/sing-box-${VER}-${os}-${arch}"
if [ ! -x "$bin" ]; then
    tmp="$(mktemp -d)"; got=""
    for _ in 1 2 3; do
        if curl -fsSL --retry 2 -o "$tmp/sb.tar.gz" "$url"; then got=1; break; fi
        sleep 2
    done
    if [ -z "$got" ]; then
        rm -rf "$tmp"
        if [ -n "${CI:-}" ]; then bad "could not download $url"; echo "FAILED (1 failed, $pass passed)"; exit 1; fi
        skip "no network to fetch sing-box (static test still covers you)"; echo "PASSED (skipped)"; exit 0
    fi
    tar -xzf "$tmp/sb.tar.gz" -C "$tmp"
    found="$(find "$tmp" -type f -name sing-box | head -1)"
    [ -n "$found" ] || { rm -rf "$tmp"; bad "sing-box binary not found in tarball"; echo "FAILED"; exit 1; }
    cp "$found" "$bin"; chmod +x "$bin"; rm -rf "$tmp"
fi
"$bin" version >/dev/null 2>&1 && ok "sing-box $VER binary runs" || { bad "sing-box binary won't run"; echo "FAILED"; exit 1; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# Fields with a validated format need real-shaped fixtures, or `check` rejects
# them: reality wants an x25519 key (generate one with the binary itself so it's
# always version-correct), and 2022-blake3-aes-128-gcm wants a 16-byte base64 PSK.
rkey="$("$bin" generate reality-keypair 2>/dev/null | awk '/PrivateKey/{print $2}')"
[ -n "$rkey" ] || rkey="wJ7dEpZ6gTfQ0nQb3l2xk9m8yq1sVd4uHc5rNpA6oXk"  # fallback x25519
ss_psk="$(printf '1234567890123456' | base64)"  # 16 bytes for aes-128

# Representative render values (kept in sync with singbox-config-valid-test.sh).
export ANYTLS_USERS_JSON='[]' REALITY_USERS_JSON='[]' SHADOWSOCKS_USERS_JSON='[]' \
       TROJAN_USERS_JSON='[]' VLESS_WS_USERS_JSON='[]' HYSTERIA2_USERS_JSON='[]' \
       HYSTERIA2_OBFS_PASSWORD='obfspw' CDN_TRANSPORT='ws' CDN_WS_PATH='/ws' \
       CLASH_API_SECRET='testsecret' DOMAIN='example.com' LOG_LEVEL='info' \
       PORT_ANYTLS='8445' PORT_SS='8388' REALITY_PRIVATE_KEY="$rkey" \
       REALITY_SERVER_NAME='www.microsoft.com' REALITY_SHORT_ID='0123abcd' \
       REALITY_TARGET_HOST='www.microsoft.com' REALITY_TARGET_PORT='443' \
       SS_METHOD='2022-blake3-aes-128-gcm' SS_SERVER_PSK="$ss_psk"

rendered="$work/config.json"
if command -v envsubst >/dev/null 2>&1; then
    envsubst < "$TEMPLATE" > "$rendered"
else
    python3 -c 'import os,re,sys; s=open(sys.argv[1]).read(); open(sys.argv[2],"w").write(re.sub(r"\$\{([A-Z0-9_]+)\}", lambda m: os.environ.get(m.group(1),""), s))' "$TEMPLATE" "$rendered"
fi

# Point cert_path inbounds at throwaway self-signed certs so `check` can load
# them (the real entrypoint rewrites /certs -> /tmp/certs and copies real certs).
sed -i.bak "s#/certs/#$work/certs/#g" "$rendered" && rm -f "$rendered.bak"
mkdir -p "$work/certs/live/$DOMAIN"
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$work/certs/live/$DOMAIN/privkey.pem" \
    -out "$work/certs/live/$DOMAIN/fullchain.pem" \
    -days 1 -subj "/CN=$DOMAIN" >/dev/null 2>&1

if "$bin" check -c "$rendered" 2>"$work/check.err"; then
    ok "sing-box $VER check passes on the rendered config"
else
    bad "sing-box check failed:"; sed 's/^/        /' "$work/check.err"
fi

# format also surfaces deprecation warnings; treat them as failures so we catch
# a field scheduled for removal before it actually breaks.
"$bin" format -c "$rendered" >/dev/null 2>"$work/fmt.err" || true
if grep -qiE "deprecat|will be removed" "$work/fmt.err"; then
    bad "deprecation warnings from format:"; sed 's/^/        /' "$work/fmt.err"
else
    ok "no deprecation warnings"
fi

echo ""
if [ $fail -eq 0 ]; then echo "PASSED ($pass checks)"; else echo "FAILED ($fail failed, $pass passed)"; exit 1; fi
