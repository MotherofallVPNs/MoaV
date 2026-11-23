#!/bin/bash
# The shell lint gate must BLOCK: a new warning fails, a fixed one forces the
# baseline down, and an error-level finding can never be baselined.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINT="$ROOT/scripts/lint-shell.sh"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "shell lint gate (scripts/lint-shell.sh)"

pinned="$(bash "$LINT" --pinned-version)"
have="$(shellcheck --version 2>/dev/null | awk '/^version:/{print $2}')"
if [ "$have" != "$pinned" ]; then
    if [ -n "${CI:-}" ]; then echo "  FAIL  shellcheck $pinned required, found '${have:-none}'"; exit 1; fi
    echo "  SKIP  shellcheck $pinned required, found '${have:-none}'"; echo "PASSED (skipped)"; exit 0
fi

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export LINT_ROOT="$work/repo" LINT_BASELINE="$work/repo/baseline.txt"
mkdir -p "$LINT_ROOT" && cd "$LINT_ROOT" && git init -q . || exit 1
# One pre-existing warning (SC2155), as in the real tree.
printf '#!/bin/bash\nf() { local a=$(date); echo "$a"; }\nf\n' > old.sh
git add old.sh
run() { bash "$LINT" "$@" >"$work/out" 2>&1; }

run --update && grep -q '^old.sh SC2155 1$' "$LINT_BASELINE" \
    && ok "--update records existing findings as <file> <code> <count>" \
    || bad "--update did not record the existing finding"
run && ok "an unchanged tree passes" || bad "an unchanged tree fails: $(cat "$work/out")"

# A second SC2155 in the same file: same code, higher count.
printf '#!/bin/bash\nf() { local a=$(date); local b=$(date); echo "$a$b"; }\nf\n' > old.sh
if run; then bad "a new finding of an already-baselined code passed"
elif grep -q 'old.sh SC2155: 1 -> 2' "$work/out"; then ok "a new finding of an already-baselined code is blocked"
else bad "blocked, but without naming the finding: $(cat "$work/out")"; fi
printf '#!/bin/bash\nf() { local a=$(date); echo "$a"; }\nf\n' > old.sh

# A warning in a brand-new file.
printf '#!/bin/bash\ncd /tmp\nls\n' > new.sh; git add new.sh
if run; then bad "a warning in a new file passed"
elif grep -q 'new.sh:2:.*SC2164' "$work/out"; then ok "a warning in a new file is blocked, with its location"
else bad "blocked, but without the location: $(cat "$work/out")"; fi
git rm -q -f --cached new.sh; rm -f new.sh

# Fixing the old warning must force the baseline down, not leave slack behind.
printf '#!/bin/bash\nf() { local a; a=$(date); echo "$a"; }\nf\n' > old.sh
if run; then bad "a fixed finding left a stale baseline entry unnoticed"
elif grep -q 'baseline is out of date' "$work/out"; then ok "a fixed finding forces a baseline update"
else bad "failed for the wrong reason: $(cat "$work/out")"; fi

# Error-level findings are refused even by --update.
printf '#!/bin/bash\nif [ -n "$1" ]\necho x\nfi\n' > broken.sh; git add broken.sh
if run --update; then bad "--update baselined an error-level finding"
else ok "--update refuses to baseline an error-level finding"; fi

echo ""
if [ "$fail" -eq 0 ]; then echo "PASSED ($pass checks)"; else echo "FAILED ($fail failed, $pass passed)"; exit 1; fi
