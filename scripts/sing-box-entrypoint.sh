#!/bin/sh

# =============================================================================
# sing-box entrypoint with logging
# =============================================================================


# Strict mode, minus `-e` (see below).
set -u
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

# Fix volume ownership (volumes may be root-owned from previous runs)
chown -R moav:moav /state /var/log/sing-box 2>/dev/null || true

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

# Run sing-box as non-root
echo "[sing-box] Starting proxy server..."
exec setpriv --reuid=moav --regid=moav --init-groups \
    --inh-caps=+net_admin,+net_bind_service \
    --ambient-caps=+net_admin,+net_bind_service \
    sing-box run -c "$RUNTIME_CONFIG"
