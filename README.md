<div align="center">

<img src="branding/logo.png" alt="MoaV logo" width="130">

# Mother of all VPNs

**Multi-protocol Internet censorship circumvention stack, optimized for hostile network environments.**

[![Website](https://img.shields.io/badge/website-moav.sh-06b6d4.svg)](https://moav.sh) [![Docs](https://img.shields.io/badge/docs-moav.sh%2Fdocs-2563eb.svg)](https://moav.sh/docs/) [![Release](https://img.shields.io/github/v/release/MotherofallVPNs/MoaV?label=release&color=16a34a&logo=github&logoColor=white)](https://github.com/MotherofallVPNs/MoaV/releases/latest) [![Pre-release](https://img.shields.io/github/v/release/MotherofallVPNs/MoaV?include_prereleases&label=pre-release&color=f59e0b&logo=github&logoColor=white)](https://github.com/MotherofallVPNs/MoaV/releases)

[![Protocols](https://img.shields.io/badge/protocols-16%2B-ef4444.svg)](#protocols) [![moav-client](https://img.shields.io/badge/client-moav--client-06b6d4.svg?logo=github&logoColor=white)](https://github.com/MotherofallVPNs/moav-client) [![AI agents](https://img.shields.io/badge/AI_agents-AGENTS.md-8b5cf6.svg)](AGENTS.md) [![Telegram](https://img.shields.io/badge/Telegram-motherofallvpns-2CA5E0.svg?logo=telegram)](https://t.me/motherofallvpns) [![X](https://img.shields.io/badge/X-@motherofallvpns-000000.svg?logo=x)](https://x.com/motherofallvpns)

[![License: MIT](https://img.shields.io/badge/license-MIT-22c55e.svg)](LICENSE) [![Stars](https://img.shields.io/github/stars/MotherofallVPNs/MoaV?style=social)](https://github.com/MotherofallVPNs/MoaV/stargazers) [![Forks](https://img.shields.io/github/forks/MotherofallVPNs/MoaV?style=social)](https://github.com/MotherofallVPNs/MoaV/network/members) [![Last commit](https://img.shields.io/github/last-commit/MotherofallVPNs/MoaV/dev?label=last%20commit&color=64748b)](https://github.com/MotherofallVPNs/MoaV/commits/dev)

🇬🇧 [English](README.md) &nbsp;·&nbsp; 🇮🇷 [فارسی](README-fa.md)

Built and maintained by the **[MoaV](https://github.com/MotherofallVPNs)** community.

</div>

---

## Why MoaV exists

No single transport survives every censor. A protocol that works this morning can be
fingerprinted by the afternoon, and the person depending on it has no way to know in
advance which one will hold.

So MoaV ships many at once, from the same server and the same user bundle. When one
path stops working the user switches to another instead of waiting for someone to
re-deploy. That is the whole idea; everything else here is in service of it.

Read the [Mission](https://moav.sh/docs/mission), the [Threat Model](https://moav.sh/docs/threat-model)
for what MoaV does and does not protect, and the [Philosophy](https://moav.sh/docs/philosophy)
for the longer argument.

---

## Table of Contents

**Links** &nbsp;·&nbsp; [Website](https://moav.sh) &nbsp;·&nbsp; [Docs](https://moav.sh/docs/) &nbsp;·&nbsp; [Telegram](https://t.me/motherofallvpns) &nbsp;·&nbsp; [moav-client](https://github.com/MotherofallVPNs/moav-client)

**Get started** &nbsp;·&nbsp; [Why MoaV exists](#why-moav-exists) &nbsp;·&nbsp; [Features](#features) &nbsp;·&nbsp; [Quick Start](#quick-start) &nbsp;·&nbsp; [Requirements](#requirements) &nbsp;·&nbsp; [Running without a domain](#running-without-a-domain)

**Use it** &nbsp;·&nbsp; [Using MoaV](#using-moav) &nbsp;·&nbsp; [Client Apps](#client-apps) &nbsp;·&nbsp; [Documentation](#documentation)

**Under the hood** &nbsp;·&nbsp; [Architecture](#architecture) &nbsp;·&nbsp; [Protocols](#protocols) &nbsp;·&nbsp; [Project Structure](#project-structure) &nbsp;·&nbsp; [Security](#security)

**Help out** &nbsp;·&nbsp; [Support the project](#support-the-project) &nbsp;·&nbsp; [Community](#community) &nbsp;·&nbsp; [Related projects](#related-projects)

**More** &nbsp;·&nbsp; [License](#license) &nbsp;·&nbsp; [Changelog](#changelog) &nbsp;·&nbsp; [Disclaimer](#disclaimer)

---

![How it works](https://github.com/user-attachments/assets/60e1726f-2733-4d49-9fa2-30be8c2dbeb5)

---

## Features

- **Multiple protocols** — 16+ circumvention transports and fallback paths, plus optional Psiphon, Tor and MahsaNet donation integrations:
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
git clone https://github.com/MotherofallVPNs/moav.git
cd moav
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

See the [Setup Guide](https://moav.sh/docs/SETUP) for complete instructions, the [CLI Reference](https://moav.sh/docs/CLI) for all commands, or browse the [full documentation](https://moav.sh/docs/).

### Deploy Your Own

[![Deploy on Hetzner](https://img.shields.io/badge/Deploy%20on-Hetzner-d50c2d?style=for-the-badge&logo=hetzner&logoColor=white)](https://moav.sh/docs/DEPLOY#hetzner)  [![Deploy on Linode](https://img.shields.io/badge/Deploy%20on-Linode-00a95c?style=for-the-badge&logo=linode&logoColor=white)](https://moav.sh/docs/DEPLOY#linode)  [![Deploy on Vultr](https://img.shields.io/badge/Deploy%20on-Vultr-007bfc?style=for-the-badge&logo=vultr&logoColor=white)](https://moav.sh/docs/DEPLOY#vultr)  [![Deploy on DigitalOcean](https://img.shields.io/badge/Deploy%20on-DigitalOcean-0080ff?style=for-the-badge&logo=digitalocean&logoColor=white)](https://moav.sh/docs/DEPLOY#digitalocean)



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
| Reality (VLESS) | 443/tcp | ★★★★★ | ★★★★☆ | ✅ | Primary; a strong first choice where it works |
| Hysteria2 | 443/udp | ★★★★☆ | ★★★★★ | ✅ | Fast, works when TCP throttled |
| Trojan | 8443/tcp | ★★★★☆ | ★★★★☆ | ✅ | Backup, uses your domain |
| AnyTLS | 8445/tcp | ★★★★★ | ★★★★☆ | ⬜ | Defeats TLS-in-TLS fingerprinting, uses your domain |
| Shadowsocks-2022 | 8388/tcp+udp | ★★★★☆ | ★★★★☆ | ✅ | AEAD-2022 anti-probing; Outline-app compatible |
| CDN (VLESS+WS) | 443 via Cloudflare | ★★★★★ | ★★★☆☆ | ⬜ | When server IP is blocked; needs Cloudflare fronting first |
| TrustTunnel | 4443/tcp+udp | ★★★★★ | ★★★★☆ | ✅ | HTTP/2 & QUIC, looks like HTTPS |
| WireGuard (Direct) | 51820/udp | ★★★☆☆ | ★★★★★ | ✅ | Full VPN, simple setup |
| AmneziaWG | 51821/udp | ★★★★★ | ★★★★☆ | ✅ | Obfuscated WireGuard, resists common DPI signatures |
| WireGuard (wstunnel) | 8080/tcp | ★★★★☆ | ★★★★☆ | ✅ | VPN when UDP is blocked |
| DNS Tunnel (dnstt) | 53/udp | ★★★☆☆ | ★☆☆☆☆ | ✅ | Last resort, hard to block |
| Slipstream | 53/udp | ★★★☆☆ | ★★☆☆☆ | ✅ | QUIC-over-DNS, 1.5-5x faster than dnstt |
| MasterDNS | 53/udp | ★★★☆☆ | ★★★☆☆ | ✅ | Advanced DNS tunnel (ARQ + resolver LB), MahsaNG v16 |
| XDNS (VLESS+mKCP+DNS) | 53/udp | ★★★☆☆ | ★☆☆☆☆ | ✅ | DNS tunnel via Xray FinalMask; all 4 DNS tunnels share port 53 |
| GooseRelay | 8444/tcp | ★★★★★ | ★★☆☆☆ | ⬜ | SOCKS5 via Google Apps Script, fronted as google.com, MahsaNG v16 |
| Telegram MTProxy | 993/tcp | ★★★★☆ | ★★★☆☆ | ✅ | Fake-TLS V2, direct Telegram access |
| XHTTP (VLESS+XHTTP+Reality) | 2096/tcp | ★★★★★ | ★★★★☆ | ✅ | Xray-core, no domain needed |
| Psiphon Conduit | — | — | — | ✅ | Donate bandwidth to Psiphon (2M+ users) |
| Tor Snowflake | — | — | — | ✅ | Donate bandwidth to Tor network |
| MahsaNet | — | — | — | ⬜ | Donate VPN configs to Mahsa VPN (2M+ users) |

**Default** = enabled in `.env.example`. Services still only run under their
profile, so `moav start conduit` is what actually starts Conduit. MahsaNet is an
action (`moav donate`), not a service.

## Using MoaV

```bash
moav                          # interactive menu over everything below
moav status                   # what's running, which profiles, health at a glance
moav doctor                   # diagnose DNS, ports, certificates, resources
moav logs sing-box            # tail a service

moav user add alice --package # create a user and build their .zip bundle
moav user add --batch 10      # ten at once
moav user list                # who exists
moav user revoke alice        # revoke immediately
moav test alice               # prove alice's configs actually pass traffic

moav start proxy admin        # start specific profiles
moav restart sing-box         # apply an .env change to one service
moav donate                   # donate configs/bandwidth (MahsaNet, Psiphon, Snowflake)
```

Each user gets `outputs/bundles/<username>/` with config files, QR codes and a
`README.html` guide, plus a base64 **V2Ray subscription** in `subscription.txt` that
imports every proxy protocol at once into [MahsaNG](https://github.com/GFW-knocker/MahsaNG),
v2rayNG or Hiddify. See the [MahsaNG import guide](https://moav.sh/docs/mahsanet).

To verify a bundle from a client's point of view, [**moav-client**](https://github.com/MotherofallVPNs/moav-client) ingests the subscription, probes every endpoint through its own tunnel and routes through whichever is live and fastest.

**Dashboards** — password for both is set during install (`ADMIN_PASSWORD` in `.env`),
reset with `moav admin password`:

| | URL | Login |
|---|---|---|
| **Admin dashboard** | `https://your-server:9443` | any username — only the password is checked |
| **Grafana** | `https://your-server:9444` | user `admin` |

**Profiles:** `proxy`, `wireguard`, `amneziawg`, `dnstunnel`, `trusttunnel`, `telegram`, `xhttp`, `admin`, `conduit`, `snowflake`, `gooserelay`, `monitoring`, `all`

**Moving to a new server:** `moav export`, then on the new host `moav import moav-backup-*.tar.gz`
and `moav migrate-ip <new-ip>`. Walkthrough in the [Setup Guide](https://moav.sh/docs/SETUP#server-migration).

**Psiphon Conduit:** once `conduit` is running it already serves Psiphon users through the
public pool — nothing to share. `moav conduit link` prints a private claim link/QR for
specific people; it embeds the private key, so share it only via Personal Pairing inside
Ryve. See [Psiphon Conduit](https://moav.sh/docs/protocols#psiphon-conduit).

Every command, flag and environment variable: **[CLI Reference](https://moav.sh/docs/CLI)**.

## Client Apps

| Platform | Recommended Apps |
|----------|------------------|
| iOS | Happ, Streisand, Hiddify, WireGuard, Shadowrocket |
| Android | Happ, v2rayNG, Hiddify, WireGuard, NekoBox |
| macOS | Happ, Hiddify, Streisand, WireGuard |
| Windows | Happ, v2rayN, Hiddify, WireGuard |
| Linux | Hiddify, sing-box, WireGuard |

See the [Client Setup guide](https://moav.sh/docs/CLIENTS) for the complete list and setup instructions, or [**moav-client**](https://github.com/MotherofallVPNs/moav-client) ([docs](https://moav.sh/docs/client)) for a desktop/CLI client with automatic failover.

## Documentation

Full docs: **[moav.sh/docs](https://moav.sh/docs/)**

**Deploy** — [Quick Start](https://moav.sh/docs/quick-start) · [Setup Guide](https://moav.sh/docs/SETUP) · [VPS Deployment](https://moav.sh/docs/DEPLOY) · [DNS Configuration](https://moav.sh/docs/DNS)

**Understand** — [Supported Protocols](https://moav.sh/docs/protocols) · [Architecture](https://moav.sh/docs/architecture) · [Threat Model](https://moav.sh/docs/threat-model) · [Mission](https://moav.sh/docs/mission) · [Philosophy](https://moav.sh/docs/philosophy)

**Connect users** — [Client Apps](https://moav.sh/docs/CLIENTS) · [MahsaNG Import](https://moav.sh/docs/mahsanet) · [MoaV Client](https://moav.sh/docs/client)

**Operate** — [CLI Reference](https://moav.sh/docs/CLI) · [Monitoring](https://moav.sh/docs/MONITORING) · [Troubleshooting](https://moav.sh/docs/TROUBLESHOOTING) · [OPSEC Guide](https://moav.sh/docs/OPSEC)

**Contribute** — [Development & Testing](https://moav.sh/docs/development) · [Translating the Docs](https://moav.sh/docs/TRANSLATING) · [Support MoaV](https://moav.sh/docs/support)

**For AI agents** — [AGENTS.md](AGENTS.md) for working in this repo, [llms.txt](https://moav.sh/llms.txt) as a compact index, [llms-full.txt](https://moav.sh/llms-full.txt) for the whole corpus.

## Requirements

**Server:**
- Debian 12, Ubuntu 22.04/24.04
- 1 vCPU, 1 GB RAM minimum (2 vCPU, 2 GB RAM if using monitoring)
- Public IPv4
- Domain name (optional - see Domain-less Mode below)

**Ports (open as needed):**
| Port | Protocol | Service | Requires Domain |
|------|----------|---------|-----------------|
| 443/tcp | TCP | Reality (VLESS) | No — borrows a public SNI via `REALITY_TARGET` |
| 443/udp | UDP | Hysteria2 | Yes |
| 8443/tcp | TCP | Trojan | Yes |
| 8445/tcp | TCP | AnyTLS | Yes |
| 8388/tcp+udp | TCP+UDP | Shadowsocks-2022 | No |
| 4443/tcp+udp | TCP+UDP | TrustTunnel | Yes |
| 2082/tcp | TCP | CDN WebSocket | Cloudflare: yes · CloudFront: no |
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

## Running without a domain

Don't have a domain? MoaV can run in **domainless mode** with:
- **Reality** (VLESS+Reality, primary protocol)
- **XHTTP** (VLESS+XHTTP+Reality via Xray-core)
- **WireGuard** (direct UDP + WebSocket tunnel)
- **AmneziaWG** (obfuscated WireGuard, resists common DPI signatures)
- **Telegram MTProxy** (fake-TLS, direct Telegram access)
- **GooseRelay** (SOCKS5 over Google Apps Script — no domain needed)
- **Admin dashboard** (uses self-signed certificate)
- **Conduit** (Psiphon bandwidth donation)
- **Snowflake** (Tor bandwidth donation)

Run `moav` and select "No domain" when prompted, or use `moav domainless` to configure.

## Project Structure

```
MoaV/
├── moav.sh              # the CLI: argument parsing, then straight into a cmd_* function
├── lib/                 # 15 host-side modules — service, users, bootstrap, doctor,
│                        #   cert, migrate, donate, nettune, dns, peers, menu, …
├── scripts/             # container entrypoints + provisioning
│   ├── *-entrypoint.sh  #   one per service
│   └── lib/             #   shared libraries, mounted into containers as /app/lib
├── configs/             # *.template files (tracked) rendered into *.json/*.conf (gitignored)
├── dockerfiles/         # image builds, one per service
├── exporters/           # Prometheus exporters (sing-box, xray, wireguard, amneziawg, …)
├── dns-router/          # Go daemon fanning port 53 out to the four DNS tunnels
├── admin/               # FastAPI dashboard
├── web/                 # decoy website
├── data/                # protocols.json — the protocol roster, source of truth
├── tests/               # the regression suite, named after the bug class each pins
├── docs/devdocs/        # contributor docs (the user docs live in moav-site)
├── docker-compose.yml
└── .env.example         # annotated config reference; commonly-changed vars up top
```

`moav.sh` is a dispatcher — the logic lives in `lib/`. `outputs/` (user bundles) and
`state/` (keys) are generated and gitignored.

## Security

- All protocols require authentication
- Decoy website for unauthenticated traffic
- Per-user credentials with instant revocation
- Minimal logging (no URLs, no content)
- TLS 1.3 everywhere

**Container privileges.** Docker API access is confined to a filtered socket
proxy on a management-only network, and the monitoring exporters read published
state files instead of the socket. The one accepted exception is **cAdvisor**
(optional `monitoring` profile): per-container CPU/memory/disk stats require
privileged mode with read-only host mounts, which is its upstream deployment
mode. If that trade-off is not acceptable, run without the monitoring profile.

See the [OPSEC guide](https://moav.sh/docs/OPSEC) for security guidelines.

## Support the project

**Run a server.** The highest-leverage thing you can do. Every MoaV server is capacity
that did not exist before — for your family, your colleagues, or people you will never
meet. Nobody runs infrastructure on your behalf; the network *is* the people running
servers. A $5/month VPS or a Raspberry Pi is enough.

**Donate capacity you already have.** Relay for other circumvention networks without
having users of your own — `moav start conduit` (Psiphon) and `moav start snowflake`
(Tor), both opt-in and capped. Or donate configs to [MahsaNet](https://www.mahsaserver.com/)
with `moav donate`, which hands them to users in Iran who cannot set up a server.

**Contribute or translate.** Bugs, protocols, packaging, docs — see
[Development & Testing](https://moav.sh/docs/development). Translation is the most useful
non-code contribution: the docs are scaffolded for Farsi and Russian and one page is a
complete contribution ([how to translate](https://moav.sh/docs/TRANSLATING)). Bug reports
count too — a reproducible report with `moav doctor` output is often more work than the fix.

> Never paste bundles, `.env` contents or share links into an issue — they contain live keys.

**Fund the infrastructure.** Test servers for the end-to-end suite, domains, build
capacity. Not salaries.

<!-- FUNDING:START -->
| Platform | Link |
|---|---|
| **GitHub Sponsors** | [github.com/sponsors/shayanb](https://github.com/sponsors/shayanb) |
| **Buy Me a Coffee** | [buymeacoffee.com/pangana](https://buymeacoffee.com/pangana) |

| Coin | Address |
|---|---|
| **Bitcoin (BTC)** | `bc1p6rpwzkgrlvpkre0n94fqayafpw47kl2j5lmvhvl0rfrtzm94wvvsmd3w5s` |
| **Ethereum (ETH)** ¹ | `0xB4D06BDb0C2f1D81E0b0b805Ed813F4ffe960aE2` |
| **Monero (XMR)** | `8BmduJgZLok9xiaX8FboSWBBbzYAugqLxUts7eZNsF2x9QDhk3Ua7iwQufBBNB8VFzcMEMAE1Uo6PjQvAYNYHmXsBRbqQqG` |
| **Zcash (ZEC)** | `u1pclheucppc87qlffh9m8wjfw87w2nka40w9nxjuqnyppj0kx9xp7z9rg6wx556662y5f8dtfyeynmm2lnz5aqvaqzmnpajlq0mnmkntdqzqqegk8lwv09cnudf3ttzm3878p3030j3lwupj257rmmv9p3ea32hgwsuf3jdh8ycv7q587` |
| **Lightning** | `lno1zrxq8pjw7qjlm68mtp7e3yvxee4y5xrgjhhyf2fxhlphpckrvevh50u0q0zdgjjahpdv7tnd9vstumyrw43snsmfmlzv0pgkqrjkgy48tsne6qsr0k64d8rz4k394pmre2rgnmstdxqsfj0w4dsmq2ec73ssek5wzqtqqv7argu9ptk09h9vfvvvham5xnwe306zjw6lptxx0d2yfk5rlvznjwefmsrmmpu8qnkqmghe0v96c8qy3m3nqgm977ay8f5p6k2d2ll2j3knnc8c4s6haufe203jx4ufy8z25tsscqqseg8jzh2qykejnc9sp2v4qm3z2q` |
| **Lightning Address** | `shayan@bitrefill.me` |
| **Tron** ² | `TBSCbnTZCELrMnioobZMkah5r9qS6B1tC6` |

¹ **Ethereum (ETH)** — same address on every EVM chain (Arbitrum, Optimism, Base, Gnosis…) and any ERC20 (USDC, USDT, DAI…)

² **Tron** — TRX and TRC-20 only — not interchangeable with the EVM address
<!-- FUNDING:END -->

Addresses are generated from [`.github/FUNDING.yml`](.github/FUNDING.yml), the single
source of truth, so what you see here is whatever that file says. Take them from this
page or the repository over HTTPS and check the first and last characters after pasting.
**We will never DM you an address.**

## Community

- **Telegram:** [t.me/motherofallvpns](https://t.me/motherofallvpns) — questions, help, release announcements
- **X:** [@motherofallvpns](https://x.com/motherofallvpns)
- **Issues:** [GitHub Issues](https://github.com/MotherofallVPNs/MoaV/issues) for bugs and feature requests
- **Docs:** [moav.sh/docs](https://moav.sh/docs)

## Related projects

MoaV is a deployment layer. The protocol work belongs to these projects:

**Companion client** — [moav-client](https://github.com/MotherofallVPNs/moav-client): desktop/CLI
client that ingests a MoaV subscription, probes every endpoint through its own tunnel and routes
through whichever is live and fastest ([docs](https://moav.sh/docs/client)).

**Protocol engines**

| Project | What MoaV uses it for |
|---|---|
| [sing-box](https://github.com/SagerNet/sing-box) | Reality, Trojan, AnyTLS, Hysteria2, Shadowsocks-2022, CDN VLESS+WS |
| [Xray-core](https://github.com/XTLS/Xray-core) | XHTTP and XDNS |
| [REALITY](https://github.com/XTLS/REALITY) | the TLS camouflage Reality and XHTTP are built on |
| [AmneziaWG](https://github.com/amnezia-vpn/amneziawg-go) · [tools](https://github.com/amnezia-vpn/amneziawg-tools) | DPI-resistant WireGuard |
| [WireGuard](https://www.wireguard.com/) | the direct UDP VPN |
| [wstunnel](https://github.com/erebe/wstunnel) | WireGuard over `wss://` when UDP is blocked |
| [TrustTunnel](https://github.com/TrustTunnel/TrustTunnel) · [client](https://github.com/TrustTunnel/TrustTunnelClient) | HTTP/2 + QUIC transport |
| [telemt](https://github.com/telemt/telemt) | Telegram MTProxy (fake-TLS) |
| [dnstt](https://www.bamsoftware.com/software/dnstt/) | the original DNS tunnel |
| [Slipstream](https://github.com/net2share/slipstream-rust-build) | QUIC-over-DNS |
| [MasterDNS](https://github.com/masterking32/MasterDnsVPN) | ARQ + resolver load-balancing DNS tunnel |
| [GooseRelay](https://github.com/kianmhz/GooseRelayVPN) | SOCKS5 over Google Apps Script |

**Networks you can donate capacity to**

| Project | |
|---|---|
| [Psiphon Conduit](https://github.com/Psiphon-Inc/conduit) | relay for Psiphon users |
| [Tor Snowflake](https://snowflake.torproject.org/) | relay for Tor users |
| [MahsaNet](https://www.mahsaserver.com/) · [MahsaNG](https://github.com/GFW-knocker/MahsaNG) | config donation and the client most Iranian users have |

**Monitoring** — [Prometheus](https://github.com/prometheus/prometheus), [Grafana](https://github.com/grafana/grafana),
[node_exporter](https://github.com/prometheus/node_exporter), [cAdvisor](https://github.com/google/cadvisor),
[clash-exporter](https://github.com/zxh326/clash-exporter).

Pinned versions for all of these live in [`.env.example`](.env.example).

## License

MIT

## Changelog
See [CHANGELOG.md](CHANGELOG.md) for release notes and version history.

## Stars over time

<a href="https://github.com/MotherofallVPNs/MoaV/stargazers">
  <img src="https://raw.githubusercontent.com/MotherofallVPNs/MoaV/refs/heads/chart/star-history.svg" alt="MoaV star history" width="800">
</a>

Every star helps someone else find a way through. Thank you.

---
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
