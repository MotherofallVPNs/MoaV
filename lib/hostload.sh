#!/bin/bash
# lib/hostload.sh — host saturation: CPU load, swap pressure, zombies, and which
# container is eating the box. Read-only.
#
# WHY THIS EXISTS. Diagnosing "REALITY feels slow" on two live servers took four
# rounds of hand-run commands (uptime, top, docker stats, ps for zombie parents)
# before the picture showed up: one box at load 1.00 on a single vCPU with 681 MiB
# swapped, a bandwidth-donation container capped at half that machine, and 39
# zombies. Every one of those is a one-line probe.
#
# The probes are separate functions so tests can drive the reporting logic with
# fixed values instead of whatever the CI runner happens to be doing.

# A probe like the others so tests can drive the reporting on a non-Linux box.
host_metrics_available() { [[ -r /proc/loadavg && -r /proc/meminfo ]]; }

host_ncpu()  { nproc 2>/dev/null || echo 1; }
host_load1() { awk '{print $1+0}' /proc/loadavg 2>/dev/null || echo 0; }

# Used swap in MiB. 0 when there is no swap device.
host_swap_used_mib() {
    awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{printf "%d", (t>0 ? (t-f)/1024 : 0)}' \
        /proc/meminfo 2>/dev/null || echo 0
}
host_swap_total_mib() {
    awk '/^SwapTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0
}
host_mem_avail_mib() {
    awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0
}

# PPIDs of every zombie, one per line.
host_zombie_ppids() { ps -eo stat=,ppid= 2>/dev/null | awk '$1 ~ /^Z/ {print $2}'; }
host_proc_name()    { ps -p "$1" -o comm= 2>/dev/null | tr -d ' '; }

# "<name> <cpu%>" of the busiest container, empty if docker is unreachable.
# Bounded: docker stats on a wedged daemon otherwise hangs the whole doctor run.
host_top_container() {
    local t=""
    command -v timeout >/dev/null 2>&1 && t="timeout 8"
    $t docker stats --no-stream --format '{{.Name}} {{.CPUPerc}}' 2>/dev/null \
        | sort -k2 -hr | head -1
}

# Services that exist to donate bandwidth to other people. They compete with the
# operator's own traffic, so naming them when the box is saturated is the point.
HOSTLOAD_DONATION_CONTAINERS="moav-conduit moav-snowflake moav-tor"

# Returns 0 = healthy, 1 = something to act on, 2 = not a Linux host.
hostload_status() {
    host_metrics_available || {
        echo -e "    ${YELLOW}○${NC} Host metrics unavailable (no /proc) — skipped"
        return 2
    }

    local pass=true ncpu load1 top_line top_name top_cpu
    ncpu=$(host_ncpu); load1=$(host_load1)
    top_line=$(host_top_container)
    top_name="${top_line%% *}"; top_cpu="${top_line##* }"

    # awk, not [[ ]]: load1 is a float and bash cannot compare those.
    local verdict
    verdict=$(awk -v l="$load1" -v n="$ncpu" 'BEGIN{ print (l >= n ? "over" : (l >= n*0.7 ? "near" : "ok")) }')
    case "$verdict" in
        over)
            echo -e "    ${YELLOW}!${NC} load $load1 on $ncpu vCPU — the run queue is full"
            [[ -n "$top_name" ]] && echo -e "      ${DIM}Busiest container: $top_name ($top_cpu)${NC}"
            pass=false
            ;;
        near)
            echo -e "    ${YELLOW}○${NC} load $load1 on $ncpu vCPU — little headroom"
            [[ -n "$top_name" ]] && echo -e "      ${DIM}Busiest container: $top_name ($top_cpu)${NC}"
            ;;
        *)
            echo -e "    ${GREEN}✓${NC} load $load1 on $ncpu vCPU"
            ;;
    esac

    # A donation service on a small host is the operator paying for strangers'
    # traffic with their own users' latency. Only worth saying when it is winning.
    if [[ "$verdict" != "ok" && -n "$top_name" ]]; then
        case " $HOSTLOAD_DONATION_CONTAINERS " in
            *" $top_name "*)
                echo -e "      ${DIM}$top_name donates bandwidth to other people and is capped at half a core.${NC}"
                echo -e "      ${DIM}On a $ncpu-vCPU host, stop it and re-test before tuning anything else.${NC}"
                ;;
        esac
    fi

    local swap_used swap_total mem_avail
    swap_used=$(host_swap_used_mib); swap_total=$(host_swap_total_mib)
    mem_avail=$(host_mem_avail_mib)
    if [[ "$swap_total" -eq 0 ]]; then
        echo -e "    ${GREEN}✓${NC} no swap configured (${mem_avail} MiB RAM available)"
    elif [[ "$swap_used" -gt 64 ]]; then
        echo -e "    ${YELLOW}!${NC} ${swap_used} MiB swapped out (${mem_avail} MiB RAM available)"
        echo -e "      ${DIM}Swap I/O shows up as latency on every connection. Drop a heavy${NC}"
        echo -e "      ${DIM}optional profile — monitoring costs ~400 MiB of the three containers.${NC}"
        pass=false
    else
        echo -e "    ${GREEN}✓${NC} ${swap_used} MiB swapped (${mem_avail} MiB RAM available)"
    fi

    local zppids zcount
    zppids=$(host_zombie_ppids)
    zcount=$(printf '%s' "$zppids" | grep -c . 2>/dev/null || true)
    zcount="${zcount:-0}"
    if [[ "$zcount" -gt 5 ]]; then
        # Name the parent: a zombie is reaped by its parent, so the parent is the
        # bug. "Restart the container" is only the fix once you know which one.
        local worst
        worst=$(printf '%s\n' "$zppids" | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
        local wname; wname=$(host_proc_name "$worst")
        echo -e "    ${YELLOW}!${NC} $zcount zombie process(es), most under PID $worst (${wname:-gone})"
        echo -e "      ${DIM}That parent is not reaping. If it is a MoaV container, recreate it:${NC}"
        echo -e "      ${DIM}moav start   # docker compose up -d; 'moav restart' keeps the old config${NC}"
        pass=false
    else
        echo -e "    ${GREEN}✓${NC} $zcount zombie process(es)"
    fi

    $pass && return 0 || return 1
}

doctor_check_host() {
    hostload_status
}
