#!/bin/bash
# Regression test: the stargazers call must send an explicit API version, and it
# must refuse to chart a response that has no timestamps.
#
# The workflow failed with HTTP 403 on both repos. It was read as a permissions
# problem and more permissions were added to the token for an afternoon; the
# actual fix was the header GitHub's own docs use:
#
#   -H "X-GitHub-Api-Version: 2026-03-10"
#
# The trap in "just copy the working curl": the docs example also uses
# `Accept: application/vnd.github+json`, which returns stargazers WITHOUT
# starred_at. This script needs the timestamps -- without them every point
# collapses and the chart renders a flat line that looks like the repo stopped
# being starred. So the star media type stays, and a response with no starred_at
# is an error rather than an empty series.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/gen-star-history.py"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "star history: API version header + timestamp requirement"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/assets"

# A `gh` that records its argv and replies with whatever MODE asks for.
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$ARGV_LOG"
case "${MODE:-dated}" in
    dated)                 # what the star media type returns
        if [[ "$*" == *"page=1"* ]]; then
            echo '[{"starred_at":"2025-01-01T00:00:00Z","user":{"login":"a"}},'
            echo ' {"starred_at":"2025-06-01T00:00:00Z","user":{"login":"b"}}]'
        else
            echo '[]'
        fi ;;
    undated)               # what the PLAIN media type returns: no timestamps
        if [[ "$*" == *"page=1"* ]]; then
            echo '[{"login":"a","id":1},{"login":"b","id":2}]'
        else
            echo '[]'
        fi ;;
    forbidden)
        echo "gh: Resource not accessible by personal access token (HTTP 403)" >&2
        exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/gh"

run_gen() {   # <mode> -> combined output; exit code in RC file
    ARGV_LOG="$TMP/argv.log" MODE="$1" \
    PATH="$TMP/bin:$PATH" \
    STAR_REPOS="acme/one" STAR_OUT="$TMP/assets/out.svg" STAR_LOGO="$TMP/none.png" \
        python3 "$SCRIPT" 2>&1
    echo "RC=$?"
}

# --- 1. the version header must be on the wire -------------------------------
: > "$TMP/argv.log"
out=$(run_gen dated)
if grep -q 'X-GitHub-Api-Version:' "$TMP/argv.log"; then
    ok "the stargazers call sends X-GitHub-Api-Version"
else
    bad "no API version header — the endpoint 403s even with a fully permitted token"
fi
if grep -q 'vnd.github.star+json' "$TMP/argv.log"; then
    ok "it still asks for the star media type (the one with starred_at)"
else
    bad "dropped vnd.github.star+json — the response would carry no timestamps"
fi
printf '%s' "$out" | grep -q 'RC=0' \
    && ok "a normal dated response renders" \
    || bad "failed on a valid response: $(printf '%s' "$out" | tr '\n' '|')"

# --- 2. a response without timestamps must be refused, not charted -----------
# This is the failure mode of copying the docs' plain-Accept example.
out_undated=$(run_gen undated)
if printf '%s' "$out_undated" | grep -q 'no starred_at'; then
    ok "a response with no starred_at is called out by name"
else
    bad "silently accepted a response with no timestamps — the chart would be a flat line"
fi
printf '%s' "$out_undated" | grep -q 'RC=0' \
    && bad "exited 0 on a timestampless response — a broken chart would be committed" \
    || ok "exits non-zero rather than committing a chart with no history"

# --- 3. a 403 still names the version header first ---------------------------
out_403=$(run_gen forbidden)
printf '%s' "$out_403" | grep -qi 'API version' \
    && ok "the 403 hint leads with the API version, which is what it was" \
    || bad "the 403 hint still sends the operator to token permissions first"
printf '%s' "$out_403" | grep -q 'starred_at field' \
    && ok "the verify command tells you what a good response looks like" \
    || bad "the verify command does not say what to look for in the output"

# --- 4. and the stub is actually exercising the real call --------------------
# Without this, a stub that never ran would make every check above vacuous.
grep -q 'repos/acme/one/stargazers' "$TMP/argv.log" \
    && ok "the stub saw the real stargazers request" \
    || bad "gh was never called with the stargazers path — the checks prove nothing"

echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
