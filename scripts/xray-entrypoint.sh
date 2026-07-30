#!/bin/bash
# Xray-core entrypoint script (VLESS+XHTTP+Reality)
set -euo pipefail

CONFIG_FILE="/etc/xray/config.json"

echo "[Xray] Starting Xray-core (VLESS+XHTTP+Reality)..."

# Check for config
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[Xray] ERROR: config.json not found at $CONFIG_FILE"
    exit 1
fi

echo "[Xray] Configuration:"
echo "  - Config: $CONFIG_FILE"
# `|| true`: `xray version | head -1` raises SIGPIPE (141) once head closes the
# pipe, which pipefail turns into a fatal error -- on a purely cosmetic line.
echo "  - Version: $(xray version 2>/dev/null | head -1 || true)"

# Check for Stats API configuration
if grep -q '"api-in"' "$CONFIG_FILE"; then
    echo "  - Stats API: enabled (port 10085)"
else
    echo "  - Stats API: NOT configured (per-user traffic metrics will be unavailable)"
fi

# Publish stats for the metrics exporter.
#
# The exporter used to run `docker exec moav-xray xray api statsquery`, which
# required mounting the raw Docker socket -- unrestricted Docker API access, i.e.
# a path to host root, for a read-only metrics scrape. The stats API listens on
# 127.0.0.1 inside this container, so the alternative would have been exposing it
# on the container network; publishing a file keeps it internal and uses the same
# mechanism the wireguard/amneziawg exporters now use.
#
# Written tmp-then-rename so a scrape never observes a half-written file; on
# failure the previous snapshot is kept rather than truncated.
METRICS_STATE_DIR="${METRICS_STATE_DIR:-/var/lib/moav-metrics}"
publish_stats() {
    for _pattern in user inbound; do
        _out="$METRICS_STATE_DIR/xray-stats-$_pattern.json"
        if xray api statsquery -s 127.0.0.1:10085 -pattern "$_pattern" \
             > "$_out.tmp" 2>/dev/null; then
            mv -f "$_out.tmp" "$_out" 2>/dev/null || true
        else
            rm -f "$_out.tmp" 2>/dev/null || true
        fi
    done
}

if [ -d "$METRICS_STATE_DIR" ]; then
    # Sleeps FIRST: the stats API is not up until xray is running below. Runs as a
    # background child so `exec` below keeps xray as PID 1 and signal handling
    # unchanged; when PID 1 exits the container stops regardless of this child.
    # The access log is what the exporter parses for per-user activity and source
    # IPs. xray cannot rotate it, so cap it here rather than adding a second
    # moving part: truncating in place is safe for both xray's append handle and
    # the exporter's tail (both detect the shrink and continue).
    ACCESS_LOG="$METRICS_STATE_DIR/xray-access.log"
    ACCESS_LOG_MAX_BYTES="${ACCESS_LOG_MAX_BYTES:-33554432}"   # 32 MiB
    cap_access_log() {
        [ -f "$ACCESS_LOG" ] || return 0
        _sz=$(stat -c %s "$ACCESS_LOG" 2>/dev/null || stat -f %z "$ACCESS_LOG" 2>/dev/null || echo 0)
        if [ "${_sz:-0}" -gt "$ACCESS_LOG_MAX_BYTES" ]; then
            : > "$ACCESS_LOG"
            echo "[Xray] access log exceeded ${ACCESS_LOG_MAX_BYTES}B - truncated"
        fi
    }
    ( while sleep 15; do publish_stats; cap_access_log; done ) &
    echo "[Xray] Publishing stats to $METRICS_STATE_DIR every 15s"
else
    echo "[Xray] $METRICS_STATE_DIR not mounted - stats publishing disabled"
fi

# Start Xray
exec xray run -c "$CONFIG_FILE"
