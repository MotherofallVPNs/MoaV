#!/bin/bash
# Regression test: doctor net must decide for itself whether drops are ongoing.
#
# The kernel's counters are since-boot and never reset, so after `moav net apply`
# fixed the cause, doctor kept printing the same warning for ever and told the
# operator to run nstat twice, 10s apart, and diff it by eye. That is doctor's
# job, and a warning that cannot go away trains people to ignore warnings.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "doctor net: is the drop still happening?"

# nt_proc_counter is called through $(...), so each call is its own subshell and
# an in-memory call counter would reset every time. State goes in a file.
run_case() {  # <before> <after>
    local state="/tmp/moav-drop-calls.$$"
    rm -f "$state"
    ( GREEN=""; YELLOW=""; NC=""; DIM=""
      source "$ROOT/lib/nettune.sh"
      BEFORE="$1"; AFTER="$2"; STATE="$state"
      nt_proc_counter() {
          case "$2" in
              SndbufErrors)
                  local n; n=$(cat "$STATE" 2>/dev/null || echo 0)
                  echo $((n + 1)) > "$STATE"
                  if [ "$n" -lt 1 ]; then echo "$BEFORE"; else echo "$AFTER"; fi ;;
              *) echo 0 ;;
          esac
      }
      MOAV_DROP_SAMPLE_SECONDS=0 nt_check_drops; echo "RC=$?" )
    rm -f "$state"
}

# --- fixed, but the total is still on the books -------------------------------
out=$(run_case 228993 228993)
grep -q "not happening now" <<<"$out" \
    && ok "a stale since-boot total is reported as no longer happening" \
    || bad "a fixed problem still reads as a live warning: $out"
grep -q "RC=0" <<<"$out" \
    && ok "and it stops failing the check" \
    || bad "stale counters keep doctor red for ever: $out"

# --- still climbing -----------------------------------------------------------
out=$(run_case 228993 229500)
if grep -q "+507 in" <<<"$out" && ! grep -q "not happening now" <<<"$out"; then
    ok "a counter still climbing is reported as live, with the delta"
else
    bad "an ongoing drop was not flagged: $out"
fi
grep -q "RC=1" <<<"$out" \
    && ok "and it fails the check" \
    || bad "an ongoing drop did not fail doctor: $out"
grep -q "moav net apply" <<<"$out" \
    && ok "the fix command is named on a live drop" \
    || bad "no fix hint on a live drop: $out"

# --- quiet host ---------------------------------------------------------------
out=$(run_case 0 0)
grep -q "No notable packet drops" <<<"$out" \
    && ok "a clean host says so and skips the sampling pause" \
    || bad "a clean host did not take the fast path: $out"

# --- a failing sysctl must name its fix too -----------------------------------
grep -q "Fix all of the above: moav net apply" "$ROOT/lib/nettune.sh" \
    && ok "a failing sysctl check names the fix command" \
    || bad "sysctl failures leave the operator to infer the fix"

echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
