#!/bin/bash
# Regression test for scripts/cert-renew.sh outcome logic (the yorkschool
# class: a failing `certbot renew --quiet` used to log "unchanged" and exit 0,
# so the daily timer never recorded a failure and the cert expired unnoticed).
#
# Runs the real script against a fake `docker` on PATH that plays certbot:
# renew exit code, before/after fingerprint, and the cert's notAfter are all
# driven by env vars. Asserts the logged outcome, the exit code, which services
# were restarted, and the Prometheus textfile metric. No Docker, no root.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# The script cd's to its own parent and reads ./.env, so give it a private copy
# of the tree rather than touching the real checkout's .env.
cp -R "$ROOT/scripts" "$ROOT/lib" "$WORK/"
mkdir -p "$WORK/bin" "$WORK/configs/monitoring"
PROM="$WORK/configs/monitoring/textfile/moav_cert.prom"

# Fake docker. Dispatches on the compose verb / certbot subcommand.
cat > "$WORK/bin/docker" <<'SHIM'
#!/bin/bash
args="$*"
case "$args" in
    *"certbot renew"*)
        exit "${FAKE_RENEW_RC:-0}" ;;
    *"stat -Lc"*)
        n=$(cat "$FAKE_STATE/calls" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$FAKE_STATE/calls"
        if [ "$n" -eq 1 ]; then echo "${FAKE_MTIME_BEFORE}"; else echo "${FAKE_MTIME_AFTER}"; fi ;;
    *"--entrypoint python3 certbot"*)
        [ -n "${FAKE_EXPIRY:-}" ] && echo "$FAKE_EXPIRY"; exit 0 ;;
    *"compose ps"*)
        printf '%s\n' ${FAKE_RUNNING:-} ;;
    *"compose restart"*)
        echo "${args##* }" >> "$FAKE_STATE/restarted" ;;
    *) echo "unexpected docker call: $args" >&2; exit 99 ;;
esac
SHIM
chmod +x "$WORK/bin/docker"
export PATH="$WORK/bin:$PATH"
export FAKE_STATE="$WORK/state"

# +3600 keeps whole-day counts stable across the second boundary.
now=$(( $(date +%s) + 3600 ))
# run <label> ; env vars set by the caller. Captures out/rc, resets shim state.
run() {
    rm -rf "$FAKE_STATE"; mkdir -p "$FAKE_STATE"
    out=$(bash "$WORK/scripts/cert-renew.sh" 2>&1); rc=$?
    restarted=$(cat "$FAKE_STATE/restarted" 2>/dev/null | tr '\n' ' ')
}
mkenv() { printf '%s\n' "$@" > "$WORK/.env"; }
metric() { sed -n "s/^$1 //p" "$PROM" 2>/dev/null | head -1; }

echo "cert-renew.sh: renewed / healthy / failed / near-expiry / unknown outcomes"

# 0. Domainless: exit 0, never calls docker.
mkenv "DOMAIN="
run
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "domainless" && [ ! -d "$FAKE_STATE/calls" ]; then
    ok "domainless mode is a clean no-op"
else
    bad "domainless: rc=$rc out=$out"
fi

mkenv "DOMAIN=example.com"
export FAKE_RUNNING="sing-box admin grafana xray"

# 1. HEALTHY: certbot ok, cert unchanged, 60 days left -> exit 0, no restarts.
export FAKE_RENEW_RC=0 FAKE_MTIME_BEFORE=100 FAKE_MTIME_AFTER=100 FAKE_EXPIRY=$(( now + 60*86400 ))
run
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "HEALTHY" && [ -z "$restarted" ]; then
    ok "healthy / not due: exit 0, logged HEALTHY, no restarts"
else
    bad "healthy: rc=$rc restarted='$restarted' out=$out"
fi
if [ "$(metric moav_cert_managed)" = "1" ] && [ "$(metric moav_cert_renew_failed)" = "0" ] \
   && [ "$(metric moav_cert_expiry_seconds)" = "$FAKE_EXPIRY" ] && [ "$(metric moav_cert_expiry_days)" = "60" ] \
   && [ -n "$(metric moav_cert_check_timestamp_seconds)" ]; then
    ok "textfile metric written: managed=1 renew_failed=0 expiry + days (60) + check timestamp"
else
    bad "metric after healthy run: $(cat "$PROM" 2>/dev/null)"
fi
if [ -z "$(ls -A "$WORK/configs/monitoring/textfile" | grep -v '^moav_cert.prom$')" ]; then
    ok "metric write is atomic (no temp file left beside the .prom)"
