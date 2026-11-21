# Dependency audit, 2026-11

Audit date: 2026-11-21. Audited tree: `main` at `6cfe730` (MoaV 2.4.0). Previous audit: 2026-10-21 (shipped in 2.3.1), refreshed 2026-10-29 (2.4.0).

This is research and planning only. No version was changed by this audit. Every "latest" below was read from the upstream release API or tag list on the audit date and is cited by tag.

## Summary

- 20 third-party components carry an explicit version pin. **12 are behind upstream, 8 are current.**
- **5 P0 security items**: Xray-core (emergency MPTCP release), stack-wide MPTCP listener hardening, Grafana (6 CVEs), Snowflake (security dependency updates plus a proxy deadlock that hits our `-capacity` setup), and the admin dashboard's Python pins (about 20 known advisories, low reachability).
- Two foundations are out of support: **Alpine 3.21 reached end of life on 2026-11-01** (base of 14 images) and three Go builder lines (1.22, 1.24, 1.25) are EOL.
- One upstream is archived (**Slipstream**, deprecated by its author on 2026-08-28) and one helper is effectively abandoned (**sgerrand/alpine-pkg-glibc**, last release 2023-04).
- Biggest wins: Xray v26.11.9 (security plus the Chrome 155 uTLS fingerprint), amneziawg-go v3.1.20261116 (obfuscation parameter hardening), MasterDNS v2026.11.18 (NXDOMAIN for non-tunnel queries, server race fix), and TrustTunnel 1.3.x finally shipping a stable server that matches the newer client line.
- sing-box, wstunnel, Conduit, dnstt, awg-tools and GooseRelay are current. Trojan, Hysteria2, Shadowsocks-2022, Snell, AnyTLS, Reality and CDN (VLESS+WS) are all served by sing-box, so they have no separate pin.

## Method

1. Fresh clone of `MotherofallVPNs/MoaV`, then a sweep of `.env.example`, `docker-compose.yml`, all 29 Dockerfiles (`dockerfiles/`, `exporters/*/`), `admin/requirements.txt`, `dns-router/go.mod`, `lib/*.sh`, `scripts/`, and `.github/workflows/`.
2. Latest stable per upstream from `gh api repos/<owner>/<repo>/releases/latest` (prereleases excluded), the Tor GitLab releases API for Snowflake, `git ls-remote --tags` for dnstt, Docker Hub tag metadata for images, PyPI and OSV for Python packages, NVD for the kernel CVE, and endoflife.date for base-image support windows.
3. Release notes and commit lists between the pinned and latest tags were read for each component that is behind.

Limits: nothing was built or run. Risk ratings are from reading upstream notes and MoaV's configs, not from a test deployment. Items marked "not verified" need a check on the test server before the bump lands.

## Inventory

### Protocol engines and transports

| Component | Pinned | Set in | Latest stable | Behind |
|---|---|---|---|---|
| sing-box | 1.14.4 | `.env.example:145` | v1.14.4 (2026-10-24) | current |
| Xray-core | v26.10.21 | `.env.example:173`, `dockerfiles/Dockerfile.client:83` (separate, see note) | v26.11.9 (2026-11-09) | 2 releases, one is a security release |
| wstunnel | 11.1.0 | `.env.example:147` | v11.1.0 (2026-10-19) | current |
| Psiphon Conduit CLI | 2.1.0 | `.env.example:149` | release-cli-2.1.0 (2026-09-30) | current |
| Snowflake proxy | 2.15.2 | `.env.example:151` | v2.15.4 (2026-11-18) | 2 patch |
| TrustTunnel endpoint | 1.1.0 | `.env.example:153` | v1.3.1 (2026-11-19) | 2 minor |
| TrustTunnel client | 1.0.49 | `.env.example:155` | v1.3.0 (2026-11-19) | 3 minor lines (1.0, 1.1, 1.3) |
| amneziawg-go | v3.1.20260828 | `.env.example:158` | v3.1.20261116 (tag, 2026-11-16) | 1 tag |
| amneziawg-tools | 3.1.20260812 | `.env.example:160` | v3.1.20260812 | current |
| Slipstream (net2share build) | 2026.04.22.1 | `.env.example:163` | v2026.04.22.1 | current, **upstream archived** |
| telemt (Telegram MTProxy) | 3.5.14 | `.env.example:165` | 3.5.17 (2026-11-08) | 3 patch |
| dnstt | v1.20260501.0 | `.env.example:167` | v1.20260501.0 (tag equals HEAD) | current |
| MasterDNS | v2026.06.13.234407-7de2476 | `.env.example:169` | v2026.11.18.210322-7198b45 | 2 releases |
| GooseRelay | v1.7.1 | `.env.example:171` | v1.7.1 (2026-05-23) | current, no commits since 2026-05-29 |
| WireGuard | alpine `wireguard-tools` package | `dockerfiles/Dockerfile.wireguard:4` | follows the Alpine release | tied to Alpine 3.21 (EOL) |

