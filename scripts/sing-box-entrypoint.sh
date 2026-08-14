#!/bin/sh

# =============================================================================
# sing-box entrypoint with logging
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

CONFIG_FILE="${CONFIG_FILE:-/etc/sing-box/config.json}"

echo "[sing-box] Starting sing-box multi-protocol proxy"
echo "[sing-box] Config: $CONFIG_FILE"

# Check config exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "[sing-box] ERROR: Config file not found at $CONFIG_FILE"
    echo "[sing-box] Run bootstrap first to generate configuration"
    exit 1
fi

# Copy config to writable location (source may be read-only mount)
RUNTIME_CONFIG="/tmp/sing-box-config.json"
cp "$CONFIG_FILE" "$RUNTIME_CONFIG"

# Validate config
echo "[sing-box] Validating configuration..."
if ! sing-box check -c "$RUNTIME_CONFIG"; then
    echo "[sing-box] ERROR: Configuration validation failed"
    exit 1
fi
echo "[sing-box] Configuration valid"

# Show enabled inbounds
# `|| true`: grep exits 1 when no tag matches, and `| head -10` SIGPIPEs once
# head closes the pipe -- both fatal under pipefail, on an informational line.
INBOUNDS=$(grep -o '"tag"[[:space:]]*:[[:space:]]*"[^"]*"' "$RUNTIME_CONFIG" | head -10 | sed 's/"tag"[[:space:]]*:[[:space:]]*//g' | tr -d '"' | tr '\n' ', ' | sed 's/,$//' || true)
echo "[sing-box] Inbounds: $INBOUNDS"

# Make the log/cache volume moav-writable. /state is mounted read-only and is
# NOT chowned: a recursive chown here swept in /state/keys/* and downgraded every
# state secret from root:root to the moav uid on each start, defeating the
# ownership hardening. sing-box's only /state need (its cache db) now lives here.
chown -R moav:moav /var/log/sing-box 2>/dev/null || true

