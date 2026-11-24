#!/bin/bash
# Regression tests for container-entrypoint strict mode (Workstream D4).
#
# The WireGuard/AmneziaWG entrypoints ran with NO `set` line at all. Adding
# strict mode required fixing two landmine classes first, both verified in the
# real target shell (busybox ash on alpine, not the dev machine's bash):
#
#   1. `grep KEY file | head -1 | cut …` raises SIGPIPE (exit 141) once `head`
#      closes the pipe -- which pipefail propagates EVEN ON A SUCCESSFUL MATCH --
#      and grep exits 1 when the key is legitimately absent. Most AmneziaWG
#      params (MTU, Jc/Jmin/Jmax/S1/S2/H1-H4) are optional, so absence is the
#      normal case. Both need `|| true`.
#   2. An empty PrivateKey used to sail past `wg set` into the monitor loop, so
#      the container reported healthy while the tunnel was dead.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "entrypoint strict-mode tests"


# --- static: strict mode declared, scrapers guarded -------------------------
for e in wireguard amneziawg; do
    f="$ROOT/scripts/${e}-entrypoint.sh"
    grep -q '^set -eu' "$f" && ok "$e: declares set -eu" || bad "$e: no strict mode"
    grep -q 'set -o pipefail' "$f" && ok "$e: enables pipefail" || bad "$e: no pipefail"
    # every scraper of this shape must carry `|| true`
    total=$(grep -cE "\| head -1 \| cut -d'=' -f2- \| tr -d ' " "$f" || true)
    guarded=$(grep -cE "\| tr -d ' \\\\t\\\\r\\\\n' \|\| true\)" "$f" || true)
    if [[ "$total" -gt 0 && "$total" == "$guarded" ]]; then
        ok "$e: all $total config scrapers guarded with || true"
    else
        bad "$e: $guarded/$total scrapers guarded — an unguarded one dies on SIGPIPE"
    fi
done

# --- D4b-1: entrypoints upgraded from bare `set -e` -------------------------
for e in conduit dnstt trusttunnel xray; do
    f="$ROOT/scripts/${e}-entrypoint.sh"
    grep -qE '^set -(eu|euo pipefail)' "$f" && ok "$e: strict mode (was bare set -e)" \
                                            || bad "$e: still bare set -e"
    grep -q 'pipefail' "$f" && ok "$e: enables pipefail" || bad "$e: no pipefail"
done

# conduit's key extraction MUST keep `|| true`: grep exits 1 when the key is
# absent and the next line (`if [ -z "$PRIVATE_KEY" ]`) exists to handle that.
# Under pipefail without the guard the script dies before reaching its own check.
if grep -qE "sed .*\\|\\| true\\)$" "$ROOT/scripts/conduit-entrypoint.sh"; then
    ok "conduit: key extraction guarded so its own empty-key branch stays reachable"
else
    bad "conduit: unguarded key extraction — pipefail kills it before the [ -z ] check"
fi

# xray prints its version via `xray version | head -1`, which SIGPIPEs under
# pipefail on a purely cosmetic line.
grep -q 'xray version 2>/dev/null | head -1 || true' "$ROOT/scripts/xray-entrypoint.sh" \
    && ok "xray: version line guarded against SIGPIPE" \
    || bad "xray: unguarded 'xray version | head -1' dies on SIGPIPE"

# --- the pipefail idiom must be subshell-probed, never `|| true` --------------
# `set` is a POSIX SPECIAL builtin: if `set -o pipefail` fails, a non-interactive
# shell EXITS IMMEDIATELY and `|| true` does not save it. dash (debian's /bin/sh)
# has no pipefail, so the naive guard killed the conduit container at line 3 with
# exit 2 and no output at all. Any `#!/bin/sh` entrypoint on a debian-based image
# hits this.
if grep -rln 'set -o pipefail 2>/dev/null || true' "$ROOT/scripts/" >/dev/null 2>&1; then
    bad "some entrypoint still uses '|| true' to guard pipefail — fatal under dash:"
    grep -rln 'set -o pipefail 2>/dev/null || true' "$ROOT/scripts/" | sed 's/^/          /'
else
    ok "no entrypoint guards pipefail with '|| true' (fatal in dash)"
fi

for e in conduit dnstt wireguard amneziawg; do
    f="$ROOT/scripts/${e}-entrypoint.sh"
    grep -q 'if ( set -o pipefail 2>/dev/null ); then' "$f" \
        && ok "$e: probes pipefail in a subshell (portable ash + dash)" \
        || bad "$e: pipefail not subshell-probed"
done

