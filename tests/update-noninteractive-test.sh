#!/bin/bash
# Regression: `moav update` must run unattended with `--yes` / `-y` or
# MOAV_NONINTERACTIVE=1 — the same switch `confirm`, bootstrap --yes and the
# --json commands already honour.
#
# The gap (hit by the MoaV Deploy app, which runs `moav update` over SSH with
# no TTY): cmd_update used bare `read -rp` for the "Stash / Discard / Abort"
# menu and the two "[Y/n]" .env questions. With stdin open and nobody typing,
# the update hung forever; with stdin closed it limped on empty-read defaults.
#
# Non-interactive defaults = the interactive defaults: Stash (1), update the
# version pins (Y), add the new variables (Y). Interactive behaviour unchanged.
# Services are never restarted either way.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
U="$ROOT/lib/update.sh"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "moav update: non-interactive mode (--yes / MOAV_NONINTERACTIVE=1)"

# --- 1. static surface --------------------------------------------------------
grep -qE '^\s+-y\|--yes\)' "$U" \
    && ok "cmd_update parses -y/--yes" \
    || bad "cmd_update does not parse -y/--yes"
grep -q 'export MOAV_NONINTERACTIVE=1' "$U" \
    && ok "--yes exports MOAV_NONINTERACTIVE=1 (survives the _post-update re-exec)" \
    || bad "--yes does not export MOAV_NONINTERACTIVE=1 — the re-exec'd post-update step would prompt again"
