#!/bin/bash
# lib/nettune.sh — kernel network tuning (BBR + socket buffers + queue depth) and
# the `moav net` command. Rationale and sources: the OPSEC guide.
#
# Sourced by moav.sh BEFORE lib/doctor's checks: `doctor_check_net` calls
# nt_status / nt_check_pmtu / nt_check_drops / nt_check_cgnat / nt_check_mtu.
# (Modules are sourced into one shell, so definition order only matters for
# top-level code — but keep the documented order anyway.)
#
# Definitions only — nothing here runs at source time.

NT_CONF_PATH="/etc/sysctl.d/99-moav-net.conf"

# Returns 0 if the kernel can use BBR. tcp_bbr is a module on most distros —
# modprobe first, otherwise OpenVZ / pre-4.9 kernels both fail cleanly.
nt_kernel_supports_bbr() {
    local avail
    avail=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "")
    if [[ " $avail " != *" bbr "* ]]; then
        local SUDO=""
        [[ "$(id -u)" -ne 0 ]] && command -v sudo &>/dev/null && SUDO="sudo"
        $SUDO modprobe tcp_bbr 2>/dev/null || true
        avail=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "")
    fi
    [[ " $avail " == *" bbr "* ]]
}

# 16 MiB on <2 GB RAM hosts, 32 MiB otherwise (quic-go floor is 7.5 MiB).
nt_buffer_max() {
    local total_mb
    total_mb=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    if [[ "$total_mb" -gt 0 && "$total_mb" -lt 2048 ]]; then
        echo 16777216   # 16 MiB
    else
        echo 33554432   # 32 MiB
    fi
}

# Human byte formatter: KiB under 1 MiB, else integer MiB. Keeps a 208 KiB
# kernel default from printing as a confusing "0 MiB".
nt_fmt_bytes() {
    local b="${1:-0}"
    if [[ "$b" -lt 1048576 ]]; then
        echo "$((b / 1024)) KiB"
    else
        echo "$((b / 1048576)) MiB"
    fi
}

# Render the sysctl bundle to stdout. Caller writes it to NT_CONF_PATH.
# bmax = max for {r,w}mem_max + tcp_{r,w}mem high bound.
nt_render_config() {
    local bmax="$1"
    cat <<EOF
# MoaV network tuning — generated $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# Reversible: moav net revert. Docs: https://moav.sh/docs/OPSEC → "Network tuning".

# BBR needs fq for pacing.
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc          = fq

net.core.rmem_max               = ${bmax}
net.core.wmem_max               = ${bmax}
net.ipv4.tcp_rmem               = 4096 131072 ${bmax}
net.ipv4.tcp_wmem               = 4096 16384 ${bmax}

# UDP defaults (Hysteria2, WireGuard, quic-go)
net.core.rmem_default           = 1048576
net.core.wmem_default           = 1048576

net.core.netdev_max_backlog     = 16384
net.core.somaxconn              = 8192
net.ipv4.tcp_max_syn_backlog    = 8192

net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing           = 1
net.ipv4.tcp_notsent_lowat         = 131072

# tcp_fastopen DELIBERATELY UNSET — middleboxes drop SYN+data, raising latency.
EOF
}

# Write the bundle to NT_CONF_PATH and reload. Returns 0 on success, 1 on any
# error (missing perms, no BBR, sysctl reload failure).
nt_apply() {
    if ! nt_kernel_supports_bbr; then
        warn "Kernel does not expose BBR in /proc/sys/net/ipv4/tcp_available_congestion_control"
        echo "  Common reasons: kernel <4.9, or OpenVZ guest where the kernel is shared."
        return 1
    fi

    local SUDO=""
    if [[ "$(id -u)" -ne 0 ]]; then
        if command -v sudo &>/dev/null; then SUDO="sudo"; else
            error "Need root (or sudo) to write $NT_CONF_PATH"
            return 1
        fi
    fi

    local bmax
    bmax=$(nt_buffer_max)
    local tmp
    tmp=$(mktemp)
    nt_render_config "$bmax" > "$tmp"

    if ! $SUDO install -m 0644 "$tmp" "$NT_CONF_PATH"; then
        rm -f "$tmp"
        error "Failed to write $NT_CONF_PATH"
        return 1
    fi
    rm -f "$tmp"

    # Persist tcp_bbr across reboot.
    echo "tcp_bbr" | $SUDO tee /etc/modules-load.d/moav-bbr.conf >/dev/null 2>&1 || true

    if $SUDO sysctl -p "$NT_CONF_PATH" >/dev/null 2>&1; then
        success "Network tuning applied → $NT_CONF_PATH (buffer max: $((bmax / 1048576)) MiB)"
    else
        warn "Wrote $NT_CONF_PATH but sysctl reload failed — will activate on next boot."
    fi
    echo ""
    nt_status
    return 0
}

