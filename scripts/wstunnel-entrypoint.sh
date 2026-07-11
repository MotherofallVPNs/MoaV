#!/bin/sh

# =============================================================================
# wstunnel entrypoint
# Prefers wss:// (TLS) using the Let's Encrypt cert when DOMAIN is set; falls
# back to plain ws:// in domainless mode. A per-install path secret (written by
# bootstrap, shared with client bundles) restricts the HTTP-upgrade path so a
# scanner can't complete the WebSocket upgrade blind.
# Runs as root to read the root-owned cert, then drops to the moav user.
# =============================================================================

WSTUNNEL_LISTEN="${WSTUNNEL_LISTEN:-0.0.0.0:8080}"
WSTUNNEL_RESTRICT="${WSTUNNEL_RESTRICT:-moav-wireguard:51820}"
DOMAIN="${DOMAIN:-}"

set -- server --restrict-to "$WSTUNNEL_RESTRICT"

# Path-prefix hardening (shared secret with client bundles)
SECRET=""
[ -f /state/keys/wstunnel-path.secret ] && SECRET=$(cat /state/keys/wstunnel-path.secret 2>/dev/null)
if [ -n "$SECRET" ]; then
    set -- "$@" --restrict-http-upgrade-path-prefix "$SECRET"
fi

SCHEME="ws"
CERT="/certs/live/$DOMAIN/fullchain.pem"
KEY="/certs/live/$DOMAIN/privkey.pem"
if [ -n "$DOMAIN" ] && [ -f "$CERT" ] && [ -f "$KEY" ]; then
    # Cert files are root:600; copy to a tmpfs the moav user can read.
    mkdir -p /tmp/certs
    if cp -L "$CERT" /tmp/certs/fullchain.pem && cp -L "$KEY" /tmp/certs/privkey.pem; then
        chmod 600 /tmp/certs/*.pem
        chown -R moav:moav /tmp/certs 2>/dev/null || true
        set -- "$@" --tls-certificate /tmp/certs/fullchain.pem --tls-private-key /tmp/certs/privkey.pem
        SCHEME="wss"
        echo "[wstunnel] TLS enabled for $DOMAIN"
    else
        echo "[wstunnel] WARN: cert copy failed — falling back to plain ws://"
    fi
else
    echo "[wstunnel] No domain/cert — running plain ws:// (domainless mode)"
fi

set -- "$@" "$SCHEME://$WSTUNNEL_LISTEN"

echo "[wstunnel] Listen: $SCHEME://$WSTUNNEL_LISTEN"
echo "[wstunnel] Restrict to: $WSTUNNEL_RESTRICT"
[ -n "$SECRET" ] && echo "[wstunnel] HTTP-upgrade path restricted"

# Drop to the unprivileged user (setpriv from util-linux). If it's somehow
# absent, run directly rather than crash-loop.
if command -v setpriv >/dev/null 2>&1; then
    exec setpriv --reuid=moav --regid=moav --init-groups /app/wstunnel "$@"
else
    echo "[wstunnel] WARN: setpriv missing — running as current user"
    exec /app/wstunnel "$@"
fi
