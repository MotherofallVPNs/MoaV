#!/bin/bash
# conduit-monitor.sh — periodic Conduit health check + known-fix autopilot for
# macOS and Linux. Run every 15-30 min from a scheduled job (macOS LaunchAgent
# with StartCalendarInterval, or a Linux systemd timer / cron) so it survives
# closed terminals and sleep. Detection logic is identical on both platforms;
# only the restart/notify commands branch on `uname`. Conservative by design:
# it applies a small set of deterministic known fixes, and logs or notifies
# about anything else rather than guessing. See README.md for details.
#
# Configuration — all via environment variables, defaults except where noted:
#   CONDUIT_SERVICE_LABEL      launchd label (macOS, default ca.psiphon.conduit)
#                              / systemd unit name (Linux, default conduit)
#   CONDUIT_PLIST_PATH         macOS only: LaunchAgent plist path
#                              (default ~/Library/LaunchAgents/$CONDUIT_SERVICE_LABEL.plist)
#   CONDUIT_METRICS_URL        Conduit metrics (default http://127.0.0.1:9090/metrics)
#   CONDUIT_LOG_PATH           Conduit log, for a recent-error heuristic (default ~/conduit.log)
#   MONITOR_LOG_PATH           this script's own log (default ~/conduit-monitor.log)
#   KICKSTART_COOLDOWN_FILE    timestamp file guarding against restart loops
#                              (default ~/.conduit_monitor_last_kickstart)
#   KICKSTART_COOLDOWN_SECS    min seconds between auto-restarts (default 1200)
#   IDLE_THRESHOLD_SECS        max conduit_idle_seconds before "stuck" (default 300)
#   ROTATE_LOG_SCRIPT          optional log-rotation helper, called weekly as
#                              `$ROTATE_LOG_SCRIPT $CONDUIT_LOG_PATH conduit`; skipped if unset
#   NETWORK_INTERFACE          macOS only, optional (e.g. en0): bounce this interface
#                              when it has no usable IPv4. No effect on Linux.
#   NETWORK_INTERFACE_IS_WIFI  macOS only (default true): WiFi vs wired bounce method
#   HOME_PUBLIC_IP_PREFIX      optional (e.g. 203.0.113): stop Conduit when the public
#                              IP doesn't match this prefix (roaming/privacy guard)
#   NTFY_TOPIC_FILE            optional file holding an ntfy.sh topic for push notifications

OS="$(uname)"   # "Darwin" or "Linux" — the only two supported

if [ "$OS" = "Darwin" ]; then
    CONDUIT_SERVICE_LABEL="${CONDUIT_SERVICE_LABEL:-ca.psiphon.conduit}"
else
    CONDUIT_SERVICE_LABEL="${CONDUIT_SERVICE_LABEL:-conduit}"
fi
CONDUIT_PLIST_PATH="${CONDUIT_PLIST_PATH:-$HOME/Library/LaunchAgents/${CONDUIT_SERVICE_LABEL}.plist}"
CONDUIT_METRICS_URL="${CONDUIT_METRICS_URL:-http://127.0.0.1:9090/metrics}"
CONDUIT_LOG_PATH="${CONDUIT_LOG_PATH:-$HOME/conduit.log}"
MONITOR_LOG_PATH="${MONITOR_LOG_PATH:-$HOME/conduit-monitor.log}"
KICKSTART_COOLDOWN_FILE="${KICKSTART_COOLDOWN_FILE:-$HOME/.conduit_monitor_last_kickstart}"
KICKSTART_COOLDOWN_SECS="${KICKSTART_COOLDOWN_SECS:-1200}"
IDLE_THRESHOLD_SECS="${IDLE_THRESHOLD_SECS:-300}"
ROTATE_LOG_SCRIPT="${ROTATE_LOG_SCRIPT:-}"
NETWORK_INTERFACE="${NETWORK_INTERFACE:-}"
NETWORK_INTERFACE_IS_WIFI="${NETWORK_INTERFACE_IS_WIFI:-true}"
HOME_PUBLIC_IP_PREFIX="${HOME_PUBLIC_IP_PREFIX:-}"
NTFY_TOPIC_FILE="${NTFY_TOPIC_FILE:-}"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$MONITOR_LOG_PATH"
}

