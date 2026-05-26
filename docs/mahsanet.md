# Importing MoaV configs into MahsaNG

[MahsaNG](https://github.com/GFW-knocker/MahsaNG) is a hardened V2RayNG fork
built for Iran (2M+ users). It speaks standard V2Ray protocols (VLESS, Trojan,
Shadowsocks, Hysteria2) plus extra anti-censorship transports, and adds
client-side circumvention (Fragment, fake-SNI, rotating configs). MoaV already
generates everything MahsaNG needs — this guide shows the fastest way to get a
user connected.

> **TL;DR:** `moav user mahsanet <username>` prints a base64 **subscription**,
> the individual **URIs**, and a **QR code** per config, and saves
> `mahsanet-sub.txt` / `mahsanet-uris.txt` into the user's bundle.

---

## 1. Install MahsaNG

- **Android (recommended):** download the latest APK from the
  [MahsaNG releases page](https://github.com/GFW-knocker/MahsaNG/releases)
  and install it (allow "install from unknown sources"). It is not on Google
  Play; only use the official GitHub releases.
- MahsaNG is Android-only. iOS/desktop users should use a standard V2Ray
  client (Streisand, Hiddify, v2rayN, NekoBox) with the same URIs — see
  [CLIENTS.md](CLIENTS.md).

Distribute the APK and configs over a channel the user can already reach
(Telegram, email, a USB drive). Treat config links as secrets.

---

## 2. Which MoaV protocols work in MahsaNG?

MahsaNG imports **standard V2Ray URIs**. MoaV's `moav user mahsanet` command
automatically selects only the compatible ones and orders them by how well
they survive Iran's censorship:

| MoaV protocol | URI scheme | MahsaNG | Notes for Iran |
|---|---|---|---|
| **Reality (VLESS)** | `vless://` | ✅ | **Best default.** No domain, indistinguishable from real TLS. |
| **CDN (VLESS+WS)** | `vless://` | ✅ | **Best when your server IP is blocked** — rides Cloudflare. |
| **XHTTP (VLESS+XHTTP+Reality)** | `vless://` | ✅ | HTTP-camouflaged; good alternate. |
| **Trojan** | `trojan://` | ✅ | Solid; needs a domain + valid TLS cert. |
| **Shadowsocks-2022** | `ss://` | ✅ | Lightweight; decent fallback. |
| **Hysteria2** | `hysteria2://` | ✅ | Fast, but UDP is frequently throttled/blocked in Iran. |
| WireGuard / AmneziaWG | `.conf` | ❌ | Not a V2Ray URI — use the WireGuard/Amnezia app. |
| TrustTunnel | config file | ❌ | Use the TrustTunnel client. |
| dnstt / Slipstream / **MasterDNS** | DNS tunnel | ⚠️ | Not a subscription entry, but **MahsaNG v16 has a native MasterDNS tab** — see §5. |
| **GooseRelay** | — | ⚠️ | **MahsaNG v16 bundles the GooseRelay client** — see §6 below. Not a V2Ray URI; configured separately via `tunnel_key` + Apps Script URL. |
| Telegram MTProxy | `tg://proxy` | ❌ | Import directly into the Telegram app, not MahsaNG. |

**Recommended ordering for Iran:** Reality → CDN → XHTTP → Trojan →
Shadowsocks → Hysteria2. `moav user mahsanet` already lists them in this order
and labels each one.

---

## 3. Generate the import package

On the server:

```bash
moav user mahsanet alice          # full output + QR codes
moav user mahsanet alice --no-qr  # skip terminal QR (just URIs + subscription)
```

This:

1. Collects the MahsaNG-compatible URIs from `outputs/bundles/alice/`.
2. Prints each URI with a label.
3. Builds the base64 subscription body and prints it.
4. Renders a scannable QR per config in the terminal.
5. Writes two files into the bundle:
   - `outputs/bundles/alice/mahsanet-uris.txt` — plain URI list (one per line)
   - `outputs/bundles/alice/mahsanet-sub.txt` — base64 subscription body

> If it reports "No MahsaNG-compatible configs found", the user has only
> non-V2Ray protocols enabled. Enable at least one of Reality/CDN/XHTTP/
> Trojan/Shadowsocks/Hysteria2 and regenerate the bundle
> (`moav user add <name>` or `moav regenerate-users`).

---

## 4. Three ways to import

### Method A — Subscription (one import, auto-updates)

A V2Ray subscription is just **base64 of a newline-separated URI list**, served
at a URL. `mahsanet-sub.txt` *is* that body. To turn it into a subscription
URL the phone can use:

- **Host the file:** put `mahsanet-sub.txt` behind any HTTPS URL the user can
  reach (a static host, a gist, an object-storage bucket), **or** have the user
  download the bundle from the MoaV **admin dashboard**
  (`https://your-server:9443` → that user → download), which includes
  `mahsanet-sub.txt`.
- In MahsaNG: **≡ → Subscription / Group → +**, paste the URL, then
  **Update subscription**. All configs appear at once and refresh on update.
- Some MahsaNG builds also accept the **base64 text pasted directly** when
  adding a subscription/group — try that if you don't want to host a file.

Keep the subscription URL unguessable and private — anyone with it gets all
of that user's configs.

### Method B — Single URI (manual, no hosting)

Copy any line from the printed output (or from `mahsanet-uris.txt`). In
MahsaNG: tap **+ → Import config from clipboard** (or paste in the manual add
screen). Start with the **Reality** URI; add **CDN** as a backup.

### Method C — QR code

`moav user mahsanet` prints a QR per config in the terminal; PNG versions are
also in `outputs/bundles/<user>/*-qr.png` (e.g. `reality-qr.png`). In MahsaNG:
**+ → Scan QR code**. Best for handing a config to someone in person without
sending text.

---

## 5. Surviving total shutdowns: add a DNS-tunnel fallback

When Iran throttles to the point that even Reality/CDN fail, a DNS tunnel is
often the only thing that still moves data. **MahsaNG v16 ships a native
MasterDNS tab**, and MoaV can run the matching MasterDNS server:

1. MasterDNS is **enabled by default** (`ENABLE_MASTERDNS=true`) — just add
   the `m` NS record (see
   [DNS.md → Step 6](DNS.md#step-6-ns-delegation-for-masterdns)) and
   rebootstrap. (Set `ENABLE_MASTERDNS=false` only if you want to opt out.)
2. The user's bundle gets `masterdns-instructions.txt` with the domain +
   encryption key. Enter those in MahsaNG's MasterDNS section.

MasterDNS is faster and far more loss-tolerant than dnstt/Slipstream and was
battle-tested through Iran's 2025 70-day blackout — see the
[DNS-tunnel comparison](DNS.md#which-dns-tunnel-should-i-use). Keep a normal
proxy config (Reality/CDN) as the primary and MasterDNS as the emergency
fallback.

---

## 6. GooseRelay — SOCKS5 fronted through Google

MahsaNG v16 bundles the **GooseRelay** client (v1.6.0). GooseRelay tunnels
SOCKS5 through a Google Apps Script web app to your VPS — from Iran's
perspective the entire connection looks like HTTPS to `google.com`, which is
extremely hard to block.

**Server setup (operator):**

```bash
# .env
ENABLE_GOOSERELAY=true
PORT_GOOSE=8444    # must be reachable from Google's servers
```

Rerun bootstrap; the server generates a shared `tunnel_key` (AES-256-GCM).
Each user bundle includes `gooserelay-instructions.txt` with:
- The `tunnel_key`
- The relay URL: `http://YOUR_SERVER_IP:8444/tunnel`
- Step-by-step Google Apps Script forwarder deployment
- Pre-filled `client_config.json`

**User setup (one-time):**

1. Open <https://script.google.com> → New project
2. Paste `Code.gs` from [GooseRelayVPN v1.6.0](https://github.com/kianmhz/GooseRelayVPN/releases/tag/v1.6.0)
3. Set `RELAY_URL = 'http://YOUR_SERVER_IP:8444/tunnel'` at the top
4. Deploy → Web app → Execute as: Me, Access: Anyone → copy Deployment ID
5. Fill `client_config.json` with the Deployment ID + `tunnel_key` from the bundle
6. In MahsaNG v16: **GooseRelay tab** → paste `client_config.json`

**Notes:**
- No domain or DNS delegation needed — only the server IP + port 8444
- Google Apps Script quota: ~20,000 calls/day per Google account; add multiple accounts for higher capacity
- The `tunnel_key` is shared (not per-user); keep it secret
- GooseRelay is **opt-in** (`ENABLE_GOOSERELAY=false` by default) — existing deployments are unaffected until you enable it

---

## 7. Tips for Iran conditions

- **Lead with Reality, keep CDN ready.** If the server IP gets blocked, the
  CDN config keeps working without any change on the server.
- **Enable MahsaNG's Fragment / fake-SNI** in its settings — these are
  client-side and complement (don't replace) the MoaV protocol choice.
- **Hysteria2 last.** It's the fastest when it works, but UDP is the first
  thing to get throttled during heavy censorship.
- **Rotate via subscription.** Using Method A means you can rotate a user's
  configs server-side (`moav regenerate-users`) and they refresh on the next
  subscription update — no need to resend links.
- **One user per person.** Per-user configs let you `moav user revoke` a
  leaked identity without disrupting everyone else.

See also: [Supported Protocols](protocols.md) ·
[DNS Configuration](DNS.md) · [Client Apps](CLIENTS.md) ·
[CLI Reference](CLI.md).