# --- D4b-2: the six that had NO `set` line at all ----------------------------
# `-u` + pipefail only. `-e` is deliberately deferred (see the entrypoint notes):
# these have never run under it, so every tolerated non-zero exit would become
# fatal, and that needs a per-command review rather than a blind sweep.
# D4c: -e enabled per-service after a per-command review, smallest first.
for e in admin sing-box snowflake wstunnel grafana grafana-proxy; do
    f="$ROOT/scripts/${e}-entrypoint.sh"
    grep -qE '^set -eu$' "$f" && ok "$e: full strict mode (set -eu)" \
                              || bad "$e: lost set -e"
done
# grafana's cert lookup returns non-zero when no certificate exists yet, and a
# plain `var=$(cmd)` assignment propagates that (unlike `local x=$(cmd)`). Without
# the guard, -e killed grafana on every install before certbot had issued, which
# is exactly the state its wait loop exists to handle.
# grafana-proxy has the SAME cert-wait pattern as grafana and had the SAME bug
# (unguarded certs=$(find_certificates) under -eu). It was missed in D4c and only
# fires before certbot issues, which the happy-path e2e never hits.
if grep -qE 'certs=\$\(find_certificates\)$' "$ROOT/scripts/grafana-proxy-entrypoint.sh"; then
    bad "grafana-proxy: unguarded certs=\$(find_certificates) -- dies before certbot issues"
else
    ok "grafana-proxy: cert lookup guarded (survives a pre-certbot install)"
fi

# grafana's HTTP-fallback branch reads GF_SERVER_CERT_KEY, which is only exported
# on the cert-found branch; under -u the no-cert path aborted before reaching it.
grep -q 'export GF_SERVER_CERT_KEY=""' "$ROOT/scripts/grafana-entrypoint.sh" \
    && ok "grafana: GF_SERVER_CERT_KEY defined on the no-cert path (HTTP fallback reachable)" \
    || bad "grafana: GF_SERVER_CERT_KEY unset on no-cert path -- aborts under -u before HTTP fallback"

# trusttunnel: `((x++))` returns 1 when x is 0, fatal under -e, one second into its
# own cert-wait loop.
if grep -qE '\(\(CERT_WAIT_COUNT\+\+\)\)' "$ROOT/scripts/trusttunnel-entrypoint.sh"; then
    bad "trusttunnel: ((CERT_WAIT_COUNT++)) returns 1 from 0 -- kills the cert wait under -e"
else
    ok "trusttunnel: counter increment is set -e safe"
fi

grep -q 'certs=$(find_certificates) || true' "$ROOT/scripts/grafana-entrypoint.sh" \
    && ok "grafana: cert lookup guarded (survives a pre-certbot install)" \
    || bad "grafana: unguarded certs=\$(find_certificates) — dies before certbot issues"

# Branding is cosmetic; a failed in-place edit must not take the container down.
unguarded=$(grep -cE '^\s*sed -i .*2>/dev/null$' "$ROOT/scripts/grafana-entrypoint.sh" || true)
[ "${unguarded:-0}" -eq 0 ] \
    && ok "grafana: all in-place branding edits guarded" \
    || bad "grafana: $unguarded unguarded 'sed -i' — a read-only layer would kill the container"


# SIGPIPE guards that pipefail would otherwise make fatal.
grep -q 'head -1 || true)' "$ROOT/scripts/admin-entrypoint.sh" \
    && ok "admin: cert-dir lookup guarded" || bad "admin: unguarded find|tail|head"
grep -q 'head -10 .*|| true)' "$ROOT/scripts/sing-box-entrypoint.sh" \
    && ok "sing-box: inbound-tag scan guarded" || bad "sing-box: unguarded grep|head|sed"
grep -q 'head -1 || true)' "$ROOT/scripts/snowflake-entrypoint.sh" \
    && ok "snowflake: default-route lookup guarded" || bad "snowflake: unguarded ip route|grep|awk|head"

# --- functional coverage lives in the e2e, deliberately ------------------------
# A docker-based harness was written here and removed: capturing a container that
# ends in a monitor loop hung the suite, and a flaky CI test is worse than no
# test. The e2e starts these exact containers with real configs and fails if
# wireguard/amneziawg do not come up, which is stronger proof than a stubbed run.
# What IS asserted here is the shape that made strict mode safe to add at all.

# --- the specific bug that made `set -e` unsafe here --------------------------
# `grep -c` prints 0 AND exits 1 on no match, so `|| echo 0` appended a SECOND
# zero -- the peer count rendered as "0 0".
# ^[^#]* so the explanatory comment (which quotes the old pattern) is not a hit.
if grep -qE '^[^#]*grep -c .*\|\| echo 0' "$ROOT/scripts/wireguard-entrypoint.sh"; then
    bad "wireguard: peer count still uses '|| echo 0' (double-prints as \"0 0\")"