# Idempotent — returns 0 even if NT_CONF_PATH doesn't exist.
nt_revert() {
    local SUDO=""
    if [[ "$(id -u)" -ne 0 ]]; then
        if command -v sudo &>/dev/null; then SUDO="sudo"; else
            error "Need root (or sudo) to remove $NT_CONF_PATH"
            return 1
        fi
    fi

    if [[ ! -f "$NT_CONF_PATH" ]]; then
        info "$NT_CONF_PATH not present — nothing to revert."
        return 0
    fi

    $SUDO rm -f "$NT_CONF_PATH"
    $SUDO rm -f /etc/modules-load.d/moav-bbr.conf 2>/dev/null || true
    $SUDO sysctl --system >/dev/null 2>&1 || true
    success "Network tuning reverted (removed $NT_CONF_PATH)."
    echo "  Some settings (rmem_max, wmem_max, congestion_control) only fully reset on reboot."
    return 0
}

# Returns 0 = applied + values match, 1 = applied but drifted, 2 = not applied
# or kernel unsupported. Called by `moav net status` and doctor_check_net.
nt_status() {
    local pass=true
    local applied=false
    if [[ -f "$NT_CONF_PATH" ]]; then
        applied=true
    fi

    local cc qd
    cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo "?")
    qd=$(cat /proc/sys/net/core/default_qdisc          2>/dev/null || echo "?")

    if ! nt_kernel_supports_bbr; then
        echo -e "    ${YELLOW}○${NC} BBR not available on this kernel — tuning skipped"
        echo -e "      ${DIM}Current: tcp_congestion_control=$cc default_qdisc=$qd${NC}"
        echo -e "      ${DIM}Reason: kernel <4.9 or OpenVZ guest. Not actionable from here.${NC}"
        return 2
    fi

    if [[ "$applied" == "true" ]]; then
        echo -e "    ${GREEN}✓${NC} Tuning file present: $NT_CONF_PATH"
    else
        echo -e "    ${YELLOW}○${NC} Tuning file not present (run: moav net apply)"
    fi

    if [[ "$cc" == "bbr" ]]; then
        echo -e "    ${GREEN}✓${NC} tcp_congestion_control = bbr"
    else
        echo -e "    ${YELLOW}!${NC} tcp_congestion_control = $cc (expected: bbr)"
        [[ "$applied" == "true" ]] && pass=false
    fi
    if [[ "$qd" == "fq" ]]; then
        echo -e "    ${GREEN}✓${NC} default_qdisc = fq"
    else
        echo -e "    ${YELLOW}!${NC} default_qdisc = $qd (expected: fq)"
        [[ "$applied" == "true" ]] && pass=false
    fi

    local rmax wmax
    rmax=$(cat /proc/sys/net/core/rmem_max 2>/dev/null || echo 0)
    wmax=$(cat /proc/sys/net/core/wmem_max 2>/dev/null || echo 0)
    local expected
    expected=$(nt_buffer_max)
    # Format sub-MiB values as KiB: the kernel default (~208 KiB) rendered as
    # integer MiB printed "0 MiB", which reads like a broken probe rather than
    # "buffer is small".
    if [[ "$rmax" -ge "$expected" && "$wmax" -ge "$expected" ]]; then
        echo -e "    ${GREEN}✓${NC} rmem_max=$(nt_fmt_bytes "$rmax")  wmem_max=$(nt_fmt_bytes "$wmax") (expected ≥ $(nt_fmt_bytes "$expected"))"
    else
        echo -e "    ${YELLOW}!${NC} buffers below recommended: rmem_max=$(nt_fmt_bytes "$rmax") wmem_max=$(nt_fmt_bytes "$wmax") (expected ≥ $(nt_fmt_bytes "$expected"))"
        [[ "$applied" == "true" ]] && pass=false
    fi

    local syn_backlog
    syn_backlog=$(cat /proc/sys/net/ipv4/tcp_max_syn_backlog 2>/dev/null || echo 0)
    if [[ "$syn_backlog" -ge 8192 ]]; then
        echo -e "    ${GREEN}✓${NC} tcp_max_syn_backlog = $syn_backlog"
    else
        echo -e "    ${YELLOW}!${NC} tcp_max_syn_backlog = $syn_backlog (expected ≥ 8192)"
        [[ "$applied" == "true" ]] && pass=false
    fi

    if [[ "$applied" == "true" ]]; then
        $pass && return 0 || return 1
    else
        return 2
    fi
}

