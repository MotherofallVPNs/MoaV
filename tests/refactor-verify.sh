#!/bin/bash
# Refactor verification harness. Automates the mechanical checks every v2
# refactor PR was gated on (see docs/devdocs/REFACTOR-VERIFICATION.md for the
# full checklist and the incidents behind each rule).
#
# Usage:
#   tests/refactor-verify.sh                 # static checks (CI-safe, no base needed)
#   tests/refactor-verify.sh compare <ref>   # + conservation & behaviour diff vs <ref>
#
# Static mode is wired into ci.yml. Compare mode is for local pre-PR use:
#   tests/refactor-verify.sh compare origin/dev
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-static}"
BASE_REF="${2:-}"

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# Function-definition census across the dispatcher + its modules.
# Deliberately the same grep every B-series PR used.
fn_defs() { # $1 = dir to census
    cat <(grep -ho '^[a-z_][a-z0-9_]*() {' "$1/moav.sh") \
        <(grep -ho '^[a-z_][a-z0-9_]*() {' "$1"/lib/*.sh) 2>/dev/null
}

echo "refactor-verify: static checks"

# --- 1. everything parses -----------------------------------------------------
syntax_bad=0
while IFS= read -r f; do
    bash -n "$f" 2>/dev/null || { syntax_bad=1; printf '        parse error: %s\n' "$f"; }
done < <(find "$ROOT" -maxdepth 2 \( -path '*/lib/*.sh' -o -name 'moav.sh' -o -path '*/scripts/*.sh' -o -path '*/tests/*.sh' \) -not -path '*/.git/*')
[[ $syntax_bad -eq 0 ]] && ok "bash -n clean across moav.sh, lib/, scripts/, tests/" \
                        || bad "bash -n found parse errors (listed above)"

# --- 2. no function defined twice across moav.sh + lib/ -----------------------
# A duplicate means an extraction left a copy behind: the sourced module
# silently shadows (or is shadowed by) the dispatcher copy. This happened once,
# after a hunk-wise merge resolution, and only this check caught it.
dups=$(fn_defs "$ROOT" | sort | uniq -d)
if [[ -z "$dups" ]]; then
    ok "no duplicate function definitions across moav.sh + lib/*.sh"
else
    bad "duplicate definitions (extraction left a copy behind):"
    printf '%s\n' "$dups" | sed 's/^/          /'
fi

# (A "modules must not execute at source time" check was tried here and removed:
# a line-based heuristic cannot distinguish top-level commands from multi-line
# array assignments or heredoc bodies, and a check with false positives trains
# readers to ignore its output. Verify that property by review instead.)

# --- 3. lib/ modules call helpers that exist ----------------------------------
# D2 regression class: a guard called log_error(), which is a scripts/lib
# helper; lib/ defines error(). The message became "command not found".
if grep -qn '\blog_error\b\|\blog_warn\b\|\blog_info\b' "$ROOT"/lib/*.sh; then
    bad "lib/ modules call scripts/lib logging helpers (use error/warn/info):"
    grep -n '\blog_error\b\|\blog_warn\b\|\blog_info\b' "$ROOT"/lib/*.sh | head -5 | sed 's/^/          /'
else
    ok "lib/ modules use only the logging helpers lib/common.sh defines"
fi

# --- 4. the test suites themselves --------------------------------------------
for t in strict-mode-test.sh net-alloc-test.sh; do
    if out=$(bash "$ROOT/tests/$t" 2>&1); then
        ok "tests/$t: $(printf '%s\n' "$out" | grep -Eo '[0-9]+ passed[^"]*' | tail -1)"
    else
        bad "tests/$t failed:"
        printf '%s\n' "$out" | tail -5 | sed 's/^/          /'
    fi
done

# --- compare mode: conservation + behaviour diff vs a base ref -----------------
if [[ "$MODE" == "compare" ]]; then
    [[ -n "$BASE_REF" ]] || { echo "usage: $0 compare <base-ref>"; exit 2; }
    echo "refactor-verify: compare vs $BASE_REF"
    wt=$(mktemp -d)
    git -C "$ROOT" worktree add -q --detach "$wt" "$BASE_REF" || { bad "cannot create worktree for $BASE_REF"; exit 1; }
    trap 'git -C "$ROOT" worktree remove --force "$wt" 2>/dev/null; git -C "$ROOT" worktree prune' EXIT

    # 5. function-count conservation. A pure relocation keeps the census equal;
    # adding/removing functions is fine but must be deliberate — the check makes
    # you look at the delta instead of discovering it later.
    old_n=$(fn_defs "$wt" | wc -l | tr -d ' ')
    new_n=$(fn_defs "$ROOT" | wc -l | tr -d ' ')
    if [[ "$old_n" == "$new_n" ]]; then
        ok "function census conserved ($new_n)"
    else
        printf '  NOTE  function census %s -> %s; delta:\n' "$old_n" "$new_n"
        diff <(fn_defs "$wt" | sort) <(fn_defs "$ROOT" | sort) | grep '^[<>]' | sed 's/^</          removed:/; s/^>/          added:  /'
        printf '        (fine if the PR intends it; a surprise here is a bug)\n'
    fi

    # 6. behaviour diff on NON-MUTATING subcommands only. Bare `moav` and
    # `moav bootstrap --help` create a .env in the clone — never add them here.
    # The banner's "v<ver> (<branch>)" line is normalised: a detached worktree
    # prints (HEAD) and the box padding shifts with branch-name length.
    # Path normalisation covers the /private prefix macOS resolves temp dirs
    # through -- error messages cite the resolved path, not the mktemp one.
    run_cmd() { (cd "$1" && MOAV_SKIP_BASH_CHECK=1 bash ./moav.sh $2 2>&1; echo "EXIT=$?") \
                | sed -E 's/v[0-9][^)]*\([^)]*\).*/VERSIONLINE/' \
                | sed -E "s#/private$wt#DIR#g; s#$wt#DIR#g; s#/private$ROOT#DIR#g; s#$ROOT#DIR#g"; }
    dcount=0
    for c in "version" "help" "--help" "check" "status" "profiles" "doctor help" "nosuchcmd"; do
        a=$(run_cmd "$wt" "$c"); b=$(run_cmd "$ROOT" "$c")
        if [[ "$a" == "$b" ]]; then
            ok "byte-identical: moav $c"
        else
            dcount=$((dcount+1))
            printf '  DIFF  moav %s\n' "$c"
            diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | head -6 | sed 's/^/          /'
        fi
    done
    rm -f "$wt/.env" "$ROOT/.env"   # belt-and-braces; these commands should not create one
    [[ $dcount -gt 0 ]] && printf '        (a DIFF is not automatically wrong — but it must be explained in the PR)\n'
fi

echo
echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]
