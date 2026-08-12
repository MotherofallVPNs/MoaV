#!/bin/bash
# Regression test: upgrading must not silently take a working CDN away.
#
# From a user report: "all the other configs work, only CDN doesn't, and it used
# to work a few versions ago". Two ways an upgrade does that, both silent:
#
# 1. ENABLE_CDN arrived in 2.1.0 defaulting to false. cdn_enabled() treats an
#    ABSENT flag as "on if CDN_SUBDOMAIN is set", which is what keeps existing
#    servers working -- but `moav update` offers to append every new variable
#    from .env.example with its default, the prompt defaults to yes, and the
#    appended `ENABLE_CDN=false` then beats that inference. The CDN survives
#    until the next bootstrap and then the inbound disappears.
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

# --- 1. the appended flag must preserve the running behaviour ----------------
# Drive the real function: a pre-2.1.0 .env (CDN in use, no ENABLE_CDN) against
# an .env.example that has ENABLE_CDN=false.
# check_env_additions takes no arguments: it reads $SCRIPT_DIR/.env against
# $SCRIPT_DIR/.env.example, so the fixture is a directory holding both.
append_for() {   # <env-contents-file> -> the resulting .env
    local work; work=$(mktemp -d)
    cp "$1" "$work/.env"
    printf 'DOMAIN=example.com\nENABLE_CDN=false\nCDN_SUBDOMAIN=cdn\n' > "$work/.env.example"
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

printf 'DOMAIN=example.com\nCDN_SUBDOMAIN=cdn\n' > "$TMP/pre210.env"
out=$(append_for "$TMP/pre210.env")

if printf '%s' "$out" | grep -qE '^ENABLE_CDN=true'; then
    ok "a server already using CDN keeps it: ENABLE_CDN=true is written"
elif printf '%s' "$out" | grep -qE '^ENABLE_CDN=false'; then
    bad "wrote ENABLE_CDN=false onto a server with CDN_SUBDOMAIN set — CDN dies at the next bootstrap"
else
    bad "ENABLE_CDN was not added at all: $(printf '%s' "$out" | tr '\n' '|')"
fi

# A server NOT using CDN must still get the safe default.
printf 'DOMAIN=example.com\n' > "$TMP/nocdn.env"
out_nocdn=$(append_for "$TMP/nocdn.env")
if printf '%s' "$out_nocdn" | grep -qE '^ENABLE_CDN=false'; then
    ok "a server without a CDN subdomain gets the opt-in default (false)"
else
    bad "turned CDN on for a server that never had it: $(printf '%s' "$out_nocdn" | tr '\n' '|')"
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
