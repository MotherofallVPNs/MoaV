#!/bin/bash
# Regression test: upgrading must not silently take a working CDN away.
#
# From a user report: "all the other configs work, only CDN doesn't, and it used
# to work a few versions ago". Two ways an upgrade does that, both silent:
#
# 1. cdn_enabled() treats an ABSENT flag as "on if CDN_SUBDOMAIN is set", which
#    is what keeps existing servers working. The trap was that `moav update`
#    offers to append every new .env.example variable with its default (prompt
#    defaults to yes), and an appended `ENABLE_CDN=false` then beat that
#    inference -- the CDN survived until the next bootstrap, then vanished.
#    Fix: .env.example ships ENABLE_CDN commented, so update never appends it and
#    the subdomain inference stays in charge. This test pins that.
#
# 2. bootstrap rotates CDN_WS_PATH when it is empty or the old "/ws" default.
#    CDN is the only protocol whose share link carries a path, so every other
#    protocol keeps working and the already-distributed CDN configs 404. Rotating
#    is correct (a guessable path is an active-probing target); doing it without
#    telling the operator to reissue bundles is not.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "CDN across an upgrade: flag inference and path rotation"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --- 1. moav update must never append ENABLE_CDN onto an upgrading server -----
# .env.example ships ENABLE_CDN commented, so check_env_additions (which copies
# only uncommented vars) must not add it. Appending `=false` is exactly what
# used to switch a configured CDN off at the next bootstrap; leaving the flag
# unset keeps cdn_enabled()'s subdomain inference in charge.
# check_env_additions takes no arguments: it reads $SCRIPT_DIR/.env against
# $SCRIPT_DIR/.env.example, so the fixture is a directory holding both.
append_for() {   # <env-contents-file> -> the resulting .env
    local work; work=$(mktemp -d)
    cp "$1" "$work/.env"
    cp "$ROOT/.env.example" "$work/.env.example"   # the real, shipped example
    (
        GREEN=''; YELLOW=''; RED=''; DIM=''; NC=''; WHITE=''; CYAN=''; BLUE=''
        SCRIPT_DIR="$work"
        # shellcheck disable=SC1091
        source "$ROOT/scripts/lib/common.sh" >/dev/null 2>&1
        # shellcheck disable=SC1091
        source "$ROOT/lib/common.sh"         >/dev/null 2>&1
        # shellcheck disable=SC1091
        source "$ROOT/lib/update.sh"         >/dev/null 2>&1
        # Answer the prompt with the default (Enter = yes).
        check_env_additions </dev/null >/dev/null 2>&1
        cat "$work/.env"
    )
    rm -rf "$work"
}

# A pre-flag server with CDN in use (CDN_SUBDOMAIN set, no ENABLE_CDN).
printf 'DOMAIN=example.com\nCDN_SUBDOMAIN=cdn\n' > "$TMP/pre210.env"
out=$(append_for "$TMP/pre210.env")
if printf '%s' "$out" | grep -qE '^ENABLE_CDN=false'; then
    bad "appended ENABLE_CDN=false onto a server with CDN_SUBDOMAIN set — CDN dies at the next bootstrap"
elif printf '%s' "$out" | grep -qE '^ENABLE_CDN='; then
    bad "appended an explicit ENABLE_CDN onto an upgrading server (should stay unset): $(printf '%s' "$out" | grep -E '^ENABLE_CDN=')"
else
    ok "a CDN-using server keeps its CDN: ENABLE_CDN is left unset (inference stays on)"
fi

# The inference must actually resolve to ON for that resulting .env.
on=$( cd "$(mktemp -d)" && printf '%s\n' "$out" > .env && \
      ( source "$ROOT/scripts/lib/common.sh" >/dev/null 2>&1
        unset ENABLE_CDN CDN_SUBDOMAIN CDN_DOMAIN
        cdn_enabled && echo on || echo off ) )
[ "$on" = "on" ] \
    && ok "cdn_enabled() stays on for the upgraded CDN server" \
    || bad "CDN resolved off after upgrade ($on) — the server lost CDN"

# A server that never used CDN must not get a surprise flag either.
printf 'DOMAIN=example.com\n' > "$TMP/nocdn.env"
out_nocdn=$(append_for "$TMP/nocdn.env")
if printf '%s' "$out_nocdn" | grep -qE '^ENABLE_CDN='; then
    bad "appended ENABLE_CDN onto a server that never had CDN: $(printf '%s' "$out_nocdn" | grep -E '^ENABLE_CDN=')"
else
    ok "a server without a CDN subdomain gets no ENABLE_CDN line"
fi

# --- 2. cdn_enabled must still honour an explicit false ----------------------
# The fix above is about what gets WRITTEN. An operator who deliberately sets
# false must still be obeyed, or the flag is meaningless.
explicit=$(
    cd "$TMP" || exit 99
    printf 'ENABLE_CDN=false\nCDN_SUBDOMAIN=cdn\n' > .env
    # shellcheck disable=SC1091
    source "$ROOT/scripts/lib/common.sh" >/dev/null 2>&1
    unset ENABLE_CDN CDN_SUBDOMAIN CDN_DOMAIN
    cdn_enabled && echo on || echo off
)
[ "$explicit" = "off" ] \
    && ok "an explicit ENABLE_CDN=false still wins over CDN_SUBDOMAIN" \
    || bad "explicit false was ignored ($explicit) — the flag does nothing"

inferred=$(
    cd "$TMP" || exit 99
    printf 'CDN_SUBDOMAIN=cdn\n' > .env
    # shellcheck disable=SC1091
    source "$ROOT/scripts/lib/common.sh" >/dev/null 2>&1
    unset ENABLE_CDN CDN_SUBDOMAIN CDN_DOMAIN
    cdn_enabled && echo on || echo off
)
[ "$inferred" = "on" ] \
    && ok "an absent flag still infers CDN from CDN_SUBDOMAIN" \
    || bad "absent flag read as off ($inferred) — every pre-2.1.0 server loses CDN"

# --- 3. rotating the WS path must say so -------------------------------------
rotate_block=$(sed -n '/^# Generate or load CDN WS path/,/^export CDN_WS_PATH/p' "$ROOT/scripts/bootstrap.sh")
if [ -z "$rotate_block" ]; then
    bad "could not find the CDN WS path block in bootstrap.sh"
else
    if printf '%s' "$rotate_block" | grep -qi 'rotated'; then
        ok "bootstrap warns when it rotates an existing path"
    else
        bad "path rotation is silent — the operator never learns to reissue bundles"
    fi
    # The warning is only useful if it says what to do about it.
    if printf '%s' "$rotate_block" | grep -q 'regenerate-users'; then
        ok "the warning names the fix (regenerate-users)"
    else
        bad "the rotation warning does not say how to recover"
    fi
    # And it must NOT fire on a first-time generation, or every fresh install
    # ships a scary warning about configs that do not exist yet.
    if printf '%s' "$rotate_block" | grep -q '_cdn_path_before'; then
        ok "the warning is conditional on there having been a previous path"
    else
        bad "no first-install guard — a fresh bootstrap would warn about nothing"
    fi
    # The path itself must never reach the logs: bootstrap output gets pasted
    # into issues, and this path is an active-probing barrier.
    if printf '%s' "$rotate_block" | grep -qE 'log_(info|warn).*\$\{?CDN_WS_PATH'; then
        bad "the CDN WS path is logged — it ends up in pasted install transcripts"
    else
        ok "the path value stays out of the logs"
    fi
fi

echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