cmd_net() {
    local sub="${1:-status}"
    case "$sub" in
        status|"")
            print_section "Network tuning status"
            nt_status
            ;;
        apply)
            print_section "Applying network tuning"
            nt_apply
            ;;
        revert)
            print_section "Reverting network tuning"
            nt_revert
            ;;
        help|--help|-h)
            echo "Usage: moav net <command>"
            echo ""
            echo "Linux kernel network tuning for VPN / proxy hosts."
            echo "Writes a single dedicated file ($NT_CONF_PATH) so revert is clean."
            echo ""
            echo "Commands:"
            echo "  status   Show current vs recommended sysctl values (default)"
            echo "  apply    Write BBR + buffer tuning bundle and reload sysctl"
            echo "  revert   Remove the moav tuning file and reload sysctl"
            echo ""
            echo "What it tunes: BBR congestion control + fq qdisc + larger TCP/UDP"
            echo "buffers + queue depth + 3 TCP hygiene flags. Does NOT enable TCP"
            echo "Fast Open (hostile in censored networks)."
            echo ""
            echo "Docs: https://moav.sh/docs/OPSEC → \"Network tuning\""
            ;;
        *)
            error "Unknown net command: $sub"
            echo ""
            cmd_net --help
            return 1
            ;;
    esac
}

# =============================================================================
# Doctor (Diagnostics)
# =============================================================================


