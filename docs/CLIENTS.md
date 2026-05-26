# Client Setup Guide

This guide explains how to connect to MoaV from various devices.

## Table of Contents

- [Quick Reference](#quick-reference)
  - [Protocol Support](#protocol-support-by-port)
  - [Client Apps](#client-apps)
- [Protocol Priority](#protocol-priority)
- [MoaV Client Container (Linux/Docker)](#moav-client-container-linuxdocker)
- [iOS Setup](#ios-setup)
- [Android Setup](#android-setup)
- [macOS Setup](#macos-setup)
- [Windows Setup](#windows-setup)
- [WireGuard Setup](#wireguard-setup)
- [AmneziaWG Setup](#amneziawg-setup)
- [Hysteria2 Setup](#hysteria2-setup)
- [CDN VLESS+WS Setup (When IP Blocked)](#cdn-vlessws-setup-when-ip-blocked)
- [TrustTunnel Setup](#trusttunnel-setup)
- [DNS Tunnel Setup (Last Resort)](#dns-tunnel-setup-last-resort)
- [Psiphon Setup](#psiphon-setup)
- [About Psiphon Conduit (Server Feature)](#about-psiphon-conduit-server-feature)
- [About Tor Snowflake (Server Feature)](#about-tor-snowflake-server-feature)
- [Troubleshooting](#troubleshooting)
- [Tips for Highly Censored Environments](#tips-for-highly-censored-environments)
- [Connection Optimization (Fragment & MUX)](#connection-optimization-fragment--mux)

---

## Quick Reference

### Protocol Support by Port

| Protocol | Port | Description |
|----------|------|-------------|
| [Reality (VLESS)](https://github.com/XTLS/REALITY) | 443/tcp | TLS camouflage, virtually undetectable |
| [Trojan](https://trojan-gfw.github.io/trojan/) | 8443/tcp | HTTPS mimicry, battle-tested |
| [Shadowsocks-2022](https://github.com/shadowsocks/shadowsocks-org/blob/main/docs/doc/sip022.md) | 8388/tcp+udp | AEAD-2022 anti-active-probing; same protocol Outline VPN uses |
| [Hysteria2](https://v2.hysteria.network/) | 443/udp | QUIC-based, fast on lossy networks |
| CDN (VLESS+WS) | 443 via Cloudflare | When server IP is blocked |
| [TrustTunnel](https://trusttunnel.org/) | 4443/tcp+udp | HTTP/2 & QUIC, looks like HTTPS |
| [WireGuard](https://www.wireguard.com/) (Direct) | 51820/udp | Full VPN mode, simple setup |
| [AmneziaWG](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module) | 51821/udp | Obfuscated WireGuard, defeats DPI |
| [WireGuard](https://www.wireguard.com/) + [wstunnel](https://github.com/erebe/wstunnel) | 8080/tcp | VPN wrapped in WebSocket |
| [DNS Tunnel (dnstt)](https://www.bamsoftware.com/software/dnstt/) | 53/udp | Last resort, slow but hard to block |
| [Slipstream](https://github.com/Mygod/slipstream-rust) | 53/udp | QUIC-over-DNS, 1.5-5x faster than dnstt |
| [Telegram MTProxy](https://github.com/telemt/telemt) | 993/tcp | Fake-TLS V2, direct Telegram access |
| [XHTTP (VLESS+XHTTP+Reality)](https://github.com/XTLS/Xray-core) | 2096/tcp | XHTTP transport with Reality TLS, experimental |
| [Psiphon](https://psiphon.ca/) | Various | Standalone app, uses Psiphon network |
| [Tor](https://www.torproject.org/) (Snowflake) | Various | Uses Tor network |

### Client Apps

#### iOS

| App | Protocols | Link |
|-----|-----------|------|
| [Shadowrocket](https://apps.apple.com/us/app/shadowrocket/id932747118) | VLESS, VMess, Trojan, Hysteria2, WireGuard | [App Store ($2.99)](https://apps.apple.com/us/app/shadowrocket/id932747118) |
| [Streisand](https://apps.apple.com/us/app/streisand/id6450534064) | VLESS/Reality, VMess, Trojan, Hysteria2, WireGuard | [App Store (Free)](https://apps.apple.com/us/app/streisand/id6450534064) |
| [Hiddify](https://apps.apple.com/us/app/hiddify-proxy-vpn/id6596777532) | VLESS, VMess, Hysteria2, Trojan, Reality, SSH | [App Store (Free)](https://apps.apple.com/us/app/hiddify-proxy-vpn/id6596777532) |
| [V2Box](https://apps.apple.com/ca/app/v2box-v2ray-client/id6446814690) | VLESS, VMess, Trojan, Hysteria2, Reality | [App Store](https://apps.apple.com/ca/app/v2box-v2ray-client/id6446814690) |
| [sing-box](https://apps.apple.com/us/app/sing-box-vt/id6673731168) | VLESS, VMess, Trojan, Hysteria2, WireGuard | [App Store (Free)](https://apps.apple.com/us/app/sing-box-vt/id6673731168) |
| [Loon](https://apps.apple.com/us/app/loon/id1373567447) | VLESS/Reality, Hysteria2, Trojan, WireGuard | [App Store](https://apps.apple.com/us/app/loon/id1373567447) |
| [Pharos Pro](https://apps.apple.com/us/app/pharos-pro/id1456610173) | VLESS, Hysteria2, Trojan, TUIC | [App Store ($2.99)](https://apps.apple.com/us/app/pharos-pro/id1456610173) |
| [Onion Browser](https://apps.apple.com/us/app/onion-browser/id519296448) | Tor | [App Store (Free)](https://apps.apple.com/us/app/onion-browser/id519296448) |
| [Psiphon](https://apps.apple.com/us/app/psiphon-vpn-freedom-online/id1276263909) | Psiphon | [App Store (Free)](https://apps.apple.com/us/app/psiphon-vpn-freedom-online/id1276263909) |
| [WireGuard](https://apps.apple.com/us/app/wireguard/id1441195209) | WireGuard | [App Store (Free)](https://apps.apple.com/us/app/wireguard/id1441195209) |
| [AmneziaWG](https://apps.apple.com/app/amneziawg/id6478942365) | AmneziaWG | [App Store (Free)](https://apps.apple.com/app/amneziawg/id6478942365) |
| [TrustTunnel](https://apps.apple.com/app/trusttunnel/id6478890498) | TrustTunnel | [App Store (Free)](https://apps.apple.com/app/trusttunnel/id6478890498) |

#### Android

| App | Protocols | Link |
|-----|-----------|------|
| [v2rayNG](https://github.com/2dust/v2rayNG) | VLESS, VMess, Trojan, Shadowsocks | [GitHub](https://github.com/2dust/v2rayNG/releases) |
| [Hiddify](https://hiddify.com/) | VLESS, VMess, Hysteria2, Trojan, Reality, SSH | [GitHub](https://github.com/hiddify/hiddify-app/releases) |
| [NekoBox](https://github.com/MatsuriDayo/NekoBoxForAndroid) | VLESS, VMess, Trojan, Hysteria2 (sing-box) | [GitHub](https://github.com/MatsuriDayo/NekoBoxForAndroid/releases) |
| [V2Box](https://play.google.com/store/apps/details?id=dev.hexasoftware.v2box) | VLESS, VMess, Trojan, Hysteria2, Reality | [Play Store](https://play.google.com/store/apps/details?id=dev.hexasoftware.v2box) |
| [sing-box](https://github.com/SagerNet/sing-box) | VLESS, VMess, Trojan, Hysteria2, WireGuard | [F-Droid](https://f-droid.org/packages/io.nekohasekai.sfa/) / [GitHub](https://github.com/SagerNet/sing-box/releases) |
| [HTTP Injector](https://play.google.com/store/apps/details?id=com.evozi.injector) | VLESS, Hysteria, DNS Tunnel, WireGuard, SSH | [Play Store](https://play.google.com/store/apps/details?id=com.evozi.injector) |
| [Clash Meta](https://github.com/MetaCubeX/ClashMetaForAndroid) | VLESS, VMess, Hysteria2, Trojan | [GitHub](https://github.com/MetaCubeX/ClashMetaForAndroid/releases) |
| [Tor Browser](https://www.torproject.org/download/) | Tor | [Play Store](https://play.google.com/store/apps/details?id=org.torproject.torbrowser) / [Official](https://www.torproject.org/download/) |
| [Psiphon](https://psiphon.ca/) | Psiphon | [Play Store](https://play.google.com/store/apps/details?id=com.psiphon3) / [APK](https://psiphon.ca/en/download.html) |
| [WireGuard](https://www.wireguard.com/) | WireGuard | [Play Store](https://play.google.com/store/apps/details?id=com.wireguard.android) |
| [AmneziaWG](https://play.google.com/store/apps/details?id=org.amnezia.awg) | AmneziaWG | [Play Store](https://play.google.com/store/apps/details?id=org.amnezia.awg) |
| [TrustTunnel](https://trusttunnel.org/) | TrustTunnel | [Play Store](https://play.google.com/store/apps/details?id=org.trusttunnel.app) / [GitHub](https://github.com/TrustTunnel/TrustTunnelClient) |

#### Windows

| App | Protocols | Link |
|-----|-----------|------|
| [v2rayN](https://github.com/2dust/v2rayN) | VLESS, VMess, Trojan, Hysteria2, TUIC | [GitHub](https://github.com/2dust/v2rayN/releases) |
| [Hiddify](https://hiddify.com/) | VLESS, VMess, Hysteria2, Trojan, Reality | [GitHub](https://github.com/hiddify/hiddify-app/releases) |
| [NekoRay](https://github.com/MatsuriDayo/nekoray) | VLESS, VMess, Trojan, Hysteria2 (sing-box) | [GitHub](https://github.com/MatsuriDayo/nekoray/releases) ¹ |
| [Mihomo Party](https://github.com/mihomo-party-org/mihomo-party) | VLESS, VMess, Hysteria2, Trojan | [GitHub](https://github.com/mihomo-party-org/mihomo-party/releases) |
| [Clash Verge](https://github.com/clash-verge-rev/clash-verge-rev) | VLESS, VMess, Hysteria2, Trojan | [GitHub](https://github.com/clash-verge-rev/clash-verge-rev/releases) |
| [Tor Browser](https://www.torproject.org/download/) | Tor | [Official](https://www.torproject.org/download/) |
| [Psiphon](https://psiphon.ca/) | Psiphon | [Official](https://psiphon.ca/en/download.html) |
| [WireGuard](https://www.wireguard.com/) | WireGuard | [Official](https://www.wireguard.com/install/) |
| [AmneziaWG](https://github.com/amnezia-vpn/amneziawg-windows-client/releases) | AmneziaWG | [GitHub](https://github.com/amnezia-vpn/amneziawg-windows-client/releases) |
| [TrustTunnel](https://trusttunnel.org/) | TrustTunnel | [GitHub](https://github.com/TrustTunnel/TrustTunnelClient/releases) |

#### macOS

| App | Protocols | Link |
|-----|-----------|------|
| [Streisand](https://apps.apple.com/us/app/streisand/id6450534064) | VLESS/Reality, VMess, Trojan, Hysteria2, WireGuard | [App Store (Free)](https://apps.apple.com/us/app/streisand/id6450534064) |
| [v2rayN](https://github.com/2dust/v2rayN) | VLESS, VMess, Trojan, Hysteria2 | [GitHub](https://github.com/2dust/v2rayN/releases) |
| [Hiddify](https://hiddify.com/) | VLESS, VMess, Hysteria2, Trojan, Reality | [GitHub](https://github.com/hiddify/hiddify-app/releases) |
| [NekoRay](https://github.com/MatsuriDayo/nekoray) | VLESS, VMess, Trojan, Hysteria2 (sing-box) | [GitHub](https://github.com/MatsuriDayo/nekoray/releases) ¹ |
| [Clash Verge](https://github.com/clash-verge-rev/clash-verge-rev) | VLESS, VMess, Hysteria2, Trojan | [GitHub](https://github.com/clash-verge-rev/clash-verge-rev/releases) |
| [sing-box](https://sing-box.sagernet.org/) | VLESS, VMess, Trojan, Hysteria2, WireGuard | [Homebrew](https://formulae.brew.sh/formula/sing-box) / [GitHub](https://github.com/SagerNet/sing-box) |
| [Tor Browser](https://www.torproject.org/download/) | Tor | [Official](https://www.torproject.org/download/) |
| [Psiphon](https://psiphon.ca/) | Psiphon | [App Store (Apple Silicon)](https://apps.apple.com/us/app/psiphon/id1276263909) |
| [WireGuard](https://www.wireguard.com/) | WireGuard | [App Store](https://apps.apple.com/us/app/wireguard/id1451685025) |
| [AmneziaWG](https://apps.apple.com/app/amneziawg/id6478942365) | AmneziaWG | [App Store](https://apps.apple.com/app/amneziawg/id6478942365) |
| [TrustTunnel](https://trusttunnel.org/) | TrustTunnel | [GitHub](https://github.com/TrustTunnel/TrustTunnelClient/releases) |

#### Linux

| App | Protocols | Link |
|-----|-----------|------|
| [Hiddify](https://hiddify.com/) | VLESS, VMess, Hysteria2, Trojan, Reality | [GitHub](https://github.com/hiddify/hiddify-app/releases) |
| [v2rayN](https://github.com/2dust/v2rayN) | VLESS, VMess, Trojan, Hysteria2 | [GitHub](https://github.com/2dust/v2rayN/releases) |
| [sing-box](https://sing-box.sagernet.org/) | VLESS, VMess, Trojan, Hysteria2, WireGuard, DNS | [GitHub](https://github.com/SagerNet/sing-box) |
| [Clash Verge](https://github.com/clash-verge-rev/clash-verge-rev) | VLESS, VMess, Hysteria2, Trojan | [GitHub](https://github.com/clash-verge-rev/clash-verge-rev/releases) |
| [Mihomo Party](https://github.com/mihomo-party-org/mihomo-party) | VLESS, VMess, Hysteria2, Trojan | [GitHub](https://github.com/mihomo-party-org/mihomo-party/releases) |
| [Tor Browser](https://www.torproject.org/download/) | Tor | [Official](https://www.torproject.org/download/) |
| [WireGuard](https://www.wireguard.com/) | WireGuard | [Official](https://www.wireguard.com/install/) |
| [AmneziaWG](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module) | AmneziaWG | `awg-quick` CLI (awg-tools) |
| [TrustTunnel](https://trusttunnel.org/) | TrustTunnel | [GitHub](https://github.com/TrustTunnel/TrustTunnelClient/releases) |
| **MoaV Client** | All MoaV protocols | Built-in (Docker) |

¹ NekoRay: Repository notes it is no longer actively maintained. Consider alternatives like Hiddify or Clash Verge.

**Notes:**
- Psiphon is not available via MoaV client - use [official Psiphon apps](https://psiphon.ca/download.html)
- iOS has no official Tor Browser; use [Onion Browser](https://apps.apple.com/us/app/onion-browser/id519296448) instead (Tor Project recommended)
- Psiphon for Linux is not officially available

## Protocol Priority

Try these in order. If one doesn't work, try the next:

1. **Reality (VLESS)** - Primary, most reliable (port 443/tcp)
2. **Hysteria2** - Fast alternative, uses QUIC/UDP (port 443/udp)
3. **Trojan** - Backup, uses your domain's TLS cert (port 8443/tcp)
4. **CDN (VLESS+WS)** - When server IP is blocked, routes via Cloudflare (port 443 via CDN)
5. **TrustTunnel** - HTTP/2 & QUIC, looks like normal HTTPS (port 4443)
6. **WireGuard (Direct)** - Full VPN mode, simple setup (port 51820/udp)
7. **WireGuard (wstunnel)** - VPN wrapped in WebSocket, for restrictive networks (port 8080/tcp)
8. **Tor (Snowflake)** - Uses Tor network (no server needed)
9. **DNS Tunnel (dnstt)** - Last resort, very slow but hard to block (port 53/udp)
10. **Slipstream** - QUIC-over-DNS, 1.5-5x faster than dnstt (port 53/udp)
11. **Psiphon** - Standalone app only, uses Psiphon network (not via MoaV client)

**Telegram-specific:** Use the **Telegram MTProxy** link (in `telegram-proxy-link.txt`) directly in the Telegram app. This only works for Telegram traffic — it's not a general proxy.

---

## MoaV Client Container (Linux/Docker)

MoaV includes a built-in multi-protocol client container. This is useful for:
- Testing server connectivity from another machine
- Running MoaV as a client on Linux servers/desktops
- Automated testing in CI/CD pipelines
- Connecting through your MoaV server from a Docker environment

### Testing Connectivity

Test all protocols for a user to verify server is working:

```bash
# Test all protocols for user1
moav test user1

# Output results as JSON (for scripts/automation)
moav test user1 --json
```

The test checks: Reality, Trojan, Hysteria2, WireGuard (config validation), dnstt, and Slipstream.

**Sample output:**
```
═══════════════════════════════════════════════════════════════
  MoaV Connection Test Results
═══════════════════════════════════════════════════════════════

  Config: /bundles/user1
  Time:   Wed Jan 28 10:30:00 UTC 2026

───────────────────────────────────────────────────────────────
  ✓ reality      Connected via VLESS/Reality
  ✓ trojan       Connected via Trojan
  ✓ hysteria2    Connected via Hysteria2
  ✓ wireguard    Config valid, endpoint reachable
  ○ dnstt        No dnstt config found in bundle

═══════════════════════════════════════════════════════════════
```

### Client Mode (Connect Through Server)

Run MoaV as a local proxy client:

```bash
# Auto-detect best working protocol
moav client connect user1

# Force a specific protocol
moav client connect user1 --protocol reality
moav client connect user1 --protocol hysteria2
moav client connect user1 --protocol trojan
moav client connect user1 --protocol wireguard
moav client connect user1 --protocol dnstt
moav client connect user1 --protocol tor
```

**Local proxy endpoints:**
- SOCKS5: `127.0.0.1:1080`
- HTTP: `127.0.0.1:8080`

Configure these ports in `.env`:
```bash
CLIENT_SOCKS_PORT=1080
CLIENT_HTTP_PORT=8080
```

**Protocol fallback order (auto mode):**
1. Reality (VLESS) - Most reliable
2. Hysteria2 - Fast, UDP-based
3. Trojan - TLS-based backup
4. WireGuard - Full VPN
5. Tor (Snowflake) - Uses Tor network (no server needed)
6. dnstt - Last resort, slow but hard to block

> **Note:** Psiphon is not available via MoaV client. Use the [official Psiphon apps](https://psiphon.ca/en/download.html) instead.

### Building the Client Image

The client image is built automatically when running `moav test` or `moav client`. To build manually:

```bash
moav client build
```

### Technical Details

The client container includes:
- **sing-box** - Handles Reality, Trojan, Hysteria2
- **wireguard-go** - Userspace WireGuard implementation
- **wstunnel** - WebSocket tunnel for WireGuard
- **dnstt-client** - DNS tunnel client
- **snowflake-client** - Tor Snowflake pluggable transport
- **tor** - Tor daemon

**Container capabilities:**
- Runs without privileged mode for most protocols
- WireGuard requires `--cap-add NET_ADMIN` for full functionality
- Uses Alpine Linux for minimal image size

---

## iOS Setup

### Shadowrocket (Recommended, $2.99)

The best all-in-one client for iOS.

**Download:** App Store (requires non-IR Apple ID)

**Import via QR Code:**
1. Open Shadowrocket
2. Tap the scanner icon (top-left)
3. Scan the QR code from your bundle (`reality-qr.png`)
4. Tap "Add" to save

**Import via Link:**
1. Copy the link from `reality.txt`
2. Open Shadowrocket
3. It auto-detects and asks to add - tap "Add"

**Import via Config File:**
1. AirDrop or share `reality-singbox.json` to your phone
2. Open with Shadowrocket
3. Import and save

**Connect:**
1. Toggle the switch ON
2. Allow VPN configuration when prompted
3. You're connected!

### Streisand (Free)

Good free alternative.

**Download:** App Store

**Setup:**
1. Open Streisand
2. Tap "+" to add server
3. Choose "Import from clipboard"
4. Paste the link from `reality.txt`

### Hiddify (Free, Iran-focused)

Specifically designed for Iran.

**Download:** App Store or https://hiddify.com

**Setup:**
1. Open Hiddify
2. Tap "Add Profile"
3. Paste or scan your Reality link

---

## Android Setup

### v2rayNG (Recommended, Free)

**Download:**
- Google Play: "v2rayNG"
- GitHub: https://github.com/2dust/v2rayNG/releases

**Import via QR Code:**
1. Open v2rayNG
2. Tap "+" button
3. Select "Import config from QRcode"
4. Scan `reality-qr.png`

**Import via Link:**
1. Copy link from `reality.txt`
2. Open v2rayNG
3. Tap "+" → "Import config from clipboard"

**Connect:**
1. Tap the server to select it
2. Tap the "V" button at bottom to connect
3. Allow VPN permission

### NekoBox (Free, sing-box based)

More advanced, uses sing-box core.

**Download:** GitHub: https://github.com/MatsuriDayo/NekoBoxForAndroid/releases

**Setup:**
1. Open NekoBox
2. Tap "+" → "Import from clipboard"
3. Paste your Reality link
4. Or import `reality-singbox.json` directly

### Hiddify (Free)

**Download:** https://hiddify.com or GitHub

**Setup:**
1. Open Hiddify
2. Add profile via link or QR code

---

## macOS Setup

### V2rayU (Free)

**Download:** https://github.com/yanue/V2rayU/releases

**Setup:**
1. Install and open V2rayU
2. Click menu bar icon → "Import"
3. Paste your Reality link
4. Click "Turn v2ray-core On"

### NekoRay (Free)

Cross-platform GUI client.

**Download:** https://github.com/MatsuriDayo/nekoray/releases

**Setup:**
1. Install and open NekoRay
2. Server → Add profile from clipboard
3. Paste your Reality link

### Command Line (sing-box)

For advanced users:

```bash
# Install sing-box
brew install sing-box

# Run with config
sing-box run -c reality-singbox.json
```

---

## Windows Setup

### v2rayN (Free)

**Download:** https://github.com/2dust/v2rayN/releases

**Setup:**
1. Extract and run v2rayN.exe
2. Click "Server" → "Add [VLESS]"
3. Or paste link: "Server" → "Import from clipboard"
4. Click "System Proxy" → "Set Global Proxy"

### NekoRay (Free)

Same as macOS version.

**Download:** https://github.com/MatsuriDayo/nekoray/releases

---

## WireGuard Setup

MoaV provides two WireGuard connection methods:

- **Direct Mode** (`wireguard.conf`) - Simple, fast, uses UDP port 51820
- **wstunnel Mode** (`wireguard-wstunnel.conf`) - Wrapped in WebSocket, uses TCP port 8080, for networks that block UDP

### Direct Mode (Recommended)

Use this when UDP traffic is allowed. Simple and fast.

**Your config file:** `wireguard.conf`

#### iOS / Android

1. Install "WireGuard" from App Store / Play Store
2. Tap "+" → "Create from QR code"
3. Scan `wireguard-qr.png`
4. Name it (e.g., "MoaV WG")
5. Toggle ON to connect

#### macOS / Windows / Linux

1. Install WireGuard from https://wireguard.com/install/
2. Click "Import tunnel(s) from file"
3. Select `wireguard.conf`
4. Click "Activate"

### wstunnel Mode (For Restrictive Networks)

Use this when UDP is blocked or heavily throttled. Wraps WireGuard in a WebSocket tunnel.

**Your config file:** `wireguard-wstunnel.conf`

#### Requirements

You need both WireGuard and wstunnel client:
- WireGuard: https://wireguard.com/install/
- wstunnel: https://github.com/erebe/wstunnel/releases

#### macOS / Linux Setup

```bash
# 1. Download wstunnel from GitHub releases
# https://github.com/erebe/wstunnel/releases

# 2. Start wstunnel client (connect to server's port 8080)
wstunnel client -L udp://127.0.0.1:51820:127.0.0.1:51820 ws://YOUR_SERVER_IP:8080

# 3. In another terminal, import WireGuard config
# The config points to 127.0.0.1:51820 (local wstunnel)
sudo wg-quick up ./wireguard-wstunnel.conf
```

#### Windows Setup

1. Download wstunnel.exe from GitHub releases
2. Open PowerShell/CMD and run:
   ```
   wstunnel.exe client -L udp://127.0.0.1:51820:127.0.0.1:51820 ws://YOUR_SERVER_IP:8080
   ```
3. Keep this running
4. Import `wireguard-wstunnel.conf` in WireGuard app
5. Activate the tunnel

#### iOS / Android (Advanced)

wstunnel on mobile requires additional apps or rooted devices. For most users, try other protocols (Reality, Hysteria2) instead if direct WireGuard is blocked.

**Note:** Replace `YOUR_SERVER_IP` with your actual server IP address.

---

## AmneziaWG Setup

AmneziaWG is a DPI-resistant fork of WireGuard that obfuscates packet headers and sizes to bypass deep packet inspection.

**Your config files:**
- `amneziawg.conf` - AmneziaWG client configuration (includes obfuscation parameters)

### Mobile Apps (iOS/Android)
1. Install **AmneziaWG** ([iOS](https://apps.apple.com/app/amneziawg/id6478942365) / [Android](https://play.google.com/store/apps/details?id=org.amnezia.awg))
2. Tap "+" and scan the QR code or import `amneziawg.conf`
3. Enable the connection

### Desktop
- **Windows:** Download [AmneziaWG Client](https://github.com/amnezia-vpn/amneziawg-windows-client/releases), import `amneziawg.conf`
- **macOS:** Install [AmneziaWG](https://apps.apple.com/app/amneziawg/id6478942365) or use `awg-quick up amneziawg.conf`
- **Linux:** Use `awg-quick up amneziawg.conf` (included in awg-tools)

---

## Hysteria2 Setup

### Using Shadowrocket / v2rayNG

Both support Hysteria2 links. Import `hysteria2.txt` the same way as Reality.

### Using Hysteria2 CLI

For desktop:

```bash
# Download from https://github.com/apernet/hysteria/releases

# Run with config
./hysteria -c hysteria2.yaml
```

This creates a local proxy on:
- SOCKS5: `127.0.0.1:1080`
- HTTP: `127.0.0.1:8080`

Configure your browser/apps to use this proxy.

---

## CDN VLESS+WS Setup (When IP Blocked)

Use this when direct connections to your server are blocked but Cloudflare IPs are accessible.

**Your config file:** `cdn-vless.txt`

CDN mode routes your traffic through Cloudflare's CDN, making it appear as regular HTTPS traffic to a CDN-hosted website.

### Using Any VLESS Client

The CDN link works in any app that supports VLESS with WebSocket transport:

1. Copy the link from `cdn-vless.txt`
2. Import into your client app (Shadowrocket, v2rayNG, Hiddify, etc.)
3. Connect

**Link format:**
```
vless://UUID@cdn.yourdomain.com:443?security=tls&type=httpupgrade&path=/auto-generated-path&sni=yourdomain.com&host=cdn.yourdomain.com&fp=random&alpn=http/1.1#MoaV-CDN-username
```

### iOS (Shadowrocket)

1. Open Shadowrocket
2. Tap scanner icon → scan `cdn-vless-qr.png`
3. Or paste the link from `cdn-vless.txt`
4. Toggle ON to connect

### Android (v2rayNG / Hiddify)

1. Open v2rayNG or Hiddify
2. Tap "+" → "Import from clipboard"
3. Paste the link from `cdn-vless.txt`
4. Connect

**Note:** CDN mode is slower than direct connections but works when your server's IP is blocked.

---

## TrustTunnel Setup

TrustTunnel uses HTTP/2 and HTTP/3 (QUIC), making traffic look like regular HTTPS.

**Your config files:**
- `trusttunnel.txt` - Credentials and instructions
- `trusttunnel.toml` - CLI client configuration
- `trusttunnel.json` - JSON format for apps

### Mobile Apps (iOS/Android)

1. Download TrustTunnel from App Store or Play Store
2. Tap "+" to add a new VPN
3. Enter the settings from `trusttunnel.txt`:
   - Server: `yourdomain.com:4443`
   - Username: (from bundle)
   - Password: (from bundle)
4. Connect

### Desktop (CLI Client)

```bash
# Download from https://github.com/TrustTunnel/TrustTunnelClient/releases

# Run with config file
trusttunnel_client --config trusttunnel.toml
```

The CLI client creates a TUN interface for full VPN functionality.

---

## DNS Tunnel Setup (Last Resort)

Use this only when all other methods are blocked. DNS tunneling is slow but often works when everything else is blocked.

### dnstt

See `dnstt-instructions.txt` in your bundle for detailed steps.

**Summary:**
1. Download dnstt-client from https://www.bamsoftware.com/software/dnstt/
2. Run: `dnstt-client -doh https://1.1.1.1/dns-query -pubkey YOUR_KEY t.yourdomain.com 127.0.0.1:1080`
3. Configure apps to use SOCKS5 proxy `127.0.0.1:1080`

### Slipstream (Faster DNS Tunnel)

Slipstream is a QUIC-over-DNS tunnel that is 1.5-5x faster than dnstt. See `slipstream-instructions.txt` in your bundle.

**Summary:**
1. Download slipstream-client from https://github.com/net2share/slipstream-rust-build/releases
2. Copy the certificate file `slipstream-cert.pem` from your bundle
3. Run: `slipstream-client --domain s.yourdomain.com --cert slipstream-cert.pem --dns-server 1.1.1.1:53 --socks-listen 127.0.0.1:1080`
4. Configure apps to use SOCKS5 proxy `127.0.0.1:1080`

**Modes:**
- **Resolver mode** (default, stealthier): Uses public DNS resolvers (~60 KB/s)
- **Authoritative mode** (faster, less stealthy): Connects directly to server (~3-4 MB/s)

### XDNS (Xray mKCP DNS Tunnel)

XDNS encodes VPN traffic inside DNS-like packets using Xray-core's mKCP transport with FinalMask. Works when most protocols are blocked. Slow but reliable during heavy internet shutdowns — best for Telegram and chat apps, not web browsing.

**Important:** XDNS requires a client app with FinalMask support. Standard v2rayNG does not support this yet. Use Happ (Android beta) or Xray CLI.

**Setup:**
1. Find `xdns-config.json` in your user bundle
2. Import into an Xray-compatible client with FinalMask support
3. The config connects directly to the server IP on port 53
4. Use as SOCKS5 proxy: `127.0.0.1:7891`
5. **For Telegram:** Settings > Proxy > SOCKS5 > `127.0.0.1:7891`

**Tips:**
- Best for **Telegram only** — too slow for web browsing
- MTU 35 (default) is safest. Try 67 or 130 for faster speeds if your network allows
- MTU must match on both server and client
- All four DNS tunnels (dnstt, Slipstream, MasterDNS, XDNS) run simultaneously on port 53 — `dns-router` fans queries out by subdomain, so no conflict
- **Resolver choice matters.** The default `xdns-config.json` round-robins across multiple public DNS resolvers (set by `XDNS_RESOLVERS` in the server's `.env`); if it keeps dropping, swap in resolvers that actually answer from your network. See [protocols.md → Reachable DNS resolvers](protocols.md#reachable-dns-resolvers) for scanner tools ([findns](https://github.com/SamNet-dev/findns), [dns-mns](https://gitlab.com/E-Gurl/dns-mns)).

---

## Psiphon Setup

Psiphon is a standalone circumvention tool that doesn't require your own server. It connects to the Psiphon network - a large, distributed system designed for censorship circumvention.

**When to use Psiphon:**
- You don't have access to a MoaV server
- Your MoaV server is blocked
- You need a quick, no-setup solution

### iOS

1. Download "Psiphon" from App Store (requires non-IR Apple ID)
2. Open the app
3. Tap "Start" to connect
4. The app automatically finds working servers

### Android

1. Download from:
   - Google Play: "Psiphon"
   - Direct APK: https://psiphon.ca/en/download.html
2. Open the app
3. Tap "Start" to connect

### Windows

1. Download from https://psiphon.ca/en/download.html
2. Run the executable (no installation needed)
3. Click "Connect"
4. Configure browser to use the local proxy shown in the app

### macOS

1. Download from https://psiphon.ca/en/download.html
2. Open the app
3. Click "Connect"
4. Configure system or browser proxy settings

**Note:** Psiphon uses various protocols internally (SSH, OSSH, etc.) and automatically switches between them to find working connections.

---

## About Psiphon Conduit (Server Feature)

**Note:** Conduit is NOT a client connection method. It's a server-side feature.

If enabled on your MoaV server, Conduit donates a portion of your server's bandwidth to the [Psiphon network](https://psiphon.ca/), helping others in censored regions bypass restrictions. Psiphon is a well-established circumvention tool used by millions.

**For server operators:**
- Enable with the `conduit` profile: `docker compose --profile conduit up -d`
- Configure bandwidth limits via `CONDUIT_BANDWIDTH` in `.env`
- This is optional and purely for helping others

**For clients:**
- You don't connect via Conduit
- Use the other protocols (Reality, Hysteria2, Trojan, WireGuard) to connect to your MoaV server
- If you need Psiphon directly, download their app from https://psiphon.ca/

---

## About Tor Snowflake (Server Feature)

**Note:** Snowflake is NOT a client connection method. It's a server-side feature.

If enabled on your MoaV server, Snowflake acts as a proxy for the [Tor network](https://www.torproject.org/), helping users in censored regions connect to Tor. Snowflake is part of Tor's pluggable transports system.

**For server operators:**
- Enable with the `snowflake` profile: `docker compose --profile snowflake up -d`
- Configure limits in `.env`:
  - `SNOWFLAKE_BANDWIDTH=50` - Mbps limit (default: 50)
  - `SNOWFLAKE_CAPACITY=20` - Max concurrent clients (default: 20)
- This is optional and purely for helping others

**For clients:**
- You don't connect via Snowflake directly
- If you need Tor, download the Tor Browser from https://www.torproject.org/
- Tor Browser will automatically use Snowflake bridges when needed

**Can I run both Conduit and Snowflake?**
Yes! Both services can run simultaneously without conflicts. They donate bandwidth to different networks (Psiphon and Tor respectively).

---

## XHTTP Setup

XHTTP uses VLESS with XHTTP transport and Reality TLS camouflage, powered by Xray-core. No domain is required.

**Your config file:** `xhttp.txt`

### Compatible Client Apps

XHTTP requires Xray-based clients that support the XHTTP transport:

| Platform | App | Link |
|----------|-----|------|
| Android | [V2rayNG](https://github.com/2dust/v2rayNG) | [GitHub](https://github.com/2dust/v2rayNG/releases) |
| Android | [Hiddify](https://hiddify.com/) | [GitHub](https://github.com/hiddify/hiddify-app/releases) |
| Android | [NekoBox](https://github.com/MatsuriDayo/NekoBoxForAndroid) | [GitHub](https://github.com/MatsuriDayo/NekoBoxForAndroid/releases) |
| iOS | [Streisand](https://apps.apple.com/us/app/streisand/id6450534064) | [App Store (Free)](https://apps.apple.com/us/app/streisand/id6450534064) |
| iOS | [Hiddify](https://apps.apple.com/us/app/hiddify-proxy-vpn/id6596777532) | [App Store (Free)](https://apps.apple.com/us/app/hiddify-proxy-vpn/id6596777532) |
| iOS | [V2Box](https://apps.apple.com/ca/app/v2box-v2ray-client/id6446814690) | [App Store](https://apps.apple.com/ca/app/v2box-v2ray-client/id6446814690) |
| Windows | [V2rayN](https://github.com/2dust/v2rayN) | [GitHub](https://github.com/2dust/v2rayN/releases) |
| macOS | [V2rayU](https://github.com/yanue/V2rayU) | [GitHub](https://github.com/yanue/V2rayU/releases) |

### Import

1. Copy the link from `xhttp.txt`
2. Import into your client app (V2rayNG, Hiddify, Streisand, etc.)
3. Connect

**Note:** XHTTP is enabled by default. Disable with `ENABLE_XHTTP=false` in `.env` if not needed.

---

## Troubleshooting

### "Connection failed" or "Timeout"

1. Check your internet connection
2. Try a different protocol (Reality → Hysteria2 → Trojan)
3. Try a different DNS (1.1.1.1 or 8.8.8.8)
4. Restart the app

### "TLS handshake failed"

- Your ISP might be blocking the connection
- Try Hysteria2 (uses UDP instead of TCP)
- Try DNS tunnel as last resort

### "Certificate error"

- Check that your device's date/time is correct
- Try Reality protocol (doesn't use your domain's cert)

### Very slow connection

- Try Hysteria2 (optimized for lossy networks)
- Check if your ISP is throttling
- DNS tunnel is inherently slow - only for emergencies

### Nothing works

- The server IP might be blocked
- Contact admin for a new server/config
- Try using a different network (mobile data vs WiFi)

---

## Tips for Highly Censored Environments

1. **Keep multiple configs** - Have Reality, Hysteria2, WireGuard, XDNS, and DNS tunnel ready
2. **Download client apps in advance** - Store APKs, wstunnel binaries, and Psiphon offline
3. **Use mobile data** as backup - Sometimes less filtered than home internet
4. **Avoid peak hours** - Filtering can be heavier during protests/events
5. **Update configs quickly** - If server is blocked, switch to backup
6. **Try wstunnel if UDP is blocked** - Some ISPs block UDP; wstunnel wraps WireGuard in TCP/WebSocket
7. **Reality is often best** - Mimics legitimate HTTPS traffic to common sites
8. **Keep Psiphon as backup** - No server needed, works independently of your MoaV setup
9. **Enable TLS Fragment and MUX** - See below for client-side optimizations

---

## Connection Optimization (Fragment & MUX)

MoaV's generated sing-box configs already include optimal Fragment and MUX settings. If you're using third-party apps (Hiddify, v2rayNG, NekoBox, etc.) or importing via share links, you can enable these manually for better performance in censored networks.

### TLS Fragment

TLS Fragment splits the TLS ClientHello message into smaller pieces, making it harder for DPI (Deep Packet Inspection) systems to detect the SNI (Server Name Indication) and block the connection. This is a **client-side only** feature — no server changes needed.

**When to use:** When connections are being blocked or reset during the TLS handshake, which is common in Iran and similar environments.

**Which protocols benefit:**

| Protocol | Fragment | Why |
|----------|----------|-----|
| Reality (VLESS) | Yes | Hides SNI from DPI during TLS handshake |
| Trojan | Yes | Same — TLS-based, benefits from fragment |
| CDN (VLESS+WS) | No | TLS terminates at Cloudflare, not your server |
| Hysteria2 | No | Uses QUIC/UDP, not TCP-based TLS |
| WireGuard / AmneziaWG | No | Not TLS-based |

#### sing-box JSON Config

MoaV's generated configs already include this. If you're building your own config:

```json
{
  "outbounds": [
    {
      "type": "vless",
      "tls": {
        "enabled": true,
        "server_name": "example.com",
        "record_fragment": true
      }
    }
  ]
}
```

The `record_fragment` option (sing-box 1.12+) automatically splits TLS records. This is simpler than Xray-core's granular settings and works well for most scenarios.

#### Hiddify

1. Go to **Settings** → **Config Options**
2. Find **TLS Fragment** section
3. Enable it and set:
   - **Size**: `10-100` (bytes per fragment)
   - **Sleep**: `10-50` (ms delay between fragments)

#### v2rayNG

1. Go to **Settings** → **TLS/Reality**
2. Enable **TLS Fragment**
3. Recommended values:
   - **Length**: `50-200`
   - **Interval**: `10-50`
   - **Packets**: `1-3`

#### Shadowrocket

Shadowrocket does not currently support TLS Fragment. Use the sing-box app or Hiddify if you need this feature on iOS.

### MUX (Multiplexing)

MUX multiplexes multiple connections over a single TCP connection, reducing the number of TLS handshakes and making traffic patterns harder to fingerprint.

**When to use:** When you experience frequent connection drops or slow initial connections. Also useful to reduce the number of observable connections to the server.

**Which protocols benefit:**

| Protocol | MUX | Why |
|----------|-----|-----|
| Reality (VLESS) | No | Incompatible with VLESS Vision flow (`xtls-rprx-vision`) |
| Trojan | Yes | Reduces handshakes, improves stability |
| CDN (VLESS+WS) | Yes | Fewer WebSocket connections through CDN |
| Hysteria2 | No | QUIC already multiplexes natively |
| WireGuard / AmneziaWG | No | Not applicable |

> **Important:** MUX is **not compatible** with Reality (VLESS Vision). Enabling MUX on a Reality connection will break it. MoaV's generated configs handle this correctly.

#### sing-box JSON Config

MoaV's generated Trojan and CDN configs already include this:

```json
{
  "outbounds": [
    {
      "type": "trojan",
      "multiplex": {
        "enabled": true,
        "protocol": "h2mux",
        "max_connections": 2,
        "padding": true
      }
    }
  ]
}
```

- `protocol`: `h2mux` is recommended (HTTP/2 multiplexing)
- `max_connections`: `2` balances speed and stealth
- `padding`: `true` adds random padding to obscure traffic patterns

#### Hiddify

1. Go to **Settings** → **Config Options**
2. Find **MUX** section
3. Enable and set:
   - **Protocol**: `h2mux`
   - **Max Connections**: `2`
   - **Padding**: On

#### v2rayNG

1. Go to **Settings** → **MUX**
2. Enable **MUX**
3. Set **Concurrency**: `2-4`

### Summary: What to Enable Per Protocol

| Protocol | Fragment | MUX | Notes |
|----------|----------|-----|-------|
| Reality (VLESS) | Yes | **No** | Vision flow is incompatible with MUX |
| Trojan | Yes | Yes | Best with both enabled |
| CDN (VLESS+WS) | No | Yes | Fragment won't help (CDN terminates TLS) |
| Hysteria2 | No | No | QUIC handles both natively |
| WireGuard | No | No | Different protocol layer |
| AmneziaWG | No | No | Has its own obfuscation |

> **Note:** MoaV v1.3.7+ automatically includes these optimizations in generated sing-box JSON configs. If you import via share links (vless://, trojan://, hy2://), you may need to enable Fragment and MUX manually in your app settings.