Note on Xray: the client test image pins Xray on its own line (`ARG XRAY_VERSION=26.10.21`, no `v` prefix) and `docker-compose.yml:1427-1432` does not pass `XRAY_VERSION` to the client build. A server bump that only edits `.env.example` leaves `moav test` on the old core.

### Monitoring and infrastructure

| Component | Pinned | Set in | Latest stable | Behind |
|---|---|---|---|---|
| Prometheus | 3.15.1 | `.env.example:175` | v3.16.0 (2026-11-05) | 1 minor |
| Grafana | 13.3.0 | `.env.example:176` | v13.3.1 (2026-11-10) | 1 patch, security |
| node_exporter | 1.12.1 | `.env.example:177` | v1.13.1 (2026-11-19) | 1 minor |
| cAdvisor | 0.60.6 | `.env.example:178` | v0.61.1 (2026-11-18) | 1 minor |
| docker-socket-proxy | v0.5.0 | `docker-compose.yml:765` | v0.6.0 (2026-11-17), but no `v0.6.0` image tag exists | tag scheme changed |
| sgerrand glibc compat | 2.35-r1 | `dockerfiles/Dockerfile.client:108` | 2.35-r1 (2023-04-13) | current, **unmaintained** |

The four monitoring pins only apply to `moav build --local`. The default path pulls floating tags (see "Floating images").

### Base images and toolchains

| Image | Used by | Status on 2026-11-21 |
|---|---|---|
| `alpine:3.21` | 14 Dockerfiles (runtime stage of amneziawg, cadvisor, client, dns-router, dnstt, gooserelay, grafana, nginx, node-exporter, prometheus, snowflake, telemt, wireguard, xray) | **EOL 2026-11-01.** Supported lines: 3.22 (to 2027-05), 3.23 (to 2027-11), 3.24 (to 2028-06) |
| `debian:bookworm-slim` | bootstrap, client (slipstream stage), masterdns, psiphon, sing-box, slipstream, trusttunnel, wstunnel | Debian 12 is in its LTS phase (to 2028-06); Debian 13 "trixie" is current stable. Image still rebuilt (2026-11-05) |
| `golang:1.22-alpine` | `Dockerfile.client:13`, `Dockerfile.dns-router:8`, `Dockerfile.gooserelay:14`; also `go-version: '1.22'` at `.github/workflows/ci.yml:194` and `go 1.22` in `dns-router/go.mod:3` | **Go 1.22 EOL 2025-02-11.** Image last rebuilt 2025-02-05 |
| `golang:1.24-alpine` | `Dockerfile.dnstt:2` | **EOL 2026-02-10.** Image frozen since 2026-02-08 |
| `golang:1.25-alpine` | `Dockerfile.amneziawg:3` | **EOL 2026-08-19.** Image frozen since that day |
| `golang:1.26-alpine` | `Dockerfile.snowflake:45` (source fallback only) | supported (1.26.11) |
| `golang:1.27-alpine` | `Dockerfile.xray:12` (source fallback only) | supported (1.27.4) |
| `python:3.12-alpine` | `Dockerfile.admin:2`, `Dockerfile.certbot:8` | supported (security fixes to 2028-10) |
| `python:3.11-alpine` | six exporters (`exporters/*/Dockerfile:1`) | supported (security fixes to 2027-10) |

