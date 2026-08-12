#!/bin/bash
# Regression test: `moav doctor peers --fix` must survive a busy server, and a
# "reset" must actually clear the stored address.
#
# Two failures seen on live 2.1.0 servers, both silent:
#
# 1. peers_live_owner piped `docker exec ... wg show` into an awk that exits on
#    the first match. On a server with enough peers the writer is still going
#    when awk exits, so docker dies of SIGPIPE; `set -o pipefail` makes the
#    assignment fail and `set -e` kills the repair with NO output at all -- the
#    report printed, then the shell returned to the prompt. It survived on a
#    19-peer server and died on a 171-peer one, because it is a race.
#
# 2. The reset removed ./state/users/<u>/<svc>.env only. `moav regenerate-users`
#    provisions in a container reading /state from the moav_state volume, so the
#    stored address survived and the duplicate came straight back.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "doctor peers --fix: survives a busy server, clears the stored address"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"/{configs/wireguard,configs/amneziawg,state/users,bin}

# Two users on one address; the live owner is the second one.
build_conf() {   # <conf> <prefix>
    printf '[Interface]\nAddress = %s.1/24\n' "$2" > "$1"
    local u
    for u in loser keeper; do
        printf '\n[Peer]\n# %s\nPublicKey = pk-%s\nAllowedIPs = %s.9/32\n' "$u" "$u" "$2" >> "$1"
    done
}
build_conf "$WORK/configs/wireguard/wg0.conf"   10.66.66
build_conf "$WORK/configs/amneziawg/awg0.conf"  10.67.67
for u in loser keeper; do
    mkdir -p "$WORK/state/users/$u"
    printf 'WG_PRIVATE_KEY=x\nWG_PUBLIC_KEY=pk-%s\nWG_CLIENT_IP=10.66.66.9\n' "$u" \
        > "$WORK/state/users/$u/wireguard.env"
    cp "$WORK/state/users/$u/wireguard.env" "$WORK/state/users/$u/amneziawg.env"
done

# A `wg show` that keeps writing long after the first match -- the busy server.
# `docker run` (the volume cleanup) records its argv and reports "nothing there",
# so the host copy is what has to satisfy the reset.
cat > "$WORK/bin/docker" <<'STUB'
#!/bin/bash
case "${1:-}" in
    exec)
        echo "pk-keeper	10.66.66.9/32"
        echo "pk-keeper	10.67.67.9/32"
        # 200k lines of other peers: awk has long since exited on the match above
        seq 1 200000 | sed 's|^|pk-other	10.66.66.|'
        ;;
    run)
        echo "$*" >> "${DOCKER_ARGV_LOG:-/dev/null}"
        exit 1
        ;;
esac
STUB
chmod +x "$WORK/bin/docker"

run_repair() {
    (
        cd "$WORK" || exit 99
        export PATH="$WORK/bin:$PATH"
        export DOCKER_ARGV_LOG="$WORK/docker-argv.log"
        set -euo pipefail                      # exactly how moav.sh runs
        RED=''; GREEN=''; YELLOW=''; CYAN=''; WHITE=''; DIM=''; NC=''
        # shellcheck disable=SC1091
        source "$ROOT/scripts/lib/common.sh"
        # shellcheck disable=SC1091
        source "$ROOT/lib/common.sh"
        # shellcheck disable=SC1091
        source "$ROOT/lib/peers.sh"
        STATE_DIR="state"
        peers_repair --yes
    ) >"$WORK/out.txt" 2>&1
}

run_repair
rc=$?

# --- 1. it must not die on the way through ----------------------------------
if [ "$rc" -eq 0 ]; then
    ok "repair completes against a long-writing 'wg show' (exit 0)"
elif [ "$rc" -eq 141 ]; then
    bad "repair died of SIGPIPE (141) -- peers_live_owner is piping into an early-exit awk again"
else
    bad "repair exited $rc; output: $(tr '\n' ' ' < "$WORK/out.txt" | tail -c 200)"
fi

# --- 2. it kept the live owner and reset the other one -----------------------
if grep -q 'reset wireguard peer for loser' "$WORK/out.txt"; then
    ok "resets the peer that lost the address"
else
    bad "did not reset 'loser' -- output: $(tr '\n' ' ' < "$WORK/out.txt" | tail -c 200)"
fi
if grep -q 'peer for keeper' "$WORK/out.txt"; then
    bad "reset the live owner 'keeper' -- that breaks the one tunnel that works"
else
    ok "leaves the live owner alone"
fi

# --- 3. the stored address is really gone ------------------------------------
[ -f "$WORK/state/users/loser/wireguard.env" ] \
    && bad "loser's state env survived -- regenerate would re-add the same address" \
    || ok "loser's stored address is cleared from the host state tree"
[ -f "$WORK/state/users/keeper/wireguard.env" ] \
    && ok "keeper's state is untouched" \
    || bad "keeper's state was cleared -- the working user would be re-keyed"

# --- 4. and the volume copy was attempted too --------------------------------
# The container provisioning path reads /state from moav_state, not ./state.
if grep -q 'moav_moav_state:/state' "$WORK/docker-argv.log" 2>/dev/null; then
    ok "also clears the moav_state volume copy"
else
    bad "never touched the moav_state volume -- the container path keeps the old address"
fi

# --- 5. negative control: the old piped form really does die -----------------
# Without this, a stub that never triggers SIGPIPE would make check 1 vacuous.
oldform=$(
    cd "$WORK" || exit 99
    export PATH="$WORK/bin:$PATH"
    set -euo pipefail
    x=$(docker exec c wg show wg0 allowed-ips 2>/dev/null \
        | awk '$0 ~ /10[.]66[.]66[.]9(\/|,|$)/ {print $1; exit}')
    echo "survived:$x"
)
if [ -z "$oldform" ]; then
    ok "the negative control confirms the piped form still dies on this stub"
else
    bad "the stub no longer provokes SIGPIPE ($oldform) -- check 1 proves nothing"
fi

echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
