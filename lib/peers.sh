#!/bin/bash
# lib/peers.sh — WireGuard / AmneziaWG peer-address integrity.
#
# WHY THIS EXISTS. Until the v2 allocator fix, the container provisioning path
# handed out peer IPs from the COUNT of [Peer] blocks (count+1) rather than from
# what was actually in use. Revoking a user drops the count below the highest
# assigned address, so the next user was given an address someone already held —
# and it cascaded. On a real 147-peer server this produced 19 duplicated
# WireGuard addresses shared by 45 peers, and 22 duplicated AmneziaWG addresses
# shared by 50 peers.
#
# WHY IT BREAKS USERS. WireGuard's crypto-routing table maps each address to
# exactly ONE peer: a later duplicate takes the address and the earlier peer
# silently loses it. The victim's tunnel still handshakes and then passes no
# return traffic — a connected-but-dead tunnel, which is miserable to diagnose.
#
# WHY `moav regenerate-users` DOES NOT FIX IT. `*_add_peer` deliberately reuses
# the stored WG_CLIENT_IP from state/users/<u>/<proto>.env so that already
# distributed bundles keep working, and it skips a user already present in the
# server config. So a regenerate faithfully re-renders the SAME colliding
# address. Healing requires resetting the loser's per-protocol state so the
# allocator runs again — which necessarily gives that user a new address and
# keypair, i.e. they need a fresh bundle. That is what `--fix` prepares.

PEERS_SPECS=(
    "WireGuard:configs/wireguard/wg0.conf:10.66.66:wireguard:wg:wg0"
    "AmneziaWG:configs/amneziawg/awg0.conf:10.67.67:amneziawg:awg:awg0"
)

# peers_octets <conf> <prefix> — every v4 host octet claimed in the config.
peers_octets() {
    local conf="$1" prefix="$2" esc="${2//./\\.}"
    [[ -f "$conf" ]] || return 0
    grep "AllowedIPs = ${esc}\." "$conf" 2>/dev/null | sed "s|.*${esc}\.\([0-9]*\).*|\1|"
}

# peers_users_for_octet <conf> <prefix> <octet> — users claiming that address, in
# config order. The "# <user>" comment is the line above PublicKey in each block.
peers_users_for_octet() {
    # [.] rather than \. — awk warns on backslash escapes in a dynamic regex.
    local conf="$1" rx="${2//./[.]}" octet="$3"
    awk -v pat="AllowedIPs = ${rx}[.]${octet}(/|,|$| )" '
        /^\[Peer\]/ { user=""; next }
        /^# / && user=="" { user=substr($0,3) }
        $0 ~ pat { if (user != "") print user; user="" }
    ' "$conf"
}

# peers_live_owner <container> <bin> <iface> <prefix> <octet>
# Which public key currently OWNS the address in the running interface (that is
# the peer whose tunnel actually works). Empty if the service is not running.
#
# The docker output is captured before awk sees it, NOT piped into it. Piping and
# then `exit`ing on the first match closes the pipe while `wg show` is still
# writing its other peers, so docker dies of SIGPIPE; under `set -o pipefail`
# that makes this assignment fail and `set -e` kills the caller mid-repair with
# no message at all. It is a race, so it only shows up on servers with enough
# peers for the match to land before the writer finishes -- which is exactly the
# servers that need the repair.
peers_live_owner() {
    local cont="$1" bin="$2" iface="$3" prefix="$4" octet="$5" out
    out=$(docker exec "$cont" "$bin" show "$iface" allowed-ips 2>/dev/null) || return 0
    awk -v pat="${prefix//./[.]}[.]${octet}(/|,|$)" '$0 ~ pat {print $1; exit}' <<<"$out"
}

# peers_pubkey_for_user <conf> <user>
peers_pubkey_for_user() {
    awk -v u="# $2" '
        /^\[Peer\]/ { hit=0; next }
        $0 == u { hit=1; next }
        hit && /^PublicKey/ { print $3; exit }
    ' "$1"
}

