#!/bin/bash
# Shell lint gate: shellcheck at warning level, blocking on anything that is not
# in the recorded baseline. Usage: lint-shell.sh [--update | --pinned-version]
set -uo pipefail
export LC_ALL=C   # stable sort order, so the baseline does not churn across machines

ROOT="${LINT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BASELINE="${LINT_BASELINE:-$ROOT/tests/shellcheck-baseline.txt}"
# Findings differ between shellcheck releases, so the baseline is tied to one.
PINNED="0.11.0"

[ "${1:-}" = "--pinned-version" ] && { echo "$PINNED"; exit 0; }

command -v shellcheck >/dev/null 2>&1 || { echo "lint-shell: shellcheck is not installed"; exit 1; }
have="$(shellcheck --version | awk '/^version:/{print $2}')"
if [ "$have" != "$PINNED" ]; then
    if [ -n "${CI:-}" ]; then
        echo "lint-shell: shellcheck $have found, the baseline needs $PINNED"; exit 1
    fi
    echo "lint-shell: SKIP, shellcheck $have found but the baseline needs $PINNED (CI is authoritative)"
    exit 0
fi

cd "$ROOT" || exit 1
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
git ls-files '*.sh' 'moav.sh' | sort -u > "$work/files"
xargs shellcheck --severity=warning -f gcc < "$work/files" > "$work/findings" 2>/dev/null

# "<file> <code> <count>", one line per file and code. Line numbers are left out
# on purpose: they shift with every unrelated edit.
sed -nE 's/^([^:]+):[0-9]+:[0-9]+: [a-z]+: .*\[(SC[0-9]+)\]$/\1 \2/p' "$work/findings" \
    | sort | uniq -c | awk '{print $2, $3, $1}' > "$work/current"
total="$(wc -l < "$work/findings" | tr -d ' ')"

# Error-level findings are never baselined.
if grep -q ': error: ' "$work/findings"; then
    echo "lint-shell: error-level findings (fix these, they cannot be baselined):"
    grep ': error: ' "$work/findings" | sed 's/^/  /'
    exit 1
fi

if [ "${1:-}" = "--update" ]; then
    {
        echo "# shellcheck $PINNED, --severity=warning: findings that predate the blocking gate."
        echo "# <file> <code> <count>. Regenerate with: scripts/lint-shell.sh --update"
        echo "# Counts may only go down. Do not add lines to make a new finding pass."
        cat "$work/current"
    } > "$BASELINE"
    echo "lint-shell: baseline rewritten ($total findings in $(wc -l < "$work/current" | tr -d ' ') file/code pairs)"
    exit 0
fi

[ -f "$BASELINE" ] || { echo "lint-shell: baseline $BASELINE is missing"; exit 1; }
grep -v '^#' "$BASELINE" > "$work/base"

# NEW: more findings than recorded. STALE: fewer, so the baseline must shrink.
awk 'NR==FNR { base[$1" "$2]=$3; next }
     { k=$1" "$2; seen[k]=1; b=(k in base)?base[k]:0
       if ($3 > b) print "NEW", $1, $2, b, $3
       else if ($3 < b) print "STALE", $1, $2, b, $3 }
     END { for (k in base) if (!(k in seen)) print "STALE", k, base[k], 0 }' \
    "$work/base" "$work/current" | sort > "$work/diff"

rc=0
if grep -q '^NEW ' "$work/diff"; then
    rc=1
    echo "lint-shell: new shellcheck findings (fix them, or add a '# shellcheck disable=SCxxxx' with a reason):"
    grep '^NEW ' "$work/diff" | while read -r _ file code was now; do
        echo "  $file $code: $was -> $now"
        grep -F "$file:" "$work/findings" | grep -F "[$code]" | sed 's/^/      /'
    done
fi
if grep -q '^STALE ' "$work/diff"; then
    rc=1
    echo "lint-shell: findings were fixed, so the baseline is out of date:"
    grep '^STALE ' "$work/diff" | while read -r _ file code was now; do
        echo "  $file $code: $was -> $now"
    done
    echo "  run scripts/lint-shell.sh --update and commit tests/shellcheck-baseline.txt"
fi
[ "$rc" -eq 0 ] && echo "lint-shell: ok ($total baselined findings, none new)"
exit "$rc"