# The only stdin prompts left are the 1/2/3 menu (guarded) and the Discard
# "Are you sure?" that only an interactive "2" can reach. The two [Y/n] .env
# questions must have moved to `confirm`.
if [ "$(grep -c 'read -rp "' "$U")" = "2" ] && [ "$(grep -c 'read -r -p ' "$U")" = "0" ] \
   && grep -qB3 'read -rp "Choice \[1/2/3\]' "$U"; then
    ok "no [Y/n] prompt reads stdin any more; the 1/2/3 menu sits behind the guard"
else
    bad "unexpected stdin prompt(s) in lib/update.sh: $(grep -nE 'read -r?p? "' "$U" | tr '\n' ' ')"
fi
grep -q 'confirm "Update component versions in .env?" "y"' "$U" \
    && ok "version-pin question uses confirm (default y)" \
    || bad "version-pin question is not routed through confirm"
grep -q 'confirm "Add these to your .env with default values?" "y"' "$U" \
    && ok "new-variables question uses confirm (default y)" \
    || bad "new-variables question is not routed through confirm"
grep -q -- '-y --yes' "$ROOT/completions/moav.bash" \
    && ok "bash completion offers --yes for update" \
    || bad "completions/moav.bash does not offer --yes for update"
if ! grep -qE '^\s*(docker compose (restart|up|down)|cmd_(restart|start|stop)\b)' "$U"; then
    ok "update never restarts services"
else
    bad "update touches service lifecycle — non-interactive mode must not restart on its own"
fi

# --- 2. functional: a real repo with local changes + stale .env --------------
command -v git >/dev/null 2>&1 || { echo "  SKIP  git unavailable"; echo ""; echo "PASSED ($pass checks)"; exit 0; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Fresh install dir per case: an origin to fetch/pull from (same commit, so no
# _post-update re-exec), a tracked file to dirty, and a gitignored .env whose
# pin is behind .env.example and which lacks a variable .env.example has.
make_install() {  # <dir>
    local d="$1"
    git init -q --bare "$d.origin.git"
    git init -q "$d"
    git -C "$d" checkout -q -b main 2>/dev/null || true
    git -C "$d" config user.email t@t; git -C "$d" config user.name t
    printf '.env\n' > "$d/.gitignore"
    printf 'tracked v1\n' > "$d/tracked.txt"
    printf 'SINGBOX_VERSION=2.0.0\n# a brand-new knob\nNEW_KNOB=true\n' > "$d/.env.example"
    git -C "$d" add -A && git -C "$d" commit -qm init
    git -C "$d" remote add origin "$d.origin.git"
    git -C "$d" push -q origin main 2>/dev/null
    printf 'SINGBOX_VERSION=1.0.0\nENABLE_XDNS=true\nENABLE_DNSTT=true\nENABLE_SLIPSTREAM=true\nPORT_XDNS=5356\nPORT_DNS=53\n' > "$d/.env"
    printf 'tracked v2 (local edit)\n' > "$d/tracked.txt"   # the local change
}

# run_update <install-dir> <stdin-text> [env assignments / flags...]
# stdin carries the answers an interactive run would take ("3" = Abort, then
# "n", "n"): a non-interactive run must IGNORE them and take its defaults.
run_update() {
    local d="$1" input="$2"; shift 2
    local envs=() flags=()
    for a in "$@"; do case "$a" in *=*) envs+=("$a") ;; *) flags+=("$a") ;; esac; done
    printf '%s' "$input" | env -i PATH="$PATH" HOME="$WORK" "${envs[@]}" \
        bash -c '
            SCRIPT_DIR="$1"; shift
            # shellcheck disable=SC1091
            source "'"$ROOT"'/scripts/lib/common.sh" >/dev/null 2>&1
            # shellcheck disable=SC1091
            source "'"$ROOT"'/lib/common.sh" >/dev/null 2>&1
            # shellcheck disable=SC1091
            source "'"$ROOT"'/lib/update.sh" >/dev/null 2>&1
            cmd_update "$@"
        ' _ "$d" "${flags[@]}" 2>&1
}

check_unattended() {  # <label> <install-dir> <output> <rc>
    local label="$1" d="$2" out="$3" rc="$4"
    [ "$rc" = "0" ] && ok "$label: exit 0" || bad "$label: rc=$rc"$'\n'"$out"
    printf '%s' "$out" | grep -q 'Non-interactive: choosing 1 (stash)' \
        && ok "$label: logged the stash decision" \
        || bad "$label: did not log the non-interactive stash choice"
    [ "$(git -C "$d" stash list | wc -l | tr -d ' ')" = "1" ] \
        && ok "$label: local change was stashed (not discarded, not left in place)" \
        || bad "$label: stash list has $(git -C "$d" stash list | wc -l | tr -d ' ') entries"
    [ -z "$(git -C "$d" status --porcelain)" ] \
        && ok "$label: tree clean for the pull" \
        || bad "$label: tree still dirty"
    if sed --version 2>/dev/null | grep -q GNU; then
        grep -q '^SINGBOX_VERSION=2.0.0$' "$d/.env" \
            && ok "$label: .env version pin updated (default Y, stdin 'n' ignored)" \
            || bad "$label: .env pin not updated: $(grep SINGBOX "$d/.env")"
    else
        # check_component_versions rewrites the pin with GNU `sed -i` (the
        # server CLI is Linux-only); on BSD sed the write fails, so only check
        # that the question was answered without a prompt.
        printf '  SKIP  %s: version-pin rewrite needs GNU sed (BSD sed here)\n' "$label"
    fi
    grep -q '^NEW_KNOB=true$' "$d/.env" \
        && ok "$label: new .env variable added (default Y, stdin 'n' ignored)" \
        || bad "$label: NEW_KNOB not added to .env"
    printf '%s' "$out" | grep -qi 'aborted' \
        && bad "$label: 'Aborted' in output — the stdin '3' was consumed" \
        || ok "$label: stdin answers were not consumed"
}

# MOAV_NONINTERACTIVE=1 in the environment (the Deploy app's route)
d1="$WORK/env"; make_install "$d1"
out=$(run_update "$d1" $'3\nn\nn\n' MOAV_NONINTERACTIVE=1); rc=$?
check_unattended "MOAV_NONINTERACTIVE=1" "$d1" "$out" "$rc"

# --yes flag
d2="$WORK/flag"; make_install "$d2"
out=$(run_update "$d2" $'3\nn\nn\n' --yes); rc=$?
check_unattended "--yes" "$d2" "$out" "$rc"

# -y short flag, combined with -b (flag order independent)
d3="$WORK/short"; make_install "$d3"
out=$(run_update "$d3" $'3\nn\nn\n' -y -b main); rc=$?
check_unattended "-y -b main" "$d3" "$out" "$rc"

# Interactive behaviour unchanged: with no flag the menu still reads stdin,
# so "3" aborts and nothing is stashed.
d4="$WORK/interactive"; make_install "$d4"
out=$(run_update "$d4" $'3\n'); rc=$?
if [ "$rc" = "0" ] && printf '%s' "$out" | grep -q 'Aborted' \
   && [ "$(git -C "$d4" stash list | wc -l | tr -d ' ')" = "0" ] \
   && grep -q '^SINGBOX_VERSION=1.0.0$' "$d4/.env"; then
    ok "interactive: '3' on stdin still aborts, nothing stashed or rewritten"
else
    bad "interactive path changed: rc=$rc stash=$(git -C "$d4" stash list | wc -l | tr -d ' ')"$'\n'"$out"
fi

# --help documents the flag
out=$(run_update "$WORK/env" '' --help)
printf '%s' "$out" | grep -q -- '-y, --yes' && ok "--help documents -y/--yes" || bad "--help lacks -y/--yes"

echo ""
if [ "$fail" -gt 0 ]; then echo "FAILED ($fail failed, $pass passed)"; exit 1; fi
echo "PASSED ($pass checks)"
