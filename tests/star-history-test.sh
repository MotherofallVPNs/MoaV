#!/bin/bash
# Regression test: the stargazers call must send an explicit API version, and it
# must refuse to chart a response that has no timestamps.
#
# The nightly workflow 403'd on /stargazers. Two wrong diagnoses came first:
# "the token needs more permissions" (it does not -- a fine-grained PAT cannot
# read this endpoint at any permission level), and "it needs the API version
# header" (the command that appeared to prove that was run with a personal login,
# not the token, so the credential was the difference, not the header).
#
# The fix is to stop needing that endpoint. The chart is built from
# assets/star-history.json, appended to from the repo object's stargazers_count:
# public, unauthenticated, unaffected by the restriction. /stargazers is now only
# an optional backfill of history from before that file existed.
#
# What must not regress:
#   - a 403, or no gh at all, still produces a chart and exits 0
#   - the history file is the input, so it must be written
#   - a flat day writes nothing, or the workflow opens a PR every night
#   - if timestamps ARE readable they win, and they must carry starred_at
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
# fetch_count: the public repo object. Answers regardless of MODE, because a 403
# on /stargazers must not stop the count path.
if [[ "$*" == *".stargazers_count"* ]]; then
    echo "${STUB_COUNT:-11}"; exit 0
fi
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
    STAR_DATA="$TMP/assets/store.json" \
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

# --- 2. a response without timestamps must not be charted as history ---------
# The trap in copying the docs' plain-Accept example: it returns stargazers with
# no starred_at, and charting those collapses every point onto one date.
out_undated=$(run_gen undated)
printf '%s' "$out_undated" | grep -q 'no starred_at' \
    && ok "a response with no starred_at is called out by name" \
    || bad "silently accepted a response with no timestamps — the chart would be a flat line"

# --- 3. a 403 must NOT fail the run any more ---------------------------------
# This is the nightly failure. The count path has to carry it.
printf '{"acme/one":{"source":"counts","updated":"2026-08-01","points":[["2026-08-01",10],["2026-08-02",11]]}}\n' \
    > "$TMP/assets/store.json"
out_403=$(run_gen forbidden)
printf '%s' "$out_403" | grep -q 'RC=0' \
    && ok "a 403 on /stargazers no longer fails the run" \
    || bad "still exits non-zero on 403 — the workflow keeps failing nightly: $(printf '%s' "$out_403" | tr '\n' '|' | tail -c 200)"
printf '%s' "$out_403" | grep -qi 'NOT a failure' \
    && ok "the note says plainly that this is not a failure" \
    || bad "the 403 note still reads like an error"
printf '%s' "$out_403" | grep -qi 'permission' \
    && bad "the note still sends the operator to token permissions — that was the wrong turn twice" \
    || ok "the note does not blame permissions"
[ -s "$TMP/assets/out.svg" ] \
    && ok "a chart is still rendered from the stored history" \
    || bad "no chart written despite having stored history"

# --- 3b. the count path: flat day writes nothing, a move appends -------------
store_points() { python3 -c "
import json;print(len(json.load(open('$TMP/assets/store.json'))['acme/one']['points']))"; }
write_store() { printf '{"acme/one":{"source":"counts","updated":"2026-08-01","points":[["2026-08-01",10],["2026-08-02",11]]}}\n' > "$TMP/assets/store.json"; }

write_store
STUB_COUNT=11 run_gen forbidden >/dev/null 2>&1
[ "$(store_points)" = "2" ] \
    && ok "an unchanged count adds no point (no nightly PR churn)" \
    || bad "a flat day grew the store to $(store_points) points — the workflow would open a PR every night"

write_store
STUB_COUNT=25 run_gen forbidden >/dev/null 2>&1
if [ "$(store_points)" = "3" ]; then
    got=$(python3 -c "
import json;print(json.load(open('$TMP/assets/store.json'))['acme/one']['points'][-1][1])")
    [ "$got" = "25" ] \
        && ok "a changed count is appended (the chart grows without any credential)" \
        || bad "appended the wrong value ($got, expected 25)"
else
    bad "a moved count did not append a point — history would never accumulate"
fi

# --- 3c. history from an unmerged chart PR must not be dropped ---------------
# The workflow resets chore/star-history from main every run, so points that
# accumulated while its PR sat unmerged live only on that branch. Without the
# fold-in, each day's PR carries main+1 point and the days between are lost.
printf '{"acme/one":{"source":"counts","updated":"2026-08-11","points":[["2026-08-10",10],["2026-08-11",11]]}}\n' \
    > "$TMP/assets/store.json"
printf '{"acme/one":{"source":"counts","updated":"2026-08-12","points":[["2026-08-10",10],["2026-08-11",11],["2026-08-12",20]]}}\n' \
    > "$TMP/assets/unmerged.json"
STUB_COUNT=30 STAR_DATA_MERGE="$TMP/assets/unmerged.json" run_gen forbidden >/dev/null 2>&1
carried=$(python3 -c "
import json;pts=json.load(open('$TMP/assets/store.json'))['acme/one']['points']
print('yes' if ['2026-08-12',20] in pts else 'no', len(pts))")
case "$carried" in
    "yes 4") ok "points from an unmerged chart PR are carried into the new run" ;;
    *)       bad "unmerged history was dropped ($carried) — an open PR loses a point a day" ;;
esac

# --- 3d. the publish path: a branch, no PR, and the history read back --------
WF="$ROOT/.github/workflows/star-history.yml"
grep -q 'git push -q --force' "$WF" && grep -q ' chart$' "$WF" \
    && ok "the workflow force-pushes the chart branch" \
    || bad "the workflow no longer publishes to the chart branch"
grep -q 'gh pr create' "$WF" \
    && bad "still opens a PR — the chart is meant to update itself daily" \
    || ok "no PR is opened"
grep -q 'origin/chart:star-history.json' "$WF" \
    && ok "the run reads the accumulated history back before appending" \
    || bad "the history is never read back — every run would start from one point"
grep -q 'cmp -s' "$WF" \
    && ok "an unchanged chart is not republished" \
    || bad "no no-op guard — the branch would get a commit every night regardless"

# --- 3e. the README link is gated ------------------------------------------
# A renamed branch or file leaves a broken image in the README, which nobody
# notices because the old URL keeps serving a cached copy for a while.
#
# --check reads README.md from the working directory, so this runs in a copy. The
# earlier version of this test edited the repo's own README and restored it after,
# which would have left it broken if the test were interrupted.
linkdir=$(mktemp -d)
cp "$ROOT/README.md" "$linkdir/README.md"
if (cd "$linkdir" && python3 "$SCRIPT" --check >/dev/null 2>&1); then
    ok "--check passes with the README pointing at the publish location"
else
    bad "--check fails against the committed README"
fi
sed 's|refs/heads/chart/star-history.svg|assets/star-history.svg|' \
    "$ROOT/README.md" > "$linkdir/README.md"
if cmp -s "$ROOT/README.md" "$linkdir/README.md"; then
    bad "could not build the broken-README fixture — has the link format changed?"
elif (cd "$linkdir" && python3 "$SCRIPT" --check >/dev/null 2>&1); then
    bad "--check accepted a README pointing at a path the workflow never writes"
else
    ok "--check catches a README that no longer matches the publish location"
fi
rm -rf "$linkdir"

# --- 4. and the stub is actually exercising the real call --------------------
# Without this, a stub that never ran would make every check above vacuous.
grep -q 'repos/acme/one/stargazers' "$TMP/argv.log" \
    && ok "the stub saw the real stargazers request" \
    || bad "gh was never called with the stargazers path — the checks prove nothing"

echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
