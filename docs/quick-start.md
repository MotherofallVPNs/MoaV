# Quick Start

Get MoaV running on a VPS in 5 steps. MoaV deploys [16+ anti-censorship protocols](protocols.md) and generates client bundles that make it easy for anyone to connect — no technical knowledge needed. For the full story, see [why MoaV exists](philosophy.md). For detailed setup options, see the full [Setup Guide](SETUP.md).

## Requirements

- A VPS with Debian 12 or Ubuntu 22.04/24.04 (1 vCPU, 1GB RAM minimum)
- A domain name (optional — see [Domainless Mode](SETUP.md#domainless-mode))

!!! tip "Need a VPS?"
    See [VPS Deployment](DEPLOY.md) for one-click deploy options starting at ~$5/month.

## Step 1: Install

SSH into your server and run:

```bash
curl -fsSL moav.sh/install.sh | bash
```

This installs Docker, clones MoaV, and launches the interactive setup.

## Step 2: Configure

The installer prompts you for:

- **Domain** — Your domain pointed at this server (or leave empty for domainless mode)
- **Email** — For Let's Encrypt TLS certificates (required if using a domain)
- **Admin password** — For the web dashboard

!!! warning "DNS first"
    If using a domain, point your DNS **before** running setup. The installer needs to verify domain ownership. See [DNS Configuration](DNS.md).

## Step 3: Start Services

```bash
moav start
```

Choose which profiles to run:

| Profile | Protocols |
|---------|-----------|
| `proxy` | Reality, Trojan, Hysteria2, CDN |
| `wireguard` | WireGuard + wstunnel |
| `amneziawg` | AmneziaWG (obfuscated WireGuard) |
| `trusttunnel` | TrustTunnel |
| `telegram` | Telegram MTProxy |
| `dnstunnel` | dnstt + Slipstream |
| `admin` | Web dashboard |
| `conduit` | Psiphon bandwidth donation |
| `snowflake` | Tor bandwidth donation |
| `monitoring` | Grafana + Prometheus |
| `all` | Everything |

```bash
moav start proxy admin wireguard   # Start specific profiles
moav start all                     # Start everything
```

## Step 4: Open Firewall

Open the ports for your enabled protocols:

```bash
# Core protocols
ufw allow 443/tcp     # Reality
ufw allow 443/udp     # Hysteria2
ufw allow 8443/tcp    # Trojan
ufw allow 51820/udp   # WireGuard
ufw allow 51821/udp   # AmneziaWG
ufw allow 8080/tcp    # wstunnel
ufw allow 4443/tcp    # TrustTunnel
ufw allow 4443/udp    # TrustTunnel (QUIC)
ufw allow 993/tcp     # Telegram MTProxy
ufw allow 9443/tcp    # Admin dashboard
```

## Step 5: Share with Users

MoaV automatically generates a **client bundle** for each user in `outputs/bundles/`. Bundles are designed for non-technical users — they contain everything needed to connect without any manual configuration:

- `README.html` — Step-by-step instructions (English + Farsi) with QR codes. Users open this in their browser, pick their platform, scan a QR code, and they're connected.
- Config files for every enabled protocol (Reality, Trojan, Hysteria2, WireGuard, etc.)
- QR codes for one-tap mobile import
- Share links compatible with popular VPN apps

**Download bundles:**

- **Web dashboard** — Open `https://your-server:9443`, login, and click Download
- **SCP** — `scp root@SERVER:/opt/moav/outputs/bundles/user01.zip ./`
- **Package** — `moav user package user01` creates a zip

**Add more users:**

```bash
moav user add alice           # Add single user
moav user add --batch 10      # Batch create user01..user10
```

Send users the bundle (or just `README.html`). They don't need to understand protocols — the instructions guide them through installing an app and scanning a QR code. See [Client Apps](CLIENTS.md) for platform-specific details.

!!! tip "Secure distribution"
    Share bundles via Signal, encrypted email, or in person. Avoid unencrypted channels.

## Next Steps

- [Client Apps](CLIENTS.md) — Platform-specific connection instructions
- [CLI Reference](CLI.md) — All `moav` commands
- [CDN Mode](SETUP.md#cdn-fronted-mode-cloudflare) — Route through Cloudflare when your IP is blocked
- [Monitoring](MONITORING.md) — Add Grafana dashboards
- [Troubleshooting](TROUBLESHOOTING.md) — Common issues and fixes
