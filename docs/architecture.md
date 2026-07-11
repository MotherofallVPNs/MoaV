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
                 ├─ AnyTLS         (opt-in; defeats TLS-in-TLS fingerprinting)
                 ├─ Hysteria2
                 ├─ Shadowsocks-2022
                 └─ CDN VLESS+WS

  xhttp        xray   (VLESS + XHTTP + Reality)

  wireguard    wireguard + wstunnel
                 (direct UDP + wss:// WebSocket fallback)

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

- **V2Ray-compatible** (Reality, Trojan, AnyTLS, Hysteria2, SS-2022, CDN, XHTTP) — share-link `.txt`s, QR `.png`s, a single base64 `subscription.txt` importable by MahsaNG / v2rayNG / Hiddify / Streisand.
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

## Security & isolation model

Every service runs in its own container with least-privilege defaults applied in `docker-compose.yml`:

- **Capability drop + selective add** — services start from `cap_drop: ALL` and add back only what they need (e.g. `NET_ADMIN` for WireGuard, `NET_BIND_SERVICE` for privileged ports). Most also set `read_only: true` with a small `tmpfs` for `/tmp`, `no-new-privileges: true`, and `mem_limit`/`cpus` caps.
- **Non-root** — services that must read the root-owned Let's Encrypt cert (sing-box, wstunnel) start their entrypoint as root only long enough to copy the cert into a tmpfs, then drop to an unprivileged user via `setpriv` before exec'ing the daemon.
- **No direct Docker socket** — the admin dashboard reads container status through a read-only [docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy) scoped to `CONTAINERS`/`NETWORKS` only, never mounting `/var/run/docker.sock` into the app.
- **Admin auth fails closed** — the dashboard refuses to serve (HTTP 503) if `ADMIN_PASSWORD` is empty or one of the known-insecure defaults, and uses constant-time comparison; an optional IP allow-list narrows access further. See [OPSEC](OPSEC.md).
- **Secrets** live under the `moav_state` Docker volume (`state/keys/`, `state/users/<user>/`), generated with `openssl rand` / `wg genkey` / `x25519`, mounted read-only into the admin service.

## Service lifecycle & health

`ENABLE_*` flags in `.env` select which profiles `moav start` brings up. The `certbot` service is a one-shot that obtains the TLS cert before the cert-consuming services start; `moav cert install` schedules ongoing renewal (see [CLI → Certificates](CLI.md#certificates)). `restart: unless-stopped` recovers services across crashes and reboots. Core engines (sing-box, xray, telemt) declare Compose healthchecks so `moav doctor` and dependency ordering can distinguish "running" from "actually serving"; extending healthchecks to the remaining long-running services is in progress.

## See also

- [Setup Guide](SETUP.md) — step-by-step deployment walkthrough
- [DNS Configuration](DNS.md) — NS records, resolver-mode vs direct-mode XDNS, port 53
- [CLI Reference](CLI.md) — every `moav` command, including the disabled-profile prompt
- [Supported Protocols](protocols.md) — protocol-level cipher, port, and client-compat detail
- [Monitoring](MONITORING.md) — dashboards, Conduit lifetime, GeoIP setup
