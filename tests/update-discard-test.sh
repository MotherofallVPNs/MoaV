#!/bin/bash
# Regression: `moav update`'s "Discard changes" option must fully reset with
# `git reset --hard`, not `git checkout -- .`.
#
# The bug (found live upgrading to a version that changed docker-compose.yml and
# added exporter files): the interactive Discard reported success, but the pull
# still aborted with "Your local changes to docker-compose.yml would be
# overwritten by merge." Cause: `git checkout -- .` only clears UNSTAGED edits;
# STAGED changes (git status MM / A) stay in the index and block the merge. The
# fix is `git reset --hard`, which clears both. Also verified functionally below.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
U="$ROOT/lib/update.sh"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "moav update: Discard fully clears staged + unstaged"

# 1. The discard path resets the index, not just the working tree.
if grep -qE 'git -C "\$install_dir" reset --hard' "$U"; then
    ok "discard uses 'git reset --hard' (clears the index too)"
else
    bad "discard does not reset --hard — staged changes survive and block the pull"
fi
if grep -qE 'git -C "\$install_dir" checkout -- \.' "$U"; then
    bad "discard still uses 'git checkout -- .' (unstaged only) — the reported bug"
else
    ok "discard no longer uses the unstaged-only 'git checkout -- .'"
fi

# 2. Functional proof of WHY: checkout -- . leaves a staged edit; reset --hard clears it.
if command -v git >/dev/null 2>&1; then
    d="$(mktemp -d)"; outf="$(mktemp)"; trap 'rm -rf "$d" "$outf"' EXIT
    (
        cd "$d" && git init -q && git config user.email t@t && git config user.name t
        printf 'v1\n' > compose.yml && git add compose.yml && git commit -qm init
        printf 'v2\n' > compose.yml && git add compose.yml   # STAGED change (like MM/A)
        git checkout -- . 2>/dev/null                        # the old discard
        staged_after_checkout=$(git status --porcelain | grep -c '^M')
        git reset --hard -q                                  # the fix
        clean_after_reset=$(git status --porcelain | wc -l | tr -d ' ')
        echo "$staged_after_checkout $clean_after_reset"
    ) > "$outf" 2>/dev/null
    read -r sc cr < "$outf"
    [ "${sc:-0}" -ge 1 ] && ok "'checkout -- .' leaves the staged edit (reproduces the bug)" \
                         || bad "expected the staged edit to survive checkout -- . (got $sc)"
    [ "${cr:-1}" = "0" ] && ok "'git reset --hard' leaves the tree clean" \
                         || bad "reset --hard did not clean the tree (got $cr)"
else
    printf '  SKIP  git unavailable for the functional check\n'
fi

echo ""
if [ "$fail" -gt 0 ]; then echo "FAILED ($fail failed, $pass passed)"; exit 1; fi
echo "PASSED ($pass checks)"