# Read a key from /proc/net/snmp or /proc/net/netstat. Returns 0 if not found.
nt_proc_counter() {
    local proto="$1" key="$2"
    local v=""
    v=$(awk -v p="$proto:" -v k="$key" '
        $1 == p {
            if ($0 ~ /[A-Za-z]/ && header == "") { header = $0; next }
            if (header != "") {
                n = split(header, h, " "); split($0, v, " ")
                for (i = 2; i <= n; i++) if (h[i] == k) { print v[i]; exit }
                header = ""
            }
        }' /proc/net/snmp /proc/net/netstat 2>/dev/null | head -1)
    echo "${v:-0}"
}

nt_check_drops() {
    local pass=true
    local listen_drops syn_overflow rcvbuf_err sndbuf_err retrans
    listen_drops=$(nt_proc_counter "TcpExt" "ListenDrops")
    syn_overflow=$(nt_proc_counter "TcpExt" "ListenOverflows")
    rcvbuf_err=$(nt_proc_counter   "Udp"    "RcvbufErrors")
    sndbuf_err=$(nt_proc_counter   "Udp"    "SndbufErrors")
    retrans=$(nt_proc_counter      "Tcp"    "RetransSegs")

    # Counters are since-boot. Operator-actionable thresholds — anything non-trivial.
    local report=()
    [[ "$listen_drops" -gt 0   ]] && report+=("TCP ListenDrops=$listen_drops (somaxconn / tcp_max_syn_backlog too small or SYN flood)")
    [[ "$syn_overflow" -gt 0   ]] && report+=("TCP ListenOverflows=$syn_overflow (accept queue overflow)")
    [[ "$rcvbuf_err"   -gt 100 ]] && report+=("UDP RcvbufErrors=$rcvbuf_err (raise rmem_max — affects Hysteria2/WG)")
    [[ "$sndbuf_err"   -gt 100 ]] && report+=("UDP SndbufErrors=$sndbuf_err (raise wmem_max)")

    if [[ ${#report[@]} -eq 0 ]]; then
        echo -e "    ${GREEN}✓${NC} No notable packet drops (TCP retrans=$retrans since boot)"
    else
        local line
        for line in "${report[@]}"; do
            echo -e "    ${YELLOW}!${NC} $line"
            pass=false
        done
    fi
    $pass && return 0 || return 1
}

nt_check_pmtu() {
    local probing
    probing=$(cat /proc/sys/net/ipv4/tcp_mtu_probing 2>/dev/null || echo "?")
    if [[ "$probing" == "1" || "$probing" == "2" ]]; then
        echo -e "    ${GREEN}✓${NC} tcp_mtu_probing = $probing (PMTU black-hole recovery enabled)"
        return 0
    fi
    echo -e "    ${YELLOW}!${NC} tcp_mtu_probing = $probing (PMTU black holes will silently stall TCP)"
    echo -e "      ${DIM}Fix: moav net apply${NC}"
    return 1
}

nt_check_cgnat() {
    # Local IP on the default route. Empty → no route → upstream broken, not our problem here.
    local local_ip iface
    local_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
    iface=$(ip -4 route get 1.1.1.1 2>/dev/null   | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    if [[ -z "$local_ip" ]]; then
        echo -e "    ${DIM}○${NC} CGNAT/NAT check skipped (no default route detected)"
        return 2
    fi

    local cgnat=false private=false
    # CGNAT = 100.64.0.0/10
    if [[ "$local_ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]]; then cgnat=true; fi
    # RFC1918: 10/8, 172.16/12, 192.168/16
    if [[ "$local_ip" =~ ^10\. ]] || \
       [[ "$local_ip" =~ ^192\.168\. ]] || \
       [[ "$local_ip" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]]; then private=true; fi

    local public_ip
    public_ip=$(get_env_val "SERVER_IP" "$SCRIPT_DIR/.env" "")

    if $cgnat; then
        echo -e "    ${RED}✗${NC} Default route uses CGNAT address ($local_ip on $iface)"
        echo -e "      ${DIM}Inbound proxy traffic from the public internet can't reach this host directly.${NC}"
        [[ -n "$public_ip" ]] && echo -e "      ${DIM}SERVER_IP=$public_ip — verify port-forwarding upstream.${NC}"
        return 1
    fi
    if $private; then
        if [[ -n "$public_ip" && "$public_ip" != "$local_ip" ]]; then
            echo -e "    ${YELLOW}!${NC} Server is behind NAT (local=$local_ip, public=$public_ip on $iface)"
            echo -e "      ${DIM}Make sure ports are forwarded from $public_ip to $local_ip.${NC}"
            return 1
        fi
        echo -e "    ${DIM}○${NC} Local address $local_ip is RFC1918 but SERVER_IP not set — can't tell if NAT'd"
        return 2
    fi
    echo -e "    ${GREEN}✓${NC} Default route uses public address ($local_ip on $iface)"
    return 0
}

nt_check_mtu() {
    local enable_wg enable_hy2
    enable_wg=$(get_env_val  "ENABLE_WIREGUARD" "$SCRIPT_DIR/.env" "true")
    enable_hy2=$(get_env_val "ENABLE_HYSTERIA2" "$SCRIPT_DIR/.env" "true")

    # Default-egress MTU.
    local egress_mtu="?"
    local egress_iface
    egress_iface=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    if [[ -n "$egress_iface" ]]; then
        egress_mtu=$(ip link show "$egress_iface" 2>/dev/null | awk '/mtu/ {for(i=1;i<=NF;i++) if($i=="mtu") {print $(i+1); exit}}')
    fi
    echo -e "    ${DIM}○${NC} Egress MTU on ${egress_iface:-?}: ${egress_mtu:-?} (Hysteria2 best near 1450–1472, WireGuard 1420)"

    if [[ "$enable_wg" == "true" ]]; then
        if ip link show wg0 >/dev/null 2>&1; then
            local wg_mtu
            wg_mtu=$(ip link show wg0 2>/dev/null | awk '/mtu/ {for(i=1;i<=NF;i++) if($i=="mtu") {print $(i+1); exit}}')
            if [[ "$wg_mtu" == "1420" ]]; then
                echo -e "    ${GREEN}✓${NC} wg0 MTU = $wg_mtu (recommended)"
            else
                echo -e "    ${YELLOW}!${NC} wg0 MTU = $wg_mtu (recommend 1420 for IPv4-over-UDP overhead)"
            fi
        fi
    fi
}
