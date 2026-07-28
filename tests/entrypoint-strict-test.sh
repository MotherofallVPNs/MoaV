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
for e in admin grafana grafana-proxy sing-box snowflake wstunnel; do
    f="$ROOT/scripts/${e}-entrypoint.sh"
    grep -qE '^set -u$' "$f" && ok "$e: set -u" || bad "$e: no set -u"
    grep -q 'if ( set -o pipefail 2>/dev/null ); then' "$f" \
        && ok "$e: pipefail subshell-probed (sing-box/wstunnel are dash — no pipefail)" \
        || bad "$e: pipefail not subshell-probed"
done

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

echo
echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]
