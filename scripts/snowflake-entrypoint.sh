#!/bin/sh
# =============================================================================
# Snowflake Proxy entrypoint with bandwidth limiting and logging
# =============================================================================


# Strict mode, minus `-e` (see below).
set -eu
# `set` is a POSIX SPECIAL builtin: a failed `set -o pipefail` exits a
# non-interactive shell outright and `|| true` does NOT save it. dash (debian's
# /bin/sh, used by sing-box and wstunnel) has no pipefail. Probe in a subshell,
# where the exit is contained, then enable it only if supported.
if ( set -o pipefail 2>/dev/null ); then set -o pipefail; fi
# NOTE: `-e` is deliberately NOT enabled here yet. This entrypoint has never run
# under it, so every currently-tolerated non-zero exit would become fatal. That
# needs a per-command review, tracked separately -- adding it blind to six
# long-running services at once is how you take down a stack.

SNOWFLAKE_BANDWIDTH="${SNOWFLAKE_BANDWIDTH:-50}"
SNOWFLAKE_CAPACITY="${SNOWFLAKE_CAPACITY:-20}"
LOG_FILE="/var/log/snowflake/snowflake.log"

# Ensure log directory exists
mkdir -p /var/log/snowflake

echo "[snowflake] Starting Tor Snowflake Proxy"
echo "[snowflake] Bandwidth limit: ${SNOWFLAKE_BANDWIDTH} Mbps"
echo "[snowflake] Max clients: ${SNOWFLAKE_CAPACITY}"
echo "[snowflake] Log file: ${LOG_FILE}"

# Set up bandwidth limiting using tc (traffic control)
# This requires NET_ADMIN capability
setup_bandwidth_limit() {
    # Find the default interface
    # `|| true`: grep exits 1 when there is no default route, and `| head -1`
    # SIGPIPEs -- both fatal under pipefail. Empty IFACE is handled below.
    IFACE=$(ip route | grep default | awk '{print $5}' | head -1 || true)

    if [ -z "$IFACE" ]; then
        echo "[snowflake] WARNING: Could not determine network interface, skipping bandwidth limit"
        return 1
    fi

    echo "[snowflake] Setting up ${SNOWFLAKE_BANDWIDTH}Mbps limit on $IFACE"

    # Clear existing qdisc (ignore errors if none exists)
    tc qdisc del dev "$IFACE" root 2>/dev/null || true

    # Convert Mbps to kbit (1 Mbps = 1000 kbit)
    RATE_KBIT=$((SNOWFLAKE_BANDWIDTH * 1000))

    # Set up rate limiting using TBF (Token Bucket Filter)
    tc qdisc add dev "$IFACE" root tbf rate ${RATE_KBIT}kbit burst 32kbit latency 400ms

    if [ $? -eq 0 ]; then
        echo "[snowflake] Bandwidth limit configured successfully"
        return 0
    else
        echo "[snowflake] WARNING: Failed to set bandwidth limit"
        return 1
    fi
}

# Try to set up bandwidth limiting (requires NET_ADMIN)
setup_bandwidth_limit || echo "[snowflake] Continuing without bandwidth limit"

# Run the proxy with output tee'd to both stdout and log file (for metrics exporter)
# Note: -verbose removed to reduce log noise (SDP offers/answers)
# /internal/metrics: relayed bytes and connection timeouts as counters.
METRICS_ARGS=""
if [ "${SNOWFLAKE_METRICS:-true}" = "true" ]; then
    METRICS_ARGS="-metrics -metrics-address 0.0.0.0 -metrics-port ${SNOWFLAKE_METRICS_PORT:-9998}"
fi

# Tor-format geoip; without it the proxy errors on start and labels country "".
GEOIP_ARGS=""
if [ -s /usr/share/tor/geoip ]; then
    GEOIP_ARGS="-geoipdb /usr/share/tor/geoip"
    [ -s /usr/share/tor/geoip6 ] && GEOIP_ARGS="$GEOIP_ARGS -geoip6db /usr/share/tor/geoip6"
else
    echo "[snowflake] no geoip db; the proxy will log a country-metrics warning"
fi

echo "[snowflake] Starting proxy..."
# shellcheck disable=SC2086  # both ARGS vars are intentionally word-split
exec /bin/proxy \
    -capacity "${SNOWFLAKE_CAPACITY}" \
    -summary-interval 90s \
    $GEOIP_ARGS $METRICS_ARGS \
    2>&1 | tee -a "${LOG_FILE}"
