#!/bin/sh
# =============================================================================
# Egress isolation for TrustTunnel. Sourced after egress-isolation.sh, which owns
# the CIDR list and the EGRESS_ISOLATION toggle. POSIX sh.
# =============================================================================

EGRESS_TT_KEY="allow_private_network_connections"

# Set the endpoint's own private-network switch in runtime vpn.toml $1 to $2.
# Only top-level lines (before the first [table]) are touched.
_egress_tt_set_key() {
    if awk -v k="$EGRESS_TT_KEY" '/^[[:space:]]*\[/ {exit 1}
            $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {found=1; exit}
            END {exit !found}' "$1"; then
        awk -v k="$EGRESS_TT_KEY" -v v="$2" '/^[[:space:]]*\[/ {t=1}
            !t && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {print k " = " v; next} {print}' \
            "$1" > "$1.egress" || return 1
    else
        { printf '%s = %s\n' "$EGRESS_TT_KEY" "$2"; cat "$1"; } > "$1.egress" || return 1
    fi
    mv -f "$1.egress" "$1"
}

_egress_tt_out_install() { # $1 = iptables|ip6tables, $2 = CIDRs, $3 = resolv.conf
    "$1" -N "$EGRESS_OUT_CHAIN" 2>/dev/null || "$1" -F "$EGRESS_OUT_CHAIN" || return 1
    # Replies to clients (which may arrive from a private Docker gateway) pass.
    "$1" -A "$EGRESS_OUT_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN || return 1
    # Docker's resolver is 127.0.0.11; no --dport, as Docker DNATs its port first.
    # shellcheck disable=SC2013
    for _egress_ns in $(awk '$1 == "nameserver" {print $2}' "$3" 2>/dev/null); do
        case "$1:$_egress_ns" in iptables:*:*|ip6tables:*.*) continue ;; esac
        "$1" -A "$EGRESS_OUT_CHAIN" -d "$_egress_ns" -j RETURN || return 1
    done
    for _egress_cidr in $2; do
        "$1" -A "$EGRESS_OUT_CHAIN" -d "$_egress_cidr" -j DROP || return 1
    done
    # All protocols: the endpoint forwards TCP, UDP and ICMP for its clients.
    "$1" -C OUTPUT -j "$EGRESS_OUT_CHAIN" 2>/dev/null \
        || "$1" -I OUTPUT 1 -j "$EGRESS_OUT_CHAIN" || return 1
}

egress_trusttunnel_clear() {
    for _egress_ipt in iptables ip6tables; do
        "$_egress_ipt" -D OUTPUT -j "$EGRESS_OUT_CHAIN" 2>/dev/null || true
        "$_egress_ipt" -F "$EGRESS_OUT_CHAIN" 2>/dev/null || true
        "$_egress_ipt" -X "$EGRESS_OUT_CHAIN" 2>/dev/null || true
    done
}

# On: the endpoint's own filter stays on and OUTPUT drops the block list, adding
# 172.33.0.0/16, which is_global_ip calls public. Off: both are lifted.
egress_trusttunnel() {
    if ! egress_isolation_enabled; then
        egress_trusttunnel_clear
        _egress_tt_set_key "$1" true || return 1
        echo "[egress] WARNING: EGRESS_ISOLATION is off: TrustTunnel clients can reach private networks"
        return 0
    fi
    _egress_tt_set_key "$1" false || return 1
    _egress_tt_out_install iptables "$EGRESS_BLOCK_V4" "${2:-/etc/resolv.conf}" || return 1
    # v6 is best-effort: the endpoint's own filter already refuses every v6 range.
    if ip6tables -S OUTPUT >/dev/null 2>&1; then
        _egress_tt_out_install ip6tables "$EGRESS_BLOCK_V6" "${2:-/etc/resolv.conf}" \
            || echo "[egress] WARNING: IPv6 egress filter not installed; v6 rests on the endpoint's own check"
    fi
    echo "[egress] Egress isolation on: TrustTunnel refuses private/infra destinations"
}
