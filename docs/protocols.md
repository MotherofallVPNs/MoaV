# Supported Protocols

MoaV deploys 13 protocols, each with different stealth characteristics, speed profiles, and network requirements. This diversity ensures that when one protocol is blocked, others remain available.

## Protocol Overview

| Protocol | Port | Stealth | Speed | Domain Required |
|----------|------|---------|-------|-----------------|
| [Reality (VLESS)](#reality-vless) | 443/tcp | Very High | High | No |
| [Trojan](#trojan) | 8443/tcp | High | High | Yes |
| [Hysteria2](#hysteria2) | 443/udp | High | Very High | Yes |
| [CDN (VLESS+WS)](#cdn-vlessws) | 443 via CDN | Very High | Medium | Yes (Cloudflare) |
| [TrustTunnel](#trusttunnel) | 4443/tcp+udp | Very High | High | Yes |
| [WireGuard](#wireguard) | 51820/udp | Medium | Very High | No |
| [AmneziaWG](#amneziawg) | 51821/udp | Very High | High | No |
| [WireGuard (wstunnel)](#wireguard-wstunnel) | 8080/tcp | High | High | No |
| [Telegram MTProxy](#telegram-mtproxy) | 993/tcp | High | Medium | No |
| [dnstt](#dnstt) | 53/udp | Medium | Low | Yes |
| [Slipstream](#slipstream) | 53/udp | Medium | Low-Medium | Yes |
| [MasterDNS](#masterdns) | 53/udp | Medium | Medium | Yes |
| [GooseRelay](#gooserelay) | 8444/tcp | Very High | Low-Medium | No |
| [Psiphon Conduit](#psiphon-conduit) | dynamic | High | Medium | No |
| [XHTTP (VLESS+XHTTP+Reality)](#xhttp-vlessxhttpreality) | 2096/tcp | Very High | High | No |
| [XDNS (VLESS+mKCP+DNS)](#xdns-vlesmkcpdns) | 53/udp | Medium | Low | Yes |
| [Tor Snowflake](#tor-snowflake) | dynamic | High | Low | No |
| [MahsaNet](#mahsanet) | — | — | — | No |

## Protocols in Detail

### Reality (VLESS)

**Primary protocol.** VLESS with Reality makes your proxy traffic indistinguishable from a real TLS connection to a legitimate website (e.g., `dl.google.com`). The server presents a genuine TLS certificate from the target site, passing even active probing.

- **Port:** 443/tcp
- **Engine:** [sing-box](https://github.com/SagerNet/sing-box)
- **Clients:** Streisand, Hiddify, v2rayNG, v2rayN, NekoBox

### Trojan

Password-authenticated TLS proxy. Traffic looks like normal HTTPS. Uses your domain's real TLS certificate from Let's Encrypt.

- **Port:** 8443/tcp
- **Engine:** [sing-box](https://github.com/SagerNet/sing-box)
- **Clients:** Streisand, Hiddify, v2rayNG, v2rayN, Shadowrocket

### Hysteria2

QUIC-based protocol optimized for high throughput on lossy networks. Includes built-in obfuscation to bypass QUIC blocking.

- **Port:** 443/udp
- **Engine:** [sing-box](https://github.com/SagerNet/sing-box)
- **Clients:** Streisand, Hiddify, v2rayNG, v2rayN
- **Note:** Requires UDP. Blocked in some censored networks that drop all non-DNS UDP.

### CDN (VLESS+WS)

Routes VLESS traffic through Cloudflare's CDN via WebSocket. When your server's IP is blocked, traffic goes through Cloudflare instead, making it unblockable without blocking all of Cloudflare.

- **Port:** 443 (Cloudflare) → 2082 (origin)
- **Engine:** [sing-box](https://github.com/SagerNet/sing-box)
- **Clients:** Streisand, Hiddify, v2rayNG, v2rayN
- **Requires:** Cloudflare-proxied domain

### TrustTunnel

Modern VPN protocol that looks like regular HTTPS traffic. Supports both HTTP/2 (TCP) and HTTP/3 (QUIC/UDP).

- **Port:** 4443/tcp + 4443/udp
- **Engine:** [TrustTunnel](https://github.com/TrustTunnel/TrustTunnel) (server) / [TrustTunnelClient](https://github.com/TrustTunnel/TrustTunnelClient) (client)
- **Clients:** TrustTunnel app (iOS, Android, macOS, Windows, Linux)

### WireGuard

Fast kernel-level VPN. Simple, audited, and widely supported. Direct UDP connection.

- **Port:** 51820/udp
- **Engine:** [sing-box](https://github.com/SagerNet/sing-box) + [wstunnel](https://github.com/erebe/wstunnel)
- **Clients:** WireGuard app (all platforms)
- **Note:** Easily fingerprinted by DPI. Use AmneziaWG or wstunnel variant in censored networks.

### AmneziaWG

Obfuscated WireGuard variant that defeats Deep Packet Inspection. Adds junk packets, changes handshake timing, and modifies header fields to avoid detection.

- **Port:** 51821/udp
- **Engine:** [amneziawg-tools](https://github.com/amnezia-vpn/amneziawg-tools)
- **Clients:** AmneziaVPN (iOS, Android, macOS, Windows, Linux)

### WireGuard (wstunnel)

WireGuard tunneled through WebSocket (TCP). Works when UDP is completely blocked.

- **Port:** 8080/tcp
- **Engine:** [wstunnel](https://github.com/erebe/wstunnel) + [sing-box](https://github.com/SagerNet/sing-box)
- **Clients:** WireGuard app + wstunnel binary

### Telegram MTProxy

Telegram-specific proxy with Fake-TLS V2. Emulates real TLS connections, including certificate mimicry and timing simulation. Provides direct access to Telegram when it's blocked.

- **Port:** 993/tcp (IMAPS port for stealth)
- **Engine:** [telemt](https://github.com/telemt/telemt)
- **Clients:** Telegram app (built-in proxy settings)

<details>
<summary><strong>Anti-DPI Tuning Settings</strong></summary>

telemt has 17+ configurable settings for hostile network environments. All configurable in `.env`:

**Traffic Disguise (anti-DPI):**

| Setting | Default | Purpose |
|---------|---------|---------|
| `TELEMT_KEEPALIVE_RANDOM` | `true` | Randomize keepalive payload to break DPI pattern-matching |
| `TELEMT_KEEPALIVE_JITTER` | `4` | ±N seconds randomness on keepalive timing |
| `TELEMT_KEEPALIVE_INTERVAL` | `20` | Base keepalive interval in seconds |
| `TELEMT_WARMUP_JITTER` | `200` | Randomize connection establishment timing (ms) |

**Connection Pool Resilience:**

| Setting | Default | Purpose |
|---------|---------|---------|
| `TELEMT_POOL_SIZE` | `12` | Number of persistent connections to Telegram DCs |
| `TELEMT_REINIT_SECS` | `600` | Rebuild all connections every N seconds (prevents long-connection fingerprinting) |
| `TELEMT_HARDSWAP` | `true` | Build new pool before tearing down old (zero-downtime rotation) |
| `TELEMT_HARDSWAP_DELAY_MIN` | `500` | Min delay between new connections during swap (ms) |
| `TELEMT_HARDSWAP_DELAY_MAX` | `1200` | Max delay between new connections during swap (ms) |

**Fast Reconnect:**

| Setting | Default | Purpose |
|---------|---------|---------|
| `TELEMT_FAST_RETRIES` | `10` | Quick retries before exponential backoff |
| `TELEMT_BACKOFF_BASE` | `300` | Backoff start interval (ms) |
| `TELEMT_BACKOFF_CAP` | `10000` | Maximum backoff interval (ms) |

**Config Stability:**

| Setting | Default | Purpose |
|---------|---------|---------|
| `TELEMT_STABLE_SNAPSHOTS` | `3` | Require N consistent config snapshots before applying changes |
| `TELEMT_APPLY_COOLDOWN` | `120` | Minimum seconds between config changes |

**For aggressive censorship** (e.g., Iran during shutdowns): increase `TELEMT_POOL_SIZE` to 16-20, decrease `TELEMT_REINIT_SECS` to 300, and increase `TELEMT_FAST_RETRIES` to 20.

Full tuning docs: [telemt TUNING.en.md](https://github.com/telemt/telemt/blob/main/docs/TUNING.en.md) | [API docs](https://github.com/telemt/telemt/blob/main/docs/API.md)

</details>

### dnstt

DNS tunnel that encodes TCP traffic within DNS queries. Extremely hard to block without breaking DNS entirely. Very slow but works as a last resort when almost everything is blocked.

- **Port:** 53/udp
- **Engine:** [dnstt](https://www.bamsoftware.com/software/dnstt/)
- **Requires:** Domain with NS delegation

### Slipstream

QUIC-over-DNS tunnel. Similar to dnstt but uses QUIC for better throughput — typically 1.5-5x faster than dnstt.

- **Port:** 53/udp
- **Engine:** [slipstream](https://github.com/Mygod/slipstream-rust) (Rust) / [pre-built binaries](https://github.com/net2share/slipstream-rust-build/releases)
- **Requires:** Domain with NS delegation

### MasterDNS

Advanced DNS tunnel optimised beyond dnstt/Slipstream: low-overhead ARQ, resolver load-balancing, and high stability under packet loss. This is the **MasterDNS** component bundled in MahsaNG v16, so the MahsaNG Android app can connect directly. Faster than dnstt and more resilient on lossy links, but still a DNS tunnel (slow vs. real proxies) — use when little else works.

- **Port:** 53/udp (via `dns-router`, on its own subdomain — coexists with dnstt/Slipstream)
- **Engine:** [MasterDnsVPN](https://github.com/masterking32/MasterDnsVPN) (Go)
- **Clients:** MahsaNG v16+, or the standalone MasterDnsVPN client (Linux/Windows/macOS/Termux)
- **Encryption:** AES-256-GCM (`DATA_ENCRYPTION_METHOD=5`); the shared key is in each user's `masterdns-instructions.txt`
- **Requires:** Domain with NS delegation (`MASTERDNS_SUBDOMAIN`, default `m`)
- **Note:** Enabled by default (set `ENABLE_MASTERDNS=false` in `.env` to opt out). Egress is routed through sing-box like dnstt/Slipstream. Unlike XDNS, MasterDNS shares port 53 *with* dnstt/Slipstream (dns-router fans out by subdomain), so no `switch-dns` needed.

### GooseRelay

SOCKS5 tunnelled through a **Google Apps Script** web app that the user deploys in their own Google account, which forwards to this VPS exit server. On the wire the client only ever appears to make a domain-fronted HTTPS request to `google.com` — everything is end-to-end AES-256-GCM and Google never sees plaintext or the key. This is the **GooseRelay** component bundled in MahsaNG v16. Extremely stealthy (looks like Google traffic), but throughput is capped by the Apps Script ~20k-calls/day-per-account quota.

- **Port:** `${PORT_GOOSE}`/tcp (default 8444 on the host → 8443 in the container; 8443 on the host is Trojan's)
- **Engine:** [GooseRelayVPN](https://github.com/kianmhz/GooseRelayVPN) (Go), server built from source
- **Clients:** MahsaNG v16+, or the standalone GooseRelay client + a user-deployed Apps Script forwarder
- **Encryption:** AES-256-GCM, shared 64-hex `tunnel_key` (in each user's `gooserelay-instructions.txt`)
- **Requires:** No domain. `PORT_GOOSE` must be reachable from Google's network. The user sets `RELAY_URL = http://SERVER_IP:PORT_GOOSE/tunnel` in their Apps Script.
- **Note:** Opt-in — set `ENABLE_GOOSERELAY=true` in `.env`. Egress is routed through sing-box. Real-time apps (Telegram/X) drain the Apps Script quota fast; add more deployments under different Google accounts for capacity.

### XHTTP (VLESS+XHTTP+Reality)

**Experimental.** VLESS over XHTTP transport with Reality TLS camouflage, powered by Xray-core. Uses the XHTTP (formerly splithttp) transport for multiplexed HTTP requests, making traffic look like regular web browsing. Reality handles TLS without needing a domain.

- **Port:** 2096/tcp
- **Engine:** [Xray-core](https://github.com/XTLS/Xray-core)
- **Clients:** V2rayNG, Hiddify, Streisand, V2Box, V2rayN, V2rayU, NekoBox
- **Note:** Uses Xray-core (separate from sing-box). Disable with `ENABLE_XHTTP=false` in `.env`.

### XDNS (VLESS+mKCP+DNS)

**Experimental.** DNS tunnel using Xray-core's mKCP transport with FinalMask XDNS. Encodes VPN traffic inside DNS queries — works when almost everything except DNS is blocked. Slower than other protocols but extremely resilient during heavy internet shutdowns.

- **Port:** 53/udp (direct to xray, not through dns-router)
- **Engine:** [Xray-core](https://github.com/XTLS/Xray-core) (built from main branch for FinalMask support)
- **Clients:** Apps with FinalMask support (Happ beta, Xray CLI). Standard v2rayNG does not support FinalMask yet.
- **Requires:** Domain (for FinalMask packet formatting, NS delegation optional)
- **Note:** XDNS and dnstt/Slipstream both use port 53 — enable one OR the other in `.env`. Client connects directly to server IP on port 53. Best for Telegram and lightweight chat apps — not fast enough for web browsing.

<details>
<summary><strong>XDNS Tuning</strong></summary>

| Setting | Default | Purpose |
|---------|---------|---------|
| `XDNS_MTU` | `35` | mKCP packet size. Smaller = works with more DNS resolvers. 35=safest, 67=most, 130=unrestricted |
| `XDNS_SUBDOMAIN` | `x` | Subdomain for XDNS queries (x.yourdomain.com) |
| `XDNS_RESOLVERS` | `1.1.1.1,8.8.8.8` | CSV of public DNS resolvers the client round-robins across in a single mKCP session (Xray v26.4.13+, [PR #5872](https://github.com/XTLS/Xray-core/pull/5872)). See [Reachable DNS resolvers](#reachable-dns-resolvers) — replace the defaults with resolvers that actually answer on your network. Set empty to fall back to single-resolver mode. |

MTU depends on domain name length — shorter domain allows higher MTU. The values above are for ~19-character domains.

For aggressive censorship: use `MTU=35` and connect via a DNS resolver you can actually reach from inside the censored network (see below).

</details>

#### Reachable DNS resolvers

DNS tunnels (dnstt, Slipstream, XDNS) only work as well as the public DNS resolvers the client can reach. Censors increasingly throttle, null-route, or transparently rewrite well-known resolvers (`1.1.1.1`, `8.8.8.8`, `9.9.9.9`) during shutdowns, while less-publicized resolvers often keep answering. The right resolver for your network changes week to week.

Find resolvers that respond on your specific network with a DNS scanner:

- [findns](https://github.com/SamNet-dev/findns) — scans the public DNS-resolver space and reports which ones answer from your vantage point.
- [dns-mns](https://gitlab.com/E-Gurl/dns-mns) — similar, with a curated list maintained for Iranian ISP conditions.

Once you have a list of reachable resolvers:

- **XDNS**: set `XDNS_RESOLVERS=<ip1>,<ip2>,<ip3>` in `.env` and re-run `moav regenerate-users`. Xray will round-robin queries across them within a single mKCP session — higher throughput plus automatic fallback when one resolver is rate-limited.
- **dnstt**: pass `-doh https://<reachable-resolver>/dns-query` (DoH) or `-utls hellorandomized -doh ...` to `dnstt-client`.
- **Slipstream**: pass `--dns-server <reachable-resolver>:53` to `slipstream-client`. Or use `--authoritative SERVER_IP:53` to skip public resolvers entirely.

### Psiphon Conduit

Bandwidth donation to the Psiphon network. Psiphon users worldwide route through your server. Not a protocol you connect to — it's a way to help others bypass censorship.

- **Engine:** [Psiphon Conduit](https://github.com/Psiphon-Inc/conduit)
- **Clients:** [Psiphon](https://psiphon.ca/) app (iOS, Android, Windows)

#### How your Conduit helps people in Iran

There are two ways your running Conduit reaches users:

1. **Public pool — automatic, nothing to share.** The moment Conduit is
   running it donates bandwidth to the Psiphon network. Psiphon app users —
   including in Iran — are brokered through your server automatically. They
   don't need a link, an invite, or any setup. This is the main way Conduit
   helps and requires zero action on the user's side.

2. **Personal Pairing — share a private path with specific people.** Psiphon's
   Conduit lets you give friends/family a private, prioritized path through
   your station. The Psiphon app has a "pairing URL" field for this. To set it
   up: install Psiphon's **Ryve** app (the Conduit manager), import your
   station with the claim link MoaV generates, then in Ryve enable Personal
   Pairing and generate a pairing link to send to people in Iran.

#### `moav conduit link`

```bash
moav conduit link      # Claim link + QR + step-by-step sharing guide
moav conduit status    # Is it running + connected clients / bandwidth
```

This prints the **Ryve claim deep link** (`network.ryve.app://…claim=…`) and
its QR code, plus the sharing walkthrough above.

> **⚠ Security:** the claim link/QR embeds this Conduit's **private key** — it
> is for importing the station into *your own* phone's Ryve app. Treat it like
> a password; do **not** post it publicly (anyone with it can take over your
> station). The public-safe link you give to users is the **Personal Pairing**
> link generated *inside Ryve*, not the claim link. As of
> [Psiphon-Inc/conduit#205](https://github.com/Psiphon-Inc/conduit/issues/205)
> the pairing-URL export lives only in the Conduit/Ryve app UI, so MoaV
> surfaces the claim link and the steps rather than minting a pairing URL
> itself. (`moav donate info` is an alias for `moav conduit link`.)

### Tor Snowflake

Bandwidth donation to the Tor network. Acts as a Snowflake proxy, helping Tor users in censored regions connect. Like Conduit, this is about helping others.

- **Engine:** [Snowflake](https://gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/snowflake)
- **Clients:** [Tor Browser](https://www.torproject.org/) with Snowflake bridge

### MahsaNet

Config donation to [MahsaServer.com](https://www.mahsaserver.com/), a decentralized VPN config sharing platform for the [Mahsa VPN](https://www.mahsaserver.com/) app. With over 2 million users in Iran, Mahsa VPN connects to donated VPN configurations from servers worldwide. Unlike Conduit and Snowflake (which donate bandwidth), MahsaNet donates your server's VPN config links — Mahsa VPN users then connect directly to your server.

- **Supported protocols:** Reality (VLESS), Hysteria2, Trojan, CDN (VLESS+WS)
- **Clients:** [Mahsa VPN](https://www.mahsaserver.com/) app (Android, iOS)
- **Setup:** Register on MahsaServer.com, get API key, then `moav donate`
- **Dashboard:** Donate, list, and manage configs from the Admin Dashboard

## Choosing Protocols

**For censored networks (Iran, China, Russia):**

1. Start with **Reality** — highest stealth, most reliable
2. Add **CDN mode** — works when your server IP is blocked
3. Enable **AmneziaWG** — for full VPN when WireGuard is fingerprinted
4. Enable **DNS tunnels** — last resort when almost everything is blocked

**For general privacy:**

1. **WireGuard** — fastest, simplest
2. **Reality** — when WireGuard is blocked

**For helping others:**

1. **Conduit** — donate bandwidth to Psiphon users
2. **Snowflake** — donate bandwidth to Tor users
3. **MahsaNet** — donate VPN configs to Mahsa VPN users in Iran