### Python packages (admin dashboard, `admin/requirements.txt`)

| Package | Pinned | Latest | Known advisories at the pinned version (OSV) |
|---|---|---|---|
| fastapi | 0.109.0 (line 1) | 0.165.0 | CVE-2024-24762. Also caps Starlette at `<0.36.0`, which carries CVE-2024-47874 (high), CVE-2025-54121, CVE-2026-48710, CVE-2026-48817, CVE-2026-54282, CVE-2026-54283 (high) |
| uvicorn[standard] | 0.27.0 (line 2) | 0.54.0 | none listed |
| httpx | 0.26.0 (line 3) | 0.28.1 | none listed |
| jinja2 | 3.1.3 (line 4) | 3.1.6 | CVE-2024-34064, CVE-2024-56201, CVE-2024-56326, CVE-2025-27516 (all moderate) |
| python-multipart | 0.0.6 (line 5) | 0.0.34 | 9 advisories, 5 high: CVE-2024-24762, CVE-2024-53981, CVE-2026-24486, CVE-2026-42561, CVE-2026-53539, plus CVE-2026-40347, CVE-2026-53537, CVE-2026-53538, CVE-2026-53540 |

Unpinned pip installs: `certbot` (`Dockerfile.certbot:18`), `maxminddb` (four exporters), `urllib3` (telemt exporter). These resolve to latest at build time, so they are current but not reproducible.

### Floating images (no version pin at all)

`certbot/certbot:latest` (`docker-compose.yml:353`), `nginx:alpine` (399, 970), `prom/prometheus:latest` (862), `grafana/grafana:latest` (901), `prom/node-exporter:latest` (1008), `gcr.io/cadvisor/cadvisor:latest` (1048), `curlimages/curl:latest` (1283, 1310).

Consequence: on the default (non `--local`) path the monitoring stack tracks upstream on every pull, independent of this audit and of the `*_VERSION` pins. That is good for picking up Grafana security patches without a MoaV release, and bad for reproducibility: a Grafana or Prometheus major would arrive unannounced.

### CI actions

`actions/checkout@v4` (latest v7.0.1), `actions/setup-go@v5` (latest v7.1.0), `actions/upload-artifact@v4` (latest v7.0.2), `anthropics/claude-code-action@v1` (current). All are major-tag pins, none are SHA pins. The repo has no Dependabot or Renovate config.

## Per-component findings

### Xray-core: v26.10.21 to v26.11.9 (P0)

