#!/bin/bash
set -euo pipefail

# =============================================================================
# Renew TLS certificates; restart consumers only when the cert actually changed.
# Scheduled automatically by `moav cert install` (systemd timer / cron.d).
# Manual run: bash scripts/cert-renew.sh
# =============================================================================

cd "$(dirname "$0")/.."

source scripts/lib/common.sh

DOMAIN=$(sed -n 's/^DOMAIN=//p' .env 2>/dev/null | tail -1 | tr -d '"' | tr -d "'")

if [[ -z "$DOMAIN" ]]; then
    log_info "No DOMAIN configured (domainless mode) - nothing to renew"
    exit 0
fi

# These copy /certs into the container at startup, so reload is not enough —
# they need a restart to pick up renewed files.
CERT_CONSUMERS="sing-box trusttunnel admin grafana grafana-proxy"

# live/ symlinks into archive/; the resolved mtime changes on renewal
cert_fingerprint() {
    docker compose run --rm --entrypoint sh certbot \
        -c "stat -Lc %Y /etc/letsencrypt/live/${DOMAIN}/fullchain.pem" 2>/dev/null | tail -1
}

log_info "Checking certificate renewal for ${DOMAIN}..."

before=$(cert_fingerprint || true)

# compose overrides the certbot entrypoint to /bin/sh for the one-shot issue
# command; without --entrypoint this would run `/bin/sh renew` and never renew
docker compose run --rm --entrypoint certbot certbot renew --quiet

after=$(cert_fingerprint || true)

if [[ -z "$after" ]]; then
    log_warn "Could not read certificate after renewal check - skipping service restarts"
    exit 0
fi

if [[ "$before" == "$after" ]]; then
    log_info "Certificate unchanged - services not restarted"
    exit 0
fi

log_info "Certificate renewed - restarting TLS consumers..."
running=$(docker compose ps --status running --format '{{.Service}}' 2>/dev/null || true)
for svc in $CERT_CONSUMERS; do
    if grep -qx "$svc" <<<"$running"; then
        log_info "  Restarting $svc..."
        docker compose restart "$svc" >/dev/null 2>&1 || log_warn "  Failed to restart $svc"
    fi
done

log_info "Certificate renewal complete"
