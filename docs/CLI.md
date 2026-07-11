# MoaV CLI Reference

Complete reference for the `moav` command-line interface.

## Table of Contents

- [Installation](#installation)
- [Quick Reference](#quick-reference)
- [Commands](#commands)
  - [General](#general)
  - [Setup & Configuration](#setup--configuration)
  - [Service Management](#service-management)
  - [Certificates](#certificates)
  - [User Management](#user-management)
  - [Testing & Client](#testing--client)
  - [Migration](#migration)
- [Profiles](#profiles)
- [Service Names & Aliases](#service-names--aliases)
- [Environment Variables](#environment-variables)
- [Examples](#examples)

---

## Installation

```bash
# Install moav command globally (run from /opt/moav)
./moav.sh install

# Or using the script directly
./moav.sh [command]

# Uninstall global command
moav uninstall
```

After installation, `moav` is available from any directory.

---

## Quick Reference

```bash
moav                      # Interactive menu
moav help                 # Show help
moav start                # Start all services
moav stop                 # Stop all services
moav status               # Show service status
moav logs                 # View logs (follow mode)
moav doctor               # Run diagnostics
moav user add NAME        # Add new user
moav user add --batch 5   # Batch create 5 users
moav user revoke NAME     # Revoke user
moav test USERNAME        # Test connectivity
moav cert status          # TLS cert expiry + renewal status
moav admin password       # Reset admin password
moav donate               # Donate configs to MahsaNet
```

---

## Commands

### General

#### `moav` (no command)
Launch the interactive menu for guided setup and management.

```bash
moav
```

#### `moav help`
Display help message with all available commands.

```bash
moav help
moav --help
moav -h
```

#### `moav version`
Show MoaV version.

```bash
moav version
moav --version
```

#### `moav install`
Install `moav` command globally to `/usr/local/bin`.

```bash
./moav.sh install
```

#### `moav uninstall`
Remove MoaV containers and global command.

```bash
moav uninstall           # Remove containers, keep data (.env, keys, bundles)
moav uninstall --wipe    # Remove EVERYTHING (fresh install ready)
```

**Without `--wipe` (default):**
- Stops and removes all Docker containers
- Removes the global `moav` command
- Preserves: `.env`, keys, certificates, user bundles, Docker volumes

**With `--wipe`:**
- Removes all Docker containers AND volumes
- Removes `.env` and all generated configs
- Removes all keys and certificates
- Removes all user bundles
- Removes the global `moav` command

After `--wipe`, run `cp .env.example .env` and `./moav.sh` for a fresh setup.

---

### Setup & Configuration

#### `moav check`
Run prerequisites check (Docker, dependencies, ports).

```bash
moav check
```

#### `moav doctor`
Run diagnostic checks for common MoaV issues.

```bash
moav doctor              # Run all checks
moav doctor docker       # Docker and prerequisites
moav doctor memory       # RAM availability
moav doctor disk         # Disk space
moav doctor logs         # Container log file sizes (offers to truncate oversized)
moav doctor dns          # DNS records
moav doctor services     # Enabled vs running services
moav doctor config       # Config files and keys
moav doctor ports        # Port availability
moav doctor conflicts    # DNS-tunnel health (all 4 share port 53 via dns-router)
moav doctor env          # Compare .env with .env.example
moav doctor updates      # Check for MoaV updates
```

**Available checks:**
- `docker` — Docker daemon running, Compose available, Docker disk usage summary
- `memory` — Total RAM, available memory, warns if <1GB or <2GB with monitoring enabled
- `disk` — Disk space on root and Docker partition, warns if <2GB free
- `logs` — Scans `/var/lib/docker/containers/*/*-json.log` for files >100 MB; lists oversized files by container name and prompts to truncate in place. `truncate -s 0` keeps the FD live so Docker keeps writing — no service restart needed. Skips the prompt in non-interactive sessions (cron / piped runs) and prints the manual command instead. Pre-1.7.6 containers keep growing under Docker's unbounded default until they're recreated; this check is the fastest way to reclaim that space without a full restart
- `dns` — Verify DNS records for enabled protocols (A records, NS delegation, CDN)
- `services` — Compare enabled services in `.env` with running containers; flag crash-looping services
- `config` — Check bootstrap has been run and config files exist for enabled protocols
- `ports` — Verify required ports are listening; detect systemd-resolved on port 53
- `conflicts` — Check DNS-tunnel health. All four tunnels (dnstt, Slipstream, MasterDNS, XDNS) share port 53 via `dns-router`, fanned out by subdomain (`t.`/`s.`/`m.`/`x.`), so they coexist — this verifies enabled-vs-running state and that `dns-router` isn't crash-looping. Toggle individual tunnels with `ENABLE_*` or `moav switch-dns`
- `env` — Compare `.env` with `.env.example` for missing variables; flag critical missing vars
- `updates` — Check current version against latest GitHub release

#### `moav bootstrap`
Run first-time setup. Generates keys, obtains TLS certificates, creates initial users.

```bash
moav bootstrap
```

This command:
1. Checks prerequisites
2. Prompts for domain, email, admin password (if not in .env)
3. Generates Reality and dnstt keypairs
4. Obtains Let's Encrypt certificate
5. Creates initial users
6. Generates user bundles

#### `moav domainless`
Enable domainless mode for servers without a domain.

```bash
moav domainless
```

Available services in domainless mode:
- Reality (VLESS+Reality)
- XHTTP (VLESS+XHTTP+Reality)
- WireGuard (direct + wstunnel)
- AmneziaWG (obfuscated WireGuard)
- Telegram MTProxy (fake-TLS)
- Admin dashboard (self-signed certificate)
- Conduit (Psiphon bandwidth donation)
- Snowflake (Tor bandwidth donation)

#### `moav profiles`
Interactively change default services for `moav start`.

```bash
moav profiles
```

Saves selection to `DEFAULT_PROFILES` in `.env`.

#### `moav update`
Update MoaV from git repository.

```bash
moav update              # Update from current branch
moav update -b dev       # Switch to dev branch and update
moav update -b main      # Switch back to main branch
```

**Options:**
- `-b BRANCH` - Switch to specified branch before updating

If local changes are detected, you'll be prompted to stash or discard them.

#### `moav setup-dns`
Free port 53 for dnstt by disabling systemd-resolved.

```bash
moav setup-dns
```

This command:
1. Stops systemd-resolved
2. Disables it from starting on boot
3. Configures /etc/resolv.conf with public DNS servers

---

### Service Management

#### `moav start`
Start services.

```bash
moav start                    # Start DEFAULT_PROFILES from .env
moav start all                # Start all services whose ENABLE_* is true
moav start proxy              # Start proxy profile only
moav start proxy admin        # Start multiple profiles
moav start proxy wireguard admin  # Start three profiles
```

**Arguments:**
- No arguments: uses `DEFAULT_PROFILES` from `.env`
- Profile names: start specific profiles (space-separated)
- `--force` / `-f`: bypass the profile-filtering prompt (see below)

##### Disabled profiles

`moav start` respects the `ENABLE_*` flags in `.env`:

- **No args** or **`moav start all`**: starts only the profiles whose `ENABLE_*` is `true`. Anything disabled is skipped (you'll see `Skipping disabled profiles: <list>`).
- **`moav start <name>`** for a profile that's disabled in `.env`: you get a prompt:
  1. **Enable + start** — flips `ENABLE_*=true` in `.env`, then starts (persists for next time).
  2. **Skip** — don't start; `.env` stays as-is.
  3. **Start once** — start now without modifying `.env` (won't auto-start next time).

  For profiles backed by multiple flags (`proxy`, `dnstunnel`), option 1 shows which flags to set manually. `--force` bypasses the prompt. Non-interactive shells default to skip.

#### `moav stop`
Stop services.

```bash
moav stop                     # Stop all running services
moav stop sing-box            # Stop specific service
moav stop conduit snowflake   # Stop multiple services
moav stop -r                  # Stop and remove containers
moav stop sing-box -r         # Stop specific service and remove container
```

**Options:**
- `-r` - Remove containers after stopping (not just stop)

#### `moav restart`
Restart services.

```bash
moav restart                  # Restart all running services
moav restart sing-box         # Restart specific service
moav restart sing-box admin   # Restart multiple services
```

#### `moav status`
Show status of all services.

```bash
moav status
```

Displays:
- Container status (running/stopped)
- Health status
- Port mappings
- Uptime

#### `moav logs`
View service logs.

```bash
moav logs                     # All logs, follow mode (Ctrl+C to exit)
moav logs sing-box            # Specific service logs
moav logs sing-box conduit    # Multiple services
moav logs -n                  # Last 100 lines, no follow
moav logs sing-box -n         # Specific service, no follow
moav logs -f conduit          # Explicit follow mode
```

**Options:**
- `-n`, `--no-follow` - Show last 100 lines without following
- `-f`, `--follow` - Follow mode (default)

#### `moav build`
Build Docker images.

```bash
moav build                    # Build all images
moav build sing-box           # Build specific image
moav build conduit snowflake  # Build multiple images
```

---

### Certificates

TLS certificates for Trojan, Hysteria2, CDN VLESS, AnyTLS, and the admin UI come from Let's Encrypt (via the bundled `certbot` service) when a `DOMAIN` is set. They expire after 90 days, so MoaV manages renewal for you.

#### `moav cert status`
Show certificate expiry and whether the auto-renewal schedule is installed.

```bash
moav cert status
```

In domainless mode this reports that no Let's Encrypt certificates are in use and exits cleanly.

#### `moav cert renew`
Run a renewal check now. Renews only if the certificate is within Let's Encrypt's renewal window, and restarts the services that load certs at startup (sing-box, wstunnel, trusttunnel, admin, grafana, grafana-proxy) **only if the certificate actually changed**.

```bash
moav cert renew
```

> Do **not** use `docker compose run --rm certbot renew` directly — the compose `certbot` service overrides its entrypoint for one-shot issuance, so that command runs `/bin/sh renew` and never invokes certbot. `moav cert renew` forces the correct entrypoint.

#### `moav cert install`
Install the daily auto-renewal schedule. Uses a **systemd timer** (`moav-cert-renew.timer`) where available, falling back to `/etc/cron.d/moav-cert-renew` on hosts without systemd. The timer runs daily with a randomized delay, well within the renewal window.

```bash
moav cert install
```

This is installed **automatically** the first time `moav start` runs with a `DOMAIN` set. Opt out by setting `CERT_AUTORENEW=false` in `.env`.

#### `moav cert uninstall`
Remove the auto-renewal timer/cron job (certificates then expire in ≤90 days unless renewed manually).

```bash
moav cert uninstall
```

**Recovering an already-expired certificate:** `moav update` then `moav cert renew` — certbot reissues the cert in place (the webroot challenge on port 80 still works), and the timer self-installs on the next `moav start`.

---

### User Management

#### `moav users`
List all users.

```bash
moav users
moav user list    # Same as above
```

#### `moav user add`
Add one or more users to all services. Users can also be created from the **Admin Dashboard** (User Bundles → + Create User).

```bash
# Single user
moav user add john            # Add user 'john'
moav user add john --package  # Add user and create zip bundle
moav user add john -p         # Short form

# Multiple users
moav user add alice bob charlie           # Add three users
moav user add alice bob charlie -p        # Add three users with zip packages

# Batch mode (auto-numbered)
moav user add --batch 5                   # Create user01, user02, ..., user05
moav user add --batch 10 --prefix team    # Create team01, team02, ..., team10
moav user add --batch 5 --prefix dev -p   # Create dev01..dev05 with packages
```

**Options:**
- `--package`, `-p` - Create distributable zip file with HTML guide
- `--batch N`, `-b N` - Create N users with auto-generated names
- `--prefix NAME` - Prefix for batch usernames (default: "user")

**Batch mode features:**
- Smart numbering: if user01-user03 exist, `--batch 2` creates user04, user05
- Services reload once at the end (not after each user)
- Shows progress for each user and summary at the end

Creates bundle in `outputs/bundles/USERNAME/` containing:
- Config files for all protocols
- QR codes for mobile import
- README.html with instructions

#### `moav user revoke`
Revoke a user from all services.

```bash
moav user revoke john         # Revoke user 'john'
```

Removes user from:
- sing-box config (Reality, Trojan, Hysteria2, CDN)
- WireGuard config
- TrustTunnel credentials
- Deletes user bundle

#### `moav user package`
Create distributable zip for an existing user.

```bash
moav user package john        # Creates outputs/bundles/john.zip
```

#### V2Ray subscription (in every bundle)
Every user bundle includes a standard base64 **V2Ray subscription** — both as
`outputs/bundles/<user>/subscription.txt` and as a click-to-copy block at the
top of the bundle's `README.html`. Paste it once into
[MahsaNG](https://github.com/GFW-knocker/MahsaNG), v2rayNG, Hiddify, Streisand,
or any V2Ray app to import all proxy protocols at once — Reality, CDN, XHTTP,
Trojan, Shadowsocks-2022, Hysteria2 (standard `vless://`/`trojan://`/`ss://`/
`hysteria2://` URIs, IPv4 + IPv6).

WireGuard/AmneziaWG/TrustTunnel/DNS-tunnel/GooseRelay/Telegram are intentionally
excluded (not subscription-importable; the DNS tunnels and GooseRelay are set up
in their own app tabs). Full walkthrough: [docs/mahsanet.md](mahsanet.md).

#### `moav user gooserelay`
Print GooseRelay setup instructions for a user (extracted from their bundle).

```bash
moav user gooserelay john     # Print tunnel_key + Apps Script setup guide
```

GooseRelay is opt-in (`ENABLE_GOOSERELAY=true` in `.env`). When enabled, each
user bundle includes `gooserelay-instructions.txt` with the shared `tunnel_key`
and a step-by-step guide for deploying the Google Apps Script forwarder. See
[docs/protocols.md → GooseRelay](protocols.md#gooserelay) for full details.

---

### Testing & Client

#### `moav test`
Test connectivity for a user across all protocols.

```bash
moav test john                # Test all protocols
moav test john --json         # Output results as JSON
moav test john -v             # Verbose output for debugging
moav test john --verbose      # Same as above
```

**Options:**
- `--json` - Output results in JSON format
- `-v`, `--verbose` - Show detailed debug output

Tests: Reality, Trojan, Hysteria2, TrustTunnel, WireGuard, dnstt, Slipstream, MasterDNS

**Sample output:**
```
═══════════════════════════════════════════════════════════════
  MoaV Connection Test Results
═══════════════════════════════════════════════════════════════

  Config: /bundles/john
  Time:   Wed Jan 28 10:30:00 UTC 2026

───────────────────────────────────────────────────────────────
  ✓ reality      Connected via VLESS/Reality
  ✓ trojan       Connected via Trojan
  ✓ hysteria2    Connected via Hysteria2
  ✓ wireguard    Config valid, endpoint reachable
  ○ dnstt        No dnstt config found in bundle
  ○ slipstream   No slipstream config found in bundle
  ○ masterdns    No masterdns config found in bundle

═══════════════════════════════════════════════════════════════
```

#### `moav client`
Client mode commands.

```bash
moav client                   # Show client help
moav client build             # Build client Docker image
moav client test john         # Same as 'moav test john'
moav client connect john      # Connect as user (exposes proxy)
```

#### `moav client connect`
Connect through your MoaV server and expose local proxy.

```bash
moav client connect john                    # Auto-detect best protocol
moav client connect john --protocol reality # Use specific protocol
moav client connect john -p hysteria2       # Short form
```

**Options:**
- `--protocol`, `-p` - Specify protocol (default: auto)

**Protocols:** `auto`, `reality`, `trojan`, `hysteria2`, `wireguard`, `tor`, `dnstt`, `slipstream`, `masterdns`

**Proxy endpoints (configurable in .env):**
- SOCKS5: `localhost:10800` (CLIENT_SOCKS_PORT)
- HTTP: `localhost:18080` (CLIENT_HTTP_PORT)

#### `moav client build`
Build the client Docker image.

```bash
moav client build
```

---

### Admin

#### `moav admin password`
Reset the admin dashboard password.

```bash
moav admin password          # Prompts for new password (or generates random)
```

---

### Config Donation

#### `moav donate`
Donate VPN configs to sharing platforms.

```bash
moav donate                  # Show available donation services
```

#### `moav donate`
Donate VPN configs and bandwidth to help people bypass censorship. Supports three donation services:

- **MahsaNet** — Donate VPN config links to Mahsa VPN (2M+ users in Iran)
- **Psiphon Conduit** — Donate bandwidth to Psiphon's relay network (millions of users worldwide)
- **Tor Snowflake** — Donate bandwidth as a Tor Snowflake proxy

```bash
# Interactive donation wizard (shows all services, donates MahsaNet configs)
moav donate

# Configure donation services (MahsaNet API key, Conduit/Snowflake bandwidth)
moav donate setup

# Show all donation services status with live stats
moav donate status

# List donated MahsaNet configs
moav donate list

# Select and delete specific MahsaNet configs
moav donate delete

# Remove all donated MahsaNet configs
moav donate remove

# Show Conduit Ryve deep link and QR code
moav donate info
```

**Subcommands:**
- `setup` — Configure any donation service (menu: MahsaNet / Conduit / Snowflake)
- `status` — Show all 3 services: MahsaNet config stats, Conduit connected clients and bandwidth, Snowflake people served and bandwidth
- `list` — List all donated MahsaNet configs with status and health
- `delete` — Select and delete specific MahsaNet configs interactively
- `remove` — Remove all donated MahsaNet configs (with confirmation)
- `info` — Show Psiphon Conduit Ryve deep link and QR code for claiming in the Ryve app

**Configuration in `.env`:**
```bash
# MahsaNet
MAHSANET_API_KEY=                    # API key from mahsaserver.com/user/api
MAHSANET_PROTOCOLS="reality hysteria2"  # Protocols to donate
MAHSANET_POOL=mahsa                  # Pool: mahsa, warp, popup, telegram

# Psiphon Conduit
CONDUIT_BANDWIDTH=100                # Bandwidth limit in Mbps
CONDUIT_MAX_COMMON_CLIENTS=200       # Max concurrent clients

# Tor Snowflake
SNOWFLAKE_BANDWIDTH=5                # Bandwidth limit in Mbps
SNOWFLAKE_CAPACITY=50                # Max concurrent clients
```

#### `moav conduit`
Show the Psiphon Conduit claim link, QR code, and sharing guide.

```bash
moav conduit              # Same as 'moav conduit link'
moav conduit link         # Ryve claim deep link + QR + sharing walkthrough
moav conduit status       # Running state + connected clients / bandwidth
moav conduit help         # Usage
```

While Conduit runs it already serves Psiphon users (including in Iran) through
the **public pool** — nothing needs to be shared for that. To give specific
people a private path, use **Personal Pairing**: import the station into the
Ryve app with the claim link this command prints, then generate a pairing
link inside Ryve.

> **⚠ Security:** the claim link/QR embeds this Conduit's **private key** (for
> your own phone's Ryve app). Treat it like a password — do **not** post it
> publicly. The link you share with users is the Personal Pairing link
> generated inside Ryve, not the claim link. `moav donate info` is an alias.

#### `moav conduit-offsets`
Manage the watcher that keeps Conduit's **lifetime bandwidth** Grafana panels accurate across container restarts.

```bash
moav conduit-offsets install    # Install the systemd watcher
moav conduit-offsets status     # Show watcher state (enabled/disabled, last run)
moav conduit-offsets uninstall  # Remove the watcher
```

The watcher installs itself automatically the first time Conduit and monitoring run together — you usually don't need to touch this. Set `CONDUIT_OFFSETS_AUTOUPDATE=false` in `.env` to opt out. Hosts without systemd skip the watcher; run `scripts/update-conduit-offsets.sh` from cron instead. See [Monitoring → Conduit lifetime bandwidth](MONITORING.md#conduit-lifetime-bandwidth).

---

### Migration

#### `moav export`
Export full configuration backup.

```bash
moav export                   # Creates moav-backup-TIMESTAMP.tar.gz
moav export mybackup.tar.gz   # Custom filename
```

**Backup includes:**
- `.env` configuration
- All cryptographic keys (Reality, WireGuard, dnstt)
- User credentials
- Generated user bundles
- TLS certificates

**Security:** Backup contains private keys. Transfer securely and delete after import.

#### `moav import`
Import configuration from backup.

```bash
moav import moav-backup-20240128.tar.gz
moav import /path/to/backup.tar.gz
```

Restores:
- `.env` file
- Keys and certificates
- User credentials
- User bundles

#### `moav migrate-ip`
Update SERVER_IP and regenerate all user configs.

```bash
moav migrate-ip 203.0.113.50              # Set new IP
moav migrate-ip $(curl -s api.ipify.org)  # Auto-detect current IP
```

This command:
1. Updates `SERVER_IP` in `.env`
2. Regenerates all user bundle configs
3. Updates QR codes (if qrencode installed)

#### `moav regenerate-users`
Regenerate all user bundles with current .env settings.

```bash
moav regenerate-users
```

Use this after:
- Changing domain
- Enabling/disabling protocols
- Adding CDN_DOMAIN
- Changing any configuration that affects client configs

---

## Profiles

Profiles group related services. Each maps to one or more `ENABLE_*` flags in `.env`; `moav start` filters disabled profiles automatically (see [Profile filtering](#moav-start)).

| Profile | Services | Controlled by |
|---------|----------|---------------|
| `proxy` | sing-box, decoy, certbot | `ENABLE_REALITY` / `ENABLE_TROJAN` / `ENABLE_HYSTERIA2` / `ENABLE_SS` (any) |
| `xhttp` | xray | `ENABLE_XHTTP` |
| `wireguard` | wireguard, wstunnel, decoy, certbot | `ENABLE_WIREGUARD` |
| `amneziawg` | amneziawg | `ENABLE_AMNEZIAWG` |
| `dnstunnel` | dns-router, dnstt, slipstream, masterdns, xray (XDNS) | `ENABLE_DNSTT` / `ENABLE_SLIPSTREAM` / `ENABLE_MASTERDNS` / `ENABLE_XDNS` (any) |
| `trusttunnel` | trusttunnel | `ENABLE_TRUSTTUNNEL` |
| `telegram` | telemt | `ENABLE_TELEMT` |
| `admin` | admin, docker-proxy | `ENABLE_ADMIN_UI` |
| `conduit` | psiphon-conduit | `ENABLE_CONDUIT` |
| `snowflake` | snowflake, snowflake-exporter | `ENABLE_SNOWFLAKE` |
| `gooserelay` | gooserelay | `ENABLE_GOOSERELAY` (opt-in) |
| `monitoring` | prometheus, grafana, grafana-proxy, node-exporter, cadvisor + per-protocol exporters | `ENABLE_MONITORING` (opt-in) |
| `setup` | bootstrap, geoip-updater | (lifecycle, not user-toggled) |
| `client` | client | (for local testing) |
| `all` | All services above | (used by `moav start all`, `moav build`, `moav logs`, etc.) |

**Usage:**
```bash
moav start proxy admin        # Start proxy and admin profiles
moav start all                # Expands to every profile whose ENABLE_* is true
```

---

## Service Names & Aliases

| Service | Aliases |
|---------|---------|
| sing-box | `proxy`, `singbox`, `reality` |
| wireguard | `wg` |
| dnstt | `dns` |
| slipstream | `slip` |
| masterdns | `mdns` |
| psiphon-conduit | `conduit` |

**Usage:**
```bash
moav logs singbox             # Same as 'moav logs sing-box'
moav restart wg               # Same as 'moav restart wireguard'
moav stop conduit             # Same as 'moav stop psiphon-conduit'
```

---

## Environment Variables

Key variables in `.env` that affect CLI behavior:

| Variable | Description | Default |
|----------|-------------|---------|
| `DEFAULT_PROFILES` | Profiles started by `moav start` | `proxy admin` |
| `CLIENT_SOCKS_PORT` | SOCKS5 port for client mode | `10800` |
| `CLIENT_HTTP_PORT` | HTTP port for client mode | `18080` |
| `INITIAL_USERS` | Users created during bootstrap | `5` |
| `MAHSANET_API_KEY` | MahsaNet API key for config donation | (empty) |
| `MAHSANET_PROTOCOLS` | Protocols to donate to MahsaNet | `reality hysteria2` |
| `MAHSANET_POOL` | MahsaNet pool for donated configs | `mahsa` |

---

## Examples

### Complete Setup Flow

```bash
# 1. Install MoaV
curl -fsSL moav.sh/install.sh | bash

# 2. Configure environment
cd /opt/moav
cp .env.example .env
nano .env    # Set DOMAIN, ACME_EMAIL, ADMIN_PASSWORD

# 3. Run bootstrap
moav bootstrap

# 4. Start services
moav start

# 5. Add a user
moav user add john --package

# 6. Download bundle
# Visit https://your-server:9443 or use SCP
```

### Daily Operations

```bash
# Check status
moav status

# View logs
moav logs sing-box

# Add new user
moav user add alice

# Add multiple users at once
moav user add alice bob charlie

# Batch create users (auto-numbered)
moav user add --batch 10 --prefix team --package

# Test user connectivity
moav test alice

# Update MoaV
moav update
```

### Server Migration

```bash
# On old server
moav export

# Copy backup to new server
scp moav-backup-*.tar.gz root@new-server:/opt/moav/

# On new server
cd /opt/moav
moav import moav-backup-*.tar.gz
moav migrate-ip $(curl -s api.ipify.org)
moav start
```

### Testing Development Branch

```bash
# Switch to dev branch
moav update -b dev

# Test changes
moav restart

# Return to stable
moav update -b main
```

### Bandwidth & Config Donation

```bash
# Set up donation services (MahsaNet API key, Conduit/Snowflake bandwidth)
moav donate setup

# Donate 5 VPN configs to MahsaNet
moav donate
# Enter: 5 for count, "mahsa" for prefix

# See all donation stats (MahsaNet configs + Conduit clients + Snowflake served)
moav donate status

# Configure Conduit bandwidth limit
moav donate setup  # Select option 2

# Get Conduit Ryve deep link (for claiming in Ryve app)
moav donate info

# List/delete MahsaNet configs
moav donate list
moav donate delete
```

### Domain-less Quick Setup

```bash
# For servers without a domain
moav domainless
moav start wireguard admin conduit
moav user add john
```
