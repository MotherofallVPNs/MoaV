#!/bin/sh
# =============================================================================
# Grafana entrypoint with SSL certificate detection and custom branding
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

echo "[grafana] Starting MoaV Grafana Dashboard"

# Determine app title (for PWA name on phone home screen)
# Priority: GRAFANA_APP_TITLE > "MoaV - DOMAIN" > "MoaV - SERVER_IP" > "MoaV"
# `:-` on each: compose always supplies these (as ${VAR:-}), but the entrypoint
# should not depend on that to survive `set -u`. Running it outside compose, or
# a compose file that drops one, would otherwise abort the container here.
if [ -n "${GRAFANA_APP_TITLE:-}" ]; then
    APP_TITLE="${GRAFANA_APP_TITLE:-}"
elif [ -n "${DOMAIN:-}" ]; then
    APP_TITLE="MoaV Grafana - ${DOMAIN}"
elif [ -n "${SERVER_IP:-}" ]; then
    APP_TITLE="MoaV Grafana - ${SERVER_IP}"
else
    APP_TITLE="MoaV Grafana"
fi
echo "[grafana] App title: $APP_TITLE"

# Construct Grafana root URL from subdomain + domain
if [ -n "${GRAFANA_SUBDOMAIN:-}" ] && [ -n "${DOMAIN:-}" ]; then
    export GF_SERVER_ROOT_URL="https://${GRAFANA_SUBDOMAIN}.${DOMAIN}:2083/"
    echo "[grafana] Root URL: $GF_SERVER_ROOT_URL"
fi

# =============================================================================
# Install MoaV branding (Grafana OSS requires direct file replacement)
# Note: GF_BRANDING_* env vars are Enterprise-only features
# =============================================================================
GRAFANA_IMG="/usr/share/grafana/public/img"
GRAFANA_BUILD="/usr/share/grafana/public/build"

if [ -d "/branding" ]; then
    echo "[grafana] Installing MoaV branding..."

    # Replace favicon (browser tab icon) — Grafana has copies in both img/ and build/img/
    if [ -f "/branding/favicon.png" ]; then
        cp /branding/favicon.png "$GRAFANA_IMG/fav32.png" 2>/dev/null && echo "[grafana] Replaced img/fav32.png"
        cp /branding/favicon.png "$GRAFANA_BUILD/img/fav32.png" 2>/dev/null && echo "[grafana] Replaced build/img/fav32.png"
        cp /branding/favicon.png "$GRAFANA_IMG/apple-touch-icon.png" 2>/dev/null && echo "[grafana] Replaced apple-touch-icon.png"
    fi
    if [ -f "/branding/favicon.ico" ]; then
        cp /branding/favicon.ico "$GRAFANA_IMG/favicon.ico" 2>/dev/null && echo "[grafana] Replaced favicon.ico"
    fi

    # Replace login page logo (Grafana uses grafana_icon.svg)
    # Create an SVG wrapper that embeds the PNG as base64
    if [ -f "/branding/logo.png" ]; then
        # Get image dimensions (default to 100x100 if not determinable)
        LOGO_B64=$(base64 -w0 /branding/logo.png 2>/dev/null || base64 /branding/logo.png)
        cat > "$GRAFANA_IMG/grafana_icon.svg" << SVGEOF
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 100 100">
  <image width="100" height="100" xlink:href="data:image/png;base64,$LOGO_B64"/>
</svg>
SVGEOF
        echo "[grafana] Created grafana_icon.svg from logo.png"
    fi

    # Replace app title in JavaScript bundles (affects browser tab and PWA name)
    if [ -d "$GRAFANA_BUILD" ]; then
        echo "[grafana] Patching app title to: $APP_TITLE"
        patched=0
        for js_file in "$GRAFANA_BUILD"/*.js; do
            [ -f "$js_file" ] || continue
            if grep -q 'AppTitle' "$js_file" 2>/dev/null; then
                # Try multiple patterns (varies by Grafana version)
                # `|| true`: branding is cosmetic. Under `set -e` a failed in-place edit
                # (read-only layer, a Grafana upgrade renaming these bundles) would take the
                # whole container down over a page title.
                sed -i "s/\"AppTitle\",\"Grafana\"/\"AppTitle\",\"$APP_TITLE\"/g" "$js_file" 2>/dev/null || true
                sed -i "s/AppTitle:\"Grafana\"/AppTitle:\"$APP_TITLE\"/g" "$js_file" 2>/dev/null || true
                sed -i "s/AppTitle=\"Grafana\"/AppTitle=\"$APP_TITLE\"/g" "$js_file" 2>/dev/null || true
                echo "[grafana] Patched AppTitle in $(basename "$js_file")"
                patched=1
            fi
            # Also patch generic title references
            if grep -q 'title:"Grafana"' "$js_file" 2>/dev/null; then
                sed -i "s/title:\"Grafana\"/title:\"$APP_TITLE\"/g" "$js_file" 2>/dev/null || true
            fi
        done
        [ "$patched" -eq 0 ] && echo "[grafana] WARNING: AppTitle pattern not found in JS bundles"
    fi

    # Also patch the HTML title tag directly
    GRAFANA_INDEX="/usr/share/grafana/public/views/index.html"
    if [ -f "$GRAFANA_INDEX" ]; then
        sed -i "s/<title>Grafana<\/title>/<title>$APP_TITLE<\/title>/g" "$GRAFANA_INDEX" 2>/dev/null && \
            echo "[grafana] Patched index.html title"
    fi

    echo "[grafana] MoaV branding installed"
fi

# Find SSL certificates (same logic as admin)
find_certificates() {
    # Check for Let's Encrypt certificates first
    for cert_dir in /certs/live/*/; do
        if [ -d "$cert_dir" ]; then
            key_path="${cert_dir}privkey.pem"
            cert_path="${cert_dir}fullchain.pem"
            if [ -f "$key_path" ] && [ -f "$cert_path" ]; then
                echo "$key_path $cert_path"
                return 0
            fi
        fi
    done

    # Fallback to self-signed certificate
    if [ -f "/certs/selfsigned/privkey.pem" ] && [ -f "/certs/selfsigned/fullchain.pem" ]; then
        echo "/certs/selfsigned/privkey.pem /certs/selfsigned/fullchain.pem"
        return 0
    fi

    return 1
}

