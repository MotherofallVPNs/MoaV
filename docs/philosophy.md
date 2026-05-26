# Mission & Philosophy

## Why MoaV Exists

MoaV was created to **democratize access to anti-censorship tools**. Running a VPN server shouldn't require deep technical expertise. Running *multiple* protocols — so users can find one that works when others are blocked — shouldn't require managing a dozen separate tools.

MoaV packages 16+ distinct protocols into a single deployment. When a government blocks one protocol, users switch to another. When that gets blocked too, there's always a fallback. DNS tunnels, CDN-fronted connections, obfuscated WireGuard, Telegram proxies — each has different network characteristics that make them resistant to different blocking techniques.

**The goal is simple:** make it as easy as possible for anyone with a $5/month VPS to provide reliable internet access to people who need it.

## Internet Access Is a Human Right

The United Nations Human Rights Council has repeatedly affirmed that the same rights people have offline must also be protected online. The Universal Declaration of Human Rights, Article 19:

> *Everyone has the right to freedom of opinion and expression; this right includes freedom to hold opinions without interference and to seek, receive and impart information and ideas through any means and regardless of frontiers.*

Internet shutdowns are not abstract policy debates. They cut people off from family, healthcare information, financial services, education, and the ability to document what is happening around them. They are used deliberately during protests and crises — precisely when communication matters most.

## Why Multi-Protocol Matters

No single protocol survives all censorship regimes. Governments invest heavily in Deep Packet Inspection (DPI) and actively adapt their blocking:

- **Protocol whitelisting** — Only DNS, HTTP, and HTTPS traffic allowed. Everything else dropped.
- **SNI inspection** — TLS handshakes inspected to block connections to non-approved domains.
- **QUIC/UDP blocking** — All UDP traffic except DNS dropped, killing WireGuard and Hysteria2.
- **Active probing** — Censors connect to suspected proxy servers to verify if they're running proxy software.
- **Bandwidth throttling** — Connections not outright blocked but throttled to unusable speeds.

MoaV's approach: run everything. Reality looks like a TLS connection to Google. Hysteria2 uses QUIC with obfuscation. WireGuard tunnels through WebSocket when UDP is blocked. DNS tunnels encode traffic in DNS queries. CDN mode routes through Cloudflare. Each protocol exploits a different gap in the censor's capabilities.

See [Supported Protocols](protocols.md) for the full list.

## Iran's Internet Shutdowns

Iran has one of the most sophisticated internet censorship systems in the world. MoaV was built with this reality in mind.

### Timeline

**November 2019** — Near-total internet shutdown during fuel price protests. The government cut connectivity for approximately one week. Amnesty International documented at least 304 deaths during the protests; other estimates are significantly higher. The shutdown prevented documentation of events and coordination of emergency response.

**September 2022 – 2023: Mahsa (Jina) Amini and the Woman, Life, Freedom Movement** — Following Mahsa Amini's death in morality police custody on September 16, 2022, nationwide protests erupted. The government responded with months of internet disruption:

- Mobile data shut down repeatedly across multiple provinces
- WhatsApp, Instagram, and Signal blocked nationwide
- International bandwidth throttled to near-unusable levels
- VPN protocols systematically identified and blocked via DPI
- Starlink connections jammed in some areas

The movement, known as *"Zan, Zendegi, Azadi"* (Woman, Life, Freedom), saw hundreds killed and thousands arrested. Internet restrictions continued through 2023.

**January 2026** — Multi-day nationwide blackout during mass protests. An estimated 30,000 to 70,000 people were killed. International connectivity dropped to near zero. Only the National Information Network (NIN, the domestic intranet) remained partially functional.

**February – March 2026** — Continued internet disruptions amid regional tensions. International bandwidth throttled heavily, with periodic full outages. Protocol-level blocking intensified, with authorities expanding their DPI capabilities to target newer circumvention tools.

### Technical Censorship Methods

Iran's censorship infrastructure operates at multiple layers:

- **National Information Network (NIN)** — A domestic intranet that continues functioning during international shutdowns, giving authorities the ability to cut external access while maintaining internal services.
- **Deep Packet Inspection** — Deployed at major peering points to inspect TLS SNI fields, detect proxy protocol signatures, and identify VPN traffic patterns.
- **Protocol whitelisting** — During heavy censorship periods, only DNS (port 53), HTTP (port 80), and HTTPS (port 443) traffic is permitted. All other protocols are dropped.
- **Active probing** — Suspected proxy servers are actively probed to confirm their function, then blocked by IP.
- **Throttling** — Rather than blocking outright, international connections are throttled to make them unusable while maintaining the appearance of connectivity.

### Why This Matters for MoaV

Each of MoaV's protocols addresses different aspects of Iran's censorship:

| Censorship Method | MoaV Counter |
|-------------------|--------------|
| Protocol blocking | Reality mimics legitimate TLS to approved sites |
| UDP blocking | WireGuard tunneled through WebSocket (TCP) |
| IP blocking | CDN mode routes through Cloudflare's network |
| DPI on SNI | TrustTunnel looks like regular HTTPS traffic |
| Total shutdown | DNS tunnels can work when only DNS is allowed |
| Active probing | Decoy website serves innocent content to probes |
| Throttling | Hysteria2's QUIC protocol maximizes throughput on constrained links |

## Contributing

If you have a VPS and want to help:

1. **[Deploy MoaV](quick-start.md)** and share access with people who need it
2. **Enable [Conduit](SETUP.md#bandwidth-donation-conduit-snowflake)** to donate bandwidth to Psiphon users worldwide
3. **Enable [Snowflake](SETUP.md#bandwidth-donation-conduit-snowflake)** to donate bandwidth to Tor users
4. **[Contribute code](https://github.com/shayanb/MoaV)** — fix bugs, add protocols, improve documentation
