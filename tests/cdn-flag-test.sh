#!/bin/bash
# Regression test: CDN is opt-in via ENABLE_CDN, without breaking servers that
# predate the flag.
#
# CDN links only work once the subdomain is actually proxied through Cloudflare.
# .env.example used to ship CDN_SUBDOMAIN=cdn with no flag, so every new server
# generated CDN links by default and handed users a config that could not
# connect unless they had separately set up Cloudflare.
#
# The flag ships UNSET (commented) now: cdn_enabled() then turns CDN on exactly
# when CDN_SUBDOMAIN is set, so a configured server needs no second toggle and an
# unconfigured one stays off. An explicit true/false still wins. Shipping it
# unset also means `moav update` never appends it onto an upgrading server.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "ENABLE_CDN flag"

# --- the flag ships commented (unset), so "on when configured" governs --------
if grep -qE '^#\s*ENABLE_CDN=\s*$' "$ROOT/.env.example"; then
    ok "'.env.example' ships ENABLE_CDN commented (unset)"
elif grep -qE '^ENABLE_CDN=' "$ROOT/.env.example"; then
    bad "ENABLE_CDN is set in .env.example ('$(grep -E '^ENABLE_CDN=' "$ROOT/.env.example")') — ship it commented so 'on when configured' governs"
else
    bad "ENABLE_CDN line missing from .env.example"
fi

# --- cdn_enabled() truth table ----------------------------------------------
# Run from a directory with no .env so only the environment decides.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
probe() {  # <env-assignments> -> prints on|off
    (
        cd "$ROOT" || exit
        # shellcheck disable=SC1091
        source scripts/lib/common.sh >/dev/null 2>&1
        cd "$tmp" || exit          # no .env here: environment only
        eval "$1"
        if cdn_enabled; then echo on; else echo off; fi
    )
}
check() { # <label> <env> <expected>
    local got; got=$(probe "$2")
    [ "$got" = "$3" ] && ok "$1 -> $3" || bad "$1 -> $got (expected $3)"
}
check "flag true, no subdomain"          'ENABLE_CDN=true;  CDN_SUBDOMAIN=' on
check "flag false, subdomain set"        'ENABLE_CDN=false; CDN_SUBDOMAIN=cdn' off
check "no flag, subdomain set (upgrade)" 'unset ENABLE_CDN; CDN_SUBDOMAIN=cdn' on
check "no flag, no subdomain"            'unset ENABLE_CDN; CDN_SUBDOMAIN=' off
check "flag false wins over CDN_DOMAIN"  'ENABLE_CDN=false; CDN_DOMAIN=cdn.example.com' off

# --- every CDN_DOMAIN derivation must be gated -------------------------------
# Downstream code all tests `-n "$CDN_DOMAIN"`, so gating the derivation is what
# turns CDN off everywhere. A new derivation site added ungated would leak.
for f in scripts/generate-user.sh scripts/bootstrap.sh scripts/user-add.sh scripts/singbox-user-add.sh; do
    if grep -q 'cdn_enabled' "$ROOT/$f"; then
        ok "$(basename "$f") gates CDN on cdn_enabled"
    else
        bad "$(basename "$f") derives CDN_DOMAIN without cdn_enabled — CDN leaks when disabled"
    fi
done

# --- doctor must respect the flag and check for the orange cloud -------------
grep -q 'ENABLE_CDN' "$ROOT/lib/doctor.sh" \
    && ok "doctor respects ENABLE_CDN" \
    || bad "doctor still checks CDN regardless of the flag"
# Match the actual test, not the prose: "cf-ray" also appears in the warning
# text, so a looser grep passes even after the check itself is removed.
if grep -qE 'grep -q[A-Za-z]* .\^\(cf-ray' "$ROOT/lib/doctor.sh"; then
    ok "doctor verifies the record is Cloudflare-PROXIED, not just resolving"
else
    bad "doctor only checks resolution — a grey-cloud record would pass"
fi

echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
