#!/bin/bash
# lib/cert.sh — TLS certificate auto-renewal scheduling and the `moav cert`
# command. Let's Encrypt certs expire after 90 days and nothing renewed them
# before v1.8.5, so a systemd timer (or a cron.d drop-in where systemd is
# absent) is installed automatically at the end of `moav start` when DOMAIN is
# set, unless CERT_AUTORENEW=false.
#
# Also home to the expiry helpers shared by scripts/cert-renew.sh, doctor and
# `moav start`: read notAfter through the certbot container, count days left,
# tell whether the scheduler is really installed, and write the
# moav_cert_* Prometheus textfile metric that node-exporter serves.
#
# Sourced by moav.sh after lib/common.sh: `moav start` calls
# auto_setup_cert_renew, and the dispatcher routes `moav cert` here.
# scripts/cert-renew.sh sources it too (only the pure helpers are used there).
#
# Definitions only — nothing here runs at source time.

CERT_RENEW_UNIT="moav-cert-renew"
CERT_RENEW_SERVICE_PATH="/etc/systemd/system/${CERT_RENEW_UNIT}.service"
CERT_RENEW_TIMER_PATH="/etc/systemd/system/${CERT_RENEW_UNIT}.timer"
CERT_RENEW_CRON_PATH="/etc/cron.d/moav-cert-renew"

# certbot renews at 30 days left; a cert still under this many days after a
# renewal attempt means renewal has been failing for over a week.
CERT_RENEW_WARN_DAYS_DEFAULT=21
# Under this many days doctor fails outright and the start line turns red.
CERT_RENEW_CRIT_DAYS=7

# node-exporter mounts this directory read-only as its textfile collector
# (docker-compose.yml). Gitignored; written by cert_metric_write.
CERT_METRIC_DIR_REL="configs/monitoring/textfile"
CERT_METRIC_FILE="moav_cert.prom"

# Read via the certbot container: python + cryptography are certbot's own deps,
# so this works on every certbot image (the openssl CLI is not guaranteed).
CERT_EXPIRY_PY='import sys, datetime
from cryptography import x509
c = x509.load_pem_x509_certificate(open(sys.argv[1], "rb").read())
na = getattr(c, "not_valid_after_utc", None) or c.not_valid_after.replace(tzinfo=datetime.timezone.utc)
print(int(na.timestamp()))'