# peers_report [--quiet] — prints findings; 0 = clean, 1 = duplicates found,
# 2 = nothing to check (no configs). Read-only.
peers_report() {
    local quiet="${1:-}" spec name conf prefix svc bin iface
    local any_conf=false problems=0

    for spec in "${PEERS_SPECS[@]}"; do
        IFS=: read -r name conf prefix svc bin iface <<<"$spec"
        [[ -f "$conf" ]] || continue
        any_conf=true

        local octets dupes total distinct
        octets=$(peers_octets "$conf" "$prefix")
        [[ -n "$octets" ]] || continue
        total=$(echo "$octets" | grep -c .)
        distinct=$(echo "$octets" | sort -n | uniq | grep -c .)
        dupes=$(echo "$octets" | sort -n | uniq -d)

        if [[ -z "$dupes" ]]; then
            [[ "$quiet" == "--quiet" ]] || echo -e "    ${GREEN}✓${NC} $name: $total peers, all addresses unique"
            continue
        fi

        local groups shared
        groups=$(echo "$dupes" | grep -c .)
        shared=$((total - distinct + groups))
        problems=$((problems + groups))
        echo -e "    ${YELLOW}!${NC} $name: ${groups} address(es) claimed by ${shared} peers (of $total)"

        local octet users owner_pk keeper
        while read -r octet; do
            [[ -n "$octet" ]] || continue
            users=$(peers_users_for_octet "$conf" "$prefix" "$octet" | tr '\n' ' ')
            owner_pk=$(peers_live_owner "moav-$svc" "$bin" "$iface" "$prefix" "$octet")
            keeper=""
            if [[ -n "$owner_pk" ]]; then
                local u
                for u in $users; do
                    if [[ "$(peers_pubkey_for_user "$conf" "$u")" == "$owner_pk" ]]; then keeper="$u"; break; fi
                done
            fi
            echo -e "        ${prefix}.${octet}  ${users}${keeper:+ ${DIM}(live owner: $keeper)${NC}}"
        done <<< "$dupes"
    done

    [[ "$any_conf" == "true" ]] || return 2
    if [[ "$problems" -gt 0 ]]; then
        echo -e "      ${DIM}Only one peer per address can receive traffic; the others connect but${NC}"
        echo -e "      ${DIM}pass no return traffic. 'moav doctor peers --fix' resets the affected${NC}"
        echo -e "      ${DIM}users so the next 'moav regenerate-users' reassigns them (new bundle).${NC}"
        return 1
    fi
    return 0
}

# peers_drop_block <conf> <user> — remove that user's [Peer] block, in place.
# Paragraph mode: peer blocks are blank-line separated, so a whole record either
# is the user's block or is kept verbatim.
peers_drop_block() {
    local conf="$1" user="$2" tmp
    tmp=$(mktemp) || return 1
    awk -v u="# $user" '
        BEGIN { RS=""; ORS="" }
        {
            drop=0
            n=split($0, L, "\n")
            for (i=1; i<=n; i++) if (L[i] == u) drop=1
            if (!drop) print (first++ ? "\n\n" : "") $0
        }
        END { print "\n" }
    ' "$conf" > "$tmp" || { rm -f "$tmp"; return 1; }
    # jq-style in-place: keep the original inode/mode (sudo CLI vs admin container)
    cat "$tmp" > "$conf" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
}

# peers_clear_state_env <svc> <user> — drop the stored keypair+IP so the next
# provisioning run reallocates. Returns 0 if a copy was actually removed.
#
# There are TWO state trees and the generators read different ones: the host CLI
# path uses ./state, while the container path (scripts/generate-user.sh, and so
# `moav regenerate-users`) reads /state from the moav_state docker volume, which
# is NOT the host directory. Clearing only the host copy leaves the volume copy
# authoritative, the stored address comes straight back, and the duplicate the
# repair just reported reappears on the next regenerate.
peers_clear_state_env() {
    local svc="$1" user="$2" gone=1
    local envf="${STATE_DIR:-state}/users/$user/${svc}.env"
    [[ -f "$envf" ]] && { rm -f "$envf" 2>/dev/null && gone=0; }
    # Same volume name and image as scripts/user-revoke.sh uses for its cleanup.
    if docker run --rm -v moav_moav_state:/state alpine \
        sh -c "[ -f /state/users/$user/${svc}.env ] && rm -f /state/users/$user/${svc}.env" 2>/dev/null
    then
        gone=0
    fi
    return $gone
}