else
    bad "leftover files in textfile dir: $(ls -A "$WORK/configs/monitoring/textfile")"
fi

# 2. RENEWED: cert changed -> exit 0, only running TLS consumers restarted.
export FAKE_MTIME_BEFORE=100 FAKE_MTIME_AFTER=200 FAKE_EXPIRY=$(( now + 89*86400 ))
run
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "RENEWED" && [ "$restarted" = "sing-box admin grafana " ]; then
    ok "renewed: exit 0, logged RENEWED, restarted exactly the running TLS consumers"
else
    bad "renewed: rc=$rc restarted='$restarted' out=$out"
fi

# 3. FAILED: certbot exits 1 -> exit non-zero, logged FAILED, metric flags it.
export FAKE_RENEW_RC=1 FAKE_MTIME_BEFORE=100 FAKE_MTIME_AFTER=100 FAKE_EXPIRY=$(( now + 60*86400 ))
run
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "FAILED: certbot renew exited 1" && [ -z "$restarted" ]; then
    ok "certbot failure: non-zero exit (was silent exit 0), logged FAILED"
else
    bad "failed: rc=$rc out=$out"
fi
[ "$(metric moav_cert_renew_failed)" = "1" ] && ok "metric moav_cert_renew_failed=1 after a failed renew" \
                                              || bad "renew_failed metric: $(metric moav_cert_renew_failed)"

# 4. NEAR-EXPIRY: certbot "succeeds" but the cert is unchanged at 10 days left
#    (the yorkschool shape) -> exit non-zero.
export FAKE_RENEW_RC=0 FAKE_MTIME_BEFORE=100 FAKE_MTIME_AFTER=100 FAKE_EXPIRY=$(( now + 10*86400 ))
run
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "NEAR-EXPIRY" && printf '%s' "$out" | grep -q "threshold 21"; then
    ok "unchanged cert inside 21 days: non-zero exit, logged NEAR-EXPIRY (default threshold 21)"
else
    bad "near-expiry: rc=$rc out=$out"
fi
[ "$(metric moav_cert_renew_failed)" = "0" ] && ok "renew_failed stays 0 when certbot itself succeeded" \
                                              || bad "renew_failed after near-expiry: $(metric moav_cert_renew_failed)"

# 4b. Already expired -> non-zero, says EXPIRED.
export FAKE_EXPIRY=$(( now - 3*86400 - 7200 ))
run
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "EXPIRED 3 day(s) ago"; then
    ok "expired cert after a no-op renew: non-zero exit, says EXPIRED"
else
    bad "expired: rc=$rc out=$out"
fi

# 4c. Threshold is configurable: CERT_RENEW_WARN_DAYS=5 makes 10 days healthy.
mkenv "DOMAIN=example.com" "CERT_RENEW_WARN_DAYS=5"
export FAKE_EXPIRY=$(( now + 10*86400 ))
run
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "HEALTHY"; then
    ok "CERT_RENEW_WARN_DAYS=5: 10 days left is HEALTHY"
else
    bad "custom threshold: rc=$rc out=$out"
fi
mkenv "DOMAIN=example.com"

# 5. UNKNOWN: expiry unreadable -> non-zero (was: warn + exit 0).
export FAKE_EXPIRY=""
run
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "UNKNOWN"; then
    ok "unreadable cert: non-zero exit, logged UNKNOWN"
else
    bad "unknown: rc=$rc out=$out"
fi
if [ "$(metric moav_cert_managed)" = "1" ] && [ -z "$(metric moav_cert_expiry_seconds)" ]; then
    ok "metric still written (managed=1, no expiry series) so the stale/unreadable alerts can fire"
else
    bad "metric after unknown: $(cat "$PROM" 2>/dev/null)"
fi

# 6. certbot failed but the cert did change: consumers still restart, exit non-zero.
export FAKE_RENEW_RC=1 FAKE_MTIME_BEFORE=100 FAKE_MTIME_AFTER=300 FAKE_EXPIRY=$(( now + 89*86400 ))
run
if [ "$rc" -ne 0 ] && [ "$restarted" = "sing-box admin grafana " ]; then
    ok "renewed-but-certbot-failed: consumers restarted, exit still non-zero"
else
    bad "renewed+failed: rc=$rc restarted='$restarted' out=$out"
fi

echo ""
if [ "$fail" -gt 0 ]; then echo "FAILED ($fail failed, $pass passed)"; exit 1; fi
echo "PASSED ($pass checks)"
