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
# "env" as the privilege prefix: a no-op wrapper that satisfies the "root or
# sudo" gate so the (re)install path can be exercised without being root.
_root_prefix() { echo "env"; }
_has_systemd() { return 1; }
# The start-time status line reads expiry through the certbot container; stub
# it so the pure scheduling logic is what's under test (no Docker here). The
# extra hour keeps the whole-day count stable across the second boundary.
cert_expiry_epoch() { echo $(( $(date +%s) + 60 * 86400 + 3600 )); }
# The log helpers reference colour vars normally set by moav.sh; default them
# so nounset doesn't trip.
: "${RED:=}" "${GREEN:=}" "${YELLOW:=}" "${BLUE:=}" "${CYAN:=}" "${WHITE:=}" "${NC:=}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SCRIPT_DIR="$WORK"
# Prefixed calls (`env systemctl ...`) bypass shell functions, so the installer
# needs a systemctl on PATH; direct calls (is-active) hit the function stubs.
mkdir -p "$WORK/bin"; printf '#!/bin/bash\nexit 0\n' > "$WORK/bin/systemctl"; chmod +x "$WORK/bin/systemctl"
export PATH="$WORK/bin:$PATH"
mkenv() { printf '%s\n' "$@" > "$WORK/.env"; }

echo "moav cert: domainless no-op + install idempotency + start-time cert status"

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

# 4. auto_setup is idempotent: already-scheduled (timer active, unit pointing
#    at this checkout) → no re-install, but the one-line cert status still prints.
mkenv "DOMAIN=example.com" "CERT_AUTORENEW=true"
_has_systemd() { return 0; }
systemctl() { return 0; }    # is-active / enable / daemon-reload all "succeed"
CERT_RENEW_TIMER_PATH="$WORK/moav-cert-renew.timer"
CERT_RENEW_SERVICE_PATH="$WORK/moav-cert-renew.service"
: > "$CERT_RENEW_TIMER_PATH"    # pretend the timer is already installed
printf 'ExecStart=/bin/bash %s/scripts/cert-renew.sh\n' "$SCRIPT_DIR" > "$CERT_RENEW_SERVICE_PATH"
out=$(auto_setup_cert_renew 2>&1); rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -qi "installing" && printf '%s' "$out" | grep -q "valid for 60 more days"; then
    ok "auto-renew is idempotent when already scheduled (and prints the cert status line)"
else
    bad "idempotent auto-renew: rc=$rc out=$out"
fi

# 4b. The upgraded-box gap: a unit file that points at a PREVIOUS install dir
#     (e.g. the pre-/opt/moav checkout) must count as not scheduled → reinstall.
printf 'ExecStart=/bin/bash /old/moav/scripts/cert-renew.sh\n' > "$CERT_RENEW_SERVICE_PATH"
out=$(auto_setup_cert_renew 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qi "installing" && grep -q "$SCRIPT_DIR/scripts/cert-renew.sh" "$CERT_RENEW_SERVICE_PATH"; then
    ok "stale unit (old install dir) is reinstalled at start"
else
    bad "stale unit reinstall: rc=$rc out=$out"
fi

# 4c. Timer file present but the timer is not active → reinstall (enable --now).
printf 'ExecStart=/bin/bash %s/scripts/cert-renew.sh\n' "$SCRIPT_DIR" > "$CERT_RENEW_SERVICE_PATH"
systemctl() { [ "${1:-}" = "is-active" ] && return 3; return 0; }
out=$(auto_setup_cert_renew 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qi "installing"; then
    ok "inactive timer is reinstalled at start"
else
    bad "inactive timer reinstall: rc=$rc out=$out"
fi
systemctl() { return 0; }

# 4d. The start line turns into a warning when the cert is near expiry, and
#     the textfile metric is refreshed (managed=1, expiry present).
cert_expiry_epoch() { echo $(( $(date +%s) + 10 * 86400 + 3600 )); }
out=$(auto_setup_cert_renew 2>&1); rc=$?
prom="$WORK/configs/monitoring/textfile/moav_cert.prom"
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "expires in 10 day(s), renewal overdue" \
   && grep -q '^moav_cert_managed 1$' "$prom" && grep -q '^moav_cert_expiry_days 10$' "$prom"; then
    ok "near-expiry cert warns at start and the textfile metric is written"
else
    bad "near-expiry start line: rc=$rc out=$out prom=$(cat "$prom" 2>/dev/null)"
fi

# 4e. Domainless: the metric is written as unmanaged so the alerts stay quiet.
mkenv "DOMAIN="
auto_setup_cert_renew >/dev/null 2>&1
if grep -q '^moav_cert_managed 0$' "$prom" && ! grep -q 'moav_cert_expiry' "$prom"; then
    ok "domainless start writes moav_cert_managed 0 (no expiry series)"
else
    bad "domainless metric: $(cat "$prom" 2>/dev/null)"
fi
cert_expiry_epoch() { echo $(( $(date +%s) + 60 * 86400 + 3600 )); }

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