else
    ok "wireguard: peer count no longer double-prints"
fi

# --- required-value validation, or strict mode buys nothing -------------------
for e in wireguard amneziawg; do
    f="$ROOT/scripts/${e}-entrypoint.sh"
    if grep -q 'ERROR: no PrivateKey' "$f"; then
        ok "$e: fails loudly on a missing PrivateKey"
    else
        bad "$e: empty key still reaches the monitor loop (container healthy, tunnel dead)"
    fi
done

# --- dual-stack Address: one `ip address add` per prefix ----------------------
# bootstrap writes "Address = 10.x/24, fd00:…/64" when the server has IPv6, and
# the whole string was passed to ip(8) ("any valid prefix is expected"), so the
# container restart-looped. Run the real set_addresses() against a stub `ip`.
_stub=$(mktemp -d)
cat > "$_stub/ip" <<'STUB'
#!/bin/sh
echo "$*" >> "$IP_LOG"
case "$*" in *,*) exit 1 ;; esac
[ "${IP_V6_FAIL:-0}" = 1 ] && case "$*" in *:*) exit 2 ;; esac
exit 0
STUB
chmod +x "$_stub/ip"
for e in wireguard amneziawg; do
    f="$ROOT/scripts/${e}-entrypoint.sh"
    fn=$(awk '/^set_addresses\(\) \{/,/^\}/' "$f")
    [ -n "$fn" ] || { bad "$e: no set_addresses() function"; continue; }
    grep -qE '^[^#]*ip addr(ess)? add "\$ADDRESS"' "$f" \
        && bad "$e: still passes the whole Address to ip(8)" \
        || ok "$e: never passes the raw Address to ip(8)"
    run() {  # $1=Address $2=IP_V6_FAIL -> prints rc, log in $_stub/log
        : > "$_stub/log"
        PATH="$_stub:$PATH" IP_LOG="$_stub/log" IP_V6_FAIL="$2" ADDRESS="$1" INTERFACE=awg0 \
            sh -c "set -eu; $fn
set_addresses" >/dev/null 2>&1; echo $?
    }
    rc=$(run "10.67.67.1/24,fd00:cafe:dead::1/64" 0)
    if [[ $rc == 0 ]] && grep -qx 'address add 10.67.67.1/24 dev awg0' "$_stub/log" \
       && grep -qx 'address add fd00:cafe:dead::1/64 dev awg0' "$_stub/log" \
       && [[ $(wc -l < "$_stub/log") -eq 2 ]]; then
        ok "$e: dual-stack Address configures both prefixes"
    else bad "$e: dual-stack Address (rc=$rc): $(tr '\n' ';' < "$_stub/log")"; fi
    rc=$(run "10.66.66.1/24" 0)
    [[ $rc == 0 && $(cat "$_stub/log") == 'address add 10.66.66.1/24 dev awg0' ]] \
        && ok "$e: single-address case unchanged" || bad "$e: single address broke (rc=$rc)"
    rc=$(run "10.67.67.1/24,fd00:cafe:dead::1/64" 1)
    [[ $rc == 0 ]] && ok "$e: IPv6 add failure is non-fatal (IPv4 still up)" \
                   || bad "$e: IPv6-disabled netns kills the container (rc=$rc)"
    PATH="$_stub:$PATH" IP_LOG=/dev/null ADDRESS="10.1.1.1/24" INTERFACE=awg0 \
        sh -c "set -eu; ip() { return 1; }; $fn
set_addresses" >/dev/null 2>&1 \
        && bad "$e: IPv4 add failure was swallowed" || ok "$e: IPv4 add failure is fatal"
done
rm -rf "$_stub"

# --- admin entrypoint: clash-secret read must not crash a secret-less install -
# The read runs under `set -eu`; grep exits 1 when /state/keys/clash-api.env is
# absent (a valid state: no sing-box protocols), so the `|| true` is load-bearing
# — without it the admin container crash-loops on every such install.
_ae="$ROOT/scripts/admin-entrypoint.sh"
if grep -qE "CLASH_API_SECRET=\\\$\(grep .*clash-api\.env.* \|\| true\)" "$_ae"; then
    ok "admin: clash-secret read is guarded with || true (secret-less install safe)"
else
    bad "admin: clash-secret read lost its || true — crash-loops when clash-api.env is absent"
fi

# --- admin must DROP privileges: the app runs as non-root `moav`, not root ----
if grep -qE '^exec su-exec moav ' "$_ae"; then
    ok "admin drops to non-root (exec su-exec moav …)"
else
    bad "admin no longer drops privileges — the dashboard would run as root"
fi

echo
echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]
