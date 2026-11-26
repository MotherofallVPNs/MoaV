#!/bin/bash
# Regression test: CLI surface consistency.
#
# Four small bugs, one shape: something is stated in more than one place, and the
# copies drifted.
#
# 1. `moav net` was dispatched but absent from `moav help`, so a working command
#    was undiscoverable. Guarded by comparing dispatch tokens to help text.
# 2. Community links were listed in three places -- the Ctrl+C goodbye, the help
#    footer, and the TUI exit (which had none). The help footer never gained the
#    GitHub link. They now come from one function.
# 3. The profile box rows were hand-padded and had drifted to 64, 65 and 66
#    columns inside a 65-column box, so the right border wobbled. Rows are now
#    width-padded from the label.
# 4. The sing-box version was pinned in NINE places, not the five that were
#    documented -- Dockerfile.bootstrap and Dockerfile.client embed it too, so a
#    partial bump silently ships a bootstrap that renders configs with a
#    different binary than the server runs.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "CLI surface consistency tests"

# --- 1. every dispatched command appears in help ------------------------------
# Only the primary token of each case is required; aliases may stay undocumented.
help_text=$(sed -n '/^show_usage()/,/^}/p' "$ROOT/lib/menu.sh")
missing=""
for cmd in net doctor bootstrap start stop restart status logs profiles build \
           users donate conduit test export import migrate-ip regenerate-users \
           cert setup-dns switch-dns domainless check admin update apply; do
    grep -qE "^\s*[a-z|-]*\b$cmd\b" <<<"$(sed -n '/case /,/esac/p' "$ROOT/moav.sh")" || continue
    printf '%s' "$help_text" | grep -q "\b$cmd\b" || missing="$missing $cmd"
done
if [ -z "$missing" ]; then
    ok "every dispatched command is documented in 'moav help'"
else
    bad "dispatched but missing from help:$missing"
fi

# `net` is the one that regressed; assert it explicitly so a future reshuffle of
# the loop above cannot quietly stop covering it.
printf '%s' "$help_text" | grep -q '  net ' \
    && ok "'moav net' is listed in help" \
    || bad "'moav net' is dispatched but not in help (the original bug)"

# --- 2. community links have one source, and include GitHub -------------------
grep -q '^community_links()' "$ROOT/lib/common.sh" \
    && ok "community_links() exists as the single source" \
    || bad "no community_links() -- links will drift again"

for want in MOAV_URL_SITE MOAV_URL_TG MOAV_URL_X MOAV_URL_GH MOAV_URL_DOCS; do
    grep -q "$want" <<<"$(sed -n '/^community_links()/,/^}/p' "$ROOT/lib/common.sh")" \
        && ok "community_links uses $want" \
        || bad "community_links is missing $want"
done

# Both formatters must read the same variables. lib/common.sh already had
# print_community_links() when community_links() was added, and the two briefly
# hardcoded overlapping URL literals.
for fn in print_community_links community_links; do
    body=$(sed -n "/^$fn()/,/^}/p" "$ROOT/lib/common.sh")
    if grep -qE 'https?://' <<<"$body"; then
        bad "$fn() hardcodes a URL instead of using the MOAV_URL_* variables"
    else
        ok "$fn() takes its URLs from the MOAV_URL_* variables"
    fi
done

# The three surfaces must all use it rather than hand-listing.
grep -q 'community_links' "$ROOT/moav.sh"      && ok "Ctrl+C goodbye uses community_links" || bad "goodbye() hand-lists links"
n=$(grep -c 'community_links' "$ROOT/lib/menu.sh")
[ "${n:-0}" -ge 2 ] \
    && ok "both the help footer and the TUI exit use community_links" \
    || bad "menu.sh uses community_links $n time(s); expected the help footer AND the TUI exit"

# The TUI exit is the one that had no links at all.
tui_exit=$(sed -n '/0|q|Q)/,/;;/p' "$ROOT/lib/menu.sh")
grep -q 'community_links' <<<"$tui_exit" \
    && ok "TUI exit prints the links (it printed none before)" \
    || bad "TUI exit still has no community links"

# --- 3. the profile box is square --------------------------------------------
grep -q '^profile_row()' "$ROOT/lib/common.sh" \
    && ok "profile_row() pads rows by width" \
    || bad "no profile_row() -- rows are hand-padded and will drift"

if grep -qE '_line="  \$\{CYAN\}\|' "$ROOT/lib/service.sh"; then
    bad "hand-padded profile rows remain in service.sh"
else
    ok "no hand-padded profile rows left"
fi

