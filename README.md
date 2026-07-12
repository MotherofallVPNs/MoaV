# MoaV

[![Website](https://img.shields.io/badge/website-moav.sh-cyan.svg)](https://moav.sh)  [![Docs](https://img.shields.io/badge/docs-moav.sh%2Fdocs-cyan.svg)](https://moav.sh/docs/)  [![Version](https://img.shields.io/badge/version-1.9.0-blue.svg)](CHANGELOG.md)  [![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

English | **[فارسی](README-fa.md)** 

Multi-protocol Internet censorship circumvention stack optimized for hostile network environments.

## Features

- **Multiple protocols** — 16+ protocols covering every censorship scenario:
  - **High-stealth proxy** — Reality (VLESS), Trojan, Hysteria2, XHTTP (VLESS+XHTTP+Reality), CDN (VLESS+WS via Cloudflare)
  - **Full VPN** — WireGuard (direct & wstunnel), AmneziaWG
  - **Specialty** — TrustTunnel (HTTP/2+QUIC), Telegram MTProxy (fake-TLS), Shadowsocks-2022, GooseRelay (SOCKS5 via Google Apps Script)
  - **DNS tunnels** — dnstt, Slipstream, MasterDNS, and XDNS — all four run simultaneously on port 53 via `dns-router`
- **Stealth-first** - All traffic looks like normal HTTPS, WebSocket, DNS, or IMAPS
- **Per-user credentials** - Create, revoke, and manage users independently
- **Easy deployment** - Docker Compose based, single command setup
- **Mobile-friendly** - QR codes and links for easy client import
- **Decoy website** - Serves innocent content to unauthenticated visitors
- **Home server ready** - Run on Raspberry Pi or any ARM64/x64 Linux as a personal VPN
- **[Psiphon Conduit](https://github.com/Psiphon-Inc/conduit)** - Optional bandwidth donation to help others bypass censorship
- **[Tor Snowflake](https://snowflake.torproject.org/)** - Optional bandwidth donation to help Tor users bypass censorship
- **[MahsaNet](https://www.mahsaserver.com/)** - Donate VPN configs to help Mahsa VPN users (2M+ users in Iran)
- **Monitoring** - Optional Grafana + Prometheus observability stack

> **[Read the full documentation](https://moav.sh/docs/)** — setup guides, CLI reference, client apps, monitoring, OPSEC, and more.

## Quick Start

**One-liner install** (recommended):

```bash
curl -fsSL moav.sh/install.sh | bash
```

This will:
- Install prerequisites (Docker, git, qrencode) if missing
- Clone MoaV to `/opt/moav`
- Prompt for domain, email, and admin password
- Offer to install `moav` command globally
- Launch the interactive setup

**Manual install** (alternative):

```bash
git clone https://github.com/shayanb/MoaV.git
cd MoaV
cp .env.example .env
nano .env  # Set DOMAIN, ACME_EMAIL, ADMIN_PASSWORD
./moav.sh
```

<!-- TODO: Screenshot of moav.sh interactive menu terminal -->
<img src="docs/assets/moav.sh.png" alt="MoaV Interactive Menu" width="350">

**After installation, use `moav` from anywhere:**

```bash
moav                      # Interactive menu
moav start                # Start services
moav status               # Show service status
moav user add alice       # Add user (generates configs + QR codes)
moav user add --batch 10  # Batch create users
moav donate               # Donate configs to MahsaNet/Psiphon/Snowflake
moav doctor               # Run diagnostics (DNS, ports, services)
moav update               # Update MoaV
moav admin password       # Reset admin/Grafana password
moav help                 # Show all commands
```

See the [Setup Guide](docs/SETUP.md) for complete instructions, the [CLI Reference](docs/CLI.md) for all commands, or browse the [full documentation](https://moav.sh/docs/).

### Deploy Your Own

[![Deploy on Hetzner](https://img.shields.io/badge/Deploy%20on-Hetzner-d50c2d?style=for-the-badge&logo=hetzner&logoColor=white)](docs/DEPLOY.md#hetzner)  [![Deploy on Linode](https://img.shields.io/badge/Deploy%20on-Linode-00a95c?style=for-the-badge&logo=linode&logoColor=white)](docs/DEPLOY.md#linode)  [![Deploy on Vultr](https://img.shields.io/badge/Deploy%20on-Vultr-007bfc?style=for-the-badge&logo=vultr&logoColor=white)](docs/DEPLOY.md#vultr)  [![Deploy on DigitalOcean](https://img.shields.io/badge/Deploy%20on-DigitalOcean-0080ff?style=for-the-badge&logo=digitalocean&logoColor=white)](docs/DEPLOY.md#digitalocean)



## Architecture

```
                                                              ┌───────────────┐  ┌───────────────┐
       ┌───────────────┐                                      │ Psiphon Users │  │   Tor Users   │
       │  Your Clients │                                      │  (worldwide)  │  │  (worldwide)  │
       │   (private)   │                                      └───────┬───────┘  └───────┬───────┘
       └───────┬───────┘                                              │                  │
               │                                                      │                  │
               ├─────────────────┐                                    │                  │
               │                 │ (when IP blocked)                  │                  │
               │          ┌──────┴───────┐                            │                  │
               │          │ Cloudflare   │                            │                  │
               │          │  CDN (VLESS) │                            │                  │
               │          └──────┬───────┘                            │                  │
               │                 │                                    │                  │
┌──────────────╪─────────────────╪────────────────────────────────────╪──────────────────╪─────────┐
│              │                 │          Restricted Internet       │                  │         │
└──────────────╪─────────────────╪────────────────────────────────────╪──────────────────╪─────────┘
               │                 │                                    │                  │
╔══════════════╪═════════════════╪════════════════════════════════════╪══════════════════╪═════════╗
║              │                 │                                    │                  │         ║
║     ┌────────┼─────────────────┼───────┼──────┐                     │                  │         ║
║     │        │         │       │       │      │                     │                  │         ║
║     ▼        ▼         ▼       ▼       ▼      ▼                     ▼                  ▼         ║
║ ┌─────────┐┌─────────┐┌───────┐┌─────────┐┌────────┐          ┌───────────┐      ┌───────────┐   ║
║ │ Reality ││WireGuard││ Trust ││  DNS    ││Telegram│          │           │      │           │   ║
║ │ 443/tcp ││51820/udp││Tunnel ││ 53/udp  ││MTProxy │          │  Conduit  │      │ Snowflake │   ║
║ │ Trojan  ││AmneziaWG││4443/  │├─────────┤│993/tcp │          │  (donate  │      │  (donate  │   ║
║ │8443/tcp ││51821/udp││tcp+udp││  dnstt  │└───┬────┘          │ bandwidth)│      │ bandwidth)│   ║
║ │Hysteria2││wstunnel ││       ││Slipstrm │    │               └─────┬─────┘      └─────┬─────┘   ║
║ │ 443/udp ││8080/tcp ││       │└────┬────┘    │                     │                  │         ║
║ │ CDN WS  │└────┬────┘└───┬───┘     │         │                     │                  │         ║
║ │2082/tcp │     │         │         │         │  ┌────────────────┐ │                  │     M   ║
║ ├─────────┤     │         │         │         │  │ Grafana  :9444 │ │                  │     O   ║
║ │ sing-box│     │         │         │         │  │ Prometheus     │ │                  │     A   ║
║ └────┬────┘     │         │         │         │  └────────────────┘ │                  │     V   ║
║      │          │         │         │         │                     │                  │         ║
╚══════╪══════════╪═════════╪═════════╪═════════╪═════════════════════╪══════════════════╪═════════╝
       │          │         │         │         │                     │                  │
       ▼          ▼         ▼         ▼         ▼                     ▼                  ▼
┌─────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                        Open Internet                                            │
└─────────────────────────────────────────────────────────────────────────────────────────────────┘
```

## Protocols

| Protocol | Port | Stealth | Speed | Default | Use Case |
|----------|------|---------|-------|---------|----------|
| Reality (VLESS) | 443/tcp | ★★★★★ | ★★★★☆ | ✅ | Primary, most reliable |
| Hysteria2 | 443/udp | ★★★★☆ | ★★★★★ | ✅ | Fast, works when TCP throttled |
| Trojan | 8443/tcp | ★★★★☆ | ★★★★☆ | ✅ | Backup, uses your domain |
| AnyTLS | 8445/tcp | ★★★★★ | ★★★★☆ | ⬜ | Defeats TLS-in-TLS fingerprinting, uses your domain |
| Shadowsocks-2022 | 8388/tcp+udp | ★★★★☆ | ★★★★☆ | ⬜ | AEAD-2022 anti-probing; Outline-app compatible |
| CDN (VLESS+WS) | 443 via Cloudflare | ★★★★★ | ★★★☆☆ | ✅ | When server IP is blocked |
| TrustTunnel | 4443/tcp+udp | ★★★★★ | ★★★★☆ | ✅ | HTTP/2 & QUIC, looks like HTTPS |
| WireGuard (Direct) | 51820/udp | ★★★☆☆ | ★★★★★ | ✅ | Full VPN, simple setup |
| AmneziaWG | 51821/udp | ★★★★★ | ★★★★☆ | ✅ | Obfuscated WireGuard, defeats DPI |
| WireGuard (wstunnel) | 8080/tcp | ★★★★☆ | ★★★★☆ | ✅ | VPN when UDP is blocked |
| DNS Tunnel (dnstt) | 53/udp | ★★★☆☆ | ★☆☆☆☆ | ✅ | Last resort, hard to block |
| Slipstream | 53/udp | ★★★☆☆ | ★★☆☆☆ | ✅ | QUIC-over-DNS, 1.5-5x faster than dnstt |
| MasterDNS | 53/udp | ★★★☆☆ | ★★★☆☆ | ✅ | Advanced DNS tunnel (ARQ + resolver LB), MahsaNG v16 |
| XDNS (VLESS+mKCP+DNS) | 53/udp | ★★★☆☆ | ★☆☆☆☆ | ✅ | DNS tunnel via Xray FinalMask; all 4 DNS tunnels share port 53 |
| GooseRelay | 8444/tcp | ★★★★★ | ★★☆☆☆ | ⬜ | SOCKS5 via Google Apps Script, fronted as google.com, MahsaNG v16 |
| Telegram MTProxy | 993/tcp | ★★★★☆ | ★★★☆☆ | ✅ | Fake-TLS V2, direct Telegram access |
| XHTTP (VLESS+XHTTP+Reality) | 2096/tcp | ★★★★★ | ★★★★☆ | ✅ | Xray-core, no domain needed |
| Psiphon Conduit | — | — | — | ⬜ | Donate bandwidth to Psiphon (2M+ users) |
| Tor Snowflake | — | — | — | ⬜ | Donate bandwidth to Tor network |
| MahsaNet | — | — | — | ⬜ | Donate VPN configs to Mahsa VPN (2M+ users) |

## User Management

```bash
moav user list            # List all users
moav user add joe         # Add user to all protocols
moav user add alice bob   # Add multiple users
moav user add --batch 10 --prefix team  # Batch create team01..team10
moav user revoke joe      # Revoke user
moav user package joe     # Create zip bundle
```

Each user gets a bundle in `outputs/bundles/<username>/` with config files, QR codes, and a README.html guide.

**MahsaNG / V2Ray users (MahsaNG has 2M+ in Iran):** every bundle includes a standard base64 **V2Ray subscription** — in `subscription.txt` and as a click-to-copy block at the top of the bundle's README — so users paste it once into [MahsaNG](https://github.com/GFW-knocker/MahsaNG), v2rayNG, Hiddify, or any V2Ray app to import all proxy protocols at once. See [docs/mahsanet.md](docs/mahsanet.md).

**Download bundles** from the admin dashboard at `https://your-server:9443` or via SCP.

## Admin Dashboard & Monitoring

- **Admin dashboard**: `https://your-server:9443` — user management, service status, MahsaNet donations
- **Grafana**: `https://your-server:9444` — per-user traffic, protocol breakdown, GeoIP distribution
- **Username**: `admin` | **Password**: set during install (stored in `.env` as `ADMIN_PASSWORD`)
- **Reset password**: `moav admin password`

## Service Management

```bash
moav status               # Show all service status
moav start                # Start services
moav start proxy admin    # Start specific profiles
moav stop                 # Stop all services
moav restart sing-box     # Restart specific service
moav logs sing-box        # View service logs
moav doctor               # Run diagnostics
moav doctor dns           # Check DNS configuration
moav donate               # Donate configs to MahsaNet/Psiphon/Snowflake
moav conduit link         # Psiphon Conduit claim link, QR & sharing guide
```

**Psiphon Conduit:** once `conduit` is running it already serves Psiphon users (including in Iran) through the public pool — no link to share. To give specific people a private path, `moav conduit link` prints the Ryve claim link/QR and the Personal Pairing steps. The claim link embeds the private key — keep it secret; share with users only via Personal Pairing inside Ryve. See [Psiphon Conduit in docs/protocols.md](docs/protocols.md#psiphon-conduit).

**Profiles:** `proxy`, `wireguard`, `amneziawg`, `dnstunnel`, `trusttunnel`, `telegram`, `xhttp`, `admin`, `conduit`, `snowflake`, `monitoring`, `all`

## Server Migration

Export and migrate your MoaV installation to a new server:

```bash
# Export full backup (keys, users, configs)
moav export                        # Creates moav-backup-TIMESTAMP.tar.gz

# On new server: import and update IP
moav import moav-backup-*.tar.gz   # Restore configuration
moav migrate-ip 1.2.3.4            # Update all configs to new IP
moav start                         # Start services
```

See [docs/SETUP.md](docs/SETUP.md#server-migration) for detailed migration workflow.

## Testing

```bash
moav test user1           # Test all protocols for a user
moav test user1 -v        # Verbose output for debugging
moav client connect user1 # Connect as user (exposes local SOCKS5/HTTP proxy)
```

## Client Apps

| Platform | Recommended Apps |
|----------|------------------|
| iOS | Happ, Streisand, Hiddify, WireGuard, Shadowrocket |
| Android | Happ, v2rayNG, Hiddify, WireGuard, NekoBox |
| macOS | Happ, Hiddify, Streisand, WireGuard |
| Windows | Happ, v2rayN, Hiddify, WireGuard |
| Linux | Hiddify, sing-box, WireGuard |

See [docs/CLIENTS.md](docs/CLIENTS.md) for complete list and setup instructions.

## Documentation

- [Setup Guide](docs/SETUP.md) - Complete installation instructions
- [CLI Reference](docs/CLI.md) - All moav commands and options
- [DNS Configuration](docs/DNS.md) - DNS records setup
- [Client Setup](docs/CLIENTS.md) - How to connect from devices
- [MahsaNG Import](docs/mahsanet.md) - Import MoaV configs into the MahsaNG app (Iran)
- [VPS Deployment](docs/DEPLOY.md) - One-click cloud deployment
- [Monitoring](docs/MONITORING.md) - Grafana + Prometheus observability
- [Troubleshooting](docs/TROUBLESHOOTING.md) - Common issues and solutions
- [OpSec Guide](docs/OPSEC.md) - Security best practices

## Requirements

**Server:**
- Debian 12, Ubuntu 22.04/24.04
- 1 vCPU, 1 GB RAM minimum (2 vCPU, 2 GB RAM if using monitoring)
- Public IPv4
- Domain name (optional - see Domain-less Mode below)

**Ports (open as needed):**
| Port | Protocol | Service | Requires Domain |
|------|----------|---------|-----------------|
| 443/tcp | TCP | Reality (VLESS) | Yes |
| 443/udp | UDP | Hysteria2 | Yes |
| 8443/tcp | TCP | Trojan | Yes |
| 8445/tcp | TCP | AnyTLS | Yes |
| 8388/tcp+udp | TCP+UDP | Shadowsocks-2022 | No |
| 4443/tcp+udp | TCP+UDP | TrustTunnel | Yes |
| 2082/tcp | TCP | CDN WebSocket | Yes (Cloudflare) |
| 51820/udp | UDP | WireGuard | No |
| 51821/udp | UDP | AmneziaWG | No |
| 8080/tcp | TCP | wstunnel | No |
| 993/tcp | TCP | Telegram MTProxy | No |
| 2096/tcp | TCP | XHTTP (VLESS+XHTTP+Reality) | No |
| 8444/tcp | TCP | GooseRelay exit (when `ENABLE_GOOSERELAY=true`) | No |
| 9443/tcp | TCP | Admin dashboard | No |
| 9444/tcp | TCP | Grafana (monitoring) | No |
| 53/udp | UDP | DNS tunnels (dnstt / Slipstream / MasterDNS / XDNS — all share this port) | Yes |
| 80/tcp | TCP | Let's Encrypt | Yes (during setup) |

### Domainless Mode

Don't have a domain? MoaV can run in **domainless mode** with:
- **Reality** (VLESS+Reality, primary protocol)
- **XHTTP** (VLESS+XHTTP+Reality via Xray-core)
- **WireGuard** (direct UDP + WebSocket tunnel)
- **AmneziaWG** (obfuscated WireGuard, defeats DPI)
- **Telegram MTProxy** (fake-TLS, direct Telegram access)
- **GooseRelay** (SOCKS5 over Google Apps Script — no domain needed)
- **Admin dashboard** (uses self-signed certificate)
- **Conduit** (Psiphon bandwidth donation)
- **Snowflake** (Tor bandwidth donation)

Run `moav` and select "No domain" when prompted, or use `moav domainless` to configure.

**Recommended VPS:**
- VPS Price Trackers: [VPS-PRICES](https://vps-prices.com/)، [VPS Price Tracker](https://vpspricetracker.com/), [Cheap VPS Price Cheat Sheet](https://docs.google.com/spreadsheets/d/e/2PACX-1vTOC_THbM2RZzfRUhFCNp3SDXKdYDkfmccis4vxr7WtVIcPmXM-2lGKuZTBr8o_MIJ4XgIUYz1BmcqM/pubhtml)
- [Time4VPS](https://www.time4vps.com/?affid=8471): 1 vCPU، 1GB RAM، IPv4، 3.99€/Month


## Project Structure

```
MoaV/
├── moav.sh                 # CLI management tool (install with: ./moav.sh install)
├── docker-compose.yml      # Main compose file
├── .env.example            # Environment template
├── Dockerfile.*            # Container definitions
├── configs/                # Service configurations
│   ├── sing-box/
│   ├── wireguard/
│   ├── amneziawg/
│   ├── trusttunnel/
│   ├── dnstt/
│   ├── masterdns/
│   ├── gooserelay/
│   ├── telemt/
│   └── monitoring/
├── scripts/                # Management scripts
│   ├── bootstrap.sh
│   ├── user-add.sh
│   ├── user-revoke.sh
│   └── lib/
├── outputs/                # Generated configs (gitignored)
│   └── bundles/
├── web/                    # Decoy website
├── admin/                  # Stats dashboard
└── docs/                   # Documentation
```

## Security

- All protocols require authentication
- Decoy website for unauthenticated traffic
- Per-user credentials with instant revocation
- Minimal logging (no URLs, no content)
- TLS 1.3 everywhere

See [docs/OPSEC.md](docs/OPSEC.md) for security guidelines.

## License

MIT

## Changelog
See [CHANGELOG.md](CHANGELOG.md) for release notes and version history.


## Disclaimer

This project provides **general-purpose open-source networking software** only.

It is not a service, not a platform, and not an operated network.

The authors and contributors:
- Do not operate infrastructure
- Do not provide access
- Do not distribute credentials
- Do not manage users
- Do not coordinate deployments

All usage, deployment, and operation are the sole responsibility of third parties.

This software is provided **“AS IS”**, without warranty of any kind.  
The authors and contributors accept **no liability** for any use or misuse of this software.

Users are responsible for complying with all applicable laws and regulations.