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
