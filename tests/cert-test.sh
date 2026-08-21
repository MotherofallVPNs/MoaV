#!/bin/bash
# Regression test for `moav cert` (lib/cert.sh): domainless commands must no-op
# cleanly, and auto-renewal install must be idempotent (never double-schedule).
# Pure-function level — no root, no Docker, no real systemd/certbot.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# cert.sh's deps are split: logging in lib/common.sh, get_env_val in
# scripts/lib/common.sh, and _has_systemd/_root_prefix in moav.sh (the CLI
# entrypoint) — stub those two so the pure logic is what's under test.
# shellcheck source=/dev/null
source "$ROOT/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/cert.sh"
_root_prefix() { echo ""; }
_has_systemd() { return 1; }
# The log helpers reference colour vars normally set by moav.sh; default them
# so nounset doesn't trip.
: "${RED:=}" "${GREEN:=}" "${YELLOW:=}" "${BLUE:=}" "${CYAN:=}" "${WHITE:=}" "${NC:=}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SCRIPT_DIR="$WORK"
mkenv() { printf '%s\n' "$@" > "$WORK/.env"; }

echo "moav cert: domainless no-op + install idempotency"

# 1. status is a clean no-op when there's no DOMAIN (must NOT hit docker/certbot).
mkenv "DOMAIN="
out=$(cmd_cert status 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "Domainless mode" && ! printf '%s' "$out" | grep -qi "certbot\|docker compose"; then
    ok "cert status is a clean no-op when domainless"
else
    bad "cert status domainless: rc=$rc out=$out"
fi

# 2. auto_setup opts out entirely when CERT_AUTORENEW=false.
mkenv "DOMAIN=example.com" "CERT_AUTORENEW=false"
out=$(auto_setup_cert_renew 2>&1); rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -qi "installing"; then
    ok "auto-renew respects CERT_AUTORENEW=false (no install)"
else
    bad "CERT_AUTORENEW=false: rc=$rc out=$out"
fi

# 3. auto_setup is a no-op with no DOMAIN even when autorenew is on.
mkenv "DOMAIN=" "CERT_AUTORENEW=true"
out=$(auto_setup_cert_renew 2>&1); rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -qi "installing"; then
    ok "auto-renew is a no-op when domainless"
else
    bad "domainless auto-renew: rc=$rc out=$out"
fi

# 4. auto_setup is idempotent: already-scheduled → no re-install.
mkenv "DOMAIN=example.com" "CERT_AUTORENEW=true"
_has_systemd() { return 0; }
CERT_RENEW_TIMER_PATH="$WORK/moav-cert-renew.timer"
: > "$CERT_RENEW_TIMER_PATH"    # pretend the timer is already installed
out=$(auto_setup_cert_renew 2>&1); rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -qi "installing"; then
    ok "auto-renew is idempotent when already scheduled"
else
    bad "idempotent auto-renew: rc=$rc out=$out"
fi

# 5. cert_renew_install (cron.d path) is idempotent: two runs → identical file.
#    Only where /etc/cron.d exists (CI/Linux); skipped otherwise.
if [ -d /etc/cron.d ]; then
    _has_systemd() { return 1; }
    CERT_RENEW_CRON_PATH="$WORK/moav-cert-renew.cron"
    cert_renew_install --quiet >/dev/null 2>&1; a=$(cat "$CERT_RENEW_CRON_PATH" 2>/dev/null)
    cert_renew_install --quiet >/dev/null 2>&1; rc=$?; b=$(cat "$CERT_RENEW_CRON_PATH" 2>/dev/null)
    if [ "$rc" -eq 0 ] && [ -n "$a" ] && [ "$a" = "$b" ]; then
        ok "cert install is idempotent (cron.d: two runs, identical schedule)"
    else
        bad "install idempotency: rc=$rc identical=$([ "$a" = "$b" ] && echo yes || echo no)"
    fi
else
    printf '  skip  install idempotency (no /etc/cron.d on this host)\n'
fi

echo ""
if [ "$fail" -gt 0 ]; then echo "FAILED ($fail failed, $pass passed)"; exit 1; fi
echo "PASSED ($pass checks)"
