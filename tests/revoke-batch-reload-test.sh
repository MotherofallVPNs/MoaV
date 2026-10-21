#!/bin/bash
# Regression test: batch `moav user revoke` must reset the proxy services ONCE
# at the end, not once per user.
#
# The bug (found live): revoking N users looped `user-revoke.sh <u>` per user,
# and each call reloaded sing-box + restarted xray/trusttunnel/telemt. Revoking
# a whole server was N reload/restart cycles — minutes of churn and repeated
# tunnel drops. Fix: the per-user revoke takes `--no-reload`, the batch loop
# passes it, and the CLI calls `scripts/reload-proxy.sh` once after the loop.
# `moav user revoke --all` enumerates every user and does the same single reset.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "user revoke: batch/--all resets the proxy services once at the end"

USERS="$ROOT/lib/users.sh"
USER_REVOKE="$ROOT/scripts/user-revoke.sh"
SINGBOX_REVOKE="$ROOT/scripts/singbox-user-revoke.sh"
RELOAD="$ROOT/scripts/reload-proxy.sh"

# 1. The shared reload script exists, is executable, and touches the services.
if [[ -x "$RELOAD" ]]; then
    ok "scripts/reload-proxy.sh exists and is executable"
else
    bad "scripts/reload-proxy.sh missing or not executable"
fi
if grep -q 'sing-box reload' "$RELOAD" 2>/dev/null && grep -q 'restart xray' "$RELOAD" 2>/dev/null; then
    ok "reload-proxy.sh reloads sing-box and restarts xray"
else
    bad "reload-proxy.sh does not reload the expected services"
fi

# 2. singbox-user-revoke.sh honors --no-reload (defers the reload to the caller).
if grep -q -- '--no-reload' "$SINGBOX_REVOKE" 2>/dev/null; then
    ok "singbox-user-revoke.sh accepts --no-reload"
else
    bad "singbox-user-revoke.sh does not accept --no-reload"
fi
# It must NOT inline the old sing-box reload block any more (that lived here and
# fired per user); the reload goes through reload-proxy.sh, gated on --no-reload.
if grep -q 'reload-proxy.sh' "$SINGBOX_REVOKE" 2>/dev/null; then
    ok "singbox-user-revoke.sh delegates the reload to reload-proxy.sh"
else
    bad "singbox-user-revoke.sh still reloads inline (would fire per user in a batch)"
fi

# 3. user-revoke.sh passes --no-reload straight through to the singbox revoke.
if grep -q 'singbox-user-revoke.sh' "$USER_REVOKE" 2>/dev/null \
   && grep -q 'NO_RELOAD' "$USER_REVOKE" 2>/dev/null; then
    ok "user-revoke.sh threads --no-reload to singbox-user-revoke.sh"
else
    bad "user-revoke.sh does not pass --no-reload down"
fi

# 4. The CLI revoke case: loop passes --no-reload, then reload-proxy.sh runs ONCE.
block=$(awk '/revoke\|rm\|remove\|delete\)/,/^            ;;$/' "$USERS")
if [[ -z "$block" ]]; then
    bad "could not locate the revoke case in lib/users.sh"
else
    if printf '%s' "$block" | grep -q 'user-revoke.sh "\$_u" --no-reload'; then
        ok "batch loop revokes each user with --no-reload"
    else
        bad "batch loop does NOT pass --no-reload — reloads fire per user again"
    fi
    # Exactly one reload-proxy.sh call after the loop.
    reloads=$(printf '%s\n' "$block" | grep -c 'reload-proxy.sh')
    if [[ "$reloads" -eq 1 ]]; then
        ok "reload-proxy.sh is called exactly once for the whole batch"
    else
        bad "expected 1 reload-proxy.sh call in the revoke case, found $reloads"
    fi
    if printf '%s' "$block" | grep -q -- '--all'; then
        ok "revoke supports --all (enumerate + confirm + single reset)"
    else
        bad "revoke does not support --all"
    fi
    # --all must require confirmation unless --yes is given (irreversible).
    if printf '%s' "$block" | grep -q 'read -r -p'; then
        ok "--all prompts for confirmation before revoking everyone"
    else
        bad "--all does not confirm — an accidental invocation wipes every user"
    fi
fi

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED ($fail failed, $pass passed)"
    exit 1
fi
echo "PASSED ($pass checks)"
