#!/bin/sh
# =============================================================================
# Egress isolation: tunneled client traffic must never reach private or infra
# networks. One CIDR list, applied by each tunnel entrypoint at container start.
# Toggle: EGRESS_ISOLATION (default on). Sourced; POSIX sh (dash, busybox ash).
# =============================================================================

# RFC1918, CGNAT, link-local, loopback (0.0.0.0/8 reaches localhost on Linux).
# 172.33.0.0/16 and 10.20.0.0/24 are DappNode's core networks, named explicitly.
EGRESS_BLOCK_V4="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 127.0.0.0/8 0.0.0.0/8 172.33.0.0/16 10.20.0.0/24"
# ULA, link-local, loopback, and the unspecified address (a loopback alias).
EGRESS_BLOCK_V6="fc00::/7 fe80::/10 ::1/128 ::/128"
EGRESS_CHAIN="MOAV-EGRESS"
EGRESS_OUT_CHAIN="MOAV-EGRESS-OUT"

# Off only on an explicit opt-out: unset, empty or a typo all stay on.
egress_isolation_enabled() {
    case "$(printf '%s' "${EGRESS_ISOLATION:-on}" | tr '[:upper:]' '[:lower:]')" in
        off|false|0|no|disabled) return 1 ;;
    esac
    return 0
}

_egress_fw_install() { # $1 = iptables|ip6tables, $2 = tunnel iface, $3 = CIDRs
    "$1" -N "$EGRESS_CHAIN" 2>/dev/null || "$1" -F "$EGRESS_CHAIN" || return 1
    for _egress_cidr in $3; do
        "$1" -A "$EGRESS_CHAIN" -d "$_egress_cidr" -j DROP || return 1
    done
    # Top of FORWARD, so it always precedes the tunnel's ACCEPT. -C keeps it single.
    "$1" -C FORWARD -i "$2" -j "$EGRESS_CHAIN" 2>/dev/null \
        || "$1" -I FORWARD 1 -i "$2" -j "$EGRESS_CHAIN" || return 1
}

# Remove the rules for tunnel iface $1. A quiet no-op when nothing is installed.
egress_firewall_clear() {
    for _egress_ipt in iptables ip6tables; do
        "$_egress_ipt" -D FORWARD -i "$1" -j "$EGRESS_CHAIN" 2>/dev/null || true
        "$_egress_ipt" -F "$EGRESS_CHAIN" 2>/dev/null || true
        "$_egress_ipt" -X "$EGRESS_CHAIN" 2>/dev/null || true
    done
}

# WireGuard/AmneziaWG: drop forwarded packets from tunnel iface $1 to a blocked
# range. Matches on -i only, so replies back to the clients' own 10.x pass.
egress_firewall() {
    if ! egress_isolation_enabled; then
        egress_firewall_clear "$1"
        echo "[egress] WARNING: EGRESS_ISOLATION is off: clients on $1 can reach private networks"
        return 0
    fi
    _egress_fw_install iptables "$1" "$EGRESS_BLOCK_V4" || return 1
    if ip6tables -S FORWARD >/dev/null 2>&1; then
        _egress_fw_install ip6tables "$1" "$EGRESS_BLOCK_V6" || return 1
    elif [ "$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || echo 0)" != "0" ]; then
        # v6 is routed but there is no filter table to enforce the block: refuse.
        echo "[egress] ERROR: IPv6 forwarding is on but ip6tables is unusable" >&2
        return 1
    fi
    echo "[egress] Egress isolation on for $1: private/infra destinations are dropped"
}

