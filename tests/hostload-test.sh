#!/bin/bash
# Regression test: `moav doctor host` must state the things that took four rounds
# of hand-run commands to establish on two live servers.
#
# The blr1 box: load 1.00 on 1 vCPU, 681 MiB swapped, 39 zombies (28 of them under
# the admin container's python), and moav-conduit -- a bandwidth-donation service
# capped at half that machine -- as the busiest container. None of that was
# visible from `moav doctor`; it came from uptime, top, docker stats and a ps
# pipeline for the zombie parents.
#
# The probes are stubbed, so this tests the reporting logic and not the CI runner.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "doctor host: load, swap and zombie reporting"

# Drive hostload_status with fixed probe values.
# <ncpu> <load1> <swap_used_mib> <swap_total_mib> <zombie-ppids...> ; TOP=<name cpu%>
run_host() {
    # T_ prefix: hostload_status declares its own `local ncpu` / `local zppids`,
    # and bash's dynamic scoping means those shadow anything the stubs would read.
    local T_NCPU="$1" T_LOAD="$2" T_SWUSED="$3" T_SWTOTAL="$4"; shift 4
    local T_ZPPIDS="$*"
    (
        GREEN=''; YELLOW=''; RED=''; DIM=''; NC=''; WHITE=''; CYAN=''
        # shellcheck disable=SC1091
        source "$ROOT/scripts/lib/common.sh" >/dev/null 2>&1
        # shellcheck disable=SC1091
        source "$ROOT/lib/hostload.sh"
        host_metrics_available() { return 0; }
        host_ncpu()           { echo "$T_NCPU"; }
        host_load1()          { echo "$T_LOAD"; }
        host_swap_used_mib()  { echo "$T_SWUSED"; }
        host_swap_total_mib() { echo "$T_SWTOTAL"; }
        host_mem_avail_mib()  { echo 851; }
        host_zombie_ppids()   { [[ -n "$T_ZPPIDS" ]] && printf '%s\n' $T_ZPPIDS; }
        host_proc_name()      { echo "python"; }
        host_top_container()  { echo "${TOP:-}"; }
        hostload_status 2>&1
        echo "RC=$?"
    )
}

# --- the blr1 shape ----------------------------------------------------------
# 39 zombies, 28 of them under PID 843463 (the admin container's python).
zom="843463 843463 843463 843463 843463 843463 843463 843463 843463 843463"
zom="$zom 843463 843463 843463 843463 843463 843463 843463 843463 843463 843463"
zom="$zom 843463 843463 843463 843463 843463 843463 843463 843463"
zom="$zom 388303 388303 388303 388303 388303 388303 388303 388303 388303 388303 388303"

out=$(TOP="moav-conduit 29.19%" run_host 1 1.00 681 2048 $zom)

printf '%s' "$out" | grep -q 'load 1.00 on 1 vCPU' \
    && ok "reports load against the core count" \
    || bad "did not state load vs vCPU: $(printf '%s' "$out" | tr '\n' '|')"

printf '%s' "$out" | grep -q 'moav-conduit' \
    && ok "names the busiest container" \
    || bad "did not name the busiest container"

printf '%s' "$out" | grep -qi 'donates bandwidth' \
    && ok "calls out that the busiest container is a donation service" \
    || bad "did not flag moav-conduit as a donation service on a saturated host"

printf '%s' "$out" | grep -q '681 MiB swapped' \
    && ok "reports swap in use" \
    || bad "did not report swap"

printf '%s' "$out" | grep -q '39 zombie' \
    && ok "counts zombies" \
    || bad "wrong zombie count: $(printf '%s' "$out" | grep -i zombie | tr '\n' '|')"

printf '%s' "$out" | grep -q 'PID 843463' \
    && ok "names the parent holding the most zombies" \
    || bad "did not name the worst zombie parent — 'restart something' is not actionable"

printf '%s' "$out" | grep -q 'RC=1' \
    && ok "fails the check so 'moav doctor' surfaces it" \
    || bad "returned success on a saturated, swapping host with 39 zombies"

# --- a healthy host must stay quiet ------------------------------------------
out_ok=$(TOP="moav-sing-box 2.07%" run_host 4 0.35 0 0)
printf '%s' "$out_ok" | grep -q 'RC=0' \
    && ok "a healthy host passes" \
    || bad "flagged a healthy host: $(printf '%s' "$out_ok" | tr '\n' '|')"
printf '%s' "$out_ok" | grep -qi 'donates bandwidth' \
    && bad "lectured about donation services on an idle host" \
    || ok "stays quiet about donation services when there is headroom"

# --- and the thresholds must actually be thresholds --------------------------
# Without this, a check that always warns would pass everything above.
out_near=$(TOP="moav-xray 4.60%" run_host 2 1.50 0 2048)
printf '%s' "$out_near" | grep -q 'little headroom' \
    && ok "0.75x load per core reads as 'little headroom', not saturated" \
    || bad "no distinction between near-capacity and over: $(printf '%s' "$out_near" | tr '\n' '|')"
printf '%s' "$out_near" | grep -q 'RC=0' \
    && ok "near-capacity alone does not fail the check" \
    || bad "'little headroom' failed the check — every busy server would look broken"

# Swap just under the threshold must not warn.
out_sw=$(run_host 4 0.10 64 2048)
printf '%s' "$out_sw" | grep -q 'RC=0' \
    && ok "64 MiB of swap is not reported as pressure" \
    || bad "64 MiB of swap failed the check"

# --- wiring: every doctor check must resolve to a real function ---------------
# `moav doctor` calls "doctor_check_${name}" by string, so a name in the list
# with no function is a runtime "command not found" for that check only -- and
# nothing else in the suite looks for it.
while IFS= read -r name; do
    [ -n "$name" ] || continue
    if grep -rqE "^doctor_check_${name}\\(\\)" "$ROOT"/lib/*.sh; then
        ok "doctor check '$name' resolves to a function"
    else
        bad "doctor check '$name' is listed but doctor_check_${name}() is not defined"
    fi
done < <(sed -n '/^DOCTOR_CHECKS=(/,/^)/p' "$ROOT/lib/doctor.sh" \
         | grep -oE '"[a-z_]+:' | tr -d '":')

# hostload.sh must be sourced before doctor.sh, like nettune.sh and peers.sh:
# doctor.sh's list names the check, the implementation lives elsewhere.
hl=$(grep -nE '^source .*lib/hostload\.sh' "$ROOT/moav.sh" | head -1 | cut -d: -f1)
dr=$(grep -nE '^source .*lib/doctor\.sh'   "$ROOT/moav.sh" | head -1 | cut -d: -f1)
if [ -n "$hl" ] && [ -n "$dr" ] && [ "$hl" -lt "$dr" ]; then
    ok "moav.sh sources hostload.sh before doctor.sh"
else
    bad "hostload.sh is sourced after doctor.sh (or not at all): hl=${hl:-none} dr=${dr:-none}"
fi

echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
