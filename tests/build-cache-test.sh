#!/bin/bash
# Regression test: the build-cache cap, exercised through prune_build_cache
# rather than through the sizing function.
#
# The first version of this feature was dead code: an earlier line already set
# MOAV_BUILD_CACHE_KEEP=4GB, so the `[[ -n ... ]] ||` guard never called the
# sizing function. A test that called default_cache_keep directly passed anyway.
# So this drives the real entry point and asserts what reaches `docker builder`.
#
# Intent of the sizing: hold the whole stack's layers when there is room (MoaV's
# in-use images are ~1.9 GB on a full install, and their cache is the same
# order), and only give ground when the disk is genuinely tight.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "build cache: the cap reaching docker builder prune"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/docker" <<'STUB'
#!/bin/bash
case "$*" in
  "system df") printf 'TYPE\tTOTAL\tACTIVE\tSIZE\tRECLAIMABLE\nBuild Cache\t234\t0\t%s\t2.1GB\n' "${FAKE_CACHE:-3.9GB}" ;;
  *"builder prune"*) echo "$*" >> "$ARGS_LOG"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
cat > "$TMP/df" <<'STUB'
#!/bin/bash
echo "Filesystem 1M-blocks Used Available Use% Mounted"
echo "/dev/vda1 24000 19000 ${FAKE_FREE:-4300} 82% /"
STUB
chmod +x "$TMP/docker" "$TMP/df"

cap_for() {   # <free MB> <cache size> [override] -> the MB value passed to docker
    : > "$TMP/args"
    (
        PATH="$TMP:$PATH" FAKE_FREE="$1" FAKE_CACHE="$2" ARGS_LOG="$TMP/args" \
        MOAV_BUILD_CACHE_KEEP="${3:-}" \
        bash -c 'cd "$0"
                 # shellcheck disable=SC1091
                 source scripts/lib/common.sh >/dev/null 2>&1
                 # shellcheck disable=SC1091
                 source lib/common.sh >/dev/null 2>&1
                 # shellcheck disable=SC1091
                 source lib/build.sh  >/dev/null 2>&1
                 prune_build_cache' "$ROOT" >/dev/null 2>&1
    )
    grep -oE 'keep-storage [0-9A-Za-z]+' "$TMP/args" | head -1 | awk '{print $2}'
}

got=$(cap_for 4300 3.9GB)
[ "$got" = "4096MB" ] \
    && ok "room on disk keeps the full 4 GB (the stack's layers stay warm)" \
    || bad "with 4.3 GB free it capped at '$got', expected 4096MB — rebuilds would lose cache"

got=$(cap_for 1000 1GB)
[ "$got" = "1024MB" ] \
    && ok "a tight disk shrinks the cap to the 1 GB floor" \
    || bad "with 1 GB free it kept '$got' — the cache would crowd the disk"

got=$(cap_for 40000 500MB)
[ "$got" = "4096MB" ] \
    && ok "a large disk is still capped at 4 GB" \
    || bad "unbounded growth on a large disk: '$got'"

# Idempotence: counting the existing cache as available is what stops the cap
# ratcheting down on every run.
a=$(cap_for 4300 3.9GB); b=$(cap_for 4300 3.9GB)
[ "$a" = "$b" ] && ok "repeated runs converge on the same cap ($a)" \
                || bad "the cap moved between identical runs: $a then $b"

# An operator override must win outright.
got=$(cap_for 4300 3.9GB "777MB")
[ "$got" = "777MB" ] \
    && ok "MOAV_BUILD_CACHE_KEEP overrides the computed value" \
    || bad "override ignored: got '$got'"

# And the sizing must actually be reached from prune_build_cache -- the exact
# bug this file exists for.
grep -q 'MOAV_BUILD_CACHE_KEEP="${MOAV_BUILD_CACHE_KEEP:-4GB}"' "$ROOT/lib/build.sh" \
    && bad "a hardcoded 4GB default is back; it makes default_cache_keep unreachable" \
    || ok "no hardcoded default shadowing the sizing function"

echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