- **Security.** v26.10.31 is an upstream emergency release. Go 1.24+ enables MPTCP on TCP listeners by default, and the public proof of concept for Linux kernel **CVE-2026-98432** (use-after-free in IPv4 TCP SYN handling, CVSS 9.8, NVD status Analyzed) needs an MPTCP listener to reach remote root. v26.10.31 turns MPTCP off by default in Xray's listener (XTLS/Xray-core#7291). Our XHTTP inbound is published on `PORT_XHTTP` (2096/tcp), built with Go 1.27.3, so it is an MPTCP listener today. The Go team's position (golang/go#82717) is that the kernel bug is not MPTCP-specific and a patched kernel is the real fix; disabling MPTCP removes the known exploit path only.
- Other fixes in range: QUIC sniffer rejects a ClientHello with gaps in CRYPTO data (#7292), hijacked A/AAAA replies kept inside the buffer (#7225), geodata download size and extension limits (#7267), file loader checks extensions without following symlinks (#7255), failed inbounds are closed and removed (#7223).
- **Censorship resistance.** uTLS switched to the XTLS fork and `hellochrome_155` is the new default `chrome` fingerprint (#7135). Upstream reports it is not yet targeted by TSPU; that claim is theirs and is not verified here. MoaV's XHTTP share links use `fp=chrome` (`scripts/lib/xray.sh:48`, `scripts/lib/moav-bundle.sh:51`), so clients on a new core pick it up without a link change. XHTTP server gains `h2Params` (#7295) and accepts `OPTIONS` as an uplink method (#7290).
- **Behaviour changes to check.** mux.cool defaults rose to `maxConcurrency` 128 and `maxReuseTimes` 1024, aimed at XDNS among others, so XDNS needs an e2e pass. `blockDelay` was renamed to `delay` in Freedom `finalRules`, and `fragment`/`noises` now warn about moving to Finalmask; MoaV's Xray template and renderers use none of these (grep of `configs/xray/config.json.template`, `scripts/lib/xray.sh`, `scripts/bootstrap.sh` returns zero hits).
- Risk: **low to medium**. Drop-in for config. Needs the client pin edited separately.
- Recommendation: bump now, server and client together.

### MPTCP exposure across the rest of the stack (P0, config not version)

Public TCP listeners written in Go, by build toolchain:

| Service | Port | Go version | MPTCP listener today |
|---|---|---|---|
| sing-box | 443, 8443, 8445, 2082, 8388, 8389 | 1.26.x | **No.** Official builds set `runtime.godebugDefault=multipathtcp=0` (`release/LDFLAGS` at tag v1.14.4) |
| xray | 2096 | 1.27.3 | Yes until v26.10.31+ |
| grafana | 9444 | Go 1.24+ | Assumed yes. Not verified whether Grafana overrides the default |
| gooserelay | 8444 | built with 1.22 here | No (default arrived in 1.24). Becomes yes the moment the builder is bumped |

Rust and C services (telemt, wstunnel, TrustTunnel, nginx) and the Python admin app are not affected by the Go default. Internal-only Go listeners (Prometheus, node_exporter, cAdvisor, Conduit metrics) are not published.

Recommendation: set `GODEBUG=multipathtcp=0` in the compose `environment` of every Go service (xray, grafana, gooserelay, prometheus, node-exporter, cadvisor, psiphon-conduit, snowflake, dns-router, dnstt, amneziawg). This is the mitigation the Go team documents, it needs no rebuild, and it keeps the stack covered regardless of what each upstream decides. Pair it with a `moav doctor` warning when the host kernel predates the fix, since the kernel update is the root fix and MoaV cannot ship it. Risk: **low**.

### Grafana: 13.3.0 to 13.3.1 (P0)

- Six CVEs fixed: CVE-2026-102589 (high 7.1, shared `renderer_token` across instances), CVE-2026-111024 (high 7.1, folder permission bypass on Git Sync resources), CVE-2026-107509 (medium 6.5, a Viewer can make Grafana allocate unbounded memory and crash), CVE-2026-110992, CVE-2026-13721, CVE-2026-14242 (medium, Git Sync provisioning).
- MoaV exposure is limited: one admin account, no image renderer, no Git Sync. Grafana is still internet-facing on 9444, so the patch is worth taking.
- Risk: **low**, patch release. Only affects `moav build --local` installs; default installs already pull `grafana/grafana:latest`.

### Snowflake proxy: 2.15.2 to 2.15.4 (P0)

- 2.15.3: fixes a deadlock in fixed-capacity proxies (issue 40557). MoaV always passes `-capacity` (`scripts/snowflake-entrypoint.sh:87`), so this one applies to us directly. Also a broker resource-exhaustion fix (broker only).
- 2.15.4: "Updates to dependencies, includes security fixes" (upstream ChangeLog wording, no CVE ids given), plus server-side fixes.
- `thetorproject/snowflake-proxy:v2.15.4` exists on Docker Hub, so the prebuilt path works.
- Risk: **low**, drop-in.

### Admin dashboard Python pins (P0, low reachability)

- The pins date from January 2024 and collect roughly 20 advisories (table above).
- Reachability is low. `admin/main.py` parses bodies with `request.json()` only, has no `Form` or `UploadFile` parameter, and every route except `/api/health`, `/favicon.ico` and `/logo.png` sits behind HTTP Basic. The multipart and form advisories are therefore not reachable in the shipped app, and the Jinja2 sandbox advisories need attacker-controlled templates, which the app does not have.
- Still worth fixing first: it is the only component in the tree with high-severity findings in any scanner output, the fix is a requirements edit, and the Starlette host-header and method-dispatch advisories are not obviously unreachable.
- Recommendation: fastapi to current (brings Starlette 1.x), jinja2 3.1.6, uvicorn 0.54.0, httpx 0.28.1, and **drop python-multipart** since nothing imports it. Risk: **medium**, because 0.109 to 0.165 crosses the Starlette 1.0 line. The app is one 1,266-line file and has `tests/admin-*`; run those plus a manual add-user and bundle download.

### amneziawg-go: v3.1.20260828 to v3.1.20261116 (P1)

- Hardening of the AWG 3.1 obfuscation parameters: `jmin > jmax` is rejected instead of underflowing the junk packet size, negative length arguments in `<r>/<rc>/<rd>/<dz>` tags are rejected, I1-I5 are safe to change while handshakes are being sent, S4 changes are checked in the encryption queue, a timer race under `modifyingLock` is fixed.
- awg-tools has no newer release; 3.1.20260812 stays matched to the 3.1 line.
- Risk: **low**, drop-in, same wire format.
- Tooling gap: `check_component_versions` (`lib/update.sh:293-306`) does not list `AMNEZIAWG_GO_VERSION` or `AWGTOOLS_VERSION`, so `moav update` will not move this pin in an existing `.env`. Fix that list in the same PR or existing servers stay on the old build.

### MasterDNS: v2026.06.13 to v2026.11.18 (P1)

- Server now returns NXDOMAIN for non-tunnel DNS queries (#189), which makes the endpoint answer stray probes like an ordinary authoritative server, adds a fallback for non-DNS UDP traffic (#199) and dual-stack wildcard listeners (#200).
- Fixes a server data race on duplicate `SESSION_INIT` (#214) and bumps `golang.org/x/crypto` 0.49.0 to 0.52.0 and `klauspost/compress`.
- Client side: FastStart and background resolver scoring (#205), resolver starvation and race fixes (#206, #213). These matter for the bundles users get, not the server image.
- Risk: **low to medium**. The release SHA256SUMS check in `Dockerfile.masterdns` keeps working. Not verified: whether the NXDOMAIN change interacts with `dns-router` fan-out, which already filters by domain.

### telemt: 3.5.14 to 3.5.17 (P2 with validation)

- 66 commits. Relevant fixes: stalled ME relays (#879), flush of buffered adaptive relay writes when the source stalls, SOCKS BND family validation, IPv4 metrics allowlists matched on dual-stack listeners (#849).
- 3.5.17 reworks the management API ("API Exposure enhanced": access policies, dry-run validation, capability discovery, OpenAPI artifacts removed). MoaV's exporter reads eight REST endpoints plus `/metrics` (`exporters/telemt/`), so repeat the 2.3.1 validation: run the rendered `config.toml` on the real 3.5.17 binary and confirm all endpoints answer 200.
- No security advisory in range. Risk: **low to medium** because of the API churn.

### TrustTunnel: endpoint 1.1.0 to 1.3.1, client 1.0.49 to 1.3.0 (P3)

- The reason the client was held (1.1.x moved from quiche to ngtcp2 while the server had no matching stable) is gone: endpoint v1.3.1 and client v1.3.0 were released as a pair on 2026-11-19.
- Worth adopting: TLS authentication with a key-derived `client_random` (`client_random_auth_key` in `rules.toml`, HKDF-SHA256 plus AES-128) instead of prefix/mask matching, per-endpoint `tls_profile` with ClientHello profiles updated to Chrome and Firefox as of November 2026, deep-link format v2, and an optional subscription URL served by the endpoint.
- Breaking or structural: the setup wizard moved into the main binary (`trusttunnel_endpoint --setup-wizard`, standalone binary removed), `gen_client_config` now errors where it used to warn, and the client gives up after a bounded number of recovery attempts.
- Risk: **high**. Two minor lines on the server, three on the client, a new QUIC stack on the client, and config-generation changes. Needs its own PR and an e2e run on both HTTP/2 and HTTP/3. Also two days old on the audit date; let it settle for a week or two.

### Prometheus 3.15.1 to 3.16.0, node_exporter 1.12.1 to 1.13.1, cAdvisor 0.60.6 to 0.61.1 (P2)

- Prometheus 3.16.0: no security content in the notes. One default change (`--web.external-url` defaults to https when `--web.config.file` enables TLS); MoaV passes neither flag. Several TSDB out-of-order and WAL-replay fixes.
- node_exporter 1.13.x: `node_cpu_frequency_hertz` behaviour reverted, netstat now parsed via procfs, an NVMe metric deprecated. MoaV's dashboards reference none of `node_cpu_frequency*`, `node_netstat_*`, `node_nvme*`.
- cAdvisor 0.61.x: dependency bumps (`opencontainers/cgroups` v0.1.1), sysinfo fixes.
- Risk: **low** for all three. One PR.

### docker-socket-proxy: v0.5.0 (P2, tag scheme change)

- Upstream v0.6.0 deprecates the `:vX.Y.Z` and `:edge` tags. Docker Hub has no `v0.6.0` tag; the supported tags are `lts`, `latest` and `3.4`, rebuilt weekly from the matching HAProxy image, and upstream recommends pinning a digest for reproducibility. v0.6.0 also runs `apk upgrade` at build.
- `v0.5.0` keeps existing but will never be rebuilt, so its Alpine and HAProxy layers age from 2026-07-27 on.
- Recommendation: move to `tecnativa/docker-socket-proxy:3.4@sha256:<digest>` and re-run the 2.3.1 smoke test (`/containers/json` 200, `/volumes` 403 under `read_only` plus `cap_drop: ALL`). Risk: **low to medium**; this container fronts the Docker socket, so test before merging.

### Alpine 3.21 (EOL) and EOL Go builders (P2, security hygiene, do this cycle)

- Alpine 3.21 stopped receiving fixes on 2026-11-01. Every `apk add` in 14 images (openssl, busybox, nginx, tor, iptables, wireguard-tools, ca-certificates) is now frozen at its last 3.21 build. Target 3.24 (supported to 2028-06).
- Things that can break on the move: the client image downloads `alpine-3.19-amneziawg-tools.zip` (still the only Alpine asset upstream ships), the sgerrand glibc package, nginx and tor minor versions, and the iptables backend in the wireguard and amneziawg images.
- Go builders: `golang:1.22-alpine` (dns-router, gooserelay, client dnstt stage) has not been rebuilt since 2025-02, `1.24` (dnstt) since 2026-02, `1.25` (amneziawg) since 2026-08. Binaries compiled from them miss every Go security release since. dns-router is stdlib-only and answers public UDP/53, so it is the one that matters most. Move all to `golang:1.27-alpine`, bump `dns-router/go.mod` and `ci.yml` to match.
- Order matters: land the `GODEBUG=multipathtcp=0` change before bumping the gooserelay builder past Go 1.24, or the bump turns an MPTCP listener on.
- Risk: **medium**. Separate PRs for Alpine and for Go builders.

### Components that are current

- **sing-box 1.14.4**: latest stable. 1.15 is at alpha.13 (MASQUE endpoints, new TUN stack, full certificate pinning, HTTP/2 and HTTP/3 for the HTTP proxy). Fields deprecated in 1.14 are removed in 1.16 (inline `tls.acme`, `download_detour`, implicit default HTTP client); MoaV's templates use none of them. Nothing to do now.
- **wstunnel 11.1.0, Conduit 2.1.0, dnstt v1.20260501.0, awg-tools 3.1.20260812, GooseRelay v1.7.1**: latest.

## Unmaintained or archived upstreams

| Component | Evidence | Recommendation |
|---|---|---|
| **Slipstream** (`Mygod/slipstream-rust`, built by `net2share/slipstream-rust-build`) | Source repo **archived**, deprecation notice dated 2026-08-28: the author no longer considers QUIC-over-DNS the right architecture. Build repo last pushed 2026-04-22. | Freeze at 2026.04.22.1, mark deprecated in `data/protocols.json` and the docs, stop enabling it by default for new installs, and plan removal. MasterDNS already covers the DNS-tunnel role and the Slipstream author is now contributing there (MasterDnsVPN #199, #200). |
| **sgerrand/alpine-pkg-glibc** | Last release 2.35-r1 on 2023-04-13, last push 2024-06, signing key no longer served (already noted in `Dockerfile.client`). glibc 2.35 gets no fixes. | Remove the dependency. sing-box publishes `linux-<arch>-musl` assets (present for v1.14.4), or move the client image's final stage to `debian:*-slim` so prebuilt glibc binaries run natively. Client image only, so no production exposure. |
| **GooseRelay** | Not archived, but no commits since 2026-05-29 and no release since v1.7.1 (2026-05-23). | Keep, watch. Re-check at the next audit; if still silent, treat like Slipstream. |
| **dnstt** | Slow by design; latest tag equals HEAD. | No action. |

## Plan

### P0: security fixes, do first

| # | Change | Config or code changes | Batching |
|---|---|---|---|
| P0-1 | Xray-core v26.10.21 to v26.11.9 | `.env.example:173`, compose and Dockerfile fallbacks, `lib/service.sh:30`, **and** `Dockerfile.client:83` (no `v`). No template change expected. e2e: XHTTP and XDNS. | PR A |
| P0-2 | `GODEBUG=multipathtcp=0` on all Go services, plus a `moav doctor` kernel note | `docker-compose.yml` environment blocks; `lib/doctor.sh`. No rebuild needed, takes effect on restart. | PR A (same theme, same test run) |
| P0-3 | Grafana 13.3.0 to 13.3.1 | `.env.example:176`, `Dockerfile.grafana:10` | PR B |
| P0-4 | Snowflake 2.15.2 to 2.15.4 | `.env.example:151`, compose and `Dockerfile.snowflake:17` fallbacks | PR B |
| P0-5 | Admin Python pins: fastapi, jinja2, uvicorn, httpx current; drop python-multipart | `admin/requirements.txt`; possibly small Starlette 1.x adjustments in `admin/main.py` | PR C, isolated (only item here with medium risk) |

PR A and PR B can ship as a 2.4.1 patch release. PR C should not block them.

### P1: censorship-resistance and protocol improvements

| # | Change | Config or code changes | Batching |
|---|---|---|---|
| P1-1 | Chrome 155 uTLS fingerprint | Arrives with P0-1 on the client image. Add a line to the user guide telling people to update their client app's Xray core. | with PR A |
| P1-2 | amneziawg-go v3.1.20261116 | `.env.example:158`, compose and `Dockerfile.amneziawg:5`; add the two AWG variables to `lib/update.sh:293-306`. Run `tests/amneziawg-v3-test.sh` and e2e. | PR D |
| P1-3 | MasterDNS v2026.11.18 | `.env.example:169`, compose and `Dockerfile.masterdns:18`. Verify behind `dns-router`, then `moav regenerate-users` guidance if client defaults changed. | PR D (both are DNS/UDP-side, one e2e pass), or split if either fails |

### P2: routine bumps and hygiene

| # | Change | Notes | Batching |
|---|---|---|---|
| P2-1 | Prometheus 3.16.0, node_exporter 1.13.1, cAdvisor 0.61.1 | Low risk. | PR E |
| P2-2 | telemt 3.5.17 | Re-validate exporter endpoints against the real binary. | PR E if validation is clean, otherwise alone |
| P2-3 | docker-socket-proxy to `3.4@sha256:...` | Re-run the socket-proxy smoke test. | PR F, isolated |
| P2-4 | Go builders to 1.27, `dns-router/go.mod`, `ci.yml` | After P0-2 has landed. | PR G |
| P2-5 | Alpine 3.21 to 3.24 | Full `moav build` plus e2e; watch client image, wireguard and amneziawg. | PR H, isolated |
| P2-6 | CI actions to current majors, SHA-pinned | checkout v7, setup-go v7, upload-artifact v7. | PR I |
| P2-7 | Tooling: wire `XRAY_VERSION` into the client build args; complete the `lib/update.sh` pin list; refresh the table in `docs/devdocs/VERSION-BUMP-CHECKLIST.md` | The checklist table omits Xray, dnstt, MasterDNS, GooseRelay, amneziawg-go, node_exporter and cAdvisor, still lists Snowflake under client build args, and names a `Dockerfile.conduit` that does not exist (it is `Dockerfile.psiphon`). | PR I |

### P3: needs design work

| # | Item | What has to be decided |
|---|---|---|
| P3-1 | TrustTunnel endpoint 1.3.1 plus client 1.3.0 | Adopt `client_random_auth_key` and `tls_profile`? Bundle format (deep-link v2, subscription URL)? Migration for existing users. Isolated PR, e2e on H2 and H3. |
| P3-2 | Slipstream retirement | Deprecation timeline, default-off for new installs, migration note pointing to MasterDNS. |
| P3-3 | Remove sgerrand glibc from the client image | musl sing-box asset vs Debian final stage; affects every prebuilt binary in that image. |
| P3-4 | Pin the floating images | Tie `IMAGE_*` defaults to the `*_VERSION` pins (or digests) so the default path matches what was audited. Trade-off: security patches then need a MoaV release. |
| P3-5 | Automated update tracking | Renovate with a regex manager over `.env.example` would have opened all 12 of these as PRs. |
| P3-6 | sing-box 1.15 | Track only. Re-evaluate at stable; the real-binary `sing-box check` CI gate will catch schema breaks. |

### Suggested order

1. PR A (Xray plus MPTCP hardening), PR B (Grafana, Snowflake): release as 2.4.1.
2. PR C (admin Python pins).
3. PR D (amneziawg-go, MasterDNS), PR E (monitoring, telemt).
4. PR F, G, H, I (socket proxy, Go builders, Alpine, CI and tooling), one at a time.
5. P3 items as separate design threads.

## Sources

- Release data: `gh api repos/<owner>/<repo>/releases` for SagerNet/sing-box, XTLS/Xray-core, erebe/wstunnel, Psiphon-Inc/conduit, TrustTunnel/TrustTunnel, TrustTunnel/TrustTunnelClient, amnezia-vpn/amneziawg-go (tags), amnezia-vpn/amneziawg-tools, net2share/slipstream-rust-build, Mygod/slipstream-rust, telemt/telemt, masterking32/MasterDnsVPN, kianmhz/GooseRelayVPN, prometheus/prometheus, grafana/grafana, prometheus/node_exporter, google/cadvisor, Tecnativa/docker-socket-proxy, sgerrand/alpine-pkg-glibc.
- Snowflake: https://gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/snowflake (releases API and `ChangeLog`).
- dnstt: `git ls-remote --tags https://www.bamsoftware.com/git/dnstt.git`.
- MPTCP: https://github.com/XTLS/Xray-core/releases/tag/v26.10.31, https://github.com/XTLS/Xray-core/pull/7291, https://github.com/golang/go/issues/82717, https://nvd.nist.gov/vuln/detail/CVE-2026-98432, sing-box `release/LDFLAGS` at v1.14.4.
- Slipstream deprecation: https://github.com/Mygod/slipstream-rust/discussions/111.
- Python advisories: https://osv.dev (queried per package and pinned version). Grafana CVE severities: GitHub Advisory Database.
- Support windows: https://endoflife.date (Alpine, Debian, Go, Python). Image freshness: Docker Hub tag metadata.
