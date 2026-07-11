# Troubleshooting Guide

Common issues and their solutions.

## Start Here: `moav doctor`

Before diving into specific issues, run the built-in diagnostics:

```bash
moav doctor
```

This runs all checks automatically and tells you exactly what's wrong:

- **docker** — Docker daemon running, Compose installed, disk usage
- **memory** — Available RAM, warns if too low for your config
- **disk** — Free disk space, warns before you run out
- **logs** — Container `json-file` log sizes; prompts to truncate any over 100 MB (useful for clearing pre-1.7.6 unbounded logs)
- **dns** — DNS records for your domain and enabled protocols
- **services** — Running containers vs enabled config, crash-looping detection
- **config** — Bootstrap status, config files exist for enabled protocols
- **ports** — Required ports listening, systemd-resolved conflicts
- **conflicts** — DNS-tunnel port-group collisions on port 53
- **env** — Missing `.env` variables compared to `.env.example`
- **updates** — New MoaV version available

You can also run individual checks:
```bash
moav doctor dns          # Just DNS
moav doctor services     # Just service status
moav doctor config       # Just config files
```

If `moav doctor` identifies the issue, follow its hints. If not, continue below.

---

## Table of Contents

- [Git and Update Issues](#git-and-update-issues)
  - [Update fails with "local changes would be overwritten"](#update-fails-with-local-changes-would-be-overwritten)
  - [Recovering from failed updates](#recovering-from-failed-updates)
  - [Breaking changes after update](#breaking-changes-after-update)
  - [Switching branches](#switching-branches)
- [Server-Side Issues](#server-side-issues)
  - [Services won't start](#services-wont-start)
  - [Certificate issues](#certificate-issues)
  - [Admin dashboard not accessible](#admin-dashboard-not-accessible)
  - [sing-box crashes](#sing-box-crashes)
  - [WireGuard connected but no traffic](#wireguard-connected-but-no-traffic)
  - [Hysteria2 not working](#hysteria2-not-working)
  - [AnyTLS not connecting](#anytls-not-connecting)
  - [TrustTunnel not connecting](#trusttunnel-not-connecting)
  - [AmneziaWG not connecting](#amneziawg-not-connecting)
  - [CDN VLESS+WS not working](#cdn-vlessws-not-working)
  - [CloudFront CDN: bad Sec-WebSocket-Key header](#cloudfront-cdn-bad-sec-websocket-key-header)
  - [XHTTP not connecting](#xhttp-not-connecting)
  - [DNS tunnel not working](#dns-tunnel-not-working)
- [Registry/Build Issues](#registrybuild-issues)
  - [Build fails on low-memory VPS (≤ 1 GB RAM)](#build-fails-on-low-memory-vps--1-gb-ram)
  - [Container registry blocked (gcr.io, ghcr.io)](#container-registry-blocked-gcrio-ghcrio)
  - [Building images locally](#building-images-locally)
- [Monitoring Issues](#monitoring-issues)
  - [System hangs after starting monitoring](#system-hangs-after-starting-monitoring)
  - [Grafana shows "No Data"](#grafana-shows-no-data)
  - [Clash-exporter authentication error (401)](#clash-exporter-authentication-error-401)
  - [High memory usage from cAdvisor](#high-memory-usage-from-cadvisor)
  - [Snowflake metrics showing zeros](#snowflake-metrics-showing-zeros)
  - [WireGuard exporter not starting](#wireguard-exporter-not-starting)
  - [GeoIP "Geographic Distribution" shows No Data](#geoip-geographic-distribution-shows-no-data)
- [MahsaNet Issues](#mahsanet-issues)
  - [Delete config returns 404](#delete-config-returns-404)
- [MoaV Test/Client Issues](#moav-testclient-issues)
- [Client-Side Issues](#client-side-issues)
- [Network-Specific Issues](#network-specific-issues)
- [Highly Censored Environments](#highly-censored-environments-specific-issues)
- [Reset and Re-bootstrap](#reset-and-re-bootstrap)
- [Common Commands](#common-commands)
- [Getting Help](#getting-help)

---

## Git and Update Issues

### Update fails with "local changes would be overwritten"

When running `moav update` or the installer, you may see:

```
error: Your local changes to the following files would be overwritten by merge:
    scripts/client-test.sh
Please commit your changes or stash them before you merge.
Aborting
```

**Why this happens:**
- You edited files while testing a fix or feature
- You manually modified configuration scripts
- You tested a development branch and switched back

**Solution 1: Use the interactive prompt (recommended)**

The latest MoaV versions detect this and offer options:
```bash
moav update
# Will show:
# ⚠ Local changes detected:
#     M scripts/client-test.sh
# Options:
#   1) Stash changes (save temporarily, can restore later)
#   2) Discard changes (reset to clean state)
#   3) Abort
```

Choose option 1 to save your changes, or option 2 to discard them.

**Solution 2: Manual stash**

```bash
cd /opt/moav

# Save your changes temporarily
git stash

# Now update
moav update
# or: git pull

# Restore your changes (may cause conflicts)
git stash pop
```

**Solution 3: Discard changes**

If you don't need your local changes:
```bash
cd /opt/moav

# Discard all local modifications
git checkout -- .

# Remove untracked files
git clean -fd

# Now update
moav update
```

### Recovering from failed updates

If an update fails partway through:

```bash
cd /opt/moav

# Check current state
git status

# If there are merge conflicts
git merge --abort

# Reset to last known good state
git reset --hard HEAD

# Try updating again
moav update
```

**If you need to completely reset:**

```bash
cd /opt/moav

# Fetch latest from remote
git fetch origin

# Hard reset to remote main
git reset --hard origin/main

# Verify
git status
```

### Breaking changes after update

Some updates include breaking changes (marked in [CHANGELOG](../CHANGELOG.md)) that require regenerating configs. Symptoms include:

- Clients can't connect after update
- Services crash on startup
- Protocol-specific errors (e.g., "invalid obfuscation password")

**Option 1: Rebuild configs (keeps users)**

```bash
moav config rebuild
moav restart
```

This regenerates server config while preserving user credentials. You must redistribute new config bundles to all users.

**Option 2: Fresh start (new keys, new users)**

If Option 1 doesn't work or you want a clean slate:

```bash
# Complete wipe and fresh install
moav uninstall --wipe

# Reconfigure
cp .env.example .env
nano .env  # Set DOMAIN, ACME_EMAIL, ADMIN_PASSWORD

# Bootstrap fresh
./moav.sh
```

**After any breaking change update:**
1. Download new user bundles from admin dashboard or `outputs/bundles/`
2. Distribute to all users
3. Users must delete old configs and import new ones

### Switching branches

**Switch to a feature/test branch:**
```bash
cd /opt/moav
git fetch origin
git checkout feature-branch-name
git pull
moav build  # Rebuild containers if needed
```

**Switch back to stable (main):**
```bash
cd /opt/moav
git checkout main
git pull
moav build
```

**If switching fails due to local changes:**
```bash
# Stash changes first
git stash
git checkout main
git pull

# Optionally restore changes
git stash pop
```

### Common scenarios

**Testing a bug fix from GitHub:**
```bash
# Save current state
cd /opt/moav
git stash

# Get the fix
git fetch origin
git checkout fix-branch-name
moav build
moav restart

# After testing, return to main
git checkout main
git stash pop  # Restore your changes if needed
```

**Accidentally edited files:**
```bash
# See what changed
git diff

# If you want to keep changes, stash them
git stash

# If you want to discard
git checkout -- filename.sh

# Or discard all changes
git checkout -- .
```

**View stashed changes:**
```bash
# List all stashes
git stash list

# Show what's in the most recent stash
git stash show -p

# Apply a specific stash
git stash apply stash@{0}

# Delete a stash
git stash drop stash@{0}
```

---

## Server-Side Issues

### Disk space full

If your server runs out of disk space, services may fail to start or behave unexpectedly.

**Quick check:**
```bash
df -h /
```

**Find what's using space with `ncdu`** (interactive disk usage analyzer):
```bash
# Install ncdu
apt install -y ncdu

# Scan from root (shows largest directories first, navigate with arrow keys)
ncdu /

# Scan just Docker data
ncdu /var/lib/docker
```

**Common space hogs:**
```bash
# Docker: remove unused images, containers, volumes
docker system prune -a --volumes

# Build cache (separate from image cache; can be many GB after failed builds)
docker builder prune -af

# Prometheus data (if monitoring enabled, ~50MB/day)
# Reduce retention in docker-compose.yml: --storage.tsdb.retention.time=7d

# Old log files
journalctl --vacuum-size=100M

# Docker container logs (can grow large)
docker system df -v
```

**Truncate oversized container logs (immediate reclaim, no restart needed):**

MoaV ≥ 1.7.6 caps each container's `json-file` log at 10 MB × 3 files via the
`x-logging` anchor in `docker-compose.yml`. The cap applies at *container
creation time* — containers that pre-date the upgrade keep growing under the
old (unbounded) policy until they're recreated.

To inspect and truncate in place:

```bash
# Top 10 largest container log files
sudo du -sh /var/lib/docker/containers/*/*-json.log 2>/dev/null | sort -h | tail

# Zero them in place — Docker keeps writing to the same FD, no service restart
# required. Kernel reclaims the disk pages immediately.
sudo truncate -s 0 /var/lib/docker/containers/*/*-json.log

# Verify rotation is enforced going forward
docker inspect moav-sing-box --format '{{json .HostConfig.LogConfig}}'
# expect: {"Type":"json-file","Config":{"max-file":"3","max-size":"10m"}}

# If the inspect shows empty/default config, force-recreate so the new
# rotation policy gets applied:
docker compose up -d --force-recreate
```

`moav doctor logs` (also part of `moav doctor`) detects oversized files
automatically and prompts to truncate them interactively.

### Services won't start

> **Quick check:** Run `moav doctor services` to see which services are enabled vs running.

**Check logs:**
```bash
docker compose logs sing-box
docker compose logs certbot
```

**Common causes:**

1. **Certificate not obtained:**
   ```bash
   # Check if cert exists
   docker compose exec sing-box ls -la /certs/live/

   # Re-run certbot
   docker compose run --rm certbot certonly --standalone \
     --non-interactive --agree-tos \
     --email YOUR_EMAIL --domains YOUR_DOMAIN
   ```

2. **Port already in use:**
   ```bash
   # Check what's using port 443
   ss -tlnp | grep 443

   # Stop conflicting service
   systemctl stop nginx  # or apache2
   ```

3. **Port 53 already in use (for dnstt):**

   This is usually caused by systemd-resolved:
   ```bash
   # Check what's using port 53
   ss -ulnp | grep 53

   # Stop and disable systemd-resolved
   systemctl stop systemd-resolved
   systemctl disable systemd-resolved

   # Set up direct DNS resolution
   echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf
   ```

4. **Configuration error:**
   ```bash
   # Validate sing-box config
   docker compose exec sing-box sing-box check -c /etc/sing-box/config.json
   ```

5. **Docker network error ("network not found"):**

   This happens when Docker networks get corrupted from failed runs:
   ```bash
   # Stop all containers and remove networks
   docker compose down
   docker network prune -f

   # Start fresh
   docker compose --profile all up -d
   ```

6. **Only some images built:**

   All services require `--profile` to be specified:
   ```bash
   # Build ALL images including optional services
   docker compose --profile all build --no-cache

   # Build only proxy services
   docker compose --profile proxy build

   # Available profiles: proxy, wireguard, dnstt, trusttunnel, admin, conduit, snowflake, monitoring, all
   ```

7. **Port already in use (8443 for Trojan):**

   Change the Trojan port in your .env file:
   ```bash
   # In .env
   PORT_TROJAN=9443  # Or any available port
   ```

### Shadowsocks not working

- **Inbound missing from sing-box config** — confirm `ENABLE_SS=true` in `.env`, then `moav restart sing-box` (the inbound is templated in at bootstrap; flipping the flag without re-bootstrapping won't add it):
  ```bash
  jq '.inbounds[] | select(.tag == "shadowsocks-in")' configs/sing-box/config.json
  # if empty, the flag was off when bootstrap ran
  moav bootstrap   # or rerun bootstrap to splice it in
  ```
- **Server PSK missing** — `moav doctor config` will flag missing state keys. The server PSK lives at `state/keys/shadowsocks-server.psk`; per-user PSK at `state/users/<user>/shadowsocks.env`.
- **Outline app says "invalid key"** — Outline's iOS/Android app expects the standard `ss://` URI with SS-2022 multi-user encoding (`method:server_psk:user_psk` base64-encoded). The bundle's `shadowsocks.txt` has this format. NekoBox / Hiddify / Streisand handle the same URI.
- **Port 8388 blocked by ISP** — change `PORT_SS` in `.env` to a less-fingerprinted port (e.g., 4443, 8443 if Trojan is off) and rerun `moav restart sing-box`.

### Certificate issues

> **Quick check:** Run `moav doctor dns` to verify DNS records point to your server, and `moav doctor config` to verify certificate files exist.

**Certificate not renewing:**
```bash
# Check expiry + whether the auto-renewal timer is installed
moav cert status

# Run a renewal check now (restarts TLS services if the cert changed)
moav cert renew

# (Re)install the daily auto-renewal timer — installed automatically on
# `moav start` since v1.8.5; pre-v1.8.5 installs need this once
moav cert install
```

> **Note:** plain `docker compose run --rm certbot renew` does NOT work — the
> compose service overrides the entrypoint for one-shot issuance and would run
> `/bin/sh renew` instead of certbot. Use `moav cert renew`, which forces
> `--entrypoint certbot` and restarts the services that load certs at startup.

**Certificate acquisition failed:**
- Ensure DNS A record points to this server
- Ensure port 80 is open (temporarily)
- Check rate limits: https://letsencrypt.org/docs/rate-limits/

### Admin dashboard not accessible

**Check if container is running:**
```bash
docker compose --profile admin ps
docker compose --profile admin logs admin
```

**Verify port is listening:**
```bash
# Inside container
docker exec moav-admin ss -tlnp

# On host
ss -tlnp | grep 9443
```

**Test locally first:**
```bash
curl -k https://localhost:9443/api/health
# Should return: {"status":"ok","timestamp":"..."}
```

**Open firewall:**
```bash
ufw allow 9443/tcp
# or
iptables -A INPUT -p tcp --dport 9443 -j ACCEPT
```

**Browser shows security warning (domainless mode):**

In domainless mode, admin uses a self-signed certificate. This is expected:
1. Click "Advanced" or "Show Details"
2. Click "Proceed to site" or "Accept the Risk"

**Access URLs:**
- With domain: `https://yourdomain.com:9443/`
- Domain-less mode: `https://YOUR_SERVER_IP:9443/`

**Admin runs on port 9443 by default** (not 8443). The internal container port is 8443, but it's mapped to 9443 externally.

### sing-box crashes

**Check the logs:**
```bash
docker compose logs -f sing-box
```

**Common fixes:**
```bash
# Rebuild container
docker compose build --no-cache sing-box
docker compose up -d sing-box

# Reset configuration
docker compose --profile setup run --rm bootstrap
```

### WireGuard handshake timeout

If you see:
```
Handshake for peer 1 (SERVER:51820) did not complete after 5 seconds, retrying
```

This means UDP packets aren't reaching the server. Common causes:

1. **UDP port 51820 blocked** - Most common in restrictive networks
   - Try WireGuard-wstunnel mode instead (tunnels over TCP/WebSocket)

2. **Server firewall:**
   ```bash
   ufw allow 51820/udp
   ```

3. **Server WireGuard not running:**
   ```bash
   docker compose --profile wireguard ps
   # Should show wireguard as "running"
   ```

### WireGuard-wstunnel not connecting

If you see errors like:
```
Cannot connect to tcp endpoint SERVER:8080 due to timeout
```

1. **Open port 8080 on server firewall:**
   ```bash
   ufw allow 8080/tcp
   ```

2. **Check wstunnel is running:**
   ```bash
   docker compose --profile wireguard ps
   # Both wireguard and wstunnel should be running
   ```

3. **Check wstunnel logs:**
   ```bash
   docker compose logs wstunnel
   ```

4. **Rebuild after update** (if you updated MoaV):
   ```bash
   docker compose --profile wireguard build wstunnel
   docker compose --profile wireguard up -d
   ```

### Hysteria2 not working

Hysteria2 uses **UDP port 443**. If it's not working but Reality/Trojan work:

1. **UDP is likely blocked** by your network - this is common in restrictive environments
2. Hysteria2 is designed for networks where TCP is throttled but UDP works
3. **Try other protocols** - Reality and Trojan use TCP and are more likely to work

**Verify server-side:**
```bash
# Check Hysteria2 is listening
docker compose logs sing-box | grep -i hysteria

# Test UDP connectivity (from another machine)
nc -vuz YOUR_SERVER_IP 443
```

### AnyTLS not connecting

AnyTLS runs inside the existing **sing-box** container on **TCP port 8445** and shares the Trojan TLS certificate for your `DOMAIN`. It is opt-in — make sure `ENABLE_ANYTLS=true` is set in `.env` and that you have re-run `moav restart sing-box` (or `moav bootstrap`).

**Check the container is running:**
```bash
docker compose ps sing-box
```

**Check the logs for the AnyTLS inbound:**
```bash
docker compose logs sing-box | grep -i anytls
# Look for the "anytls-in" inbound starting without errors
```

**Common issues:**

1. **Port not open:**
   ```bash
   ufw allow 8445/tcp
   ```
   Verify from another machine: `nc -vz YOUR_SERVER_IP 8445`

2. **Certificate issue:**
   - AnyTLS uses the same Let's Encrypt certificate as Trojan (for your `DOMAIN`)
   - If the cert is missing or expired, see [Certificate issues](#certificate-issues) and re-run `moav bootstrap`

3. **Client config error:**
   - Verify the password matches `anytls.txt` in the user bundle (same password as Trojan/Hysteria2)
   - Confirm the link points to your domain on port 8445 with `sni=<DOMAIN>` and `insecure=0`

4. **Client does not support AnyTLS (most common):**
   - AnyTLS has narrower client support than VLESS/Trojan. Use a recent build of **Hiddify**, **sing-box (SFA/SFI)**, **NekoBox/NekoRay**, **Mihomo Party**, or **Shadowrocket 2.2.65+**
   - Clients such as v2rayNG, Streisand, V2Box, and Clash Verge do **not** support AnyTLS and will fail to import the link — switch to a supported client or use another protocol (Reality, Trojan, Hysteria2)

### TrustTunnel not connecting

**Check container is running:**
```bash
docker compose --profile trusttunnel ps
docker compose logs trusttunnel
```

**Common issues:**

1. **Port not open:**
   ```bash
   ufw allow 4443/tcp
   ufw allow 4443/udp
   ```

2. **Certificate issue:**
   - TrustTunnel uses the same Let's Encrypt certificate as other services
   - If cert is missing, run `moav bootstrap` again

3. **Client config error:**
   - Verify credentials match `trusttunnel.txt` in user bundle
   - Check `trusttunnel.toml` has correct domain/IP

### AmneziaWG not connecting

**Check container is running:**
```bash
docker compose --profile amneziawg ps
docker compose logs amneziawg
```

**Common issues:**

1. **Port not open:**
   ```bash
   ufw allow 51821/udp
   ```

2. **Config mismatch:**
   - Obfuscation parameters (S1, S2, H1-H4) must match between server and client
   - Re-download the user bundle if parameters are wrong

3. **awg-quick not found (client):**
   - Install awg-tools from https://github.com/amnezia-vpn/amneziawg-tools/releases
   - Or use the Amnezia VPN app which includes built-in support

### CDN VLESS+WS not working

**DNS lookup failure:**
If you see `lookup cdn.yourdomain.com: operation was canceled`:
1. Verify `cdn` subdomain exists in Cloudflare DNS
2. Check it's set to **Proxied** (orange cloud)
3. Wait for DNS propagation (up to 5 minutes)

**Connection refused:**
1. Verify port 2082 is open: `ufw allow 2082/tcp`
2. Check sing-box is listening: `docker compose logs sing-box | grep vless-ws`

**Cloudflare 521 "Web server is down":**

This usually means Cloudflare can't reach your origin on the correct port.

1. **Check Origin Rule exists** (most common cause):
   - Go to Cloudflare → Rules → Origin Rules
   - You need a rule that redirects `cdn.yourdomain.com` to port 2082
   - Without this, Cloudflare connects to port 80 (wrong port)
   - See [DNS.md Cloudflare section](DNS.md#cloudflare) for setup instructions

2. **Verify port 2082 is reachable:**
   ```bash
   # From another machine, test direct access to your server
   curl -s -o /dev/null -w "%{http_code}" http://YOUR_SERVER_IP:2082/test
   # Should return 400 or 404 (sing-box responding)
   ```

3. **Check firewall:**
   ```bash
   ufw allow 2082/tcp
   ```

4. **Verify sing-box is listening:**
   ```bash
   docker compose logs sing-box | grep -i "vless-ws"
   ```

**Cloudflare 525 "SSL Handshake Failed":**

This means Cloudflare is trying HTTPS to your origin, but MoaV's CDN inbound on port 2082 is plain HTTP.

1. **Set SSL/TLS mode to Flexible** in Cloudflare dashboard:
   - Go to **SSL/TLS** → **Overview** → Set to **Flexible**
   - **Full** and **Full (Strict)** will NOT work — they make Cloudflare connect via HTTPS, but port 2082 doesn't speak TLS
2. **If you need Full SSL for other subdomains**, create a Configuration Rule:
   - Go to **Rules** → **Configuration Rules** → **Create rule**
   - Match: **Hostname** equals `cdn.yourdomain.com`
   - Setting: **SSL** → **Flexible**
   - This overrides the zone-wide SSL mode for just the CDN subdomain

**Cloudflare 520 "Unknown error":**
1. Set SSL/TLS mode to **Flexible** in Cloudflare dashboard (see 525 section above)
2. Verify sing-box container is running
3. Check sing-box config has `vless-ws-in` inbound on port 2082

### CloudFront CDN: `bad "Sec-WebSocket-Key" header`

```
inbound/vless[vless-ws-in]: process connection from 15.158.x.x: upgrade websocket connection: handshake error: bad "Sec-WebSocket-Key" header
```

CloudFront is stripping WebSocket upgrade headers before forwarding to your server. Two things to fix:

**1. CDN_TRANSPORT must be `ws`** (not `httpupgrade`):

```bash
# Check current sing-box config
docker exec moav-sing-box cat /etc/sing-box/config.json | jq '.inbounds[] | select(.tag == "vless-ws-in") | .transport.type'
# Must return "ws". If it returns "httpupgrade", fix .env and re-bootstrap:
# Set CDN_TRANSPORT=ws in .env, then: moav bootstrap && moav restart sing-box
```

**2. CloudFront must have `AllViewer` Origin Request Policy:**

```bash
# Check current policies
aws cloudfront get-distribution --id YOUR_DIST_ID \
  --query 'Distribution.DistributionConfig.DefaultCacheBehavior.{Cache: CachePolicyId, OriginRequest: OriginRequestPolicyId}' \
  --output table
```

Expected:
- CachePolicyId: `4135ea2d-6df8-44a3-9df3-4b5a84be39ad` (CachingDisabled)
- OriginRequestPolicyId: `216adef6-5c7f-47e4-b989-5492eafa07d3` (AllViewer)

If `OriginRequestPolicy` is `None`, CloudFront drops the `Sec-WebSocket-Key`, `Upgrade`, and `Connection` headers. Fix:

```bash
aws cloudfront get-distribution-config --id YOUR_DIST_ID > /tmp/cf-config.json

jq '.DistributionConfig.DefaultCacheBehavior.OriginRequestPolicyId = "216adef6-5c7f-47e4-b989-5492eafa07d3" | .DistributionConfig.DefaultCacheBehavior.CachePolicyId = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" | .DistributionConfig' /tmp/cf-config.json > /tmp/cf-update.json

ETAG=$(jq -r '.ETag' /tmp/cf-config.json)
aws cloudfront update-distribution --id YOUR_DIST_ID --if-match "$ETAG" --distribution-config file:///tmp/cf-update.json
```

Wait 5-10 minutes for CloudFront deployment, then test:
```bash
curl -s -o /dev/null -w "%{http_code}" https://d1234abcd.cloudfront.net/test
# Should return 400 (sing-box responding to non-WebSocket request)
```

### XHTTP not connecting

**Check container is running:**
```bash
docker compose --profile xhttp ps
docker compose logs xhttp
```

**Common issues:**

1. **Port not open:**
   ```bash
   ufw allow 2096/tcp
   ```

2. **Service not enabled:**
   - XHTTP is experimental and opt-in. Ensure `ENABLE_XHTTP=true` in `.env`
   - Restart after enabling: `moav restart`

3. **Verify port is listening:**
   ```bash
   ss -tlnp | grep 2096
   ```

4. **Client compatibility:**
   - XHTTP requires Xray-compatible clients: V2rayNG, Hiddify, Streisand, V2Box, V2rayN, V2rayU, NekoBox
   - Ensure your client app is updated to a version that supports XHTTP transport

### WireGuard connected but no traffic

**Check if peer is loaded:**
```bash
docker compose exec wireguard wg show
```

Look for your peer's public key. It should show:
- `latest handshake: X seconds ago`
- `transfer: X received, X sent`

If there's no handshake, check for **key mismatch**:

```bash
# What the client config expects (server public key)
cat configs/wireguard/server.pub

# What's actually running
docker compose exec wireguard wg show wg0 public-key
```

**If keys don't match**, run the sync script:
```bash
# Automatically sync keys from running WireGuard
./scripts/wg-sync-keys.sh

# Or manually fix:
docker compose exec wireguard wg show wg0 public-key > configs/wireguard/server.pub

# Regenerate user with correct key
./scripts/wg-user-add.sh newuser
```

**Check NAT/masquerade:**
```bash
docker compose exec wireguard iptables -t nat -L -n | grep MASQUERADE
```

**Check IP forwarding:**
```bash
docker compose exec wireguard cat /proc/sys/net/ipv4/ip_forward
# Should return 1
```

**Check firewall allows WireGuard port:**
```bash
ufw allow 51820/udp
```

**Update MoaV if issue persists:**

Older versions had missing iptables rules for return traffic. Update and rebuild:
```bash
cd /opt/moav
moav update
docker compose --profile wireguard build --no-cache wireguard
moav restart wireguard
```

### DNS tunnel not working

> **Quick check:** Run `moav doctor dns` to verify NS delegation for DNS tunnel subdomains, and `moav doctor ports` to check port 53 conflicts.

**Enabling/disabling individual tunnels:** All four DNS tunnels share port 53 via `dns-router` (queries fanned out by subdomain suffix). Enable or disable each independently in `.env`:
```bash
# All four DNS tunnels are on by default:
ENABLE_DNSTT=true
ENABLE_SLIPSTREAM=true
ENABLE_MASTERDNS=true
ENABLE_XDNS=true       # needs FinalMask-aware client; set false to opt out
PORT_DNS=53            # dns-router public port (owns port 53)
PORT_XDNS=5356         # xray XDNS secondary host port
```
Or use `moav switch-dns` to manage tunnel daemons: `moav switch-dns dnstt+slipstream+masterdns+xdns` (all four) or `moav switch-dns off`.

**Check logs for domain issues:**
```bash
docker compose logs dnstt        # dnstt
docker compose logs xray         # XDNS (runs inside xray container)
docker compose logs dns-router   # DNS routing (all tunnels)
```

If you see `NXDOMAIN: not authoritative for example.com`, the domain wasn't set correctly during bootstrap:

```bash
# Check the config file
cat configs/dnstt/server.conf
# Should show: DNSTT_DOMAIN=t.yourdomain.com (not example.com)

# If wrong, update it
sed -i 's/example.com/yourdomain.com/g' configs/dnstt/server.conf

# Rebuild and restart dnstt
docker compose build dnstt
docker compose --profile dnstt up -d dnstt
```

**Verify NS delegation:**
```bash
dig NS t.yourdomain.com
# Should return dns.yourdomain.com (or your server)
```

**Test dnstt server:**
```bash
docker compose logs dnstt
# Should show "listening on :5353" and your correct domain
```

**Check firewall:**
```bash
# Ensure UDP 53 is open
ufw allow 53/udp
# or
iptables -A INPUT -p udp --dport 53 -j ACCEPT
```

#### dnstt connects but no traffic flows (`begin session` but no `begin stream`)

**Symptom:** the client (especially **MahsaNG v16**) reports `TLS handshake timeout` / "failed to detect internet" and never actually passes traffic. `docker compose logs dnstt` shows `begin session <id>` repeating with a **new id each time** and **no** `begin stream`.

**Cause:** this is almost always a **client-side MTU that's too high**, not a server problem. The tiny session-handshake packets get through (so the session opens), but the larger stream-open packets exceed what the DNS path/resolver will carry and get dropped — so a stream never opens and the client keeps retrying with fresh sessions.

**First, confirm the server is fine** — run a stock `dnstt-client` against your own server, bypassing your app entirely. If it fetches your server's IP, the whole server chain (NS → resolver → dns-router → dnstt → sing-box egress) is correct and the problem is purely the client:

```bash
# Replace PUBKEY (from outputs/dnstt/server.pub) and t.yourdomain.com
docker run --rm --network host \
  -e GOPROXY='https://proxy.golang.org|https://goproxy.cn|direct' -e GOSUMDB=off \
  golang:1.24-alpine sh -c '
  apk add --no-cache git curl >/dev/null
  git clone https://www.bamsoftware.com/git/dnstt.git /src >/dev/null 2>&1 || git clone https://repo.or.cz/dnstt.git /src >/dev/null 2>&1
  cd /src/dnstt-client && go build -o /usr/local/bin/dnstt-client .
  dnstt-client -udp 8.8.8.8:53 -pubkey PUBKEY t.yourdomain.com 127.0.0.1:7000 &
  sleep 8
  curl -s --socks5-hostname 127.0.0.1:7000 -m 40 https://api.ipify.org; echo
'
```
Watch `moav logs -f dnstt` alongside it: if you see `begin stream` (not just `begin session`) and curl returns your server IP, the server is **verified good** — the standalone client works because it negotiates a small `effective MTU` (~132).

**Fix (client side):** lower the client's dnstt MTU.
- The **standalone dnstt-client** picks a safe MTU automatically — it works out of the box.
- **MahsaNG v16 does not expose a dnstt MTU control**, so dnstt often opens a session but never a stream there. On MahsaNG, prefer **MasterDNS** (the native DNS tunnel in v16 — it manages its own small MTU, e.g. upload 109 / download 500, and works without tuning) or **Slipstream**; use the standalone dnstt-client when you specifically need dnstt with a tunable MTU.

> The same "session opens, nothing flows" logic applies to any DNS tunnel: the server side is almost never the culprit if the isolation test above passes — check the client's MTU/transport (UDP vs DoH) settings.

#### dnstt stream opens but resets immediately (`connection reset by peer` on `:1080`)

**Symptom:** the dnstt log shows `begin stream` followed immediately by `copy stream←upstream: … ->…:1080: read: connection reset by peer` and `end stream`, repeating. The client app reports something like `SSH Tunnel established` then `Handshake timeout`.

**Cause — client-type mismatch, by design (not a bug):** the client is an **SSH-over-DNS app** (HTTP Injector / Dark Tunnel / "SSH + DNSTT" style) that expects an **SSH server** at the far end of the tunnel. MoaV's DNS tunnels forward to **sing-box's SOCKS5 inbound** (`sing-box:1080`), *not* an SSH host — so sing-box receives SSH handshake bytes it can't parse and resets the connection.

**MoaV's DNS tunnels (dnstt, Slipstream, MasterDNS) are a SOCKS5 transport, not an SSH host.** Use a client that speaks SOCKS5 to the tunnel endpoint:
- the standalone **dnstt-client**, with your app pointing SOCKS5 at its local listener;
- **MahsaNG v16** (use its native **MasterDNS** tunnel);
- **v2ray / sing-box / Xray** clients using the local dnstt port as a SOCKS proxy.

SSH-tunnel apps that require an SSH account behind dnstt are **not supported** — there is no SSH server behind MoaV's DNS tunnels.

---

## Registry/Build Issues

### Build fails on low-memory VPS (≤ 1 GB RAM)

**Symptoms:** During `moav start` or `moav build --profile all` on a small VPS, the parallel build dies with one of these errors (they have the same root cause):

```
target amneziawg-exporter: NotFound: forwarding Ping: no such job mxjreqi1urjzqlsbvdw622pdk
```
or:
```
target xray: failed to solve: process "/bin/sh -c apk add --no-cache bash ca-certificates tzdata"
did not complete successfully: failed to create endpoint fs4tn8... on network bridge:
failed to find host side interface vethf6f8751: resource temporarily unavailable
```
or: build hangs at ~1200s (20 min) before failing.

**Cause:** Recent Docker Compose (v2.22+) defaults to "bake" mode, which builds all images in parallel via BuildKit. With 19+ MoaV images attempting to build concurrently on a tight VPS:

- **OOM in BuildKit daemon** → `NotFound: no such job ...` (job registry corrupts when memory pressure kills internal goroutines)
- **Kernel/network resource exhaustion** → `failed to find host side interface vethN: resource temporarily unavailable` (bridge networking can't allocate veth pairs fast enough when many containers spawn concurrently)
- **Heavy swapping** → build appears stuck for 15-20+ minutes before eventually failing

All three are the same underlying problem — too many parallel operations on a machine without the RAM to serve them.

**Fix — reset buildx state and force sequential builds:**

> ⚠️ Compose v2 removed the `--parallel N` flag — it will be interpreted as a service name. Use one of the patterns below instead.

```bash
# 1. Clear the broken buildx state
docker buildx prune -af
docker buildx rm --force default 2>/dev/null || true

cd /opt/moav

# 2a. RECOMMENDED — loop one service at a time (most reliable on ≤ 1 GB RAM)
for svc in $(COMPOSE_BAKE=false docker compose --profile all config --services); do
    echo "=== Building $svc ==="
    COMPOSE_BAKE=false docker compose build "$svc" || { echo "FAILED: $svc"; break; }
done

# 2b. ALTERNATIVE — env-var based serialization (Compose v2.30+)
# COMPOSE_BAKE=false COMPOSE_PARALLEL_LIMIT=1 docker compose --profile all build

# 2c. LAST RESORT — disable BuildKit entirely (classic builder, always serial)
#     May fail if any Dockerfile uses BuildKit-specific syntax
# DOCKER_BUILDKIT=0 COMPOSE_DOCKER_CLI_BUILD=0 COMPOSE_BAKE=false \
#     docker compose --profile all build

# 3. Once build succeeds, start normally
moav start
```

**Prevent recurrence on low-RAM hosts:** Add these to your shell profile (`~/.bashrc` or `~/.zshrc`):

```bash
export COMPOSE_BAKE=false
export COMPOSE_PARALLEL_LIMIT=1
```

With bake disabled and parallelism pinned to 1, Compose builds images sequentially. Each build still succeeds — they just happen one at a time instead of 19 concurrently.

**When to worry about this:**

| RAM | Parallel build | Sequential build |
|-----|----------------|------------------|
| ≥ 2 GB | Usually OK | Always OK |
| 1 GB  | Frequently crashes (this issue) | OK but slow (~15-20 min) |
| < 1 GB | Not supported | Try, but may OOM anyway |

### Container registry blocked (gcr.io, ghcr.io)

In some regions (Iran, Russia, China), certain container registries are blocked:

| Registry | Images Affected | Status |
|----------|-----------------|--------|
| `gcr.io` | cAdvisor | Often blocked |
| `ghcr.io` | clash-exporter | Often blocked |
| `docker.io` | Most base images | Usually works (mirrors available) |

**Symptoms:**
- `docker pull` hangs or times out
- Build fails with "connection refused" or "timeout"
- Monitoring stack won't start

**Solution:** Build blocked images locally using `moav build --local`:

```bash
# Build commonly blocked images (gcr.io, ghcr.io)
moav build --local

# Build specific image
moav build --local cadvisor
moav build --local clash-exporter

# Build ALL external images locally
moav build --local all
```

### Building images locally

MoaV can build monitoring stack images from source when registries are blocked.

**Available images for local build:**

| Image | Registry | Build Command |
|-------|----------|---------------|
| cAdvisor | gcr.io | `moav build --local cadvisor` |
| clash-exporter | ghcr.io | `moav build --local clash-exporter` |
| Prometheus | docker.io | `moav build --local prometheus` |
| Grafana | docker.io | `moav build --local grafana` |
| Node Exporter | docker.io | `moav build --local node-exporter` |
| Nginx | docker.io | `moav build --local nginx` |
| Certbot | docker.io | `moav build --local certbot` |

**How it works:**
1. Downloads pre-built binaries from GitHub releases (not blocked)
2. Creates a local Docker image
3. Updates `.env` to use the local image

**Version control:**

Set versions in `.env` before building:
```bash
# In .env
PROMETHEUS_VERSION=3.5.1
GRAFANA_VERSION=12.3.3
NODE_EXPORTER_VERSION=1.10.2
CADVISOR_VERSION=0.56.2
CLASH_EXPORTER_VERSION=0.0.4
```

**Force rebuild:**
```bash
moav build --local --no-cache cadvisor
```

**Build everything locally (no registry pulls):**
```bash
moav build --local all
```

This builds both MoaV services and all external monitoring images.

---

## Monitoring Issues

> **Warning**: The monitoring stack nearly doubles MoaV's resource requirements. While MoaV alone runs on 1 vCPU / 1GB RAM, adding monitoring requires at least **2 vCPU / 2GB RAM** for stable operation.

### System hangs after starting monitoring

If your server hangs or becomes unresponsive after starting monitoring (especially the first time), you're likely running out of RAM.

**Symptoms:**
- SSH connection freezes
- Commands stop responding
- Server becomes unreachable

**Solution 1: Recover and disable monitoring**

If you can still SSH in (wait a few minutes):
```bash
# Stop all monitoring services
docker compose --profile monitoring stop

# Or stop individual heavy services
docker stop moav-prometheus moav-grafana moav-cadvisor
```

If SSH is frozen, reboot via your VPS control panel, then:
```bash
cd /opt/moav
# Don't start monitoring on boot
moav start proxy admin  # Without monitoring
```

**Solution 2: Upgrade your server**

Monitoring requires at least 2GB RAM. Upgrade your VPS to 2GB+ RAM before enabling monitoring.

**Solution 3: Run lighter monitoring**

If you must have metrics on 1GB RAM, disable the heaviest components:
```bash
# Start only essential monitoring (skip cAdvisor)
docker compose --profile monitoring up -d prometheus grafana node-exporter clash-exporter

# Stop cAdvisor if running (uses ~150MB)
docker stop moav-cadvisor
```

### Grafana shows "No Data"

> **Quick check:** Run `moav doctor services` to verify monitoring services are running.

1. Check Prometheus is running:
   ```bash
   docker logs moav-prometheus
   ```

2. Verify targets are up - access Prometheus internally:
   ```bash
   docker exec moav-grafana wget -qO- http://prometheus:9091/api/v1/query?query=up
   ```

3. Ensure services are on the same Docker network (`moav_net`)

### Clash-exporter authentication error (401)

**Symptoms:**
```
failed to dial: failed to WebSocket dial: expected handshake response status code 101 but got 401
```

This means `CLASH_API_SECRET` in `.env` doesn't match the secret in sing-box's config. This typically happens after a re-bootstrap where the state volume has a different secret than `.env`.

**Diagnose:**
```bash
# What .env has (used by clash-exporter)
grep CLASH_API_SECRET .env

# What sing-box actually uses (source of truth)
docker compose exec sing-box cat /etc/sing-box/config.json | python3 -m json.tool | grep -A2 clash_api
```

**Fix:**
```bash
# Sync .env with the actual sing-box secret
SECRET=$(docker compose exec sing-box cat /etc/sing-box/config.json | python3 -c "import sys,json; print(json.load(sys.stdin)['experimental']['clash_api']['secret'])")
sed -i "s/^CLASH_API_SECRET=.*/CLASH_API_SECRET=$SECRET/" .env
docker compose restart clash-exporter
```

Or use `moav restart monitoring` — the `ensure_clash_api_secret()` function now auto-syncs stale secrets from the state volume on startup.

### High memory usage from cAdvisor

Limit cAdvisor resources in `docker-compose.yml`:
```yaml
cadvisor:
  deploy:
    resources:
      limits:
        memory: 256M
```

### Snowflake metrics showing zeros

The Snowflake exporter parses log files for summary statistics. Summaries are logged periodically. If you just started Snowflake, wait for the first summary to appear:

```bash
# Check if summaries exist
docker exec moav-snowflake cat /var/log/snowflake/snowflake.log | grep "In the"
```

### WireGuard exporter not starting

The exporter needs read access to WireGuard config. Check:
```bash
docker logs moav-wireguard-exporter
ls -la configs/wireguard/wg0.conf
```

### GeoIP "Geographic Distribution" shows No Data

The GeoIP feature requires the DB-IP Lite database to be downloaded first.

**Step 1: Download the GeoIP database**
```bash
docker compose --profile setup run --rm geoip-updater
```

**Step 2: Verify the database is in the volume**
```bash
docker run --rm -v moav_geoip:/geoip alpine ls -la /geoip/
# Should show: dbip-country-lite.mmdb (~5MB)
```

**Step 3: Restart the exporters**
```bash
docker compose restart singbox-exporter xray-exporter wireguard-exporter amneziawg-exporter
```

**Step 4: Verify GeoIP is loaded**
```bash
docker logs moav-singbox-exporter 2>&1 | grep GeoIP
# Should show: GeoIP: loaded database from /geoip/dbip-country-lite.mmdb
```

**Step 5: Check metrics are being emitted**
```bash
# For sing-box:
docker exec moav-grafana wget -qO- http://singbox-exporter:9102/metrics | grep country
# For xray:
docker exec moav-grafana wget -qO- http://xray-exporter:9103/metrics | grep country
```

**Common issues:**

| Symptom | Cause | Fix |
|---------|-------|-----|
| `GeoIP: could not load ...` | Database not downloaded | Run `geoip-updater` (see step 1) |
| `GeoIP: maxminddb not installed` | Exporter image outdated | Rebuild: `docker compose build singbox-exporter` |
| Metrics show only `country="XX"` | Database loaded but IPs not resolving | DB may be corrupt — re-run `geoip-updater` |
| sing-box geo works but xray doesn't | Xray log format issue | Check `docker logs moav-xray` for `accepted` lines with IPs |
| WireGuard shows geo but sing-box doesn't | Clash API not reachable | Check `docker logs moav-singbox-exporter` for API errors |

For complete monitoring documentation, see [MONITORING.md](MONITORING.md).

---

## MahsaNet Issues

### Delete config returns 404

**Symptom:** Clicking "del" on a donated config in the admin dashboard shows:
```
MahsaNet API returned 404: {"detail":"No Config matches the given query."}
```

**Cause:** The MahsaNet API uses `id` (not `hash`) as the delete identifier. The config list endpoint returns `hash` but some API versions may not include `id`. MoaV now automatically falls back to looking up the config by hash to find the `id` for deletion.

**Fixes:**
1. Update MoaV to the latest version (includes the fallback logic)
2. If the error persists, the config may have already been deleted on MahsaNet's side — click "Refresh" to reload the list

**MahsaNet API reference:** [https://www.mahsaserver.com/backend/api/schema/redoc/](https://www.mahsaserver.com/backend/api/schema/redoc/)

Key endpoints:

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/backend/api/v1/config/` | List configs (supports `?hash=`, `?alias=`, `?is_active=` filters) |
| POST | `/backend/api/v1/config/` | Create (donate) a config |
| DELETE | `/backend/api/v1/config/{id}/` | Delete a config by `id` |

Authentication: `Authorization: Token <your-api-key>` header on all requests.

---

## MoaV Test/Client Issues

### `moav test` fails to build

**Docker build errors:**
```bash
# Rebuild with no cache
moav client build --no-cache

# Or manually:
docker build --no-cache -t moav-client -f Dockerfile.client .
```

**Network issues during build:**
- Pre-built binaries are downloaded from GitHub/GitLab
- If downloads fail, the build falls back to compiling from source (slower)
- Check your server has internet access

### `moav test` shows all protocols as "skip"

**User bundle not found:**
```bash
# Check if bundle exists
ls -la outputs/bundles/user1/

# Regenerate user bundle
moav user add user1
```

**Bundle path issue:**
```bash
# Verify the bundle contains config files
ls outputs/bundles/user1/
# Should contain: reality.txt, trojan.txt, hysteria2.yaml, etc.
```

### `moav test` shows "sing-box failed to start"

**Configuration format issue:**
- sing-box 1.12+ requires `route.final` instead of deprecated special outbounds
- Check sing-box version: `docker run --rm moav-client sing-box version`

**Debug with verbose output:**
```bash
# Run test container interactively
docker run --rm -it \
  -v "$(pwd)/outputs/bundles/user1:/config:ro" \
  moav-client /bin/bash

# Inside container, manually test
VERBOSE=true CONFIG_DIR=/config /app/client-test.sh
```

### `moav client connect` can't establish connection

**Check server is running:**
```bash
moav status
# Ensure sing-box and other services show as "running"
```

**Try different protocols:**
```bash
moav client connect user1 --protocol hysteria2
moav client connect user1 --protocol trojan
```

**Check firewall on server:**
```bash
# Server-side
ufw status
ss -tlnp  # TCP ports
ss -ulnp  # UDP ports
```

### Client proxy ports already in use

**Change ports in .env:**
```bash
# In .env
CLIENT_SOCKS_PORT=10800
CLIENT_HTTP_PORT=18080
```

**Or stop conflicting service:**
```bash
# Check what's using port 1080
ss -tlnp | grep 1080
```

### WireGuard test shows "endpoint not reachable"

This is expected if:
- UDP port 51820 is blocked by firewall
- Server WireGuard container is not running

**Check WireGuard is running:**
```bash
docker compose --profile wireguard ps
```

**Check UDP is not blocked:**
```bash
# From client machine
nc -vuz YOUR_SERVER_IP 51820
```

### Tor/Snowflake fallback not working

**Tor is standalone and doesn't require your server:**
```bash
# Test Snowflake independently
docker run --rm moav-client snowflake-client --help
```

**If binaries are missing:**
- Some optional binaries may fail to download during build
- Check build logs for "not available (optional)" messages

**For Psiphon:**
- Psiphon is not available via MoaV client
- Use the [official Psiphon apps](https://psiphon.ca/en/download.html) instead

---

## Client-Side Issues

### Can't connect at all

1. **Verify server is reachable:**
   ```bash
   ping YOUR_SERVER_IP
   curl -I https://yourdomain.com
   ```

2. **Check if IP is blocked:**
   - Try from a different network (mobile data)
   - Use online tools to check if IP is accessible from Iran

3. **Try different protocols:**
   Reality → Hysteria2 → Trojan → WireGuard → DNS tunnel

### TLS handshake timeout

**Causes:**
- Server certificate issue
- Deep packet inspection blocking
- Server overloaded

**Solutions:**
1. Try Reality protocol (doesn't use your cert)
2. Try Hysteria2 (uses UDP)
3. Check server certificate is valid

### Slow connection

**Hysteria2 often helps** - it's optimized for lossy networks.

**For sing-box clients:**
- Enable multiplexing
- Try different congestion control

**Check server resources:**
```bash
docker stats
htop
```

### Frequent disconnections

1. **Enable keep-alive:**
   - In client app, look for "persistent connection" or "keep-alive"

2. **Check server uptime:**
   ```bash
   docker compose ps
   uptime
   ```

3. **Check for IP blocks:**
   - ISP may be actively disrupting connections
   - Try rotating to a new server IP

### "Invalid config" errors

1. Ensure you're using the correct link for your app
2. Check for extra spaces or newlines in the link
3. Try importing the JSON file instead of the link

---

## Network-Specific Issues

### Works on WiFi but not mobile data

Mobile carriers may have different filtering:
- Try Hysteria2 (UDP-based)
- Try DNS tunnel
- Some carriers block all VPN signatures

### Works on mobile data but not WiFi

Home ISPs often have stricter filtering:
- Try Reality protocol
- Try different Reality target sites
- Try port 80 or other ports (if configured)

### Very slow despite connection working

1. **Check if throttled:**
   - Speed test without VPN
   - Speed test with VPN
   - If VPN is significantly slower, you're being throttled

2. **Try Hysteria2:**
   - Uses UDP which is sometimes less throttled
   - Has built-in congestion control

3. **Try different times:**
   - Filtering may be heavier during peak hours

---

## highly censored environments-Specific Issues

### All protocols blocked

When ISP blocks everything:

1. **DNS Tunnel** - Often still works as it's hard to block all DNS
2. **Different Reality targets** — Choose a domain that your ISP can't easily block (e.g., domestic banking or fintech sites). See [Choosing a Reality Target](SETUP.md#choosing-a-reality-target-sni) for how to pick and verify targets.

3. **Get a new server** - Your IP may be specifically blocked

### Protocol detected and blocked

Signs your protocol is detected:
- Works for a few minutes then dies
- Works initially then stops
- Specific protocol fails but others work

**Solutions:**
1. Switch protocols immediately
2. Change Reality target domain
3. Update to latest sing-box version (better anti-detection)

### Total internet shutdown

During major events, Govs sometimes shuts internet entirely:

1. DNS tunnel might still work (if any DNS works)
2. Satellite internet (Starlink) if available
3. Wait for restoration

---

## Reset and Re-bootstrap

### Full reset (start fresh)

If things are broken beyond repair, reset everything:

```bash
# Complete wipe - removes all containers, volumes, configs, keys, bundles
moav uninstall --wipe

# Reconfigure
cp .env.example .env
nano .env  # Set DOMAIN, ACME_EMAIL, ADMIN_PASSWORD

# Fresh bootstrap
./moav.sh
```

This gives you a completely clean installation with new keys and certificates.

### Partial reset (keep data)

Remove containers but keep your configuration for quick reinstall:

```bash
# Remove containers only, keep .env, keys, bundles
moav uninstall

# Reinstall and start
./moav.sh install
moav start
```

### Re-bootstrap only

To regenerate server config without removing anything:

```bash
# Remove only the bootstrap flag
docker run --rm -v moav_moav_state:/state alpine rm /state/.bootstrapped

# Re-run bootstrap
moav bootstrap

# Restart services
moav restart
```

### Reset only WireGuard

```bash
# Remove WireGuard config
rm configs/wireguard/wg0.conf configs/wireguard/server.pub

# Remove WireGuard keys from state
docker run --rm -v moav_moav_state:/state alpine rm -f /state/keys/wg-server.key /state/keys/wg-server.pub

# Remove bootstrap flag and re-run
docker run --rm -v moav_moav_state:/state alpine rm /state/.bootstrapped
docker compose --profile setup run --rm bootstrap

# Restart WireGuard
docker compose --profile wireguard up -d wireguard
```

### Reset only dnstt

```bash
# Remove dnstt config and keys
rm configs/dnstt/server.conf configs/dnstt/server.pub
docker run --rm -v moav_moav_state:/state alpine rm -f /state/keys/dnstt-*

# Remove bootstrap flag and re-run
docker run --rm -v moav_moav_state:/state alpine rm /state/.bootstrapped
docker compose --profile setup run --rm bootstrap

# Restart dnstt
docker compose --profile dnstt up -d dnstt
```

---

## Common Commands

### View logs

```bash
# All services
docker compose logs

# Specific service
docker compose logs sing-box
docker compose logs -f sing-box  # Follow

# Last 100 lines
docker compose logs --tail=100 sing-box
```

### Restart services

```bash
# Restart all (specify the profile you're using)
docker compose --profile all restart

# Restart specific service
docker compose --profile proxy restart sing-box

# Full rebuild
docker compose --profile all down
docker compose --profile all up -d --build
```

### Apply .env changes

**Important:** Docker caches environment variables at container creation time. Simply restarting a service does NOT pick up `.env` changes.

```bash
# WRONG - does NOT apply .env changes
docker compose restart snowflake

# CORRECT - recreates container with new .env values
docker compose up -d --force-recreate snowflake

# Or use moav (handles this automatically)
moav stop snowflake && moav start snowflake
```

### Check resource usage

```bash
docker stats
```

### Test connectivity

```bash
# Test from server
curl -I https://google.com

# Test TLS
openssl s_client -connect yourdomain.com:443

# Test specific protocol
# (run from a client that works)
```

### Reload configuration

```bash
# sing-box hot reload
docker compose exec sing-box sing-box reload

# Or restart container
docker compose restart sing-box
```

---

## Getting Help

If issues persist:

1. **Collect logs:**
   ```bash
   docker compose logs > logs.txt
   ```

2. **Check configuration:**
   ```bash
   docker compose exec sing-box sing-box check -c /etc/sing-box/config.json
   ```

3. **Verify network:**
   ```bash
   curl -I https://yourdomain.com
   dig yourdomain.com
   ```

4. **Document:**
   - What protocol you're trying
   - What client app and version
   - Error messages
   - When it started failing
