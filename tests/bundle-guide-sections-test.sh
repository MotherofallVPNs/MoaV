#!/bin/bash
# Regression test: a protocol whose config is in the bundle must be VISIBLE in
# README.html, and one that is absent must be hidden.
#
# Reported by a user: TrustTunnel was generated, and the admin dashboard listed
# it, but its section was missing from the guide. Cause: the section was keyed on
# `trusttunnel.txt`, a filename nothing has ever written -- the real artifacts are
# trusttunnel.toml and trusttunnel.json -- so `_hide()` hid it in EVERY bundle
# ever produced. The same phantom-filename bug hid the whole dnstt section, keyed
# on `dnstt-instructions.txt`, which also never existed. dnstt is server-wide and
# has no per-user file at all, so its signal is the server pubkey the guide embeds.
#
# The class of bug is "section keyed on a file that is never generated", which is
# invisible from the outside: the guide just quietly omits a protocol. So this
# asserts the round trip -- render with the artifact, render without it -- rather
# than checking the mapping by eye.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "bundle guide section visibility"

command -v python3 >/dev/null || { echo "  python3 required"; exit 1; }
tpl="$ROOT/templates/client-guide-template.html"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# Render the guide for a bundle containing exactly $1.. files, then report the
# style attribute of section $SECTION.
render() {   # <outdir>
    local out="$1"
    RB_OUTPUT_DIR="$out" \
    RB_TEMPLATE="$tpl" \
    RB_OUTPUT_HTML="$out/README.html" \
    RB_CONTEXT="host" \
    RB_USERNAME="t" RB_SERVER_IP="203.0.113.9" RB_DOMAIN="example.com" \
    RB_DNSTT_PUBKEY="${RB_DNSTT_PUBKEY:-}" \
    RB_USER_PASSWORD="pw" \
    python3 "$ROOT/scripts/lib/bundle_readme.py" >/dev/null 2>&1
}

section_style() {  # <html> <section-id>
    grep -oE "id=\"$2-en\" style=\"[^\"]*\"" "$1" | head -1 | sed 's/.*style="//; s/"$//'
}

# section-id : the artifact file(s) that should make it appear
# Empty artifact means "driven by an env var, not a file" (dnstt).
run_case() {  # <label> <section> <artifact...>
    local label="$1" section="$2"; shift 2
    local d="$tmp/$section"; rm -rf "$d"; mkdir -p "$d"
    local f
    for f in "$@"; do
        case "$f" in
            *.json) printf '{"server":"203.0.113.9"}\n' > "$d/$f" ;;
            *.png)  printf 'x' > "$d/$f" ;;
            *)      printf 'server=203.0.113.9\n' > "$d/$f" ;;
        esac
    done
    render "$d"
    local st; st=$(section_style "$d/README.html" "$section")
    if [ -z "$st" ]; then
        ok "$label: visible"
    else
        bad "$label: HIDDEN ($st) although its artifact is in the bundle"
    fi

    # And the converse: with the artifacts gone it must hide.
    rm -f "$d"/*
    ( unset RB_DNSTT_PUBKEY; render "$d" )
    st=$(section_style "$d/README.html" "$section")
    if [ "$st" = "display:none" ]; then
        ok "$label: hidden when absent"
    else
        bad "$label: still shown with no artifact (style='$st')"
    fi
}

run_case "reality"     reality      reality.txt
run_case "hysteria2"   hysteria2    hysteria2.txt
run_case "trojan"      trojan       trojan.txt
run_case "anytls"      anytls       anytls.txt
run_case "shadowsocks" shadowsocks  shadowsocks.txt
run_case "snell"       snell        snell.txt
run_case "xhttp"       xhttp        xhttp-vless.txt
run_case "telegram"    telemt       telegram-proxy-link.txt
run_case "wireguard"   wireguard    moav-srv-wg.conf
run_case "amneziawg"   amneziawg    moav-srv-awg.conf
run_case "masterdns"   masterdns    masterdns-client_config.toml
run_case "xdns"        xdns         xdns-config.json
run_case "slipstream"  slipstream   slipstream-cert.pem
run_case "gooserelay"  gooserelay   gooserelay-client_config.json
# The reported bug: .toml and .json are what actually ship.
run_case "trusttunnel" trusttunnel  trusttunnel.toml trusttunnel.json

# dnstt now ships the server pubkey per user, written only when dnstt is enabled
# for that user. It used to key on RB_DNSTT_PUBKEY, which is server-wide and set
# regardless of ENABLE_DNSTT -- so the section appeared in DONATED bundles, whose
# users have no dnstt at all.
run_case "dnstt" dns-tunnel dnstt-server.pub

# The old signal must not resurrect it: a bundle with no dnstt artifact stays
# hidden even on a server whose pubkey is in the environment.
d="$tmp/dnstt-env"; mkdir -p "$d"
printf 'vless://x\n' > "$d/reality.txt"
RB_DNSTT_PUBKEY="deadbeefdeadbeefdeadbeefdeadbeef" render "$d"
st=$(section_style "$d/README.html" "dns-tunnel")
[ "$st" = "display:none" ] \
    && ok "dnstt: hidden when only the SERVER pubkey is set (donated-bundle case)" \
    || bad "dnstt: shown from the server pubkey alone (style='$st') — donated bundles regress"

# --- no section may key on a file nothing writes -----------------------------
# The root cause. Any _hide()/isfile() target must be a name some generator
# actually produces, or the section silently disappears from every bundle.
for name in $(grep -oE '_hide\("[^"]+"\)|isfile\(os\.path\.join\(OUT, "[^"]+"\)' \
                "$ROOT/scripts/lib/bundle_readme.py" | grep -oE '"[^"]+"' | tr -d '"' | sort -u); do
    case "$name" in
        # resolved through _candidates() globs to the moav-<server>-* names
        wireguard.conf|amneziawg.conf|wireguard-wstunnel.conf|wireguard-ipv6.conf|amneziawg-ipv6.conf) continue ;;
    esac
    if grep -rqF "$name" "$ROOT/scripts" --include="*.sh" 2>/dev/null; then
        ok "$name is written by a generator"
    else
        bad "$name is referenced by the guide but NO script writes it — section hides silently"
    fi
done

# --- the dashboard and the guide must read the SAME per-user signal ----------
# The reported bug was a disagreement: the dashboard listed dnstt for a donated
# user while the bundle had no dnstt file. Both sides now key on the per-user
# artifact, and neither may go back to a server-wide path.
if grep -q 'has_dnstt = (user_dir / "dnstt-server.pub").exists()' "$ROOT/admin/main.py"; then
    ok "dashboard detects dnstt from the user's own bundle"
else
    bad "dashboard does not key dnstt on the per-user file — it would claim dnstt for every user"
fi
if grep -qE 'has_dnstt.*bundle_path\.parent' "$ROOT/admin/main.py"; then
    bad "dashboard reads the SERVER dnstt pubkey again — donated users would show dnstt"
else
    ok "dashboard no longer reads the server-wide dnstt path"
fi
# RB_DNSTT_PUBKEY legitimately stays as the value the guide DISPLAYS; what must
# not come back is deriving visibility from it.
if grep -qE '^dnstt_present\s*=.*RB_DNSTT_PUBKEY' "$ROOT/scripts/lib/bundle_readme.py"; then
    bad "the guide keys dnstt VISIBILITY on RB_DNSTT_PUBKEY again (server-wide, ignores ENABLE_DNSTT)"
else
    ok "dnstt visibility is not derived from the server-wide pubkey"
fi


echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