notify() {
    local msg
    msg="[$(date '+%m/%d %H:%M')] $1"
    if [ "$OS" = "Darwin" ]; then
        if command -v terminal-notifier >/dev/null 2>&1; then
            terminal-notifier -message "$msg" -title "Conduit Monitor" -open "file://$MONITOR_LOG_PATH" >/dev/null 2>&1
        else
            osascript -e "display notification \"$msg\" with title \"Conduit Monitor\"" >/dev/null 2>&1
        fi
    else
        # Most headless Linux servers have no desktop notification service
        # at all -- only attempt this if notify-send actually exists, and
        # don't treat its absence as a problem worth logging. ntfy (below)
        # is the reliable channel on Linux; this is a bonus if available.
        command -v notify-send >/dev/null 2>&1 && notify-send "Conduit Monitor" "$msg" >/dev/null 2>&1
    fi
    if [ -n "$NTFY_TOPIC_FILE" ] && [ -f "$NTFY_TOPIC_FILE" ]; then
        curl -s --max-time 5 -d "$msg" -H "Title: Conduit Monitor" "https://ntfy.sh/$(cat "$NTFY_TOPIC_FILE")" >/dev/null 2>&1
    fi
}

# Bounces $NETWORK_INTERFACE and kickstarts Conduit when that interface has no
# usable IPv4 (empty or a self-assigned 169.254.x link-local — DHCP never
# completed). Has no prerequisites: a repair for "no working network" must not
# itself depend on a working network.
fix_no_ip_interface() {
    [ "$OS" != "Darwin" ] && return   # not ported to Linux -- see header comment
    [ -z "$NETWORK_INTERFACE" ] && return
    local ip
    ip=$(ipconfig getifaddr "$NETWORK_INTERFACE" 2>/dev/null)
    if [ -n "$ip" ] && ! echo "$ip" | grep -qE "^169\.254\."; then
        return   # has a real address, nothing to do
    fi
    if [ "$NETWORK_INTERFACE_IS_WIFI" = "true" ]; then
        # `networksetup -setairportpower` doesn't validate its argument is a
        # WiFi device — given an unknown name it silently toggles whatever WiFi
        # interface exists. Confirm NETWORK_INTERFACE is the real Wi-Fi port first.
        local wifi_device
        wifi_device=$(networksetup -listallhardwareports | awk '/Hardware Port: Wi-Fi/{getline; print $2}')
        if [ "$wifi_device" != "$NETWORK_INTERFACE" ]; then
            ANOMALIES+=("NETWORK_INTERFACE=$NETWORK_INTERFACE is not this system's actual Wi-Fi device (that's $wifi_device) -- refusing to touch airport power to avoid affecting the wrong interface, needs a manual look")
            return
        fi
        networksetup -setairportpower "$NETWORK_INTERFACE" off
        sleep 5
        networksetup -setairportpower "$NETWORK_INTERFACE" on
    else
        local service
        service=$(networksetup -listallhardwareports | awk -v dev="$NETWORK_INTERFACE" '/Hardware Port:/{name=$0; sub(/Hardware Port: /,"",name)} $0=="Device: " dev {print name}')
        if [ -z "$service" ]; then
            ANOMALIES+=("NETWORK_INTERFACE=$NETWORK_INTERFACE has no usable IPv4 (${ip:-none}), but could not find its network service name to bounce it — needs a manual look")
            return
        fi
        networksetup -setnetworkserviceenabled "$service" off
        sleep 3
        networksetup -setnetworkserviceenabled "$service" on
    fi
    sleep 12
    service_restart
    ACTIONS+=("$NETWORK_INTERFACE had no usable IPv4 (was: ${ip:-none}), bounced it and restarted Conduit")
}

# Small OS-branching wrappers so the actual health-check logic below (which
# is identical on both platforms) doesn't need its own if/else at every step.
service_is_running() {
    if [ "$OS" = "Darwin" ]; then
        [ "$(launchctl print "gui/$(id -u)/${CONDUIT_SERVICE_LABEL}" 2>/dev/null | grep -m1 state | awk '{print $3}')" = "running" ]
    else
        systemctl is-active --quiet "${CONDUIT_SERVICE_LABEL}.service" 2>/dev/null
    fi
}