# cert_expiry_epoch <domain>: unix time of notAfter for the live cert, or
# non-zero (nothing printed) when it cannot be read.
cert_expiry_epoch() {
    local domain="$1" out
    [[ -n "$domain" ]] || return 1
    out=$(cd "$SCRIPT_DIR" && docker compose run --rm --no-deps -T --entrypoint python3 certbot \
        -c "$CERT_EXPIRY_PY" "/etc/letsencrypt/live/${domain}/fullchain.pem" 2>/dev/null | tr -d '\r' | tail -1)
    [[ "$out" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$out"
}

# cert_days_left <epoch>: whole days until that time (negative once expired).
cert_days_left() {
    local now; now=$(date +%s)
    echo $(( ($1 - now) / 86400 ))
}

cert_renew_warn_days() {
    local v
    v=$(get_env_val "CERT_RENEW_WARN_DAYS" "$SCRIPT_DIR/.env" "$CERT_RENEW_WARN_DAYS_DEFAULT")
    [[ "$v" =~ ^[0-9]+$ ]] || v="$CERT_RENEW_WARN_DAYS_DEFAULT"
    echo "$v"
}

# cert_metric_write <managed 0|1> [expiry-epoch] [renew_failed 0|1]
# Atomic (temp + mv) so node-exporter never reads a half-written file. An empty
# renew_failed keeps the value from the previous run (moav start does not know).
cert_metric_write() {
    local managed="$1" expiry="${2:-}" renew_failed="${3:-}"
    local dir="$SCRIPT_DIR/$CERT_METRIC_DIR_REL" file tmp now
    file="$dir/$CERT_METRIC_FILE"
    mkdir -p "$dir" 2>/dev/null || return 1
    if [[ -z "$renew_failed" ]]; then
        renew_failed=$(sed -n 's/^moav_cert_renew_failed //p' "$file" 2>/dev/null | head -1)
        [[ "$renew_failed" =~ ^[01]$ ]] || renew_failed=0
    fi
    now=$(date +%s)
    tmp=$(mktemp "$dir/.moav_cert.XXXXXX" 2>/dev/null) || return 1
    {
        echo "# HELP moav_cert_managed 1 when a Let's Encrypt certificate is in use (DOMAIN set), 0 in domainless mode."
        echo "# TYPE moav_cert_managed gauge"
        echo "moav_cert_managed $managed"
        echo "# HELP moav_cert_check_timestamp_seconds Unix time of the last certificate check (renewal timer or moav start)."
        echo "# TYPE moav_cert_check_timestamp_seconds gauge"
        echo "moav_cert_check_timestamp_seconds $now"
        echo "# HELP moav_cert_renew_failed 1 if the last certbot renew attempt exited non-zero."
        echo "# TYPE moav_cert_renew_failed gauge"
        echo "moav_cert_renew_failed $renew_failed"
        if [[ "$expiry" =~ ^[0-9]+$ ]]; then
            echo "# HELP moav_cert_expiry_seconds Unix time the Let's Encrypt certificate expires (notAfter)."
            echo "# TYPE moav_cert_expiry_seconds gauge"
            echo "moav_cert_expiry_seconds $expiry"
            echo "# HELP moav_cert_expiry_days Whole days until the Let's Encrypt certificate expires (negative once expired)."
            echo "# TYPE moav_cert_expiry_days gauge"
            echo "moav_cert_expiry_days $(cert_days_left "$expiry")"
        fi
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 644 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$file"
}

# Create the textfile dir before compose bind-mounts it, so it is owned by the
# operator rather than created root-owned by Docker (non-root CLI must write it).
# World-searchable regardless of umask: node-exporter reads it as `nobody`.
cert_metric_dir_ensure() {
    local dir="$SCRIPT_DIR/$CERT_METRIC_DIR_REL"
    mkdir -p "$dir" 2>/dev/null || true
    chmod 755 "$dir" 2>/dev/null || true
}

cert_renew_install() {
    local quiet="${1:-}"
    local sudo_prefix; sudo_prefix=$(_root_prefix)

    if _has_systemd; then
        if [[ $EUID -ne 0 && -z "$sudo_prefix" ]]; then
            error "Need root (or sudo) to install ${CERT_RENEW_UNIT}.timer."
            return 1
        fi
        $sudo_prefix tee "$CERT_RENEW_SERVICE_PATH" >/dev/null <<UNIT
[Unit]
Description=MoaV TLS certificate renewal
Documentation=https://github.com/MotherofallVPNs/moav
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=${SCRIPT_DIR}
ExecStart=/bin/bash ${SCRIPT_DIR}/scripts/cert-renew.sh
UNIT
        $sudo_prefix tee "$CERT_RENEW_TIMER_PATH" >/dev/null <<UNIT
[Unit]
Description=MoaV TLS certificate renewal (daily)

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
UNIT
        $sudo_prefix systemctl daemon-reload
        if $sudo_prefix systemctl enable --now "${CERT_RENEW_UNIT}.timer" >/dev/null 2>&1; then
            [[ "$quiet" == "--quiet" ]] || success "Installed ${CERT_RENEW_UNIT}.timer (daily renewal check)"
            [[ "$quiet" == "--quiet" ]] && info "TLS certs will now auto-renew daily (${CERT_RENEW_UNIT}.timer)"
            return 0
        fi
        error "Failed to enable ${CERT_RENEW_UNIT}.timer. Check: systemctl status ${CERT_RENEW_UNIT}.timer"
        return 1
    fi

    # No systemd (container / WSL): cron.d if a cron daemon is plausible
    if [[ -d /etc/cron.d ]]; then
        $sudo_prefix tee "$CERT_RENEW_CRON_PATH" >/dev/null <<CRON
# MoaV TLS certificate renewal (installed by: moav cert install)
17 3 * * * root /bin/bash ${SCRIPT_DIR}/scripts/cert-renew.sh >>/var/log/moav-cert-renew.log 2>&1
CRON
        [[ "$quiet" == "--quiet" ]] || success "Installed ${CERT_RENEW_CRON_PATH} (daily renewal check)"
        return 0
    fi

    error "Neither systemd nor cron.d detected — cannot schedule renewals."
    echo "  Certs expire after 90 days; run 'bash scripts/cert-renew.sh' periodically"
    echo "  with whatever scheduler this host has."
    return 1
}

cert_renew_uninstall() {
    local sudo_prefix; sudo_prefix=$(_root_prefix)
    if _has_systemd; then
        $sudo_prefix systemctl disable --now "${CERT_RENEW_UNIT}.timer" >/dev/null 2>&1 || true
        $sudo_prefix rm -f "$CERT_RENEW_TIMER_PATH" "$CERT_RENEW_SERVICE_PATH"
        $sudo_prefix systemctl daemon-reload
    fi
    [[ -f "$CERT_RENEW_CRON_PATH" ]] && $sudo_prefix rm -f "$CERT_RENEW_CRON_PATH"
    success "Removed cert auto-renewal (certs expire in ≤90 days unless renewed manually)"
}

# Is renewal really scheduled on this host, for THIS checkout? A unit file
# alone is not enough: a timer left disabled, or pointing at a previous install
# directory, fails every night without anyone noticing.
cert_renew_scheduled() {
    local script="${SCRIPT_DIR}/scripts/cert-renew.sh"
    if _has_systemd; then
        [[ -f "$CERT_RENEW_TIMER_PATH" && -f "$CERT_RENEW_SERVICE_PATH" ]] || return 1
        grep -qF "ExecStart=/bin/bash ${script}" "$CERT_RENEW_SERVICE_PATH" 2>/dev/null || return 1
        systemctl is-active --quiet "${CERT_RENEW_UNIT}.timer" 2>/dev/null
        return $?
    fi
    [[ -f "$CERT_RENEW_CRON_PATH" ]] || return 1
    grep -qF "$script" "$CERT_RENEW_CRON_PATH" 2>/dev/null
}

cert_renew_scheduler_status() {
    if cert_renew_scheduled; then
        if _has_systemd; then
            systemctl list-timers "${CERT_RENEW_UNIT}.timer" --no-pager 2>/dev/null || true
        else
            info "Renewal scheduled via ${CERT_RENEW_CRON_PATH}"
        fi
        return 0
    fi
    if _has_systemd && [[ -f "$CERT_RENEW_TIMER_PATH" ]]; then
        warn "Cert auto-renewal timer is installed but inactive or stale, reinstall with: moav cert install"
        return 1
    fi
    warn "Cert auto-renewal is NOT scheduled — install with: moav cert install"
    return 1
}

# One line of cert health for `moav start` and `moav cert status`: days left and
# whether the scheduler is live. Also refreshes the Prometheus textfile metric.
# Informational only; never fails the caller.
cert_report_line() {
    local domain="$1" epoch="" days sched warn_days
    warn_days=$(cert_renew_warn_days)
    if cert_renew_scheduled; then
        sched="daily renewal scheduled"
    elif [[ "$(get_env_val "CERT_AUTORENEW" "$SCRIPT_DIR/.env" "true")" == "true" ]]; then
        sched="renewal NOT scheduled, run: moav cert install"
    else
        sched="auto-renewal disabled (CERT_AUTORENEW=false)"
    fi
    epoch=$(cert_expiry_epoch "$domain") || epoch=""
    cert_metric_write 1 "$epoch" >/dev/null 2>&1 || true
    if [[ -z "$epoch" ]]; then
        warn "TLS cert for ${domain}: expiry unknown (not issued yet, or Docker down); ${sched}"
        return 0
    fi
    days=$(cert_days_left "$epoch")
    if [[ "$days" -lt 0 ]]; then
        error "TLS cert for ${domain}: EXPIRED $(( -days )) day(s) ago, run: moav cert renew; ${sched}"
    elif [[ "$days" -lt "$CERT_RENEW_CRIT_DAYS" ]]; then
        error "TLS cert for ${domain}: expires in ${days} day(s), run: moav cert renew; ${sched}"
    elif [[ "$days" -le "$warn_days" ]]; then
        warn "TLS cert for ${domain}: expires in ${days} day(s), renewal overdue; ${sched}"
    else
        success "TLS cert for ${domain}: valid for ${days} more days; ${sched}"
    fi
    return 0
}

cmd_cert() {
    case "${1:-status}" in
        renew)
            bash "$SCRIPT_DIR/scripts/cert-renew.sh"
            ;;
        status)
            local domain
            domain=$(get_env_val "DOMAIN" "$SCRIPT_DIR/.env" "")
            if [[ -z "$domain" ]]; then
                info "Domainless mode — no Let's Encrypt certificates in use."
                return 0
            fi
            docker compose run --rm --entrypoint certbot certbot certificates 2>/dev/null || \
                warn "Could not read certificates (is Docker running?)"
            echo ""
            cert_report_line "$domain"
            cert_renew_scheduler_status || true
            ;;
        install)          cert_renew_install ;;
        uninstall|remove) cert_renew_uninstall ;;
        *)
            echo "Usage: moav cert {status|renew|install|uninstall}"
            echo ""
            echo "  status     Show certificate expiry and renewal-schedule status."
            echo "  renew      Run a renewal check now (restarts TLS services if renewed)."
            echo "  install    Install the daily auto-renewal timer (systemd, or cron.d fallback)."
            echo "  uninstall  Remove the auto-renewal timer."
            return 1
            ;;
    esac
}

# Called at the end of `moav start`. Domain deployments: (re)install the daily
# renewal whenever it is missing, inactive or points at another checkout (the
# upgraded-box gap), then print one line of cert health. Domainless: just mark
# the metric unmanaged so the monitoring alerts stay quiet. Never blocks start.
auto_setup_cert_renew() {
    local domain
    domain=$(get_env_val "DOMAIN" "$SCRIPT_DIR/.env" "")
    if [[ -z "$domain" ]]; then
        cert_metric_write 0 "" 0 >/dev/null 2>&1 || true
        return 0
    fi
    if [[ "$(get_env_val "CERT_AUTORENEW" "$SCRIPT_DIR/.env" "true")" == "true" ]] && ! cert_renew_scheduled; then
        echo ""
        info "Domain deployment detected, installing daily TLS cert auto-renewal..."
        cert_renew_install --quiet || \
            warn "Auto-install failed; run 'moav cert install' manually (or set CERT_AUTORENEW=false to silence)."
    fi
    cert_report_line "$domain"
}
