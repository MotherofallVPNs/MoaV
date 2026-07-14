#!/bin/bash
# =============================================================================
# moav CLI smoke test — runs a battery of `moav` commands against a LIVE stack
# and asserts they don't crash or hang. Complements the protocol connectivity
# tests (client-test.sh): those check the tunnels, this checks the tool.
#
# Run from the repo root with the stack up (this is what the e2e workflow does):
#   ./moav.sh start all && bash tests/cli-smoke-test.sh
#
# Two classes of check:
#   must  — the command must exit 0 (a read/report command; non-zero = breakage)
#   info  — any exit within the timeout is fine (state-dependent exit codes,
#           e.g. `net status` returns 2 when the tuning bundle isn't applied);
#           only a *timeout* (hang) or crash fails it.
# =============================================================================
set -uo pipefail

MOAV="./moav.sh"
SMOKE_USER="clismoke$$"
TIMEOUT=120
pass=0 fail=0

run() {
    local mode="$1" desc="$2"; shift 2
    [[ "${1:-}" == "--" ]] && shift
    local out rc
    out=$(timeout "$TIMEOUT" "$@" 2>&1); rc=$?
    if [[ $rc -eq 124 ]]; then
        echo "FAIL $desc (TIMED OUT after ${TIMEOUT}s — command hangs)"
        fail=$((fail + 1)); return
    fi
    if [[ "$mode" == "must" && $rc -ne 0 ]]; then
        echo "FAIL $desc (exit $rc)"
        echo "$out" | tail -4 | sed 's/^/       | /'
        fail=$((fail + 1)); return
    fi
    echo "ok   $desc (exit $rc)"
    pass=$((pass + 1))
}

echo "============================================================"
echo "  moav CLI smoke test"
echo "============================================================"

# --- read / report commands (must not error) ---
run must "moav help"                    -- "$MOAV" help
run must "moav version"                 -- "$MOAV" version
run must "install.sh --help"            -- bash site/install.sh --help
run must "moav status"                  -- "$MOAV" status
run must "moav users"                   -- "$MOAV" users
run must "moav profiles"                -- "$MOAV" profiles
run must "moav cert status"             -- "$MOAV" cert status
run must "moav logs --no-follow"        -- "$MOAV" logs --no-follow --tail 20

# --- diagnostics / state-dependent (any clean exit is fine) ---
run info "moav check"                   -- "$MOAV" check
run info "moav doctor"                  -- "$MOAV" doctor
run info "moav net status"              -- "$MOAV" net status
run info "moav conduit-offsets status"  -- "$MOAV" conduit-offsets status

# --- user lifecycle (mutating but reversible) ---
run must "moav user add $SMOKE_USER"    -- "$MOAV" user add "$SMOKE_USER"
run info "moav user revoke $SMOKE_USER" -- "$MOAV" user revoke "$SMOKE_USER"
run must "moav user add --batch 2"      -- "$MOAV" user add --batch 2 --prefix "${SMOKE_USER}b"
run info "moav user revoke (batch)"     -- "$MOAV" user revoke "${SMOKE_USER}b01" "${SMOKE_USER}b02"

# --- admin / backup / misc CLI surface ---
# admin password: Enter (empty) => generate a random one (non-interactive)
run must "moav admin password (generate)" -- bash -c "printf '\n' | timeout 60 $MOAV admin password"
run must "moav restart admin"           -- "$MOAV" restart admin
run must "moav export"                  -- "$MOAV" export /tmp/moav-smoke-backup.tar.gz
run info "moav import (round-trip)"     -- bash -c "printf 'y\n' | timeout 120 $MOAV import /tmp/moav-smoke-backup.tar.gz"
run must "moav update --help"           -- "$MOAV" update --help
# donate: display/status ONLY — never actually donates (that publishes real
# configs to an external service). No API key => non-zero, so classed info.
run info "moav donate status"           -- "$MOAV" donate status

# --- interactive menu (TUI): should launch and exit on EOF, not hang ---
run info "moav (TUI menu launches)"     -- bash -c "printf '\n' | timeout 30 $MOAV >/dev/null 2>&1 || true"

echo "------------------------------------------------------------"
echo "  smoke: $pass passed, $fail failed"
echo "------------------------------------------------------------"
[[ $fail -eq 0 ]]
