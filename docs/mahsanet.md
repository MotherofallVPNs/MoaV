# Importing MoaV configs into MahsaNG

[MahsaNG](https://github.com/GFW-knocker/MahsaNG) is a hardened V2RayNG fork
built for Iran (2M+ users). It speaks standard V2Ray protocols (VLESS, Trojan,
Shadowsocks, Hysteria2) plus extra anti-censorship transports, and adds
client-side circumvention (Fragment, fake-SNI, rotating configs). MoaV already
generates everything MahsaNG needs — this guide shows the fastest way to get a
user connected.

> **TL;DR:** every user bundle already contains a base64 **V2Ray subscription**
> — in `subscription.txt` and as a click-to-copy block at the top of the
> bundle's `README.html`. Paste it once into MahsaNG to import all proxy
> protocols. (No separate command — it's generated with the bundle.)

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

MahsaNG imports **standard V2Ray URIs**. MoaV's bundle generator automatically
includes only the compatible ones in the subscription, ordered by how well they
survive Iran's censorship:

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
Shadowsocks → Hysteria2. The bundle's subscription already includes them in
this order.

---

## 3. Where the subscription lives

MoaV builds the subscription into **every user bundle automatically** (on
`moav user add` / `moav regenerate-users`) — there's no separate command to run.
Each bundle in `outputs/bundles/<user>/` contains:

- **`subscription.txt`** — the base64 **V2Ray subscription body** (all
  compatible configs in one string).
- **`README.html`** — opens with an **"Import everything at once"** card showing
  the same subscription as a click-to-copy block (EN + FA).
- the individual config files (`reality.txt`, `trojan.txt`, `shadowsocks.txt`,
  …) and a PNG QR per config (`reality-qr.png`, …).

The compatible configs (Reality, CDN, XHTTP, Trojan, Shadowsocks-2022,
Hysteria2 — IPv4 + IPv6) are selected automatically and ordered by reliability
for Iran. Download a user's bundle from the MoaV **admin dashboard**
(`https://your-server:9443`) or via SCP.

> If `subscription.txt` is missing (or the README's import card is hidden), the
> user has only non-V2Ray protocols enabled. Enable at least one of
> Reality/CDN/XHTTP/Trojan/Shadowsocks/Hysteria2 and regenerate the bundle
> (`moav user add <name>` or `moav regenerate-users`).

---

## 4. Three ways to import

### Method A — Subscription (one import, auto-updates)

A V2Ray subscription is just **base64 of a newline-separated URI list**.
`subscription.txt` *is* that body, and the README's import card holds the same
string. Two ways to use it:

- **Paste the text directly:** copy the subscription (from the README card or
  `subscription.txt`) and in MahsaNG tap **≡ → Subscription / Group → +** and
  paste it — MahsaNG, v2rayNG and Hiddify accept the base64 body directly. All
  configs appear at once.
- **Host it as a URL:** put `subscription.txt` behind any HTTPS URL the user can
  reach (a static host, a gist, an object-storage bucket), then add that URL as
  a subscription in MahsaNG — configs refresh whenever you regenerate them
  server-side.

Keep the subscription private — anyone with it gets all of that user's configs.

### Method B — Single URI (manual, no hosting)

Copy any individual config from the bundle (`reality.txt`, `trojan.txt`, …) or
from the README's per-protocol sections. In MahsaNG: tap **+ → Import config
from clipboard**. Start with the **Reality** URI; add **CDN** as a backup.

### Method C — QR code

Each config has a PNG QR in the bundle (`outputs/bundles/<user>/*-qr.png`, e.g.
`reality-qr.png`), also shown in the README. In MahsaNG: **+ → Scan QR code**.
Best for handing a config to someone in person without sending text.

---

## 5. Surviving total shutdowns: add a DNS-tunnel fallback

When Iran throttles to the point that even Reality/CDN fail, a DNS tunnel is
often the only thing that still moves data. **MahsaNG v16 ships a native
MasterDNS tab**, and MoaV can run the matching MasterDNS server:

1. MasterDNS is **enabled by default** (`ENABLE_MASTERDNS=true`) — just add
   the `m` NS record (see
   [DNS.md → NS Delegations](DNS.md#steps-36-ns-delegations-for-the-four-dns-tunnels))
   and rebootstrap. (Set `ENABLE_MASTERDNS=false` only if you want to opt out.)
2. The user's bundle gets `masterdns-instructions.txt` with the domain +
   encryption key. Enter those in MahsaNG's MasterDNS section.

MasterDNS is faster and far more loss-tolerant than dnstt/Slipstream and was
battle-tested through Iran's 2025 70-day blackout — see the
[DNS-tunnel comparison](DNS.md#which-dns-tunnel-should-i-use). Keep a normal
proxy config (Reality/CDN) as the primary and MasterDNS as the emergency
fallback.

---

## 6. GooseRelay — SOCKS5 fronted through Google

MahsaNG v16 bundles the **GooseRelay** client; MoaV pins the server to
GooseRelay **v1.7.1** (fully interoperable with v1.6.x). GooseRelay tunnels
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
Each user bundle then contains three ready-made GooseRelay files (nothing to
hand-edit except pasting in one ID):
- **`gooserelay-AppsScript.gs`** — the v1.7.1 Apps Script forwarder with the
  `RELAY_URLS` array **already pointed at this server**. Paste as-is.
- **`gooserelay-client_config.json`** — a complete client config (tunnel_key,
  SNI, tuning) with only the Deployment ID left to fill.
- **`gooserelay-instructions.txt`** — the short walkthrough below.

**User setup (one-time):**

1. Open <https://script.google.com> → New project
2. Paste the **whole** of `gooserelay-AppsScript.gs` (no editing — the
   `RELAY_URLS` array is already filled in)
3. Deploy → New deployment → Web app → Execute as: Me, Access: Anyone → copy the Deployment ID
4. In `gooserelay-client_config.json`, replace `REPLACE_WITH_YOUR_APPS_SCRIPT_DEPLOYMENT_ID` with that Deployment ID
5. Load `gooserelay-client_config.json` into the GooseRelay client, or paste it into MahsaNG v16's **GooseRelay tab**

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
