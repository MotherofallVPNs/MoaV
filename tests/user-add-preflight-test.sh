#!/bin/bash
# Regression test: `moav user add` checks its config writes up front.
#
# A non-root operator outside the admin group (gid 2000) got through the
# sing-box step and then died on "configs/trusttunnel/credentials.toml:
# Permission denied", leaving a half-added user and no hint how to fix it.
# user-add.sh now runs _preflight_config_writes before provisioning anything;
# this runs the real function on files the caller cannot write.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "user add: config write preflight"

if [[ "$(id -u)" -eq 0 ]]; then
    echo "SKIPPED (root can write any file; run as a normal user)"; exit 0
fi

T=$(mktemp -d); trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
fn=$(sed -n '/^_preflight_config_writes() {/,/^}/p' "$ROOT/scripts/user-add.sh")
[[ -n "$fn" ]] || { bad "_preflight_config_writes not found in scripts/user-add.sh"; echo "FAILED"; exit 1; }

# run <admin-gid> [VAR=value ...]: rc and log of the real function in $T.
run() {
    local gid="$1"; shift
    ( cd "$T" || exit 99
      log_error() { echo "ERR $*"; }
      eval "$fn"
      export ADMIN_GID="$gid"
      for kv in "$@"; do export "${kv?}"; done
      _preflight_config_writes ) > "$T/out" 2>&1
    echo $?
}

mkdir -p "$T"/configs/{sing-box,xray,wireguard,amneziawg,trusttunnel,telemt} "$T/state/users"
for f in sing-box/config.json xray/config.json wireguard/wg0.conf amneziawg/awg0.conf \
         trusttunnel/credentials.toml telemt/config.toml; do
    echo x > "$T/configs/$f"
done
NOT_MINE=4242   # a gid this account is not in
while [[ " $(id -G) " == *" $NOT_MINE "* ]]; do NOT_MINE=$((NOT_MINE+1)); done

[[ $(run "$NOT_MINE") -eq 0 && ! -s "$T/out" ]] \
    && ok "all writable: passes silently" || bad "all writable: rc/out unexpected: $(cat "$T/out")"

# What the operator hit: credentials.toml root:2000 0664, caller not in 2000.
chmod 444 "$T/configs/trusttunnel/credentials.toml"
rc=$(run "$NOT_MINE")
[[ "$rc" -ne 0 ]] && ok "unwritable credentials.toml: fails before provisioning" \
    || bad "unwritable credentials.toml: preflight passed"
grep -q 'configs/trusttunnel/credentials.toml' "$T/out" \
    && ok "names the file it cannot write" || bad "file not named: $(cat "$T/out")"
grep -q "usermod -aG" "$T/out" && grep -q "group $NOT_MINE" "$T/out" \
    && ok "outside the admin group: says how to join it" || bad "no group hint: $(cat "$T/out")"
grep -q 'No user was added' "$T/out" \
    && ok "says nothing was changed" || bad "does not say nothing was added"

[[ $(run "$NOT_MINE" ENABLE_TRUSTTUNNEL=false) -eq 0 ]] \
    && ok "TrustTunnel disabled: its file is not required" \
    || bad "TrustTunnel disabled but preflight still failed: $(cat "$T/out")"

# In the admin group but the file is still not writable (e.g. root:root 0644).
rc=$(run "$(id -g)")
[[ "$rc" -ne 0 ]] && grep -q "sudo moav start" "$T/out" && ! grep -q usermod "$T/out" \
    && ok "in the admin group: points at 'moav start' to restore ownership" \
    || bad "in-group hint wrong (rc $rc): $(cat "$T/out")"
chmod 644 "$T/configs/trusttunnel/credentials.toml"

# wireguard is 2770 root:2000: an outsider cannot even see wg0.conf, and
# wg-user-add.sh would then skip WireGuard as "not configured".
chmod 600 "$T/configs/wireguard"
[[ $(run "$NOT_MINE") -ne 0 ]] && grep -q 'configs/wireguard' "$T/out" \
    && ok "untraversable configs/wireguard is caught, not skipped" || bad "untraversable dir missed: $(cat "$T/out")"
chmod 755 "$T/configs/wireguard"

chmod 555 "$T/state/users"
[[ $(run "$NOT_MINE") -ne 0 ]] && grep -q 'state/users' "$T/out" \
    && ok "unwritable state/users is caught too" || bad "state/users not checked: $(cat "$T/out")"
chmod 755 "$T/state/users"

# It must run before the per-user loop, not after the damage is done.
pre=$(grep -n '^_preflight_config_writes || exit 1' "$ROOT/scripts/user-add.sh" | cut -d: -f1)
loop=$(grep -n '^# Create each user' "$ROOT/scripts/user-add.sh" | cut -d: -f1)
[[ -n "$pre" && -n "$loop" && "$pre" -lt "$loop" ]] \
    && ok "preflight runs before any user is created" \
    || bad "preflight call missing or after the per-user loop (call line '${pre}', loop '${loop}')"

echo ""
echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]