# Render for real and compare every row to the box width.
render=$(
    CYAN=""; NC=""; GREEN=""; DIM=""; YELLOW=""
    eval "$(sed -n '/^PROFILE_ROW_W=/,/^}$/p' "$ROOT/lib/common.sh")"
    for spec in "1|proxy|Reality, Trojan, Hysteria2 (v2ray apps)" \
                "2|wireguard|WireGuard VPN + WebSocket tunnel" \
                "3|amneziawg|AmneziaWG (obfuscated WireGuard)" \
                "4|dnstunnel|DNS tunnels (dnstt/Slipstream/MasterDNS/XDNS)" \
                "5|trusttunnel|TrustTunnel VPN (HTTP/2 + QUIC)" \
                "6|xhttp|VLESS+XHTTP+Reality (Xray-core)" \
                "7|telegram|Telegram MTProxy (fake-TLS)" \
                "8|admin|Stats dashboard (port 9443)" \
                "4|dnstunnel|DNS tunnels (disabled)"; do
        IFS='|' read -r n nm d <<<"$spec"
        profile_row "$n" "$nm" "$d"; echo
    done
)
widths=$(printf '%s\n' "$render" | awk -F'│' 'NF>=3 {print length($2)}' | sort -u)
if [ "$(printf '%s\n' "$widths" | grep -c .)" -eq 1 ]; then
    ok "every profile row renders to the same width ($widths columns)"
else
    bad "profile rows render at differing widths: $(printf '%s' "$widths" | tr '\n' ' ')"
fi

# The box border must match that width, or the rows are uniformly wrong.
# Counted per CHARACTER, not per byte: awk's length() counts bytes in most
# builds and "─" is three of them, which reads a 65-column rule as 195.
border=$(grep -m1 -oE '┌─+┐' "$ROOT/lib/service.sh" | grep -o '─' | grep -c .)
if [ -n "$border" ] && [ "$border" = "$widths" ]; then
    ok "row width matches the box border ($border)"
else
    bad "rows are $widths columns but the border is $border"
fi

# --- 4. the DNS tunnel label names all four ----------------------------------
for t in dnstt Slipstream MasterDNS XDNS; do
    grep -q "$t" <<<"$(grep 'dnstunnel_line=.*profile_row' "$ROOT/lib/service.sh")" \
        && ok "dnstunnel label names $t" \
        || bad "dnstunnel label omits $t"
done

# --- 5. every sing-box pin agrees --------------------------------------------
# Nine sites, and two of them (Dockerfile.bootstrap, Dockerfile.client) were not
# in the card. A partial bump ships mismatched binaries.
vers=$(grep -rhoE 'SINGBOX_VERSION[=: ]+\$?\{?[A-Z_]*:?-?([0-9]+\.[0-9]+\.[0-9]+)' \
        "$ROOT/.env.example" "$ROOT/docker-compose.yml" "$ROOT"/dockerfiles/Dockerfile.* "$ROOT"/lib/*.sh 2>/dev/null \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -u)
count=$(printf '%s\n' "$vers" | grep -c .)
if [ "$count" -eq 1 ]; then
    ok "all sing-box pins agree ($vers)"
else
    bad "sing-box pins disagree: $(printf '%s' "$vers" | tr '\n' ' ')"
fi

# --- 6. IPv6 profile labels survive truncation -------------------------------
# The marker used to be a -IPv6 SUFFIX on an already-long name, so clients that
# truncate showed two identical rows. It must precede the username.
if grep -rqE '"\$\{USER(_ID|NAME)\}-IPv6"' "$ROOT/scripts/"*.sh; then
    bad "IPv6 marker is still a suffix -- truncating clients show duplicate rows"
else
    ok "IPv6 marker precedes the username (survives truncation)"
fi
n6=$(grep -rc 'IPv6-${USER' "$ROOT/scripts/generate-user.sh" "$ROOT/scripts/singbox-user-add.sh" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')
[ "${n6:-0}" -ge 10 ] \
    && ok "all $n6 IPv6 link call sites use the prefixed form" \
    || bad "only ${n6:-0} IPv6 call sites converted; expected 10"

# The rename must not reach the bundle: README.html is keyed on fixed filenames
# and protocol slugs, never on the label. Assert that stays true.
if grep -qE 'reality-ipv6|wg6\.conf' "$ROOT/scripts/lib/bundle_readme.py"; then
    ok "README.html keys off fixed slugs/filenames, not the profile label"
else
    bad "bundle_readme.py no longer keys off fixed slugs -- a label rename could break README.html"
fi
if grep -qE "split\(['\"]#" "$ROOT/scripts/lib/bundle_readme.py"; then
    bad "bundle_readme.py parses the URI fragment -- label renames would break it"
else
    ok "nothing parses the URI fragment back out"
fi

echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
