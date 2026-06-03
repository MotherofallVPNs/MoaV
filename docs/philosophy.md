# Mission & Philosophy

Internet freedom doesn't happen by accident. It doesn't come from governments deciding to be generous, or from corporations choosing not to surveil. It comes from people — engineers, activists, diaspora communities, strangers with a spare VPS — building the infrastructure that makes it real.

We built MoaV because the tools already existed but the friction was too high. Running a reliable multi-protocol circumvention server shouldn't require a week of configuration and a systems-engineering background. With MoaV it takes ten minutes. One command. A $5 server. And you're part of the network that keeps people connected when their governments decide they shouldn't be.

This is not someone else's problem to solve. The window to act is between blackouts, not during them.

## Internet Access Is a Human Right

The United Nations Human Rights Council has repeatedly affirmed that the same rights people have offline must also be protected online. The Universal Declaration of Human Rights, Article 19:

> *Everyone has the right to freedom of opinion and expression; this right includes freedom to hold opinions without interference and to seek, receive and impart information and ideas through any means and regardless of frontiers.*

Internet shutdowns are not abstract policy debates. They cut people off from family, healthcare information, financial services, education, and the ability to document what is happening around them. They are used deliberately during protests and crises — precisely when communication matters most.

## Why MoaV Exists

MoaV was created to **democratize access to anti-censorship tools**. Running a VPN server shouldn't require deep technical expertise. Running *multiple* protocols — so users can find one that works when others are blocked — shouldn't require managing a dozen separate tools.

MoaV packages 16+ distinct protocols into a single deployment. One command deploys all of them. A $5 VPS is enough. The goal is simple: make it as easy as possible for anyone with a spare server to provide reliable internet access to people who need it.

## What Infrastructure Actually Means

Here is the difference between using a tool and being infrastructure.

**Using a tool**: you install a VPN app. It works, or it doesn't. When it gets blocked, you try the next one. You are a consumer of access.

**Being infrastructure**: you run a server. Other people connect through it. When the protocols they're using get blocked, your server already has the fallback ready. You are a node in the network of free communication.

MoaV was built to make the second thing as easy as the first.

## Why Multi-Protocol Matters

No single protocol survives all censorship regimes. Governments invest heavily in Deep Packet Inspection (DPI) and adapt their blocking continuously:

- **Protocol whitelisting** — only DNS, HTTP, and HTTPS allowed; everything else dropped.
- **SNI inspection** — TLS handshakes inspected to block connections to non-approved domains.
- **QUIC/UDP blocking** — all UDP except DNS dropped, killing WireGuard and Hysteria2.
- **Active probing** — censors connect to suspected proxy servers to verify they're running proxy software.
- **Throttling** — connections not outright blocked but throttled to unusable speeds.

MoaV's approach: run everything. Each protocol exploits a different gap in the censor's capabilities.

| Censorship method | MoaV counter |
|---|---|
| Protocol blocking | Reality mimics legitimate TLS to approved sites |
| UDP blocking | WireGuard tunneled through WebSocket (TCP) |
| IP blocking | CDN mode routes through Cloudflare's network |
| DPI on SNI | TrustTunnel looks like regular HTTPS traffic |
| Total shutdown | DNS tunnels work when only DNS is allowed |
| Active probing | Shadowsocks-2022 AEAD ciphers resist probes; decoy site serves innocent content |
| Throttling | Hysteria2's QUIC maximizes throughput on constrained links |

You don't know which protocol will survive the next shutdown. Neither does the censor. Running all of them is not inefficient — it's the point. See [Supported Protocols](protocols.md) for the full list.

## The Internet Is Closing

In January 2026, Iran went dark.

Not throttled. Not partially blocked. Dark. International connectivity dropped to near zero for days. The only network that kept running was the National Information Network — the domestic intranet Iran had been quietly building for exactly this scenario. External internet: off. Internal surveillance: intact.

The confirmed death toll from the protests that triggered the blackout is somewhere between 30,000 and 70,000. The number is disputed because during a total blackout, there is no one left to document it in real time. That is the point.

This wasn't the first time. In 2019, Iran killed the internet for a week during fuel protests. In 2022, they tried less successfully to go dark during the Woman, Life, Freedom movement. By 2026 the state had learned.