# peers_repair [--yes] — for every duplicated address, keep the peer that owns it
# on the live interface (or the last one in the config, which is who WireGuard
# would pick on load) and reset the rest: drop their [Peer] block and their
# per-protocol state env, so the allocator reassigns them on the next
# `moav regenerate-users`.
peers_repair() {
    local assume_yes="${1:-}" spec name conf prefix svc bin iface
    local -a resets=()

    for spec in "${PEERS_SPECS[@]}"; do
        IFS=: read -r name conf prefix svc bin iface <<<"$spec"
        [[ -f "$conf" ]] || continue
        local dupes; dupes=$(peers_octets "$conf" "$prefix" | sort -n | uniq -d)
        [[ -n "$dupes" ]] || continue

        local octet users owner_pk keeper u
        while read -r octet; do
            [[ -n "$octet" ]] || continue
            users=$(peers_users_for_octet "$conf" "$prefix" "$octet")
            owner_pk=$(peers_live_owner "moav-$svc" "$bin" "$iface" "$prefix" "$octet")
            keeper=""
            if [[ -n "$owner_pk" ]]; then
                for u in $users; do
                    [[ "$(peers_pubkey_for_user "$conf" "$u")" == "$owner_pk" ]] && { keeper="$u"; break; }
                done
            fi
            # No live owner (service down): keep the last block — WireGuard's own
            # load order gives the address to the last claimant.
            [[ -n "$keeper" ]] || keeper=$(echo "$users" | tail -1)
            for u in $users; do
                [[ "$u" == "$keeper" ]] && continue
                resets+=("$svc|$conf|$u")
            done
        done <<< "$dupes"
    done

    if [[ ${#resets[@]} -eq 0 ]]; then
        info "No duplicate peer addresses to repair."
        return 0
    fi

    echo ""
    echo -e "  ${WHITE}Will reset ${#resets[@]} peer(s)${NC} — each gets a NEW address and keypair,"
    echo -e "  so ${YELLOW}these users need a fresh bundle${NC} afterwards:"
    local entry svc2 conf2 user2
    for entry in "${resets[@]}"; do
        IFS='|' read -r svc2 conf2 user2 <<<"$entry"
        echo "    $svc2: $user2"
    done
    echo ""

    if [[ "$assume_yes" != "--yes" ]]; then
        if [[ ! -t 0 ]]; then
            echo -e "      ${DIM}Run interactively, or re-run with: moav doctor peers --fix --yes${NC}"
            return 1
        fi
        local reply
        read -r -p "    Reset these peers now? [y/N] " reply
        [[ "$reply" =~ ^[Yy]$ ]] || { info "Cancelled."; return 1; }
    fi

    local done_n=0 stuck=0
    for entry in "${resets[@]}"; do
        IFS='|' read -r svc2 conf2 user2 <<<"$entry"
        if ! peers_drop_block "$conf2" "$user2"; then
            echo -e "    ${RED}✗${NC} could not edit $conf2 for $user2"
            continue
        fi
        # Dropping the block alone is not a reset: with the stored address still
        # readable the next regenerate re-adds the very same duplicate.
        if peers_clear_state_env "$svc2" "$user2"; then
            echo -e "    ${GREEN}✓${NC} reset $svc2 peer for $user2"
            done_n=$((done_n + 1))
        else
            echo -e "    ${YELLOW}!${NC} dropped $svc2 peer for $user2 but found no stored state to clear"
            stuck=$((stuck + 1))
        fi
    done

    echo ""
    if [[ "$stuck" -gt 0 ]]; then
        warn "$stuck peer(s) had no state file in ./state or the moav_state volume."
        echo -e "  ${DIM}Their address came from somewhere else, so a regenerate may re-add the${NC}"
        echo -e "  ${DIM}duplicate. Check 'docker volume ls' for moav_moav_state, then report this.${NC}"
    fi
    success "Reset $done_n peer(s)."
    echo -e "  ${CYAN}Next:${NC} moav regenerate-users   ${DIM}# reassigns addresses + rebuilds bundles${NC}"
    echo -e "  Then distribute the new bundles to the users listed above."
    return 0
}

# Doctor check — read-only.
doctor_check_peers() {
    peers_report
}
