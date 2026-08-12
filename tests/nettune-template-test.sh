#!/bin/bash
# Regression test: the sysctl bundle has two copies and neither may go stale.
#
# A live 2.1.0 server was still running the tuning file written by v1.8.4:
# `moav net apply` and install.sh both skip a host that already has the file, so
# whatever key set was current when the operator first tuned is what they keep,
# forever. tcp_max_syn_backlog was added in v1.8.5, so `moav doctor net` reported
# "✓ Tuning file present" one line above "! tcp_max_syn_backlog = 256" -- which
# reads as an external override and sends you hunting through /etc/sysctl.d.
#
# Two invariants:
#   1. nt_status flags a file that lacks any key the current template sets.
#   2. install.sh's inline copy of the bundle matches nt_render_config, or a
#      fresh install writes an older bundle than `moav net apply` would.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "net tuning: stale-file detection + template drift"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --- 1. the two copies of the bundle must agree ------------------------------
keys_of() { grep -E '^net\.' | sed 's/[[:space:]]\+/ /g' | sort; }
sed -n '/^nt_render_config/,/^}/p' "$ROOT/lib/nettune.sh"        | keys_of > "$TMP/lib.txt"
sed -n '/# MoaV network tuning/,/^EOF$/p' "$ROOT/install.sh"     | keys_of > "$TMP/inst.txt"

if [ ! -s "$TMP/lib.txt" ]; then
    bad "could not extract the template from lib/nettune.sh (nt_render_config renamed?)"
elif [ ! -s "$TMP/inst.txt" ]; then
    bad "could not extract the template from install.sh (heredoc markers changed?)"
elif diff -q "$TMP/lib.txt" "$TMP/inst.txt" >/dev/null; then
    ok "install.sh and lib/nettune.sh set the same $(wc -l < "$TMP/lib.txt" | tr -d ' ') keys"
else
    bad "template drift between install.sh and lib/nettune.sh: $(diff "$TMP/lib.txt" "$TMP/inst.txt" | tr '\n' ' ')"
fi

# --- 2. nt_status must notice a file missing a current key --------------------
# Drive the real function with NT_CONF_PATH pointed at a fixture.
status_against() {   # <fixture-file> -> stdout of nt_status
    (
        # shellcheck disable=SC1091
        source "$ROOT/scripts/lib/common.sh" >/dev/null 2>&1
        RED=''; GREEN=''; YELLOW=''; CYAN=''; WHITE=''; DIM=''; NC=''
        # shellcheck disable=SC1091
        source "$ROOT/lib/nettune.sh"
        NT_CONF_PATH="$1"
        # The fixture stands in for the file; the kernel probes read this host and
        # are not what is under test here.
        nt_kernel_supports_bbr() { return 0; }
        nt_status 2>&1
    )
}

# A current file: whatever the template renders right now.
(
    # shellcheck disable=SC1091
    source "$ROOT/scripts/lib/common.sh" >/dev/null 2>&1
    # shellcheck disable=SC1091
    source "$ROOT/lib/nettune.sh"
    nt_render_config 16777216
) > "$TMP/current.conf"

if grep -q '^net\.ipv4\.tcp_max_syn_backlog' "$TMP/current.conf"; then
    ok "the current template sets tcp_max_syn_backlog"
else
    bad "the current template no longer sets tcp_max_syn_backlog -- fixture below is meaningless"
fi

# The v1.8.4 file, reproduced by dropping that one line: exactly what the live
# server had.
grep -v '^net\.ipv4\.tcp_max_syn_backlog' "$TMP/current.conf" > "$TMP/stale.conf"

out_stale=$(status_against "$TMP/stale.conf")
if printf '%s' "$out_stale" | grep -q 'from an older MoaV'; then
    if printf '%s' "$out_stale" | grep -q 'tcp_max_syn_backlog'; then
        ok "a stale file is reported as stale, naming the missing key"
    else
        bad "reported stale but did not name the missing key: $(printf '%s' "$out_stale" | tr '\n' ' ')"
    fi
else
    bad "a file missing tcp_max_syn_backlog still reported as present/OK -- the operator is sent hunting"
fi

out_cur=$(status_against "$TMP/current.conf")
if printf '%s' "$out_cur" | grep -q 'Tuning file present'; then
    ok "an up-to-date file is not flagged"
else
    bad "a current file was reported stale: $(printf '%s' "$out_cur" | tr '\n' ' ')"
fi

# --- 3. and the check is not vacuous -----------------------------------------
# If the comparison silently matched nothing, the stale fixture above would pass
# for the wrong reason. Drop three keys and require all three to be named.
grep -vE '^net\.(ipv4\.tcp_mtu_probing|core\.somaxconn|ipv4\.tcp_notsent_lowat)' \
    "$TMP/current.conf" > "$TMP/older.conf"
out_older=$(status_against "$TMP/older.conf")
missed=""
for k in tcp_mtu_probing somaxconn tcp_notsent_lowat; do
    printf '%s' "$out_older" | grep -q "$k" || missed="$missed $k"
done
[ -z "$missed" ] && ok "names every missing key, not just the first" \
                 || bad "did not name:$missed"

echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