# Wait for certificates (up to 30 seconds)
waited=0
max_wait=30
while [ $waited -lt $max_wait ]; do
    # `|| true`: find_certificates returns 1 when no certificate exists yet, and a
    # plain `var=$(cmd)` assignment PROPAGATES that status (unlike `local x=$(cmd)`,
    # which masks it). Under `set -e` that killed grafana on every install before
    # certbot had issued -- which is exactly the state this loop exists to wait out.
    certs=$(find_certificates) || true
    if [ -n "$certs" ]; then
        break
    fi
    echo "[grafana] Waiting for certificates..."
    sleep 5
    waited=$((waited + 5))
done

certs=$(find_certificates) || true
if [ -n "$certs" ]; then
    key_file=$(echo "$certs" | cut -d' ' -f1)
    cert_file=$(echo "$certs" | cut -d' ' -f2)
    echo "[grafana] SSL: Enabled"
    echo "[grafana] Key: $key_file"
    echo "[grafana] Cert: $cert_file"

    # Set Grafana SSL environment variables
    export GF_SERVER_PROTOCOL=https
    export GF_SERVER_CERT_KEY="$key_file"
    export GF_SERVER_CERT_FILE="$cert_file"
else
    echo "[grafana] SSL: Disabled (no certificates found)"
    export GF_SERVER_PROTOCOL=http
fi

# Test certificate readability and fall back to HTTP if not readable
if [ -n "$GF_SERVER_CERT_KEY" ]; then
    certs_ok=true
    if [ -r "$GF_SERVER_CERT_KEY" ]; then
        echo "[grafana] Key file readable: OK"
    else
        echo "[grafana] WARNING: Cannot read key file: $GF_SERVER_CERT_KEY"
        ls -la "$GF_SERVER_CERT_KEY" 2>&1 || echo "[grafana] File does not exist"
        certs_ok=false
    fi
    if [ -r "$GF_SERVER_CERT_FILE" ]; then
        echo "[grafana] Cert file readable: OK"
    else
        echo "[grafana] WARNING: Cannot read cert file: $GF_SERVER_CERT_FILE"
        ls -la "$GF_SERVER_CERT_FILE" 2>&1 || echo "[grafana] File does not exist"
        certs_ok=false
    fi

    # Fall back to HTTP if certs aren't readable
    if [ "$certs_ok" = "false" ]; then
        echo "[grafana] Falling back to HTTP mode"
        unset GF_SERVER_CERT_KEY
        unset GF_SERVER_CERT_FILE
        export GF_SERVER_PROTOCOL=http
    fi
fi

echo "[grafana] Starting Grafana server (protocol: $GF_SERVER_PROTOCOL)..."

# Background task to star all MoaV dashboards after Grafana is ready
star_dashboards() {
    echo "[grafana] Waiting for Grafana to be ready..."
    sleep 15  # Wait for Grafana to fully start

    # Use same protocol Grafana is running with
    PROTO="${GF_SERVER_PROTOCOL:-http}"
    WGET_OPTS=""
    if [ "$PROTO" = "https" ]; then
        WGET_OPTS="--no-check-certificate"
    fi

    # Wait for Grafana API to be available (up to 60 seconds)
    for i in $(seq 1 12); do
        if wget -q -O /dev/null $WGET_OPTS "${PROTO}://localhost:3000/api/health" 2>/dev/null; then
            break
        fi
        sleep 5
    done

    # Get admin password from env
    ADMIN_PASS="${GF_SECURITY_ADMIN_PASSWORD:-admin}"
    API="${PROTO}://localhost:3000/api"

    # Build Basic auth header (works with both BusyBox wget and GNU wget)
    AUTH_B64=$(printf 'admin:%s' "$ADMIN_PASS" | base64 2>/dev/null || echo "")
    AUTH_HEADER="Authorization: Basic ${AUTH_B64}"

    # Star all MoaV dashboards
    for uid in moav-system moav-containers moav-singbox moav-xray moav-wireguard moav-amneziawg moav-snowflake moav-conduit moav-telemt; do
        wget -q -O /dev/null $WGET_OPTS \
            --header="$AUTH_HEADER" \
            --header="Content-Type: application/json" \
            --post-data="" \
            "${API}/user/stars/dashboard/uid/${uid}" 2>/dev/null && \
            echo "[grafana] Starred dashboard: ${uid}"
    done
    echo "[grafana] Dashboard starring complete"
}

# Run starring in background
star_dashboards &

# Run Grafana (handle both official image and local build)
if [[ -x /run.sh ]]; then
    # Official grafana/grafana image
    exec /run.sh
elif [[ -x /usr/share/grafana/bin/grafana ]]; then
    # Local build from Dockerfile.grafana
    exec /usr/share/grafana/bin/grafana server
else
    echo "[grafana] ERROR: No grafana executable found"
    exit 1
fi
