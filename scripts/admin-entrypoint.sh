#!/bin/sh

# =============================================================================
# Admin dashboard entrypoint with logging
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

echo "[admin] Starting MoaV Admin Dashboard"
echo "[admin] Port: 8443"

# Copy certs to a moav-readable location (originals are root:root 600, volume is read-only)
mkdir -p /tmp/certs/selfsigned
cp -rL /certs/selfsigned/* /tmp/certs/selfsigned/ 2>/dev/null || true
for d in /certs/live/*/; do
    dir="/tmp/certs/live/$(basename "$d")"
    mkdir -p "$dir"
    cp -rL "$d"* "$dir/" 2>/dev/null || true
done
chown -R moav:moav /tmp/certs 2>/dev/null || true

# Check for SSL certificates
# `|| true`: `… | head -1` SIGPIPEs (141) once head closes the pipe, which
# pipefail makes fatal. An empty result is also a legitimate "no certs yet".
CERT_DIRS=$(find /certs/live -maxdepth 1 -type d 2>/dev/null | tail -n +2 | head -1 || true)
if [ -n "$CERT_DIRS" ]; then
    echo "[admin] SSL: Enabled (found certificates)"
else
    echo "[admin] SSL: Disabled (no certificates found)"
fi

# Ensure required directories exist and are writable by moav user
# Use chmod 777 instead of chown — more reliable across Docker volume mount scenarios
mkdir -p /project/outputs/bundles /project/state/users /project/configs/amneziawg /project/configs/wireguard 2>/dev/null || true
chown -R moav:moav /project/outputs /project/configs /project/state 2>/dev/null || true
chmod -R a+rwX /project/outputs /project/state 2>/dev/null || true
chmod -R a+rwX /project/configs/sing-box /project/configs/xray /project/configs/amneziawg /project/configs/wireguard /project/configs/trusttunnel /project/configs/telemt 2>/dev/null || true

# Run the dashboard as non-root
echo "[admin] Starting uvicorn server..."
exec su-exec moav python main.py
