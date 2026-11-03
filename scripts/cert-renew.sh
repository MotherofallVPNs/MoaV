#!/bin/bash
set -euo pipefail

# =============================================================================
# Renew TLS certificates; restart consumers only when the cert actually changed.
# Loud on purpose: exits non-zero when certbot fails, when the cert cannot be
# read, or when it is still near expiry after the attempt, so the systemd timer
# / cron job records a FAILURE instead of a silent "unchanged". Every run also
# refreshes the moav_cert_* Prometheus textfile metric.
#
# Outcomes (one logged per run): RENEWED, HEALTHY (not due yet), FAILED,
# NEAR-EXPIRY, UNKNOWN (cert unreadable).
# Scheduled automatically by `moav cert install` (systemd timer / cron.d).
# Manual run: bash scripts/cert-renew.sh   (or: moav cert renew)
# =============================================================================

cd "$(dirname "$0")/.."
SCRIPT_DIR="$(pwd)"

source scripts/lib/common.sh
# Expiry reading, the warn threshold and the textfile metric writer live with
# the host-side `moav cert` command. Definitions only; safe to source here.
source lib/cert.sh

DOMAIN=$(get_env_val "DOMAIN" .env "")

if [[ -z "$DOMAIN" ]]; then
    log_info "No DOMAIN configured (domainless mode) - nothing to renew"
    exit 0
fi

# These copy /certs into the container at startup, so reload is not enough:
# they need a restart to pick up renewed files.
CERT_CONSUMERS="sing-box wstunnel trusttunnel admin grafana grafana-proxy"
WARN_DAYS=$(cert_renew_warn_days)

# live/ symlinks into archive/; the resolved mtime changes on renewal
cert_fingerprint() {
    docker compose run --rm --entrypoint sh certbot \
        -c "stat -Lc %Y /etc/letsencrypt/live/${DOMAIN}/fullchain.pem" 2>/dev/null | tail -1
}

restart_consumers() {
    local running svc
    running=$(docker compose ps --status running --format '{{.Service}}' 2>/dev/null || true)
    for svc in $CERT_CONSUMERS; do
        if grep -qx "$svc" <<<"$running"; then
            log_info "  Restarting $svc..."
            docker compose restart "$svc" >/dev/null 2>&1 || log_warn "  Failed to restart $svc"
        fi
    done
}

# finish <exit-code> <renew_failed 0|1>: publish the metric, then exit.
finish() {
    cert_metric_write 1 "${expiry:-}" "$2" \
        || log_warn "Could not write the cert-expiry metric (${CERT_METRIC_DIR_REL}/${CERT_METRIC_FILE})"
    exit "$1"
}

log_info "Checking certificate renewal for ${DOMAIN}..."

before=$(cert_fingerprint || true)

# compose overrides the certbot entrypoint to /bin/sh for the one-shot issue
# command; without --entrypoint this would run `/bin/sh renew` and never renew.
# --quiet silences certbot's "not yet due" chatter, NOT its exit code.
renew_rc=0
docker compose run --rm --entrypoint certbot certbot renew --quiet || renew_rc=$?

after=$(cert_fingerprint || true)
expiry=$(cert_expiry_epoch "$DOMAIN" || true)
days=""
[[ -n "$expiry" ]] && days=$(cert_days_left "$expiry")

changed=false
if [[ -n "$before" && -n "$after" && "$before" != "$after" ]]; then
    changed=true
    log_info "Certificate renewed - restarting TLS consumers..."
    restart_consumers
fi

if [[ "$renew_rc" -ne 0 ]]; then
    log_error "FAILED: certbot renew exited ${renew_rc} for ${DOMAIN}${days:+ (certificate expires in ${days} days)}"
    log_error "Inspect: docker compose logs certbot  |  moav doctor cert"
    finish 1 1
fi

if [[ -z "$expiry" ]]; then
    log_error "UNKNOWN: could not read the certificate expiry for ${DOMAIN} after the renewal check"
    log_error "Is the certificate issued and Docker running? Inspect: moav logs certbot"
    finish 1 0
fi

if [[ "$days" -le "$WARN_DAYS" ]]; then
    if [[ "$days" -lt 0 ]]; then
        log_error "NEAR-EXPIRY: certificate for ${DOMAIN} EXPIRED $(( -days )) day(s) ago and renewal did not replace it"
    else
        log_error "NEAR-EXPIRY: certificate for ${DOMAIN} expires in ${days} day(s) (threshold ${WARN_DAYS}) and renewal did not replace it"
    fi
    log_error "certbot thinks it is not due, or renews into a different lineage. Inspect: moav cert status  |  docker compose logs certbot"
    finish 1 0
fi

if $changed; then
    log_info "RENEWED: certificate for ${DOMAIN} now valid for ${days} days; TLS consumers restarted"
    finish 0 0
fi

log_info "HEALTHY: certificate for ${DOMAIN} valid for ${days} more days, renewal not due - services not restarted"
finish 0 0
