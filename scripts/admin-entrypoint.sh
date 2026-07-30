#!/bin/sh

# =============================================================================
# Admin dashboard entrypoint with logging
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

# Last-resort TLS: if neither a Let's Encrypt nor a bootstrap self-signed cert
# made it here, mint one now. main.py refuses to serve plaintext, so without this
# a certs volume that is empty for any reason (wiped, admin started before
# bootstrap) would mean no dashboard at all. /tmp is a writable tmpfs and we are
# still root at this point, so this always succeeds.
if [ -z "$(find /tmp/certs -name fullchain.pem 2>/dev/null | head -1)" ]; then
    echo "[admin] No certificate present - generating a last-resort self-signed cert"
    mkdir -p /tmp/certs/selfsigned
    openssl req -x509 -newkey rsa:2048 \
        -keyout /tmp/certs/selfsigned/privkey.pem \
        -out /tmp/certs/selfsigned/fullchain.pem \
        -days 365 -nodes -subj "/CN=MoaV Admin" 2>/dev/null \
        && echo "[admin] Last-resort certificate created (browser warning expected)" \
        || echo "[admin] WARNING: could not generate a certificate"
    chown -R moav:moav /tmp/certs 2>/dev/null || true
fi

# Check for SSL certificates
# `|| true`: `… | head -1` SIGPIPEs (141) once head closes the pipe, which
# pipefail makes fatal. An empty result is also a legitimate "no certs yet".
# Report what main.py will ACTUALLY bind, which is /tmp/certs (Let's Encrypt if
# present, else the self-signed fallback, else the last-resort cert generated
# above). Checking only /certs/live printed "SSL: Disabled" even when a fallback
# certificate existed and TLS was about to be served -- an operator reading that
# would reasonably think the panel was plaintext when it was not. main.py refuses
# to start without TLS, so "Disabled" is now genuinely a failure state.
CERT_DIRS=$(find /certs/live -maxdepth 1 -type d 2>/dev/null | tail -n +2 | head -1 || true)
FALLBACK_CERT=$(find /tmp/certs -name fullchain.pem 2>/dev/null | head -1 || true)
if [ -n "$CERT_DIRS" ]; then
    echo "[admin] SSL: Enabled (Let's Encrypt certificate)"
elif [ -n "$FALLBACK_CERT" ]; then
    echo "[admin] SSL: Enabled (self-signed fallback; browser warning expected)"
else
    echo "[admin] SSL: no certificate found - the dashboard will refuse to start"
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
