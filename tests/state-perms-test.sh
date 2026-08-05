#!/bin/bash
# Regression test for secure_state_keys (scripts/lib/common.sh).
#
# Secrets under state/keys were written via `cat > … <<EOF` / `echo … >`, which
# inherit umask 022 and land 0644 -- world-readable. Verified on a live server:
# reality.env (REALITY_PRIVATE_KEY), clash-api.env (Clash secret + Hy2 obfs
# password), shadowsocks-server.psk, masterdns-encrypt.key, gooserelay-tunnel.key
# and wstunnel-path.secret were all 0644, while the *.key files written under
# `umask 077` beside them were correctly 0600.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

echo "state key permission tests"

STATE_DIR=$(mktemp -d); export STATE_DIR
trap 'rm -rf "$STATE_DIR"' EXIT
mkdir -p "$STATE_DIR/keys"
log_info() { :; }   # stub before sourcing

# shellcheck disable=SC1091
source "$ROOT/scripts/lib/common.sh" 2>/dev/null || { echo "cannot source common.sh"; exit 1; }

# Secrets, deliberately created loose (0644) the way the heredoc writers do.
for f in reality.env clash-api.env cdn.env amneziawg.env shadowsocks-server.psk \
         wstunnel-path.secret masterdns-encrypt.key gooserelay-tunnel.key slipstream-key.pem; do
    echo "SECRET=x" > "$STATE_DIR/keys/$f"; chmod 644 "$STATE_DIR/keys/$f"
done
# Public counterparts must stay readable -- other parties consume them.
for f in wg-server.pub awg-server.pub dnstt-server.pub.hex slipstream-cert.pem; do
    echo "public" > "$STATE_DIR/keys/$f"; chmod 644 "$STATE_DIR/keys/$f"
done
# Already-correct file: must be left alone, and must not be counted as "fixed".
echo k > "$STATE_DIR/keys/wg-server.key"; chmod 600 "$STATE_DIR/keys/wg-server.key"

secure_state_keys "$STATE_DIR/keys" >/dev/null 2>&1

for f in reality.env cdn.env amneziawg.env shadowsocks-server.psk \
         wstunnel-path.secret masterdns-encrypt.key gooserelay-tunnel.key slipstream-key.pem; do
    m=$(mode "$STATE_DIR/keys/$f")
    [[ "$m" == "600" ]] && ok "secret $f -> 0600" || bad "secret $f is $m (expected 600)"
done

# clash-api.env is a deliberate exception: admin/main.py reads it and the admin
# container runs as a NON-root user (uid 100), so 0600 crash-loops it with
# PermissionError. Tightening this one regressed a live e2e -- assert it stays
# readable so the exception cannot be "helpfully" removed later.
# REPAIR case: an earlier build of secure_state_keys already tightened this file,
# and the state volume survives upgrades -- so the exemption must actively restore
# readability, not merely skip. A skip-only version passed the test above while
# leaving already-damaged installs permanently crash-looping.
chmod 600 "$STATE_DIR/keys/clash-api.env"
secure_state_keys "$STATE_DIR/keys" >/dev/null 2>&1
m=$(mode "$STATE_DIR/keys/clash-api.env")
[[ "$m" == "644" ]] && ok "clash-api.env already at 0600 is REPAIRED back to readable" \
                    || bad "clash-api.env stayed $m — an install damaged by the earlier bug stays broken"

m=$(mode "$STATE_DIR/keys/clash-api.env")
[[ "$m" == "644" ]] && ok "clash-api.env left readable for the non-root admin ($m)" \
                    || bad "clash-api.env is $m — the admin container cannot read it and will crash-loop"

for f in wg-server.pub awg-server.pub dnstt-server.pub.hex slipstream-cert.pem; do
    m=$(mode "$STATE_DIR/keys/$f")
    [[ "$m" == "644" ]] && ok "public $f left readable ($m)" || bad "public $f became $m — consumers need read"
done

m=$(mode "$STATE_DIR/keys/wg-server.key")
[[ "$m" == "600" ]] && ok "already-0600 key untouched" || bad "wg-server.key became $m"

# Idempotent: a second pass must change nothing and still exit 0.
secure_state_keys "$STATE_DIR/keys" >/dev/null 2>&1
rc=$?
[[ $rc -eq 0 ]] && ok "second pass is idempotent (exit 0)" || bad "second pass exited $rc"

# Missing directory must be a no-op, not an error (bootstrap calls it early).
secure_state_keys "$STATE_DIR/nope" >/dev/null 2>&1
[[ $? -eq 0 ]] && ok "missing keys dir is a clean no-op" || bad "missing dir returned non-zero"

# Bootstrap must actually call it, or none of the above matters in production.
if grep -q 'secure_state_keys' "$ROOT/scripts/bootstrap.sh"; then
    ok "bootstrap.sh calls secure_state_keys"
else
    bad "bootstrap.sh never calls secure_state_keys — secrets stay 0644 in practice"
fi

# --- .env is created 0600 -------------------------------------------------------
# .env holds ADMIN_PASSWORD, REALITY_PRIVATE_KEY, CLASH_API_SECRET and the
# Hysteria2 obfs password. Both creation sites `chmod 600 .env || true`; the
# `|| true` means a silent regression (e.g. chmod removed) would go unnoticed.
# Assert the chmod is present at both sites rather than the runtime mode, since
# these run before any .env exists.
env_chmod_sites=0
for f in lib/bootstrap.sh moav.sh; do
    if grep -qE 'chmod 600 \.env' "$ROOT/$f"; then
        env_chmod_sites=$((env_chmod_sites + 1))
    else
        bad "$f creates .env but does not chmod 600 it"
    fi
done
[[ "$env_chmod_sites" -eq 2 ]] && ok ".env is chmod 600 at both creation sites (bootstrap + moav.sh)"

# And functionally: chmod 600 on a freshly-created file yields 0600.
tmp_env="$STATE_DIR/env-probe"
printf 'ADMIN_PASSWORD=x\n' > "$tmp_env"; chmod 600 "$tmp_env"
m=$(mode "$tmp_env")
[[ "$m" == "600" ]] && ok ".env probe: chmod 600 produces 0600" || bad ".env probe is $m, not 600"

echo
echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]
