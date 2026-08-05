#!/bin/sh
# =============================================================================
# Grafana Proxy entrypoint - finds SSL certs and configures nginx
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

echo "[grafana-proxy] Starting Grafana CDN Proxy"

# Find SSL certificates (same logic as other services)
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
    # `|| true`: find_certificates returns 1 when no cert exists yet, and a plain
    # var=$(cmd) propagates that (unlike `local x=$(cmd)`). Under -e this killed the
    # proxy on every install before certbot issued -- the exact bug fixed in
    # grafana-entrypoint.sh; it was missed here in D4c.
    certs=$(find_certificates) || true
    if [ -n "$certs" ]; then
        break
    fi
    echo "[grafana-proxy] Waiting for certificates..."
    sleep 5
    waited=$((waited + 5))
done

certs=$(find_certificates) || true
if [ -z "$certs" ]; then
    echo "[grafana-proxy] ERROR: No certificates found, cannot start"
    exit 1
fi

key_file=$(echo "$certs" | cut -d' ' -f1)
cert_file=$(echo "$certs" | cut -d' ' -f2)
echo "[grafana-proxy] Using certificates:"
echo "[grafana-proxy]   Key:  $key_file"
echo "[grafana-proxy]   Cert: $cert_file"

# Wait for Grafana to be ready (up to 60 seconds)
echo "[grafana-proxy] Waiting for Grafana to be ready..."
waited=0
while [ $waited -lt 60 ]; do
    if wget -q --spider --no-check-certificate "https://grafana:3000/api/health" 2>/dev/null || \
       wget -q --spider "http://grafana:3000/api/health" 2>/dev/null; then
        echo "[grafana-proxy] Grafana is ready"
        break
    fi
    sleep 3
    waited=$((waited + 3))
done
if [ $waited -ge 60 ]; then
    echo "[grafana-proxy] WARNING: Grafana not ready after 60s, starting anyway"
fi

# Generate nginx config with correct certificate paths
cat > /etc/nginx/conf.d/default.conf << EOF
# Nginx reverse proxy for Grafana (auto-generated)
# Routes grafana.\${DOMAIN} through Cloudflare to Grafana

server {
    listen 443 ssl;
    http2 on;
    server_name grafana.*;

    # SSL certificates
    ssl_certificate $cert_file;
    ssl_certificate_key $key_file;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript application/xml+rss application/atom+xml image/svg+xml;

    # Caching for static assets
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        proxy_pass https://grafana:3000;
        proxy_ssl_verify off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # Cache static assets
        expires 7d;
        add_header Cache-Control "public, immutable";
    }

    # WebSocket support for live updates
    location /api/live/ {
        proxy_pass https://grafana:3000;
        proxy_ssl_verify off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # Main proxy
    location / {
        proxy_pass https://grafana:3000;
        proxy_ssl_verify off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # Timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
EOF

echo "[grafana-proxy] Configuration generated, starting nginx..."
exec nginx -g "daemon off;"
