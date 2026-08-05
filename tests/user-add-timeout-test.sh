#!/bin/bash
# Regression test for #220 (user add freezes on "Adding to AmneziaWG") and the
# wg-user-add dedup.
#
# The freeze class: a `docker compose exec` against a wedged container blocks
# forever, and `moav user add` hangs with it. The fix routes every container
# call in the provisioning scripts through compose_timeout (SIGTERM at the
# deadline, SIGKILL 5s later). A single bare call reintroduces the hang.
#
# The dedup: scripts/wg-user-add.sh re-implemented wireguard_add_peer and had
# drifted (fresh keys on every run, no third-state guard, hard-exit on an
# existing peer). It must stay routed through the shared lib.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "user-add timeout + wg dedup tests"

# --- compose_timeout: exists, shared, and actually enforces a deadline ----
if grep -qE 'timeout -k 5 .*docker compose' "$ROOT/scripts/lib/common.sh"; then
    ok "compose_timeout lives in the shared lib with a hard deadline"
else
    bad "compose_timeout missing from scripts/lib/common.sh (or lost its timeout -k)"
fi

# Functional: the deadline must actually fire. Stub `docker` with a hang.
_tmp=$(mktemp -d); trap 'rm -rf "$_tmp"' EXIT
cat > "$_tmp/docker" <<'EOF'
#!/bin/sh
sleep 300
EOF
chmod +x "$_tmp/docker"
log_info() { :; }; log_warn() { :; }; log_error() { :; }
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/common.sh"
start=$(date +%s)
( PATH="$_tmp:$PATH" COMPOSE_TIMEOUT=2 compose_timeout exec -T amneziawg awg show ) >/dev/null 2>&1
elapsed=$(( $(date +%s) - start ))
if [[ $elapsed -le 10 ]]; then
    ok "compose_timeout kills a wedged docker call (${elapsed}s, deadline 2s)"
else
    bad "compose_timeout did not enforce its deadline (took ${elapsed}s)"
fi

# --- no bare docker compose calls in the provisioning scripts -------------
for f in user-add.sh wg-user-add.sh singbox-user-add.sh; do
    bare=$(grep -nE '^[^#]*docker compose' "$ROOT/scripts/$f" | grep -v 'compose_timeout' || true)
    [[ -z "$bare" ]] && ok "$f: every docker compose call has a deadline" \
                     || bad "$f: bare docker compose call can hang user add (#220): $bare"
done

# --- wg-user-add must stay routed through the shared lib ------------------
grep -q 'wireguard_add_peer' "$ROOT/scripts/wg-user-add.sh" \
    && ok "wg-user-add.sh routes through wireguard_add_peer" \
    || bad "wg-user-add.sh no longer calls wireguard_add_peer — the inline copy is back"
if grep -qE 'cat >> "\$WG_CONFIG_DIR/wg0.conf"' "$ROOT/scripts/wg-user-add.sh"; then
    bad "wg-user-add.sh appends its own [Peer] block — duplicate of the lib mutation"
else
    ok "wg-user-add.sh does not duplicate the wg0.conf peer append"
fi
if grep -qE '^[^#]*wg_keypair' "$ROOT/scripts/wg-user-add.sh"; then
    bad "wg-user-add.sh mints its own keypair — the lib reuses stored keys; this re-breaks idempotent re-issue"
else
    ok "wg-user-add.sh does not mint its own keypair"
fi

echo ""
echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]
