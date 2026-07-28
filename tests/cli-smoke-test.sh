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
run must "install.sh --help"            -- bash install.sh --help
run must "moav status"                  -- "$MOAV" status
run must "moav users"                   -- "$MOAV" users
run must "moav profiles"                -- "$MOAV" profiles
run must "moav cert status"             -- "$MOAV" cert status
run must "moav logs --no-follow"        -- "$MOAV" logs --no-follow --tail 20

# --- diagnostics / state-dependent (any clean exit is fine) ---
run info "moav check"                   -- "$MOAV" check
run info "moav doctor"                  -- "$MOAV" doctor
# doctor peers: duplicate-IP detection must exit 0 on a healthy fresh install
# (built for a real incident — 45 WG / 50 AWG peers sharing addresses).
run must "moav doctor peers"            -- "$MOAV" doctor peers
run info "moav net status"              -- "$MOAV" net status
run info "moav conduit-offsets status"  -- "$MOAV" conduit-offsets status

# --- user lifecycle (mutating but reversible) ---
run must "moav user add $SMOKE_USER"    -- "$MOAV" user add "$SMOKE_USER"
run must "moav user base64"             -- "$MOAV" user base64 "$SMOKE_USER"
# The packager standalone (not via --package): callable on any existing bundle;
# previously only reachable through `user add --package`, so a packager-only
# breakage would surface as a confusing --package failure.
run must "user-package.sh (standalone)" -- ./scripts/user-package.sh "$SMOKE_USER"
run info "moav user revoke $SMOKE_USER" -- "$MOAV" user revoke "$SMOKE_USER"

# --package must ship the FULLY RENDERED guide. The packager used to re-render the
# template itself, substituting only a subset of the placeholders and overwriting
# the correct README.html — so the zip went out with ~26 raw {{PLACEHOLDER}}
# markers (Shadowsocks/XHTTP/AmneziaWG/Telegram/XDNS sections). Assert on the
# ZIP's guide, not just the bundle's: this path had no coverage at all, which is
# exactly why the regression shipped.
run must "moav user add --package"       -- "$MOAV" user add "${SMOKE_USER}p" --package
run must "packaged guide fully rendered" -- bash -c '
    user="'"${SMOKE_USER}"'p"
    zip="outputs/bundles/${user}-configs.zip"
    # No skipping: zip/unzip/qrencode are installed by the e2e preflight, and a
    # missing tool is a suite bug to fix, not a test to opt out of.
    for t in zip unzip; do
        command -v "$t" >/dev/null 2>&1 || { echo "$t is not installed — the e2e preflight should have installed it"; exit 1; }
    done
    if [[ ! -f "$zip" ]]; then
        # Self-diagnosing: user-add.sh runs the packager inside an `if`, so its
        # failure is absorbed and invisible. Re-run it here to surface the cause.
        echo "no package zip at $zip"
        echo "  bundle dir:   $(ls -d "outputs/bundles/$user" 2>/dev/null || echo MISSING)"
        echo "  bundle guide: $(ls "outputs/bundles/$user/README.html" 2>/dev/null || echo MISSING)"
        echo "  --- re-running the packager to show why ---"
        ./scripts/user-package.sh "$user" 2>&1 | tail -15 | sed "s/^/  | /"
        exit 1
    fi
    tmp=$(mktemp -d); trap "rm -rf $tmp" EXIT
    unzip -q "$zip" -d "$tmp" || { echo "unzip failed on $zip"; exit 1; }
    readme=$(find "$tmp" -name README.html | head -1)
    [[ -n "$readme" ]] || { echo "package contains no README.html"; exit 1; }
    left=$(grep -oE "\{\{[A-Z0-9_]+\}\}" "$readme" | sort -u | tr "\n" " ")
    [[ -z "$left" ]] || { echo "unsubstituted placeholders in packaged guide: $left"; exit 1; }
'
run info "moav user revoke (package)"   -- "$MOAV" user revoke "${SMOKE_USER}p"
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
