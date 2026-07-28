#!/bin/bash
# Regression tests for Workstream D (strict-mode / set -u defects).
#
# Each case reproduces a real crash in isolation: the shell fragment is the same
# shape as the production one, run under the same `set -euo pipefail` the real
# scripts use. They are shape tests, not integration tests -- they pin the
# pattern so it cannot be reintroduced.
set -uo pipefail

pass=0; fail=0
ok()   { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "strict-mode regression tests"

# --- 1. paired `read` from a generator that produces no output -----------------
# Guarded form must report the real cause instead of dying on "unbound variable".
out=$(
  set -euo pipefail
  fake_keypair() { return 1; }          # emits nothing, like wg_keypair with no backend
  f() {
      local priv pub
      if ! { read -r priv && read -r pub; } < <(fake_keypair); then
          echo "no-generator"; return 1
      fi
      echo "$pub"
  }
  f || true
) 2>&1
check "guarded read reports the real cause" "$out" "no-generator"

# Control: the unguarded shape must still be broken, or the test above proves
# nothing. How it breaks is bash-version-dependent, so assert the invariant that
# holds everywhere -- the key never arrives:
#
#   bash >= 4.x : `local pub` unassigned is UNSET -> set -u kills the run, loudly
#                 but with a misleading "client_public_key: unbound variable".
#   bash 3.2    : `local pub` unassigned reads as SET-but-empty -> no crash, and
#                 an EMPTY public key gets written into the client config. Worse:
#                 silent, and the peer never works.
#
# Either way the guard is required, so assert "no valid key" rather than "crash".
out=$(
  set -euo pipefail
  fake_keypair() { return 1; }
  f() {
      local priv pub
      { read -r priv && read -r pub; } < <(fake_keypair)
      printf 'present=%s value=[%s]' "${pub+yes}" "${pub:-}"
  }
  f
) 2>&1 || out="crashed:$out"
case "$out" in
    *"unbound variable"*)      ok "unguarded read fails loudly on this bash (>=4.x)";;
    "present=yes value=[]")    ok "unguarded read yields an empty key on this bash (3.2)";;
    *) bad "unguarded read produced something unexpected: '$out'";;
esac

# --- 2. grep|cut under pipefail on empty input ---------------------------------
out=$(
  set -euo pipefail
  content=""
  v=$(echo "$content" | grep KEY | cut -d= -f2 || true)
  echo "survived:${v}"
) 2>&1
check "grep|cut with || true survives empty input" "$out" "survived:"

# --- 3. reality.env is sourced regardless of ENABLE_REALITY --------------------
# XHTTP is VLESS+Reality-over-xhttp and defaults to on, so gating the source on
# ENABLE_REALITY left REALITY_PUBLIC_KEY unset while XHTTP still read it.
gu="$ROOT/scripts/generate-user.sh"
if grep -qE '^\s*if \[\[ "\$\{ENABLE_REALITY:-true\}" == "true" \]\] && \[\[ -f "\$STATE_DIR/keys/reality\.env" \]\]' "$gu"; then
    bad "generate-user.sh still gates reality.env on ENABLE_REALITY (breaks XHTTP)"
else
    ok "generate-user.sh sources reality.env unconditionally"
fi

if grep -q 'require_keys "Reality/XHTTP" REALITY_PUBLIC_KEY REALITY_SHORT_ID' "$gu"; then
    ok "generate-user.sh asserts Reality keys with a remediation hint"
else
    bad "generate-user.sh lost the Reality key assertion"
fi

# --- 4. required-value assertion produces an actionable message ----------------
out=$(
  set -euo pipefail
  STATE_DIR=/state
  log_error() { echo "$*"; }
  require_keys() {
      local why="$1"; shift
      local missing=() v
      for v in "$@"; do [[ -n "${!v:-}" ]] || missing+=("$v"); done
      if (( ${#missing[@]} )); then
          log_error "$why needs ${missing[*]}, which is not in $STATE_DIR/keys/."
          return 1
      fi
  }
  require_keys "Reality/XHTTP" REALITY_PUBLIC_KEY || true
) 2>&1
check "missing key names the variable and the location" \
      "$out" "Reality/XHTTP needs REALITY_PUBLIC_KEY, which is not in /state/keys/."

# --- 5. the guarded read is actually present in both generators ----------------
for f in scripts/lib/wireguard.sh scripts/lib/amneziawg.sh; do
    if grep -q 'if ! { read -r client_private_key && read -r client_public_key; }' "$ROOT/$f"; then
        ok "$f guards the paired keypair read"
    else
        bad "$f has an unguarded paired keypair read"
    fi
done

# --- 6. flags that take a value must reject a missing one ---------------------
# `moav logs --tail` / `moav update -b` used to die on a bare "$2" with
# "$2: unbound variable" and no usage hint.
for spec in "lib/service.sh:--tail requires a value" "lib/update.sh:-b/--branch requires a branch name"; do
    f="${spec%%:*}"; msg="${spec#*:}"
    if grep -qF -- "$msg" "$ROOT/$f"; then ok "$f validates its flag argument"
    else bad "$f does not validate its flag argument"; fi
done

# The guards must call a helper that actually exists in these modules. `lib/`
# defines error(), not log_error() -- using the wrong one turned a clean message
# back into "log_error: command not found".
if grep -q 'log_error' "$ROOT/lib/service.sh" "$ROOT/lib/update.sh"; then
    bad "lib/ modules call log_error(), which is a scripts/lib helper -- use error()"
else
    ok "lib/ modules use the error() helper they actually define"
fi

# --- 7. bash version guard ----------------------------------------------------
# declare -A is a bash 4 builtin option; on bash 3.2 it failed with
# "declare: -A: invalid option". The guard must itself parse under 3.2.
if grep -q 'BASH_VERSINFO' "$ROOT/moav.sh"; then
    ok "moav.sh guards on bash version"
else
    bad "moav.sh has no bash-version guard but uses declare -A"
fi
if command -v /bin/bash >/dev/null && [[ "$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}')" -lt 4 ]]; then
    out=$(/bin/bash "$ROOT/moav.sh" version 2>&1 | head -1)
    case "$out" in *"requires bash 4"*) ok "bash 3.2 gets an actionable message";;
                    *) bad "bash 3.2 got: '$out'";; esac
else
    ok "system bash is >= 4 (3.2 message path not exercised here)"
fi

echo
echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]