service_start() {
    if [ "$OS" = "Darwin" ]; then
        launchctl bootstrap "gui/$(id -u)" "$CONDUIT_PLIST_PATH" 2>/dev/null
    else
        systemctl start "${CONDUIT_SERVICE_LABEL}.service" 2>/dev/null
    fi
}

service_stop() {
    if [ "$OS" = "Darwin" ]; then
        launchctl bootout "gui/$(id -u)" "$CONDUIT_PLIST_PATH" 2>/dev/null
    else
        systemctl stop "${CONDUIT_SERVICE_LABEL}.service" 2>/dev/null
    fi
}

service_restart() {
    if [ "$OS" = "Darwin" ]; then
        launchctl kickstart -k "gui/$(id -u)/${CONDUIT_SERVICE_LABEL}" 2>/dev/null
    else
        systemctl restart "${CONDUIT_SERVICE_LABEL}.service" 2>/dev/null
    fi
}

# --- gather state ---
if service_is_running; then CONDUIT_STATE="running"; else CONDUIT_STATE="not running"; fi
METRICS=$(curl -s --max-time 5 "$CONDUIT_METRICS_URL")
IS_LIVE=$(echo "$METRICS" | awk '/^conduit_is_live/{print $2}')
CONNECTED=$(echo "$METRICS" | awk '/^conduit_connected_clients/{print $2}')
IDLE_SECONDS=$(echo "$METRICS" | awk '/^conduit_idle_seconds/{print $2}')
ERROR_COUNT=$(tail -n 100 "$CONDUIT_LOG_PATH" 2>/dev/null | grep -cE "404|ERROR")

ACTIONS=()
ANOMALIES=()

# --- optional: fix an interface with no usable IPv4 BEFORE the home-network
# check below, which itself needs working connectivity to run. ---
fix_no_ip_interface

# --- optional: pause Conduit if this Mac's public IP doesn't match the
# configured home prefix (mobile/laptop stations only — skipped entirely
# if HOME_PUBLIC_IP_PREFIX is unset) ---
ON_NON_HOME_NETWORK="no"
PUBLIC_IP_LOOKUP_FAILED="no"
if [ -n "$HOME_PUBLIC_IP_PREFIX" ]; then
    CURRENT_PUBLIC_IP=$(curl -s --max-time 5 https://api.ipify.org)
    if [ -z "$CURRENT_PUBLIC_IP" ]; then
        # An inconclusive lookup must NOT be treated as "confirmed away from
        # home": pausing on a failed lookup then blocks the un-pause on every
        # later check too. Default to "assume home, don't act" and log the
        # failure as a visible anomaly.
        PUBLIC_IP_LOOKUP_FAILED="yes"
    else
        case "$CURRENT_PUBLIC_IP" in
            ${HOME_PUBLIC_IP_PREFIX}*) ON_NON_HOME_NETWORK="no" ;;
            *) ON_NON_HOME_NETWORK="yes" ;;
        esac
    fi
fi

if [ "$PUBLIC_IP_LOOKUP_FAILED" = "yes" ]; then
    ANOMALIES+=("public-IP lookup (api.ipify.org) failed/empty this cycle — treated as inconclusive, did NOT pause Conduit, but check general internet routing if this recurs")
fi

# --- metrics endpoint unreachable entirely ---
# Expected/correct when Conduit is intentionally paused on a non-home
# network (nothing listening on the metrics port) — not an anomaly then.
if [ -z "$METRICS" ] && [ "$ON_NON_HOME_NETWORK" = "no" ]; then
    ANOMALIES+=("metrics endpoint ($CONDUIT_METRICS_URL) did not respond at all — Conduit or its metrics exporter may be down, needs a look")
fi

# --- Conduit not running -> start it ---
# Skipped if on a non-home network — that's the correct, intentionally-
# paused state, not something to fight every cycle.
if [ "$CONDUIT_STATE" != "running" ] && [ "$ON_NON_HOME_NETWORK" = "no" ]; then
    service_start
    ACTIONS+=("Conduit was not running, started it")
fi

# --- Conduit running on a non-home network -> pause it ---
if [ -n "$HOME_PUBLIC_IP_PREFIX" ] && [ "$CONDUIT_STATE" = "running" ] && [ "$ON_NON_HOME_NETWORK" = "yes" ]; then
    service_stop
    ACTIONS+=("Conduit was running on a non-home network (public IP: ${CURRENT_PUBLIC_IP:-unknown}), paused it")