# Copy certs to a moav-readable location (originals are root:root 600, volume is read-only)
if [ -d /certs/live ]; then
    for d in /certs/live/*/; do
        dir="/tmp/certs/live/$(basename "$d")"
        mkdir -p "$dir"
        cp -rL "$d"* "$dir/" 2>/dev/null || true
    done
fi
if [ -d /certs/selfsigned ]; then
    mkdir -p /tmp/certs/selfsigned
    cp -rL /certs/selfsigned/* /tmp/certs/selfsigned/ 2>/dev/null || true
fi
chown -R moav:moav /tmp/certs 2>/dev/null || true

# Rewrite cert paths in config to use the moav-readable copy
sed -i 's|/certs/|/tmp/certs/|g' "$RUNTIME_CONFIG"

# Relocate the cache db off the now-read-only /state onto the moav-writable log
# volume. Rewriting the runtime copy self-heals existing installs whose rendered
# config still points the cache at /state (no re-bootstrap needed).
sed -i 's|/state/sing-box-cache.db|/var/log/sing-box/sing-box-cache.db|g' "$RUNTIME_CONFIG"

# Publish the log to a file for the exporter to tail: usernames appear only in
# the log, never in the Clash API. Rewritten on the runtime copy so existing
# installs pick it up on restart without a re-bootstrap.
ACCESS_LOG="/var/log/sing-box/sing-box.log"
ACCESS_LOG_MAX_BYTES="${SINGBOX_LOG_MAX_BYTES:-33554432}"   # 32 MiB

# sing-box logs the username and the destination on the same line, and every
# line carries a connection id that ties the username to the client IP on
# another. Scrubbing only the obvious line would leave the link reconstructable,
# so destinations are stripped from every shape before anything is written to
# disk. sing-box writes into a FIFO on tmpfs; only the scrubbed stream is
# persisted. See MotherofallVPNs/MoaV#297.
RAW_LOG="/tmp/sing-box-raw.fifo"
LOG_SINK="$ACCESS_LOG"

if [ -d /var/log/sing-box ] && mkfifo -m 600 "$RAW_LOG" 2>/dev/null; then
    chown moav:moav "$RAW_LOG" 2>/dev/null || true

    # Hold the FIFO open read+write for the life of the container. Opening it
    # read-write never blocks, so sing-box's open() returns at once, and a
    # scrubber restart can never hand it EOF or a missing reader.
    ( while true; do sleep 3600; done ) <> "$RAW_LOG" 2>/dev/null &

    # The scrubber. Restarted if it ever dies: sing-box blocks on a full pipe,
    # so something must always be draining.
    ( while true; do
          awk '{
              sub(/ connection to .*$/, " connection to -")
              # Everything after a dns verb is a name. Keep the verb only, so a
              # verb we have not seen cannot leak by default.
              if (match($0, /dns: /)) {
                  head = substr($0, 1, RSTART + RLENGTH - 1)
                  rest = substr($0, RSTART + RLENGTH)
                  split(rest, w, " ")
                  if (w[1] == "lookup" && w[2] == "failed") {
                      i = index(rest, ": ")     # keep the reason, drop the name
                      $0 = head "lookup failed for -" (i ? substr(rest, i) : "")
                  } else {
                      $0 = head w[1] " -"
                  }
              }
              print; fflush()
          }' < "$RAW_LOG" >> "$ACCESS_LOG" 2>/dev/null
          sleep 1
      done ) &

    # Everything already in the file predates scrubbing, so it still pairs
    # usernames with destinations. Upgrades would otherwise keep it until the
    # 32 MiB truncation happens to come round.
    if [ -s "$ACCESS_LOG" ]; then
        : > "$ACCESS_LOG" 2>/dev/null \
            && echo "[sing-box] Cleared the pre-scrub log (it still held destinations)"
    fi

    LOG_SINK="$RAW_LOG"
    echo "[sing-box] Destinations are scrubbed from the log before it is written"
fi

if [ -d /var/log/sing-box ] && ! grep -q '"output"' "$RUNTIME_CONFIG"; then
    _cand="/tmp/sing-box-config.withlog.json"
    sed 's|"log"[[:space:]]*:[[:space:]]*{|"log": {"output": "'"$LOG_SINK"'",|' \
        "$RUNTIME_CONFIG" > "$_cand" 2>/dev/null || true
    # A bad injection must cost metrics, never boot.
    if [ -s "$_cand" ] && sing-box check -c "$_cand" >/dev/null 2>&1; then
        mv -f "$_cand" "$RUNTIME_CONFIG"

        # moav-owned so sing-box can append; 644 because the exporter is
        # cap_drop ALL and reads it only through the world bits.
        : >> "$ACCESS_LOG" 2>/dev/null || true
        chown moav:moav "$ACCESS_LOG" 2>/dev/null || true
        chmod 644 "$ACCESS_LOG" 2>/dev/null || true

        # log.output silences the console, so mirror it back or `moav logs` dies.
        # It also strips colour (sing-box sets DisableColor for file output and
        # it carries json:"-", so the config cannot re-enable it), so restore it
        # here: the level, and the connection id, which is what lets you follow
        # one connection across lines.
        ( tail -n 0 -F "$ACCESS_LOG" 2>/dev/null | awk '
        BEGIN {
            lc["FATAL"]="1;31"; lc["PANIC"]="1;31"; lc["ERROR"]="31"
            lc["WARN"]="33";    lc["INFO"]="36";    lc["DEBUG"]="90"
            lc["TRACE"]="90"
            n = split("41,227,83,155,117,214,213,85,120,209,147,80", pal, ",")
        }
        {
            line = $0
            if (match(line, /^[A-Z]+ /)) {
                lvl = substr(line, 1, RLENGTH - 1)
                if (lvl in lc)
                    line = "\033[" lc[lvl] "m" lvl "\033[0m" substr(line, RLENGTH)
            }
            # "[3319605072 0ms]" -- colour the id by its own value, so a given
            # connection keeps one colour for its whole life.
            if (match(line, /\[[0-9]+ /)) {
                id = substr(line, RSTART + 1, RLENGTH - 2)
                line = substr(line, 1, RSTART) \
                       "\033[38;5;" pal[(id % n) + 1] "m" id "\033[0m" \
                       substr(line, RSTART + RLENGTH - 1)
            }
            print line
            fflush()
        }' ) &

        # sing-box cannot rotate. Truncating in place is safe for its append
        # handle and for the exporter's tail.
        ( while sleep 30; do
              [ -f "$ACCESS_LOG" ] || continue
              chmod 644 "$ACCESS_LOG" 2>/dev/null || true
              _sz=$(stat -c %s "$ACCESS_LOG" 2>/dev/null || echo 0)
              if [ "${_sz:-0}" -gt "$ACCESS_LOG_MAX_BYTES" ]; then
                  : > "$ACCESS_LOG"
                  echo "[sing-box] log exceeded ${ACCESS_LOG_MAX_BYTES}B - truncated"
              fi
          done ) &

        echo "[sing-box] Logging to $ACCESS_LOG (mirrored to stdout) for per-user metrics"
    else
        rm -f "$_cand" 2>/dev/null || true
        echo "[sing-box] WARN: could not enable file logging - per-user Grafana panels will stay empty"
    fi
fi

# Run sing-box as non-root
echo "[sing-box] Starting proxy server..."
exec setpriv --reuid=moav --regid=moav --init-groups \
    --inh-caps=+net_admin,+net_bind_service \
    --ambient-caps=+net_admin,+net_bind_service \
    sing-box run -c "$RUNTIME_CONFIG"