# sing-box: rewrite config $1 in place so blocked ranges are rejected before any
# route. Domains are resolved first, so a name pointing at a private IP is caught.
egress_singbox() {
    if ! egress_isolation_enabled; then
        echo "[egress] WARNING: EGRESS_ISOLATION is off: sing-box clients can reach private networks"
        return 0
    fi
    jq --arg cidrs "$EGRESS_BLOCK_V4 $EGRESS_BLOCK_V6" '
        ($cidrs | split(" ")) as $block
        | (.route.final // "direct") as $out
        # A fallback target (the decoy) lives on the Docker network: keep exactly
        # that host:port reachable, matched before sniffing can spoof the domain.
        | [.inbounds[]? | select(.fallback.server? and .fallback.server_port?)
           | {action: "route", outbound: $out, inbound: [.tag], port: [.fallback.server_port]}
             + (if (.fallback.server | test("^[0-9.]+$|:")) then {ip_cidr: [.fallback.server]}
                else {domain: [.fallback.server]} end)] as $allow
        | (.route.rules // []) as $rules
        # The sniff/hijack-dns/resolve preamble stays first: hijacked DNS is
        # answered locally, so a client whose resolver is a LAN IP keeps working.
        | ($rules | map(.action | IN("sniff", "hijack-dns", "resolve", "route-options"))
           | index(false) // length) as $n
        | .route.rules = $allow + $rules[:$n]
            + (if any($rules[:$n][]; .action == "resolve") then [] else [{action: "resolve"}] end)
            + [{action: "reject", ip_cidr: $block}]
            + $rules[$n:]
    ' "$1" > "$1.egress" && mv -f "$1.egress" "$1" \
        && echo "[egress] Egress isolation on: sing-box rejects private/infra destinations"
}

_egress_out_install() { # $1 = iptables|ip6tables, $2 = CIDRs, $3 = resolv.conf
    "$1" -N "$EGRESS_OUT_CHAIN" 2>/dev/null || "$1" -F "$EGRESS_OUT_CHAIN" || return 1
    # Replies to clients (seen as a private IP behind the Docker gateway) pass.
    "$1" -A "$EGRESS_OUT_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN || return 1
    # The container's own resolvers stay reachable. No --dport: Docker DNATs
    # 127.0.0.11:53 to a random port before this chain sees the packet.
    # shellcheck disable=SC2013
    for _egress_ns in $(awk '$1 == "nameserver" {print $2}' "$3" 2>/dev/null); do
        case "$1:$_egress_ns" in iptables:*:*|ip6tables:*.*) continue ;; esac
        "$1" -A "$EGRESS_OUT_CHAIN" -d "$_egress_ns" -j RETURN || return 1
    done
    for _egress_cidr in $2; do
        "$1" -A "$EGRESS_OUT_CHAIN" -d "$_egress_cidr" -j DROP || return 1
    done
    "$1" -C OUTPUT -p udp -j "$EGRESS_OUT_CHAIN" 2>/dev/null \
        || "$1" -I OUTPUT 1 -p udp -j "$EGRESS_OUT_CHAIN" || return 1
}

# sing-box routes a UDP session once, on its first packet; later packets may name
# any destination. Filter the container's own UDP egress so those are dropped too.
egress_udp_backstop() {
    if ! egress_isolation_enabled; then
        for _egress_ipt in iptables ip6tables; do
            "$_egress_ipt" -D OUTPUT -p udp -j "$EGRESS_OUT_CHAIN" 2>/dev/null || true
            "$_egress_ipt" -F "$EGRESS_OUT_CHAIN" 2>/dev/null || true
            "$_egress_ipt" -X "$EGRESS_OUT_CHAIN" 2>/dev/null || true
        done
        return 0
    fi
    _egress_out_install iptables "$EGRESS_BLOCK_V4" "${1:-/etc/resolv.conf}" || return 1
    if ip6tables -S OUTPUT >/dev/null 2>&1; then
        _egress_out_install ip6tables "$EGRESS_BLOCK_V6" "${1:-/etc/resolv.conf}" || return 1
    fi
}

# Xray: write runtime config $2 from $1. The routing rule blackholes blocked IP
# targets; freedom finalRules re-checks the address actually dialed (and each
# UDP packet), which is what catches a domain that resolves to a blocked range.
egress_xray() {
    if ! egress_isolation_enabled; then
        echo "[egress] WARNING: EGRESS_ISOLATION is off: MoaV adds no Xray egress rules"
        cp "$1" "$2"
        return
    fi
    jq --arg cidrs "$EGRESS_BLOCK_V4 $EGRESS_BLOCK_V6" '
        ($cidrs | split(" ")) as $block
        | (.api.tag // "api") as $api
        # The stats API targets 127.0.0.1 by design, so its rules stay ahead.
        | .routing.rules = [.routing.rules[]? | select(.outboundTag == $api)]
            + [{type: "field", ip: $block, outboundTag: "egress-block"}]
            + [.routing.rules[]? | select(.outboundTag != $api)]
        | .outbounds = [.outbounds[]? | select(.tag != "egress-block")
              | if .protocol == "freedom"
                then .settings.finalRules = [{action: "block", ip: $block}] + (.settings.finalRules // [])
                else . end]
            + [{protocol: "blackhole", tag: "egress-block"}]
    ' "$1" > "$2" \
        && echo "[egress] Egress isolation on: Xray blocks private/infra destinations"
}