Traffic into Iran has since reached about 60% of pre-January levels. Internet-traffic analyst Doug Madory at Kentik describes the pattern as "erratic" partial restoration — "we do not know what internet will look like in the long run." When connectivity trickled back, VPN demand in Iran surged **934% in a single day**.

The demand had been building the entire time. It just had nowhere to go.

## A Global Pattern

Iran is not alone. Every time a government restricts connectivity, the response is the same — millions of people immediately try to route around it, and most of them don't know how.

- **Uganda**, January 2026 elections: VPN demand spiked **2,557%** after social platforms were blocked.
- **Nepal**, September 2025: peaked at **2,892%** when social media was banned.
- **United Kingdom**, July 2025: age-verification rollout drove a single-day spike of **1,987%**.
- **Myanmar**, February 2021: the military cut the internet hours after the coup. Mobile first. Then broadband. Then only a few whitelisted ports.
- **Russia**, post-February 2022: didn't cut the internet — they blocked the tools used to circumvent their filtering. Psiphon. Tor. Signal. The lesson: you don't have to turn off the internet to control it; you just have to make resistance unusable.
- **China**: two decades of the Great Firewall. Protocol after protocol identified, fingerprinted, blocked. VPN vendors in a permanent arms race.

And the laws that seem unthinkable right now keep becoming law in democracies. The EU's Chat Control proposal would mandate client-side scanning of encrypted messages. France has proposed banning end-to-end encryption for apps used to coordinate "criminal" activity. The UK Online Safety Act gives regulators the power to demand backdoors. The infrastructure that keeps communication free in Iran is the same infrastructure that will matter in Europe when those laws come into force.

## The Arms Race Gets Creative

One of the things that gives us hope — and that governments consistently underestimate — is the ingenuity of people building tools to stay connected under pressure.

Every censorship technique creates its own workaround. Block VPN protocols, developers build obfuscated ones. Block obfuscated VPNs, they route through CDNs too large to block. Block CDNs, they build DNS tunnels. Block DNS, and you break your own country's domestic internet.

But the creativity doesn't stop at DNS:

- **[BaleVPN](https://github.com/kookoo1sabzy/BaleVPN)** routes traffic through Bale — Iran's officially approved video-call platform. The tunnel encodes IP traffic as what looks like a Bale voice call. To the network, an approved domestic app doing approved domestic things. To the user, internet access. The government built the infrastructure for its own circumvention.
- **[GooseRelay](protocols.md#gooserelay)** (shipped natively in MoaV) routes traffic through Google Apps Script. To the censor, an HTTPS request to a Google Workspace serverless function used by millions of businesses. Blocking GooseRelay means blocking Apps Script globally, which means breaking every company and university using it in the country. The cost of the block exceeds the benefit.
- **[SNI Spoofing](https://github.com/aleskxyz/SNI-Spoofing-Go)** exploits a different seam — the unencrypted hostname in the TLS handshake. A local proxy sends a fake ClientHello with a decoy hostname (say, `microsoft.com`) while the real connection continues underneath. The DPI box sees something benign; the traffic gets through.

The censor's playbook has a finite number of pages. The circumvention community keeps adding new chapters.

## You Are Donating Bandwidth (Or You Could Be)

Three of the donation paths MoaV bundles are not for you. They are for everyone else.

**[Psiphon Conduit](https://psiphon.ca)** turns your server into a relay node for Psiphon users — people who can't reach the app directly and need a trusted intermediary. Psiphon has tens of millions of users in Iran, Russia, Belarus, Venezuela, and dozens of other censored countries. Your VPS becomes part of the network they depend on.

**[Tor Snowflake](https://snowflake.torproject.org/)** does the same for Tor. Your server becomes a Tor bridge — a relay that Tor users can connect to when the public ones are blocked. You're not an exit node; you're handling the first step for someone who otherwise can't reach the network at all.

**[MahsaNet](mahsanet.md)** is the MahsaNG peer network — and it's worth understanding what makes it different. It's not just a relay pool, it's a distribution channel. When you donate your server config to MahsaNet, you're publishing your server's address and credentials to a network that MahsaNG users can query directly from the app. No diaspora contact required. No Telegram group to find. The app discovers your server automatically, the moment it's needed. MahsaNG has its own distribution infrastructure that already reaches the 2 million+ people using the app.

The marginal cost is bandwidth — a few dollars a month at most on a standard VPS plan. The marginal impact is someone being able to say they're alive.

## Iran's Shutdown History

Iran's censorship infrastructure operates at multiple layers: the National Information Network (NIN, the domestic intranet), Deep Packet Inspection at major peering points, protocol whitelisting during heavy periods (only ports 53/80/443 permitted), active probing of suspected proxy servers, and throttling that maintains the appearance of connectivity while making it unusable.

The chronology that shaped MoaV's design:

- **November 2019** — near-total internet shutdown during fuel-price protests. Amnesty International documented at least 304 deaths; other estimates are significantly higher. The shutdown prevented documentation of events and coordination of emergency response.
- **September 2022 – 2023: Woman, Life, Freedom** — following Mahsa (Jina) Amini's death in morality-police custody, nationwide protests met months of internet disruption: WhatsApp/Instagram/Signal blocked, international bandwidth throttled to near-unusable levels, VPN protocols systematically identified and DPI-blocked, Starlink jammed in some areas. Hundreds killed, thousands arrested.
- **January 2026** — the multi-day nationwide blackout described above. International connectivity to near zero. Only the NIN remained functional. Casualty estimates: 30,000–70,000.
- **February – March 2026** — continued disruptions amid regional tensions. Protocol-level blocking intensified, with authorities expanding DPI capabilities to target newer circumvention tools.
- **May 2026** — partial restoration to ~60% of baseline; erratic, unstable. The pattern that suggests the next shutdown is being planned.

## The Window Is Open. It Won't Stay That Way.

This is the trap. The state allows a partial reopening after protests wind down — enough for people to feel like things are normalizing, enough to seem like the isolation was temporary. Meanwhile, everything the government learned about circumvention tool usage during a blackout goes into improving the next one. Which DNS resolvers kept working. Which protocols leaked through. Which apps people used when everything else was blocked.

That data is now in the hands of the people planning the next shutdown.

The time to build capacity is not during the shutdown. During a shutdown, new server deployments can't reach the people who need them. Domain names can't be shared through a blocked internet. Configuration files can't be distributed when the distribution channels are offline.

**The servers that matter in the next crisis are the ones being deployed right now, while the window is open.**

## The Argument in One Line

Every time a government has tried to cut the internet completely, they've proven why distributed infrastructure matters. And every time, the people who kept the connections alive were engineers and activists who had set up their servers before the crisis — not during it.

We can be those people. Not as a political statement, not as an act of heroism — as a practical decision, made now, that runs in the background and serves people we'll never know.

That's how infrastructure works.

## Contributing

If you have a VPS and want to help:

1. **[Deploy MoaV](quick-start.md)** and share access with people who need it.
2. **[Enable Conduit](SETUP.md#bandwidth-donation-conduit--snowflake)** to relay bandwidth for Psiphon users worldwide.
3. **[Enable Snowflake](SETUP.md#bandwidth-donation-conduit--snowflake)** to relay bandwidth for Tor users.
4. **[Donate configs to MahsaNet](mahsanet.md)** so 2M+ MahsaNG users discover your server automatically.
5. **[Contribute code](https://github.com/shayanb/MoaV)** — fix bugs, add protocols, improve documentation.

## Sources & Further Reading

Numbers and events cited above:

- Iran shutdown timeline, NIN architecture: [NetBlocks](https://netblocks.org/), [Access Now Shutdown Tracker](https://www.accessnow.org/keepiton/)
- Iran 934% VPN demand surge (May 2026), Uganda 2,557% (Jan 2026), Nepal 2,892% (Sep 2025), UK 1,987% (Jul 2025): [Top10VPN demand statistics](https://www.top10vpn.com/research/vpn-demand-statistics/)
- Iran 60% restoration analysis: Doug Madory / [Kentik](https://www.kentik.com/), May 2026
- Mahsa Amini protests: Amnesty International reports, 2022–2023
- BaleVPN — TCP over Bale voice calls: [github.com/kookoo1sabzy/BaleVPN](https://github.com/kookoo1sabzy/BaleVPN)
- SNI Spoofing Go — local proxy sending decoy ClientHello: [github.com/aleskxyz/SNI-Spoofing-Go](https://github.com/aleskxyz/SNI-Spoofing-Go)
