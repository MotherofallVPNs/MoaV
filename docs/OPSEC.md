# Operational Security Guide

Security recommendations for running and using MoaV safely.

## Table of Contents

- [For Server Operators](#for-server-operators)
  - [Server Security](#server-security)
  - [Firewall & Docker](#firewall--docker)
  - [Admin & Monitoring Access Control](#admin--monitoring-access-control)
  - [Domain Security](#domain-security)
  - [Credential Management](#credential-management)
  - [Monitoring](#monitoring)
  - [Docker Security Hardening](#docker-security-hardening)
  - [If Server is Blocked](#if-server-is-blocked)
- [For Users](#for-users)
  - [Device Security](#device-security)
  - [Connection Security](#connection-security)
  - [App Security](#app-security)
  - [Behavior Security](#behavior-security)
  - [If You Suspect Compromise](#if-you-suspect-compromise)
- [Distribution Security](#distribution-security)
- [Legal Considerations](#legal-considerations)
- [Emergency Procedures](#emergency-procedures)
- [Checklist](#checklist)

---

## For Server Operators

### Server Security

1. **Keep system updated:**
   ```bash
   apt update && apt upgrade -y
   # Enable automatic security updates
   apt install unattended-upgrades
   dpkg-reconfigure unattended-upgrades
   ```

2. **Use SSH keys, disable password auth:**
   ```bash
   # In /etc/ssh/sshd_config:
   PasswordAuthentication no
   PermitRootLogin prohibit-password
   ```

3. **Change SSH port** (optional but recommended):
   ```bash
   # 1. Add firewall rule for new port FIRST
   ufw allow 2222/tcp

   # 2. Then change SSH config
   # In /etc/ssh/sshd_config:
   Port 2222

   # 3. Restart SSH
   systemctl restart sshd

   # 4. Test new port works (from another terminal), then remove old rule
   ufw delete allow 22/tcp
   ```

### Firewall & Docker

> **Important: Docker bypasses UFW/iptables.** Docker publishes ports by inserting iptables rules *before* UFW's chains. This means `ufw deny 9443` does NOT block access to port 9443 if Docker is publishing it. Ports listed in `docker-compose.yml` under `ports:` are publicly accessible regardless of UFW rules.
>
> Ports listed under `expose:` (without `ports:`) are Docker-internal only and NOT affected.
>
> See: [Docker packet filtering docs](https://docs.docker.com/engine/network/packet-filtering-firewalls/)

**Basic UFW setup** (for non-Docker ports like SSH):

```bash
ufw allow 22/tcp      # SSH (IMPORTANT: always allow SSH first!)
ufw enable
```

> **Warning:** UFW rules only effectively control non-Docker services (SSH, system services). For Docker-published ports, use the methods below.

**Protocol ports** (published by Docker — UFW rules are informational only):

| Port | Service | Notes |
|------|---------|-------|
| 443/tcp | Reality (VLESS) | Required |
| 443/udp | Hysteria2 | Required if enabled |
| 8443/tcp | Trojan | Required if enabled |
| 4443/tcp+udp | TrustTunnel | Required if enabled |
| 2082/tcp | CDN WebSocket | Required if enabled |
| 51820/udp | WireGuard | Required if enabled |
| 51821/udp | AmneziaWG | Required if enabled |
| 8080/tcp | wstunnel | Required if enabled |
| 993/tcp | Telegram MTProxy | Required if enabled |
| 2096/tcp | XHTTP | Required if enabled |
| 53/udp | DNS tunnels — dnstt, Slipstream, MasterDNS, XDNS (all 4 via dns-router) | Required if DNS tunnels enabled |
| 8444/tcp | GooseRelay (SOCKS5-over-Google-Apps-Script exit) | Only if `ENABLE_GOOSERELAY=true` |
| 80/tcp | Let's Encrypt | Required during cert renewal |
| 9443/tcp | Admin dashboard | See access control below |
| 9444/tcp | Grafana | See access control below |
| 2083/tcp | Grafana CDN proxy | See access control below |

Protocol ports (Reality, Hysteria2, etc.) are designed to be public — they require authentication. The concern is admin/monitoring ports.

#### Option 1: Use `ADMIN_IP_WHITELIST` (Recommended)

MoaV's admin dashboard has built-in IP whitelisting. Set in `.env`:

```bash
# Allow only your IP (comma-separated for multiple)
ADMIN_IP_WHITELIST=YOUR_HOME_IP,YOUR_OFFICE_IP

# Then restart admin
moav restart admin
```

This blocks all other IPs at the application level, regardless of Docker/UFW.

#### Option 2: Bind to localhost + SSH tunnel

For maximum security, bind admin/monitoring to `127.0.0.1` so they're only accessible via SSH tunnel:

```bash
# In .env — bind to localhost only
PORT_ADMIN=127.0.0.1:9443
PORT_GRAFANA=127.0.0.1:9444
```

Then access via SSH tunnel:
```bash
# From your local machine
ssh -L 9443:127.0.0.1:9443 -L 9444:127.0.0.1:9444 root@YOUR_SERVER
# Then open https://localhost:9443 in your browser
```

#### Option 3: ufw-docker (Advanced)

[ufw-docker](https://github.com/chaifeng/ufw-docker) patches UFW to work with Docker by adding rules to the `DOCKER-USER` iptables chain. This makes `ufw` commands effective for Docker ports.

```bash
# Install
sudo wget -O /usr/local/bin/ufw-docker https://github.com/chaifeng/ufw-docker/raw/master/ufw-docker
sudo chmod +x /usr/local/bin/ufw-docker
sudo ufw-docker install
sudo systemctl restart ufw

# Allow specific ports from any IP
sudo ufw-docker allow moav-sing-box 443/tcp
sudo ufw-docker allow moav-sing-box 443/udp

# Allow admin only from your IP
sudo ufw-docker allow moav-admin 8443/tcp from YOUR_IP
```

> **Trade-offs:** Requires modifying UFW config files (`/etc/ufw/after.rules`). Rules use `ufw route` syntax. Needs reload after container restarts. Works well but adds complexity. For most users, `ADMIN_IP_WHITELIST` is simpler.

### Admin & Monitoring Access Control

**Admin dashboard** (`https://server:9443`):
- Username: `admin`
- Password: set during install (in `.env` as `ADMIN_PASSWORD`)
- Reset: `moav admin password`
- IP whitelist: `ADMIN_IP_WHITELIST` in `.env`

**Grafana** (`https://server:9444`):
- Username: `admin`
- Password: same as `ADMIN_PASSWORD`
- Accessible from any IP by default (password-protected)

**Internal services** (not publicly accessible):
- Prometheus (9091) — `expose:` only, Docker-internal
- All exporters — `expose:` only, Docker-internal
- cAdvisor — `expose:` only, Docker-internal
- Docker socket proxy — `expose:` only, Docker-internal

### Domain Security

1. **Use WHOIS privacy** — hide personal information in domain registration
2. **Use a neutral registrar** — avoid country-specific registrars
3. **Keep registration info generic** — don't use real name if possible
4. **Pay anonymously** — use crypto if available
5. **Separate domain from identity** — don't use a domain linked to your name

### Reality fallback target (`REALITY_TARGET`)

Reality's `REALITY_TARGET` (and `XHTTP_REALITY_TARGET`) is the public TLS site the inbound proxies non-Reality TLS hellos to. Every probe and every misauthenticated client gets that site's real ServerHello back — so an outside observer sees a normal connection to a real CDN, not a closed port.

**The hostname MUST resolve in public DNS and be reachable from your server's network.** If it doesn't, the inbound RSTs every TLS hello — including ones from your own users — and your `:443` looks visibly dead to passive scanners. This is exactly what issue #115 reported (`update.samsung.com` is not a real public hostname; Samsung's update infrastructure uses opaque internal names).

Bootstrap now validates this and `moav doctor reality` re-checks it post-deployment.

**Vetted targets:**

| Audience | Hostname | Why it works |
|---|---|---|
| Global | `www.cloudflare.com:443` | Real TLS 1.3, ECH-capable, anycast, won't go dark |
| Global | `www.apple.com:443` | Corporate, stable, real ECH support |
| Global | `cdn.kernel.org:443` | Linux kernel CDN, real, neutral |
| Iran users | `www.aparat.com:443` | Iranian video CDN — looks like normal domestic traffic to Iran DPI |
| Iran users | `digikala.com:443` | Iran e-commerce, high-volume traffic profile |
| Iran users | `taghche.com:443` | Iranian book platform, plausible browsing target |

**Avoid:**

- `dl.google.com:443` — throttled by Iran DPI; works elsewhere but bad for Iran-bound clients
- Hostnames that *sound* like an update server but aren't real public DNS names (`update.samsung.com`, `swl.samsung.com`, `update.windows.com`, `cdn.tesla.com`) — verify with `getent hosts <host>` first
- Hostnames behind country-specific blocks from your VPS region (some VPS providers throttle major CDNs)
- Anything you wouldn't expect a real browser to talk to on a quiet Tuesday

**If you change `REALITY_TARGET` after bootstrap**, you must re-issue client bundles so the SNI in their config matches:

```bash
docker compose restart sing-box xray
moav regenerate-users
```

### Credential Management

1. **Never share master credentials** — each user gets unique credentials
2. **Revoke compromised users immediately:**
   ```bash
   moav user revoke compromised_user
   ```
3. **Keep dnstt private keys private** — `state/keys/dnstt-server.key.hex` is the persistent dnstt server private key. It should be readable only by the dnstt container user (`100:101`, mode `0600`). If MoaV cannot set that ownership during bootstrap, fix the host permissions and re-run bootstrap rather than making the key world-readable.
4. **Rotate server keys periodically** — re-bootstrap if concerned
5. **Keep backups:**
   ```bash
   moav export    # Creates moav-backup-TIMESTAMP.tar.gz
   ```
6. **Use strong admin password** — at least 16 characters, generated randomly

### Monitoring

1. **Use `moav doctor`** to check for configuration issues:
   ```bash
   moav doctor         # All checks
   moav doctor dns     # DNS only
   moav doctor ports   # Port conflicts
   ```

2. **Check logs regularly:**
   ```bash
   moav logs sing-box    # Proxy logs
   moav logs admin       # Admin dashboard logs
   ```

3. **Inspect connections** to see who's connecting and what they're accessing:
   ```bash
   ./scripts/inspect-connections.sh          # All connections (last 6h)
   ./scripts/inspect-connections.sh IR 24h   # Filter by country
   ./scripts/inspect-connections.sh --csv    # CSV export
   ```

4. **Grafana dashboards** (if monitoring enabled):
   - Per-user traffic and connections
   - GeoIP country distribution
   - Protocol breakdown
   - System health (CPU, RAM, disk)

5. **Watch for unusual patterns:**
   - Sudden traffic spikes from unexpected countries
   - Single IPs with very high error counts (scanning/probing)
   - Connections to suspicious destinations

### Docker Security Hardening

MoaV applies these hardening measures to all containers (since v1.7.2):

- `cap_drop: ALL` — drops all Linux capabilities, adds back only what's needed
- `read_only: true` — read-only root filesystem with targeted `tmpfs` mounts
- `no-new-privileges: true` — prevents privilege escalation
- `mem_limit` and `cpus` — resource limits per container
- Non-root users — containers run as unprivileged `moav` user where possible
- Docker socket proxy — admin uses `tecnativa/docker-socket-proxy` instead of mounting the raw Docker socket

### Network tuning

The installer offers a one-time kernel-level network tuning bundle aimed at the long-RTT / lossy paths that proxy traffic to censored regions actually traverses. Real-world Portugal→Vilnius testing (Time4VPS box, ~400 ms RTT with burst loss) showed BBR roughly 3× single-flow TCP throughput compared to the Linux default (CUBIC 5.45 Mbps → BBR 14.8 Mbps), and dramatically faster recovery from packet loss. Bigger UDP buffers help Hysteria2 and WireGuard even though they don't use BBR — quic-go alone needs ≥7.5 MiB to avoid drops at high throughput.

**What it tunes** (written to a single dedicated file, `/etc/sysctl.d/99-moav-net.conf`, for clean rollback):

| Knob | Value | Why |
|---|---|---|
| `net.ipv4.tcp_congestion_control` | `bbr` | RTT/bandwidth-based, recovers from loss faster than CUBIC |
| `net.core.default_qdisc` | `fq` | Required for BBR's pacing |
| `net.core.{r,w}mem_max` | 32 MiB (16 MiB if RAM < 2 GB) | Headroom for high-BDP TCP + QUIC |
| `net.ipv4.tcp_{r,w}mem` | `4096 / 131072 / max` | TCP buffer auto-tune range |
| `net.core.{r,w}mem_default` | 1 MiB | Default UDP socket buffer (Hysteria2 / WireGuard) |
| `net.core.netdev_max_backlog` | 16384 | Queue depth — UDP drops hurt circumvention more than TCP drops |
| `net.core.somaxconn` | 8192 | Listen backlog for high-concurrency inbounds |
| `net.ipv4.tcp_slow_start_after_idle` | 0 | Avoid restarting at congestion-window 1 on idle long-lived proxies |
| `net.ipv4.tcp_mtu_probing` | 1 | Recover gracefully if a path silently has a smaller MTU |
| `net.ipv4.tcp_notsent_lowat` | 131072 | Smaller send buffers to reduce HOL latency for interactive flows |

**What it deliberately does NOT set:** `net.ipv4.tcp_fastopen`. TFO server-side *adds* latency in heavily-censored networks because middleboxes (notably China Mobile) drop SYN+data on ~5% of paths and the client has to retry. The same reason MoaV v1.8.4 removed `tcp_fast_open: true` from the sing-box Reality and Trojan inbounds.

**Commands:**

```bash
moav net status   # show current vs recommended values
moav net apply    # write 99-moav-net.conf + reload sysctl
moav net revert   # remove the file + reload sysctl (clean rollback)
moav doctor net   # same check that runs in the full doctor sweep
```

**When it skips silently:** kernel <4.9 (no BBR), OpenVZ guests (shared kernel, no sysctl writes), or already-applied installs.

**Compatibility notes:**

- `net.ipv4.tcp_*` sysctls are network-namespaced, so they apply per-container. MoaV's sing-box runs in `network_mode: host` and inherits the host's BBR directly. Bridge-network containers (xray, telemt) use the host's settings as their default and pick up BBR on container restart after `moav net apply`.
- BBR + fq are mainline since kernel 4.9 — Ubuntu 20.04+, Debian 11+, RHEL 9+, every supported modern distro.
- Existing custom sysctl tweaks in `/etc/sysctl.conf` or other `/etc/sysctl.d/*.conf` files are not modified. If a later-numbered file (`99-moav-net.conf` is at 99) overrides something, it wins by sysctl-load order.

### If Server is Blocked

1. **Try different protocols first** — switch from Reality to Hysteria2, XHTTP, or CDN mode
2. **CDN mode** — routes through Cloudflare/CloudFront, works when server IP is blocked
3. **DNS tunnels** — XDNS/dnstt/Slipstream work when most traffic is blocked
4. **If IP is burned:**
   ```bash
   # On old server: export
   moav export

   # On new server: import and update IP
   moav import moav-backup-*.tar.gz
   moav migrate-ip NEW_IP
   moav start
   ```
5. **Donate bandwidth** — even if your server is blocked for your users, it can still serve millions through Psiphon Conduit, Tor Snowflake, and MahsaNet

---

## For Users

### Device Security

1. **Use a separate profile/user** for circumvention apps on shared devices
2. **Don't screenshot QR codes** — or delete immediately after import
3. **Delete bundle files** after importing to your apps
4. **Use device encryption** — enable full disk encryption
5. **Set strong device PIN/password**

### Connection Security

1. **Verify you're connected:**
   - Check your IP: https://whatismyip.com
   - Should show server IP, not your real IP

2. **Use HTTPS everywhere** even over tunnel:
   - The tunnel encrypts transport, HTTPS encrypts content
   - Protects against compromised tunnel endpoints

3. **Don't trust public WiFi** even with VPN:
   - Your device can still be attacked locally
   - Tunnel doesn't protect against local network attacks

### App Security

1. **Keep apps updated** — updates often fix detection bypasses
2. **Download from official sources:**
   - iOS: App Store (Happ, Streisand, Hiddify)
   - Android: GitHub releases (Happ, v2rayNG, Hiddify)
   - Avoid random APK sites

3. **Backup your configs** — export from apps, store securely

### Behavior Security

1. **Don't share your credentials** — each person should have their own
2. **Don't share screenshots** showing server addresses or QR codes
3. **Don't mention specific servers** in public forums
4. **Use secure messaging** to receive configs (Signal, encrypted email)

### If You Suspect Compromise

1. **Stop using that config immediately**
2. **Contact admin** for new credentials
3. **Check your device** for malware
4. **Change passwords** for any accounts accessed over that connection

---

## Distribution Security

### Sharing Bundles Safely

**DO:**
- Use end-to-end encrypted messaging (Signal, Telegram secret chat)
- Share in person when possible (scan QR code directly)
- Use encrypted file sharing (OnionShare)
- Delete messages after recipient confirms receipt

**DON'T:**
- Email unencrypted configs
- Post links in public channels
- Share via unencrypted cloud storage
- Send screenshots of QR codes to groups

### Recommended Distribution Methods

1. **In Person** — safest, scan QR code directly
2. **Signal** — send configs as files, enable disappearing messages
3. **Telegram (Secret Chat only)** — NOT regular chats, use self-destruct timer
4. **Admin Dashboard** — share download links directly (HTTPS, password-protected)

---

## Legal Considerations

**Disclaimer:** This is not legal advice.

- Laws vary by country — running or using circumvention tools may carry legal risks
- Assess your personal risk level
- The decoy website provides plausible deniability (server looks like a normal HTTPS site)

### Data Retention

MoaV is configured for minimal logging:
- No URLs logged
- No request content
- Basic connection stats only (for admin dashboard)
- IP addresses are in memory only (not persisted to disk)

To minimize logging further:
```bash
# In .env
LOG_LEVEL=error
```

---

## Emergency Procedures

### If You Think You're Monitored

1. Stop using current credentials
2. Contact admin through alternate channel
3. Get fresh credentials
4. Consider using a different device
5. Assess whether to continue using service

### If Server is Seized

User data exposure is limited:
- No content is logged
- IP addresses are in memory only
- User identifiers are usernames (not real names)

But assume:
- Server IP is known
- User identifiers are known
- Active connections at time of seizure are known

### If User is Compromised

As admin:
1. Revoke user immediately: `moav user revoke username`
2. Monitor for unusual activity
3. Consider rotating server if credentials were extracted
4. Do NOT contact compromised user through normal channels

---

## Checklist

### Server Operator

- [ ] SSH keys only, no password auth
- [ ] SSH port changed from default 22
- [ ] System auto-updates enabled
- [ ] Admin IP whitelist configured (`ADMIN_IP_WHITELIST`)
- [ ] Strong admin password (16+ characters)
- [ ] Unique user credentials for everyone
- [ ] `moav doctor` passes all checks
- [ ] Backup plan if blocked (new IP or migration ready)
- [ ] Secure distribution channel established
- [ ] Monitoring enabled (Grafana) or logs checked regularly

### User

- [ ] Device encrypted
- [ ] App from official source
- [ ] Config imported securely
- [ ] Bundle files deleted after import
- [ ] Knows which protocol to try if one fails
- [ ] Knows how to contact admin securely
