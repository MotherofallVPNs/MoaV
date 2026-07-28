#!/bin/bash
# Golden-diff gate for Workstream C (unified config loader).
#
# The repo resolves .env values two ways: ~42 ad-hoc `grep|cut|tr` scrapers in
# scripts/, and the single `get_env_val` accessor used 203x in lib/. C1 migrates
# the scrapers onto the accessor -- which CHANGES RESOLVED VALUES in several
# cases. This test pins exactly which, so the migration is a reviewed set of
# deliberate fixes rather than a silent semantic drift.
#
# Every difference below is the accessor being MORE correct. The point is that
# they are enumerated and expected, not discovered later in a bundle.
set -uo pipefail

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ENV="$TMP/.env"

# The accessor under consideration (verbatim from moav.sh:234).
get_env_val() {
    local key="$1" file="$2" default="${3:-}"
    local val
    val=$(grep "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d'=' -f2- | sed 's/#.*//' | tr -d '"' | tr -d "'" | xargs) || true
    echo "${val:-$default}"
}

# The dominant legacy shape (15 of the 42 sites).
legacy() {
    local key="$1" file="$2"
    grep -E "^${key}=" "$file" 2>/dev/null | cut -d= -f2 | tr -d '"'
}

echo "env resolution: legacy scraper vs get_env_val"

# case: key, .env line(s), expectation
check() {
    local desc="$1" key="$2" expect_same="$3"; shift 3
    : > "$ENV"; for l in "$@"; do printf '%s\n' "$l" >> "$ENV"; done
    local old new
    old=$(legacy "$key" "$ENV"); new=$(get_env_val "$key" "$ENV")
    if [[ "$expect_same" == "same" ]]; then
        [[ "$old" == "$new" ]] && ok "$desc — identical [$new]" \
                               || bad "$desc — DIVERGED old=[$old] new=[$new] (unexpected)"
    else
        if [[ "$old" != "$new" ]]; then
            ok "$desc — differs as expected: old=[$old] -> new=[$new]"
        else
            bad "$desc — expected a difference (the accessor should fix this) but both gave [$old]"
        fi
    fi
}

# --- cases where behaviour MUST be preserved -------------------------------
check "plain value"                 FOO same "FOO=bar"
check "double-quoted value"         FOO same 'FOO="bar"'
check "empty value"                 FOO same "FOO="
check "missing key"                 FOO same "OTHER=x"
check "value with a dash"           FOO same "FOO=a-b-c"

# --- cases where the accessor is deliberately DIFFERENT (i.e. correct) -----
# Base64/PSKs contain '='. `cut -d= -f2` truncates at the first one, silently
# corrupting keys; `-f2-` keeps the whole value.
check "value containing '=' (base64 padding)"  FOO differ "FOO=YWJjZGVm=="
check "inline comment"                          FOO differ "FOO=bar   # a note"
check "single-quoted value"                     FOO differ "FOO='bar'"
check "duplicate keys (last should win)"        FOO differ "FOO=first" "FOO=second"
check "leading/trailing whitespace"             FOO differ "FOO=  bar  "

# --- the truncation bug, stated explicitly ---------------------------------
: > "$ENV"; echo 'SS_PSK=c29tZXNlY3JldA==' >> "$ENV"
old=$(legacy SS_PSK "$ENV"); new=$(get_env_val SS_PSK "$ENV")
[[ "$new" == "c29tZXNlY3JldA==" ]] && ok "accessor preserves a base64 PSK intact" \
                                   || bad "accessor mangled the PSK: [$new]"
[[ "$old" != "c29tZXNlY3JldA==" ]] && ok "legacy scraper DOES truncate it: [$old]" \
                                   || bad "legacy scraper unexpectedly preserved it"

# --- the accessor must be available to BOTH trees before C1 can land -------
# lib/ (host CLI) and scripts/ (container) are separate source trees; the
# accessor currently lives in moav.sh, which scripts/ never sources.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The credential-bearing sites must NOT use the truncating scraper. A
# MAHSANET_API_KEY containing '=' (base64 keys routinely do) was silently cut
# short, producing auth failures that look like "wrong key".
for f in lib/donate.sh moav.sh; do
    if grep -qE "grep -E \"\\^(MAHSANET_API_KEY|ADMIN_PASSWORD)=\".*cut -d= -f2" "$ROOT/$f"; then
        bad "$f still reads a credential with the truncating 'cut -d= -f2' scraper"
    else
        ok "$f reads credentials via the accessor (no '=' truncation)"
    fi
done

# NOTE (not a failure): get_env_val currently lives in moav.sh, so only the lib/
# tree can call it. Migrating the scripts/ (container) scrapers in C1 proper
# requires hoisting it into a shared location first. Recorded so the sequencing
# is explicit rather than discovered mid-migration.
if grep -q '^get_env_val()' "$ROOT/scripts/lib/common.sh" 2>/dev/null; then
    ok "get_env_val available to scripts/ (container tree) — C1 can migrate those too"
else
    ok "get_env_val is lib/-only for now (C1 must hoist it before touching scripts/)"
fi

echo
echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]