fi

# --- not connected to the broker at all -- no known fix, needs a human look ---
if [ -n "$METRICS" ] && [ "$IS_LIVE" != "1" ]; then
    ANOMALIES+=("conduit_is_live=$IS_LIVE (not connected to broker) — no known fix for this, needs investigation")
fi

# --- stale/stuck proxy, two failure shapes both worth catching:
# 1) conduit_idle_seconds elevated — genuinely dead, no activity at all.
# 2) connected=0 with recent errors — "actively failing" rather than idle, so
#    idle_seconds can stay near zero while still broken. Keep both checks. ---
IDLE_INT=${IDLE_SECONDS%.*}
STALE_REASON=""
if [ "$IS_LIVE" = "1" ] && [ -n "$IDLE_INT" ] && [ "$IDLE_INT" -gt "$IDLE_THRESHOLD_SECS" ] 2>/dev/null; then
    STALE_REASON="idle_seconds=${IDLE_INT}"
elif [ "$IS_LIVE" = "1" ] && [ "$CONNECTED" = "0" ] && [ "$ERROR_COUNT" -gt 0 ] 2>/dev/null; then
    STALE_REASON="connected=0 with ${ERROR_COUNT} errors/100 lines despite active connecting attempts"
fi

if [ -n "$STALE_REASON" ]; then
    LAST_KICKSTART=$(cat "$KICKSTART_COOLDOWN_FILE" 2>/dev/null || echo 0)
    NOW=$(date +%s)
    if [ $((NOW - LAST_KICKSTART)) -gt "$KICKSTART_COOLDOWN_SECS" ]; then
        service_restart
        echo "$NOW" > "$KICKSTART_COOLDOWN_FILE"
        ACTIONS+=("stale/stuck proxy ($STALE_REASON), kickstarted Conduit")
    else
        ANOMALIES+=("stale/stuck proxy detected ($STALE_REASON) but kickstarted within the last ${KICKSTART_COOLDOWN_SECS}s — skipping to avoid a restart loop, this needs a manual look, it is NOT self-resolving")
    fi
fi

# --- optional weekly log rotation, if a rotation helper is configured ---
if [ -n "$ROTATE_LOG_SCRIPT" ] && [ -x "$ROTATE_LOG_SCRIPT" ]; then
    ROTATE_OUTPUT=$("$ROTATE_LOG_SCRIPT" "$CONDUIT_LOG_PATH" conduit)
    [ -n "$ROTATE_OUTPUT" ] && ACTIONS+=("$ROTATE_OUTPUT")
fi

# --- log + notify (one consolidated notification per run, not one per finding) ---
if [ ${#ACTIONS[@]} -eq 0 ] && [ ${#ANOMALIES[@]} -eq 0 ]; then
    log "CHECK: healthy (live=$IS_LIVE, connected=$CONNECTED, idle=${IDLE_INT}s, errors=$ERROR_COUNT) ACTION: none"
else
    ACTION_TEXT="none"
    [ ${#ACTIONS[@]} -gt 0 ] && ACTION_TEXT=$(IFS='; '; echo "${ACTIONS[*]}")
    ANOMALY_TEXT=$(IFS='; '; echo "${ANOMALIES[*]}")

    if [ ${#ANOMALIES[@]} -gt 0 ]; then
        log "CHECK: live=$IS_LIVE connected=$CONNECTED idle=${IDLE_INT}s errors=$ERROR_COUNT ACTION: $ACTION_TEXT NEEDS-ATTENTION: $ANOMALY_TEXT"
        notify "NEEDS ATTENTION: ${ANOMALIES[0]}$([ ${#ANOMALIES[@]} -gt 1 ] && echo " (+$((${#ANOMALIES[@]}-1)) more, see $MONITOR_LOG_PATH)")"
    else
        log "CHECK: live=$IS_LIVE connected=$CONNECTED idle=${IDLE_INT}s errors=$ERROR_COUNT ACTION: $ACTION_TEXT"
        notify "Fixed automatically: ${ACTIONS[0]}$([ ${#ACTIONS[@]} -gt 1 ] && echo " (+$((${#ACTIONS[@]}-1)) more, see log)")"
    fi
fi
