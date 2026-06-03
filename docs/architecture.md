# Architecture

How MoaV is wired together. For protocol-level details see [protocols.md](protocols.md); for CLI behavior see [CLI.md](CLI.md); for DNS-tunnel mechanics see [DNS.md](DNS.md).

## Container topology

Every protocol is one or more containers grouped into a docker-compose **profile**. `moav start` reads `ENABLE_*` flags from `.env` and only brings up the profiles whose flag is on (see [CLI → Disabled profiles](CLI.md#moav-start)).

```
        .env  (ENABLE_* flags)
                │
                ▼
    Compose profile resolution
                │
                ▼  (only enabled profiles start)


  proxy        sing-box
                 ├─ Reality (VLESS)
                 ├─ Trojan
                 ├─ Hysteria2
                 ├─ Shadowsocks-2022
                 └─ CDN VLESS+WS

  xhttp        xray   (VLESS + XHTTP + Reality)

  wireguard    wireguard + wstunnel
                 (direct UDP + WebSocket fallback)

  amneziawg    amneziawg   (obfuscated WireGuard)

  dnstunnel    dns-router + dnstt + slipstream
               + masterdns + xray (XDNS)
                 (all four DNS tunnels share port 53)

  trusttunnel  trusttunnel   (HTTP/2 + QUIC, TLS)

  telegram     telemt   (MTProxy, fake-TLS)

  admin        admin + docker-proxy
                 (FastAPI dashboard, HTTP Basic auth)

  conduit      psiphon-conduit       ─┐
  snowflake    snowflake + exporter   ├─ bandwidth donations
  gooserelay   gooserelay            ─┘

  monitoring   prometheus + grafana
               + per-protocol exporters

  setup        bootstrap + geoip-updater   (one-shot lifecycle)
  client       client                      (local testing)
```

## DNS-router fan-out

All four DNS tunnels share **port 53** through a small Go service called `dns-router`, which inspects each query's subdomain prefix and forwards to the matching backend. Each tunnel container listens on its own internal port; only `dns-router` binds the public port.

```
              Public 53/udp
                   │
            ┌──────▼──────┐
            │ dns-router  │
            └──────┬──────┘
                   │
   subdomain routing:
       t.*  ─────►  dnstt
       s.*  ─────►  slipstream
       m.*  ─────►  masterdns
       x.*  ─────►  xray   (XDNS via FinalMask)
```

Delegating a tunnel only requires adding its NS record (`t.` / `s.` / `m.` / `x.`); see [DNS → NS Delegations](DNS.md#steps-36-ns-delegations-for-the-four-dns-tunnels). Disabling a tunnel via `ENABLE_*=false` removes its container; `dns-router` simply has no backend to forward to.

## Bundle generation flow

User credentials and per-protocol configs originate inside the `bootstrap` container, then get rendered into per-user bundles on the host. The split exists because container-side bundle generation can't see the host's `outputs/` mount layout.

```
   moav user add alice
            │
            ▼
   ┌─────────────────────────────────────────────────────────┐
   │ bootstrap container (sing-box-user-add.sh)              │
   │   - generates UUID + per-protocol keys                  │
   │   - writes state/users/alice/credentials.env (volume)   │
   └────────────────────┬────────────────────────────────────┘
                        │  HOST sees state/users/ via volume
                        ▼
   ┌─────────────────────────────────────────────────────────┐
   │ host: generate-single-user.sh                           │
   │   - reads credentials.env + .env                        │
   │   - writes outputs/bundles/alice/{*.txt, *.json, *.png, │
   │     subscription.txt, README.html, ...}                 │
   └─────────────────────────────────────────────────────────┘
```

Bundles split into three groups:

- **V2Ray-compatible** (Reality, Trojan, Hysteria2, SS-2022, CDN, XHTTP) — share-link `.txt`s, QR `.png`s, a single base64 `subscription.txt` importable by MahsaNG / v2rayNG / Hiddify / Streisand.
- **L3 VPNs** (WireGuard, AmneziaWG, TrustTunnel) — `.conf` / `.toml` configs + QR.
- **DNS tunnels** (dnstt, Slipstream, MasterDNS, XDNS) and **donations** (GooseRelay) — text instruction files + protocol-specific config blobs (`xdns-config.json`, `gooserelay-AppsScript.gs` + `gooserelay-client_config.json`, etc.).

`README.html` is a bilingual (EN/FA) collapsible bundle viewer with embedded QR images and one-click subscription import.

## Monitoring stack

The `monitoring` profile is opt-in. When enabled, it adds Prometheus + Grafana plus a set of exporters — one per protocol. Each exporter lives in the same Compose profile as its target service (not in `monitoring`), so disabling a protocol takes its metrics down too.

```
   Exporters (each in its target's profile)
     ├── clash-exporter      (sing-box Clash API)
     ├── singbox-exporter    (log parser)
     ├── xray-exporter
     ├── telemt-exporter     (REST /v1/health)
     ├── wireguard-exporter
     ├── amneziawg-exporter
     ├── snowflake-exporter  (snowflake profile)
     ├── node-exporter       (host metrics)
     └── cAdvisor            (container metrics)
                │
                │ scraped by
                ▼
         ┌──────────────┐
         │  Prometheus  │  + recording rules (e.g. Conduit lifetime)
         └──────┬───────┘
                │
                ▼
         ┌──────────────┐
         │   Grafana    │  (+ optional grafana-proxy → Cloudflare CDN)
         │  dashboards  │
         └──────────────┘
```

Pre-built dashboards land in `configs/monitoring/grafana/dashboards/`. The Conduit lifetime panels depend on a recording rule plus an offset watcher — see [Monitoring → Conduit lifetime bandwidth](MONITORING.md#conduit-lifetime-bandwidth).

## See also

- [Setup Guide](SETUP.md) — step-by-step deployment walkthrough
- [DNS Configuration](DNS.md) — NS records, resolver-mode vs direct-mode XDNS, port 53
- [CLI Reference](CLI.md) — every `moav` command, including the disabled-profile prompt
- [Supported Protocols](protocols.md) — protocol-level cipher, port, and client-compat detail
- [Monitoring](MONITORING.md) — dashboards, Conduit lifetime, GeoIP setup
