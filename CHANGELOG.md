# Changelog

All notable changes to MoaV will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **All 4 DNS tunnels can now run in parallel on a single port 53** — `dns-router` routes queries to dnstt, Slipstream, MasterDNS, and XDNS by subdomain suffix (`t.` → dnstt, `s.` → Slipstream, `m.` → MasterDNS, `x.` → XDNS). No `moav switch-dns` is needed to combine them; the v1.7.5 port-group mutual exclusion model is retired. dnstt, Slipstream, and MasterDNS are on by default; XDNS remains opt-in (`ENABLE_XDNS=false` by default) because it requires a FinalMask-aware client. Set `ENABLE_XDNS=true` to add it to the mix.
- **XDNS no longer binds host port 53 directly** — xray's XDNS inbound is now an internal dns-router backend (`xray:5355`). The host port for xray shifts to `PORT_XDNS` (default `5356`, was `53`). `PORT_DNS=53` is the single public-facing DNS port, owned by dns-router.
- **`moav switch-dns` reframed** — all four tunnels are in the same group; any combination is valid. Command now described as "enable/disable tunnel daemons" rather than "pick which group owns port 53." Dead port-group conflict check removed. `moav switch-dns dnstt+slipstream+masterdns+xdns` activates all four simultaneously.
- **`moav doctor conflicts`** updated — multi-group conflict checks removed (all tunnels same group); now reports enabled tunnels and checks port 53 availability cleanly.
- **`moav start`** — removed hard-block port-group conflict guard; port 53 check now covers all four tunnels.
- **`moav doctor env`** — removed stale XDNS-vs-dnstt conflict warning; port 53 check unified to cover any enabled tunnel.
- **`docs/TROUBLESHOOTING.md`** — "Port 53 conflict" section rewritten to reflect all-four coexistence; `.env` snippet updated.
- **`docs/DNS.md`** — "Which DNS tunnel" table updated with Default column; all remaining switch-dns/mutual-exclusion notes removed.

### Added
- **`dns-router` XDNS routing** — `ENABLE_XDNS=true` adds an `x.<domain>` → `xray:5355` route to dns-router, enabling XDNS to coexist with the other three tunnels on port 53. Closes [#99](https://github.com/shayanb/MoaV/issues/99).
- **`dns-router` test suite expanded** — all four tunnels covered: `TestDomainRouting` and `TestDomainIsolation` now verify the full 4-tunnel parallel configuration; `TestBuildRoutes` validates the XDNS-off default (3 routes) and the all-on case (4 routes). Run with `cd dns-router && go test ./... -v`
- **`dns-router/README.md`** — architecture note explaining subdomain-based fan-out and why all four DNS tunnels can coexist on port 53

## [1.7.9] - 2026-05-26

### Fixed
- **`get_env_val` 2-argument miscalls in `moav start`** — six call sites passed the *default value* where the function expects the *.env file path* (`get_env_val "ENABLE_DNSTT" "true"` → the literal `true` was grepped as a filename, always returning empty). Effects: the fallback profile builder (used when `DEFAULT_PROFILES` is unset) never added the `dnstunnel`/`amneziawg` profiles, and the v1.7.5 DNS port-group conflict hard-block was silently weakened (`dnstt_enabled`/`slipstream_enabled`/`xdns_start_enabled` always read empty). All now pass `$SCRIPT_DIR/.env` so the flags are read correctly and the conflict check works as intended. Also fixed the same miscall in the new Conduit auto-updater guard (it caused `auto_setup_conduit_offsets` to no-op, so the watcher never auto-installed on `moav start`)
- **`moav regenerate-users` now actually refreshes existing bundles** (issue [#98](https://github.com/shayanb/MoaV/issues/98), thanks @vibecodegits) — it ran `bootstrap /app/generate-user.sh <user>`, but the bootstrap image's `ENTRYPOINT` is `bootstrap.sh`, so the `generate-user.sh` argument was ignored and a *full bootstrap* ran instead. Bootstrap regenerates bundles **without** `force`, so existing files were skipped and stale IP/domain/port values persisted (nothing in the codebase ever passed `force`, so there was no working refresh path). It now invokes `generate-user.sh <user> force` directly (via `--entrypoint /bin/sh`), syncs `/host-state/users` → `/state/users` first so users created with `moav user add` are found during regeneration, and passes the full DNS-tunnel env set (`DNSTT_SUBDOMAIN`, `ENABLE_XDNS`, `XDNS_SUBDOMAIN`, `XDNS_MTU`, `XDNS_RESOLVERS`, `PORT_DNS`, `PORT_XDNS`) so regenerated bundles match the active `.env` instead of falling back to defaults (`t`/`x`/`53`)
- **XDNS bundle UUID could regenerate empty** (issue [#98](https://github.com/shayanb/MoaV/issues/98)) — `generate-user.sh` sources `USER_UUID` from `credentials.env`, but the XDNS block then reset it to empty and only re-read a separate `uuid.env` that doesn't exist on current installs, yielding an XDNS config with a blank `id`. It now prefers the already-loaded `USER_UUID` and lets `uuid.env` override only if present
- **Stale `xdns.txt` after regeneration** (issue [#98](https://github.com/shayanb/MoaV/issues/98)) — `generate-user.sh` rewrote `xdns-config.json`/`xdns-direct-config.json` but not the human-readable `xdns.txt`, so its instructions (domain, resolvers) could drift from the JSON after a config change. It now emits `xdns.txt` from the same values, consistent with `singbox-user-add.sh`

### Added
- **Conduit lifetime bandwidth tracking** (PR [#97](https://github.com/shayanb/MoaV/pull/97), thanks @jSFBay) — `conduit_bytes_downloaded`/`conduit_bytes_uploaded` are in-memory gauges that reset on every Conduit restart, so cumulative contribution was impossible to see in Grafana. New Prometheus recording rules (`configs/monitoring/conduit_lifetime.rules.yml`) maintain `*_lifetime` totals by adding a per-install offset to the live counters, and two **Lifetime Download / Lifetime Upload** stat panels were added to the Conduit dashboard. After a Conduit restart, `scripts/update-conduit-offsets.sh` recovers the pre-restart running total and rewrites the offset, then reloads Prometheus (SIGHUP). Offsets start at 0 for new installs. By default the script reaches Prometheus through the running container (`docker compose exec prometheus`), so it works without publishing port 9091 to the host; set `PROM_URL` to override with a host-reachable address or an external Prometheus. It preflights connectivity and fails with a clear message if Prometheus is unreachable. The offset is derived from the `*_lifetime` metric's high-water mark (not the raw gauge) so it accumulates correctly across multiple restarts
- **Conduit lifetime offsets update automatically** — a systemd watcher (`scripts/conduit-offsets-watch.sh`) reacts to Conduit container `start` events (crash-restarts, host reboots, manual restarts) and runs `update-conduit-offsets.sh` after a short settle delay, so the lifetime totals stay accurate with no manual step. `moav start` auto-installs it the first time Conduit + monitoring are both running (guarded: needs systemd; opt out with `CONDUIT_OFFSETS_AUTOUPDATE=false`). Manage directly with `moav conduit-offsets {install|uninstall|status}`. On hosts without systemd it's skipped and the script can be run by hand or from cron

## [1.7.8] - 2026-05-15

### Upgrade Notes
- **No re-bootstrap required for the Xray `clients` → `users` rename.** Xray v26.5.9 renamed the inbound `clients`/`accounts` key to `users` ([#6083](https://github.com/XTLS/Xray-core/pull/6083)), but kept `clients`/`accounts` as **backward-compatible aliases** — the VLESS/Hysteria/Shadowsocks inbound configs now carry both fields and copy `clients → users` at build time. An existing `configs/xray/config.json` (still using `clients`) loads correctly on v26.5.9 with no crash and no action needed; MoaV's templates emit `users` for fresh installs. Re-bootstrapping (`moav bootstrap`, idempotent, preserves keys + user UUIDs) is **optional** — it just migrates the on-disk config to the new key. To pick up the new `XDNS_RESOLVERS` default in *existing* user bundles, run `moav regenerate-users`. Note: a rebuilt image only takes effect once containers are recreated — use `moav start` (`docker compose up -d`), since `moav restart` reuses the old image

### Added
- **`moav doctor logs` check** — New diagnostic that scans `/var/lib/docker/containers/*/*-json.log` for files over 100 MB, prints them grouped by container name with total MB, and prompts interactively to truncate them in place. Helpful for clearing accumulated logs from pre-1.7.6 containers that were created before the `x-logging` rotation anchor was added (rotation only applies to containers created *after* the upgrade — pre-existing containers keep growing under Docker's unbounded default until they're recreated). Skips the prompt non-interactively (cron / piped runs) and prints the manual `truncate -s 0` command instead. Auto-prefixes `sudo` when not running as root
- **`XDNS_RESOLVERS` env var (multi-resolver fan-out for XDNS)** — New optional CSV env var (default `1.1.1.1,8.8.8.8`) wired into the client-side `xdns-config.json` finalmask settings. Enables Xray's per-PR-#5872 round-robin distribution of DNS queries across multiple public resolvers within a single mKCP session — higher throughput plus a real fallback when one resolver is rate-limited (e.g. during Iran shutdowns when `8.8.8.8` gets throttled or null-routed). Only applied to the DNS-tunnel-mode bundle (`xdns-config.json`); direct mode (`xdns-direct-config.json`) omits the field since it bypasses public DNS entirely. Set `XDNS_RESOLVERS=` (empty) to fall back to single-resolver legacy behavior

### Changed
- **`xray` image now installs the prebuilt release binary instead of compiling from source** — `Dockerfile.xray` downloads the official `Xray-linux-<arch>.zip` for the pinned tag (the same binary the client image already uses, FinalMask/XDNS included) and only falls back to a `go build` from source when the download is unavailable (e.g. GitHub blocked, or no asset for the target arch). This cuts the `xray` build from a multi-minute Go compilation to a few seconds. Source compilation was a leftover from the pre-1.7.4 era of building Xray-core from its `main` branch; now that builds are pinned to release tags, the prebuilt binary is functionally identical. The Go module-proxy resilience knobs below still apply to the fallback path
- **Resilient Go module fetching for source builds** — All services that compile Go from source (xray, amneziawg, dnstt, dns-router, snowflake, and the client image) now build with `GOPROXY=https://proxy.golang.org|https://goproxy.cn|direct` and `GOSUMDB=off`, exposed as overridable `.env` knobs and build args. The pipe (`|`) separator makes Go fall through to the next proxy on **any** error — including the `403 Forbidden` that Google's module CDN returns to a VPS under rate-limiting or regional restriction — whereas the previous comma (`,`) only fell through on 404/410 and would hard-fail the build (e.g. `klauspost/compress@v1.17.4: 403 Forbidden` mid-`xray` build even though the module exists). `goproxy.cn` is not subject to Google's CDN limits; `GOSUMDB=off` drops the matching dependency on Google's checksum server while module integrity stays verified against each upstream repo's committed `go.sum`. Override `GOPROXY`/`GOSUMDB` in `.env` to force Google-only or point at a private Athens mirror
- **`moav update` post-update guidance is now config-aware** — After a self-update pull, `moav update` diffs the pulled commits for changed server config templates (`configs/**/*.template`). When a template changed, it prints a complete ordered apply sequence — `moav build … --no-cache` → `moav bootstrap` (regenerate configs to pick up the change) → `moav regenerate-users` → `moav start` — instead of the previous bare `moav build` hint. This surfaces two non-obvious steps: (1) a config-template change generally wants a re-bootstrap to take effect, not just a rebuild, and (2) `moav build` doesn't recreate containers and `moav restart` reuses the old image, so `moav start` (`docker compose up -d`) is required to actually run rebuilt images. Detection is print-only by design — it never auto-rebuilds or restarts a running node
- **TROUBLESHOOTING.md "Disk space full"** — Documents in-place log truncation (`truncate -s 0` keeps the file descriptor live so Docker keeps writing without a service restart), the `--force-recreate` follow-up to enforce the 10m × 3 rotation policy on still-running pre-1.7.6 containers, and adds `docker builder prune -af` to the common-space-hogs list
- **Xray-core** — Updated v26.3.27 → v26.5.9 (six intermediate releases). Highlights since v26.3.27: **mKCP transport now defaults to an unaggressive congestion-control strategy** (v26.4.13, [#5890](https://github.com/XTLS/Xray-core/pull/5890)) — the old behavior multiplied the congestion window by 20× which got punished harder on lossy networks; the new default respects congestion control and is a free stability win for XDNS in heavily-throttled environments. **XHTTP client memory-leak fix in stream-up/one** (v26.5.9, [#6095](https://github.com/XTLS/Xray-core/pull/6095)) — automatic on rebuild. **XDNS finalmask now supports `resolvers` (client-side multi-resolver fan-out)** (v26.4.13, [#5872](https://github.com/XTLS/Xray-core/pull/5872)) — wired into MoaV's client bundles via the new `XDNS_RESOLVERS` env var (see Added). **XDNS server now uses a single UDP socket for multiple resolvers** (v26.4.25, [#5982](https://github.com/XTLS/Xray-core/pull/5982)) — automatic. Also: TLS outer ALPN camouflage option for WSS/HUS (v26.5.3, [#6034](https://github.com/XTLS/Xray-core/pull/6034)); FinalMask `bbrProfile` for QUIC variants (v26.5.3, [#5869](https://github.com/XTLS/Xray-core/pull/5869), not applicable to MoaV's current mKCP-based XDNS); header-custom finalmask programmable handshake templates (v26.4.15, [#5920](https://github.com/XTLS/Xray-core/pull/5920), MoaV uses `type: xdns` so not directly affected). **Config-schema rename** `clients` / `accounts` → `users` in inbound settings (v26.5.9, [#6083](https://github.com/XTLS/Xray-core/pull/6083)) — MoaV's templates (`configs/xray/config.json.template` and the dynamic `vless-xdns` inbound in `scripts/bootstrap.sh`) now emit `users`, but the rename is **backward-compatible**: Xray keeps `clients`/`accounts` as aliases, so an existing on-disk config keeps working with no re-bootstrap (see Upgrade Notes above)
- **telemt** — Updated 3.4.10 → 3.4.11. Highlights: persistent quota state (`general.quota_state_path`), REST quota-reset endpoint (`POST /v1/users/{username}/reset-quota`), optional strict config validation (`general.config_strict`), per-user source deny lists (`access.user_source_deny` with CIDR matching), and security hardening — constant-time API authorization-header comparison, fail-closed source-deny-list checks at TLS and MTProto handshake stages, rejection of untrusted PROXY-protocol sources before header parsing, and bounded control-plane HTTP timeouts. New TLS health metrics (profile state tracking) and class-based rejected-connection metrics are emitted automatically; existing Grafana panels keep working, dashboard refresh deferred to a follow-up. No new env knobs are exposed by MoaV — operators using the REST API directly can take advantage of the new features by editing `configs/telemt/config.toml`
- **wstunnel** — Updated 10.5.3 → 10.5.5. Bug fixes only: HTTP proxy password no longer leaks into logs ([#500](https://github.com/erebe/wstunnel/issues/500)), TLS platform provider no longer mis-used for DNS resolution ([#501](https://github.com/erebe/wstunnel/issues/501)), `read_system_conf` skipped on Android (improves mobile bundle compatibility), Rust toolchain bumped to 1.95. No CLI or config changes
- **DNS-tunnel docs — reachable-resolver guidance** — Added a new *Reachable DNS resolvers* subsection under `docs/protocols.md` XDNS, with short cross-refs from `docs/DNS.md` (DNS-tunnel section) and `docs/CLIENTS.md` (XDNS Tips). Explains that the right public DNS resolver changes per network during shutdowns (well-known resolvers like `1.1.1.1` / `8.8.8.8` are commonly throttled or null-routed), links to the [findns](https://github.com/SamNet-dev/findns) and [dns-mns](https://gitlab.com/E-Gurl/dns-mns) scanners, and ties the new `XDNS_RESOLVERS` env knob back to the same canonical guidance. The bundled per-user `xdns.txt` shows the actual resolvers the user's config is round-robining over and points to the same scanners. Client-guide HTML keeps its existing one-liner reference (unchanged scanner links, updated to note multi-resolver fan-out is on by default)

## [1.7.7] - 2026-05-01

### Added
- **Shadowsocks-2022 protocol** — New `ENABLE_SS=true` toggle adds a Shadowsocks-2022 inbound to the existing sing-box service (no new container, no new daemon). Defaults to `2022-blake3-aes-128-gcm` for multi-user support (sing-box's SS-2022 multi-user mode only supports the AES variants; `chacha20-poly1305` is single-user only). Per-user PSKs are generated at bootstrap and persisted under `state/users/<id>/shadowsocks.env`; the server PSK lives at `state/keys/shadowsocks-server.psk`. Bootstrap auto-regenerates the SS state if `SS_METHOD` changes and the saved PSK no longer matches the cipher key length. User bundles emit a standard `ss://` URI + QR + sing-box JSON, compatible with NekoBox / Hiddify / Streisand / sing-box clients and the Outline mobile app. Off by default; enable via `ENABLE_SS=true` in `.env` and re-bootstrap. Refs [#93](https://github.com/shayanb/MoaV/issues/93)
- **Container log rotation** — All long-running services in `docker-compose.yml` now use a shared `x-logging` anchor that caps each container's `json-file` log at `max-size: 10m` × `max-file: 3` (~30 MB per container). Previously containers used the Docker default with no size cap, and chatty services (xray, sing-box, telemt, prometheus) could fill `/var/lib/docker/containers` over time on long-running VPS deployments
- **`DNSTT_VERSION` env knob** — dnstt builds (server + client) are now pinned to a configurable git tag (`v1.20260501.0` default) and tracked alongside the other component versions in `moav update` and `moav versions`. Was previously cloned at HEAD with no version visibility

### Fixed
- **dnstt-server silent stalls under load** — Updated dnstt to upstream `v1.20260501.0`, which fixes a bug where the server could keep accepting DNS queries but stop sending responses if `sendLoop` died on a transient `sendto: operation not permitted` (commonly triggered when the host's Netfilter conntrack table overflows under many concurrent users). Process now exits if either `recvLoop` or `sendLoop` returns, and `sendLoop` only logs (no longer dies on) most send errors. See [net4people/bbs#609](https://github.com/net4people/bbs/issues/609)
- **`moav user add` failing on `wireguard/server.pub` permission denied** — `wg-user-add.sh` defensively re-synced the server public key file on every run, but bootstrap chowns `configs/` to `0:1000` with `chmod -R g+r` (read-only for the admin container's uid 1000). The write failed and `set -euo pipefail` aborted the whole user-add flow. The sync is now best-effort: failed writes log a warning and the script proceeds with the in-memory key from `wg show` (which is authoritative)
- **dnstt build fails over bamsoftware.com dumb HTTP** — `Dockerfile.dnstt` and the dnstt-client builder stage in `Dockerfile.client` used `git clone --depth 1 --branch ${DNSTT_VERSION}`, which requires smart-HTTP upload-pack. bamsoftware.com serves git as a static Apache directory and rejected the request with exit 128. Switched to a full clone + `git checkout ${DNSTT_VERSION}` (tag pinning preserved)

## [1.7.6] - 2026-05-01

### Added
- **telemt container healthcheck** — Wired up the `telemt healthcheck … --mode liveness` subcommand (added upstream in 3.4.3) as a Docker healthcheck on the telemt service. `docker compose ps` and `moav doctor` now reflect actual daemon liveness instead of just process-up state

### Changed
- **telemt** — Updated 3.3.39 → 3.4.10. Highlights since 3.3.39: configurable mask timeouts and unlimited `mask_relay_max_bytes` (3.4.0/3.4.5), traffic-control + weighted fairness + 3-leveled pressure model (3.4.1/3.4.4), TLS 1.2/1.3 correctness in fronting + full ServerHello + ALPN in TLS Fetcher (3.4.6), unknown-SNI reject-handshake option (3.4.4), bounded relay queues by bytes (3.4.7), restored active-IP observability for users without unique-IP limits (3.4.8), TimeWindow IP-limit fix and atomic config Includes (3.4.9), and TLS full-cert budget bookkeeping + IP-tracker refactor (3.4.10). No config-file changes required — MoaV's existing `[censorship]` and `[server.api]` sections remain compatible
- **wstunnel** — Updated 10.5.2 → 10.5.3 (proxy-protocol IP-family-mismatch workaround, log-noise reduction, deps bump)
- **Grafana Conduit dashboard** — Region panels now show `CODE: Country Name` (full ISO 3166-1 set, 249 mappings) instead of bare 2-letter codes; *Connected Clients by Region* enlarged and joined by a sortable Mean/Max/Last stats table (PR [#91](https://github.com/shayanb/MoaV/pull/91), thanks @jSFBay)

## [1.7.5] - 2026-04-12

### Added
- **`moav switch-dns`** — New command to switch active DNS tunnel(s) on port 53. Supports single tunnels (`xdns`, `dnstt`, `slipstream`) and same-group combos (`dnstt+slipstream` via dns-router). Flips `ENABLE_*` flags, swaps `PORT_DNS`/`PORT_XDNS`, stops old services, starts new profile. Pre-flight checks for missing state keys (dnstt/slipstream) and offers to re-run bootstrap before starting containers that would otherwise crash-loop
- **`moav doctor conflicts`** — New diagnostic check for DNS tunnel port-group conflicts: multiple groups enabled in `.env`, multiple groups running, config/runtime drift, and dns-router crash loops. Uses a "port group" model where tunnels in the same group (e.g. dnstt+slipstream share dns-router) coexist via subdomain routing, while tunnels in different groups conflict on port 53
- **Per-service state key checks in `moav doctor config`** — Detects when an enabled service (dnstt, slipstream, wireguard, amneziawg) is missing its key files, which previously only surfaced as silent container crash loops

### Changed
- **DNS tunnel defaults flipped** — `ENABLE_DNSTT=true` and `ENABLE_SLIPSTREAM=true` are now the defaults; `ENABLE_XDNS=false`. Rationale: dnstt+Slipstream have broader client-ecosystem support (standalone binaries on 25+ platforms) while XDNS requires a FinalMask-aware Xray client (Happ, Xray CLI). `PORT_DNS=53` and `PORT_XDNS=5353` are the new default port assignments. Switching is a one-command operation via `moav switch-dns xdns`. `moav update` runs an automatic migration that detects sparse `.env` files and pins explicit values based on currently-running containers before `check_env_additions` appends the new defaults — existing installs are never silently flipped
- **`moav start` blocks DNS tunnel conflicts** — Previously only warned; now hard-fails when starting a profile would put tunnels from different port groups on port 53. `--force` bypasses the check. Same-group tunnels (dnstt+slipstream) still allowed to coexist via dns-router multiplexing
- **`dns_tunnels_running` detection for shared containers** — xray serves both XHTTP and XDNS; previously "xray container running" was mis-reported as "xdns running" even when `ENABLE_XDNS=false`. Now requires the enable flag to be true for tunnels on shared containers
- **telemt** — Updated to 3.3.39 (memory hard-bounds, TLS fronting hash compact cert, bounded retries, build info metrics)
- **TrustTunnel** — Updated server to v1.0.33 (deep-link DNS upstreams and server display names)
- **TrustTunnel Client** — Updated to v1.0.49 (deep-link import, DNS socket hardening, `dns_upstreams` moved to `[endpoint]` section)

### Fixed
- **GeoIP database download during bootstrap was slow** — Switched `geoip-updater` from `python:3.11-alpine` (~50 MB) to `curlimages/curl:latest` (~9 MB), eliminating the in-container `apk add curl` step that ran on every invocation. First-run bootstrap is faster and subsequent GeoIP refreshes are near-instant
- **dns-router crash loop under port 53 conflict** — Previously when both XDNS (via xray) and dnstunnel profile were started, dns-router would infinitely restart trying to bind host port 53 already held by xray. Now blocked at `moav start` with a clear error message pointing to `moav switch-dns`
- **Silent dnstt/slipstream crash loops on missing keys** — When `ENABLE_DNSTT=true` or `ENABLE_SLIPSTREAM=true` were set after initial bootstrap, containers started but waited indefinitely for key files that were never generated. `moav switch-dns` now detects missing keys pre-start and offers to bootstrap; `moav doctor` flags the condition explicitly

## [1.7.4] - 2026-03-27

### Added
- **Connection inspector** — `./scripts/inspect-connections.sh` parses sing-box logs with GeoIP country lookup. Filter by country, time range, CSV/JSON export. Shows source IPs, destinations, users, inbounds, error rates per IP
- **Shell completions auto-install** — `moav install` now adds completions to `.bashrc`/`.zshrc` and sources them immediately (no shell restart needed)

### Changed
- **Xray-core** — Updated to v26.3.27 (was building from main branch). Now pinned to release tags for reproducible builds. Key improvements: mKCP ACK fix (better XDNS stability), new Finalmask obfuscation methods (header-custom, Sudoku), XHTTP/H3 with BBR congestion control, expanded mKCP TTI range (10-5000ms)
- **telemt** — Updated from 3.3.28 to 3.3.32. DPI evasion hardening, adaptive TLS fingerprint profiles (Chrome/Firefox/TLS1.2 cascade), parallel health checks, improved concurrency model
- **XHTTP share links** — Added `headers=chrome` parameter for User-Agent spoofing across all HTTP headers (Xray v26.3.27 feature)
- **XDNS client instructions** — Updated to reference Xray v26+, Happ listed for all platforms
- **Shell completions** — Added `donate`, `admin`, `xhttp` profile, `xray` service, all monitoring exporters, service aliases, `--local` build targets
- **OPSEC guide rewrite** — Docker/UFW bypass warning with three mitigation options (IP whitelist, localhost binding, ufw-docker). Admin/monitoring access control section. Docker security hardening documentation. Updated commands, checklist, and monitoring instructions
- **MahsaNet bulk donation** — Adaptive rate limiting: 1s between calls, increases to 3s after first 429. Retries extract wait time from API response

### Fixed
- **`dnstunnel` profile started when disabled** — Hardcoded fallback profile list included `dnstunnel` even when `ENABLE_DNSTT=false`. Now respects `ENABLE_*` flags
- **MkDocs tables not rendering** — 8 tables across 3 docs missing required blank line before table markup
- **Slipstream authoritative mode port** — Direct connection instructions now use `${PORT_DNS}` instead of hardcoded port 53

## [1.7.3] - 2026-03-24

### Added
- **Telemt teardown monitoring** — New Grafana dashboard panels for ME writer teardowns (attempts by reason/mode, success rate, escalations, duration) and exporter metrics from telemt 3.3.27+ API
- **CloudFront troubleshooting** — Diagnostic steps and fix commands for `bad "Sec-WebSocket-Key" header` errors in `docs/TROUBLESHOOTING.md` and `docs/DNS.md`
- **Xray and WireGuard in admin dashboard** — Services grid now includes xray (XHTTP/XDNS) and wireguard; users table shows XHTTP and XDNS protocol tags
- **MahsaNet setup prompt** — Admin dashboard shows collapsed setup section with instructions when MahsaNet API key is not configured
- **Happ client** — Added to all platform client app tables on website and READMEs

### Changed
- **Telemt** — Updated from 3.3.23 to 3.3.28
- **MahsaNet donation rate limiting** — Admin dashboard now pauses every 8 API calls and retries on HTTP 429 with extracted wait time (matches CLI behavior)
- **Admin dashboard mobile layout** — Users table horizontally scrollable, forms stack vertically, protocol checkboxes wrap
- **Admin collapse/panel behavior** — Collapsing a section auto-closes any open create/donate panel; panels expand section when opened
- **README cleanup** — Both EN and FA READMEs updated with current commands (`doctor`, `donate`, `admin password`), removed verbose sections, added admin credentials note
- **Website metadata** — Updated to 16+ protocols, added XDNS/FinalMask/Happ to SEO, version bumped to 1.7.3
- **CloudFront docs** — Added `CDN_TRANSPORT=ws` requirement warning, origin/viewer protocol clarification, fix-existing-distribution CLI commands

### Fixed
- **Admin user creation permission error** ([#85](https://github.com/shayanb/MoaV/issues/85)) — `configs/sing-box/` and other config directories now get `chmod a+rwX` in admin entrypoint; `user-add.sh` uses `su-exec root` fallback when `sudo` is unavailable (admin container)
- **MahsaNet donate panel hidden when collapsed** — Panel CSS exclusion and section auto-expand on toggle

## [1.7.2] - 2026-03-22

### Added
- **DNS zone file export** — `moav doctor` generates a BIND-format zone file (`outputs/dns-records.txt`) with all required DNS records, importable into Cloudflare; includes all protocols even when disabled for easier setup
- **XDNS NS record in DNS setup table** — Bootstrap DNS configuration table now includes XDNS NS delegation (`x.domain`) and a "Used by" column showing which protocols need each record
- **Happ client** — Added to all protocol client app tables in user bundle (iOS, Android, Desktop)
- **XHTTP tag** — Added to Xray-core client app listings
- **XDNS documentation** — Added NS delegation step and port configuration notes to `docs/DNS.md`

### Changed
- **Default protocol toggles** — XDNS and XHTTP now enabled by default; dnstt and Slipstream disabled by default. XDNS uses the latest Xray-core FinalMask technology that is currently working in the most restrictive environments. To use dnstt/Slipstream instead, set `ENABLE_XDNS=false` and `ENABLE_DNSTT=true` in `.env`
- **`PORT_DNS` default** — Changed from `53` to `5353` in `.env.example` to avoid port 53 conflict with XDNS (which is now enabled by default)
- **Docker Compose security hardening** (PR [#81](https://github.com/shayanb/MoaV/pull/81)) — `cap_drop: ALL` with selective `cap_add`, `read_only: true`, `no-new-privileges`, resource limits per service; removed `privileged: true` from WireGuard/AmneziaWG; `gosu` → `setpriv` for capability retention through user switch
- **User bundle template cleanup** — Removed all "When to use" sections; replaced per-protocol "Download Client" blocks with links to unified apps table; streamlined XDNS Telegram proxy instructions
- **CLI help reorganized** — Grouped commands into logical sections (Setup, Services, Users, Donate & Test, Backup & Migration); removed duplicate Migration section; trimmed examples
- **Monitoring prompt** — `ENABLE_MONITORING` no longer pre-set to `false` in `.env.example`; users are now prompted during bootstrap whether to enable monitoring
- **GitHub release action** — Title format changed from "MoaV vX.Y.Z" to "vX.Y.Z"; documentation links updated to moav.sh/docs

### Fixed
- **XDNS user bundle not generated during bootstrap** — `generate-user.sh` now creates `xdns-config.json` and `xdns-direct-config.json` (previously only generated by `singbox-user-add.sh` on host)
- **XDNS user bundle not replaced in `user-add.sh`** — `{{CONFIG_XDNS}}` and `{{CONFIG_XDNS_DIRECT}}` placeholders were not being replaced when creating users from the admin dashboard; added file-based Python replacement
- **Port 53 conflict on fresh install** — Bootstrap and `moav start` now check for systemd-resolved when XDNS is enabled (not just dnstt/Slipstream); auto-disables dnstt/Slipstream if XDNS is active to prevent port 53 double-bind
- **`moav migrate-ip` missing protocols** — Added IP migration for AmneziaWG, Telegram MTProxy, XHTTP, CDN, TrustTunnel, XDNS, and README.html
- **Admin dashboard user creation permission error** — Entrypoint now pre-creates required directories (`outputs/bundles`, `state/users`, etc.) before dropping privileges
- **Bootstrap config permissions** — Generated configs now group-readable (`chown 0:1000`, `chmod g+r`) for non-root admin container
- **`copyConfig()` broken for multiline configs** — Removed guard that blocked copying JSON config blocks; added fallback copy methods
- **Let's Encrypt certificate generation failed** — Decoy nginx missing `NET_BIND_SERVICE` capability (couldn't bind port 80 for ACME challenge); certbot blocked by `read_only: true`
- **Grafana proxy "Host Error"** — Missing `NET_BIND_SERVICE` capability and `/var/log/nginx` tmpfs
- **Grafana plugin install "no space left"** — `/tmp` tmpfs increased from 10MB to 100MB
- **GeoIP database download failed on bootstrap** — `read_only: true` blocked `apk add curl` in geoip-updater container
- **Telemt "Read-only file system" warning** — Added `/app/cache` tmpfs for beobachten snapshot writes
- **Conduit entrypoint** — Fixed `setpriv` compatibility with `no-new-privileges` by adding required capabilities
- **Bash 3.x compatibility** — Replaced `declare -A` associative array (bash 4+ only) with function-based lookup for `--local` build map

## [1.7.0] - 2026-03-19

### Added
- **XDNS protocol (VLESS+mKCP+DNS)** — DNS tunnel via Xray-core FinalMask, encodes VPN traffic inside DNS-like packets for use during heavy internet shutdowns
  - Runs as additional inbound in existing xray container on port 53 (direct, bypasses dns-router)
  - Mutually exclusive with dnstt/Slipstream (both use port 53) — `moav doctor` warns about conflicts
  - Server MTU 900 (return path), client MTU configurable (35/67/130) based on DNS resolver compatibility
  - Client config generated as JSON file in user bundles with Telegram SOCKS proxy deep link
  - Per-inbound traffic stats on Grafana: XDNS vs XHTTP traffic breakdown
  - Best for Telegram and chat apps — not fast enough for web browsing
  - Requires FinalMask-capable client (Happ beta, Xray CLI)
- **Xray-core built from source** — Dockerfile changed from pre-built binary to Go multi-stage build from main branch, ensuring latest FinalMask/XDNS support and PR #5773 mKCP MTU fix
- **`moav doctor` command** (PR [#79](https://github.com/shayanb/MoaV/pull/79)) — 9 diagnostic checks:
  - `docker` — Docker daemon, Compose version, disk usage
  - `memory` — RAM availability, warns if too low for monitoring
  - `disk` — Free disk space with cleanup suggestions
  - `dns` — DNS records for all enabled protocols including XDNS NS delegation
  - `services` — Enabled vs running containers, crash-loop detection
  - `config` — Bootstrap status, config file existence
  - `ports` — Port availability, systemd-resolved conflicts, XDNS/dnstt port 53 conflict
  - `env` — Missing `.env` variables compared to `.env.example`
  - `updates` — Version check against latest GitHub release
- **Xray per-inbound traffic metrics** — `xray_inbound_upload_bytes` and `xray_inbound_download_bytes` with inbound tag label; Grafana panels: "Traffic by Protocol" (timeseries) and "Protocol Traffic Total" (table)

### Fixed
- **DNS NS delegation check** — Fixed `dig +short NS` not returning subdomain NS records; now queries authoritative nameserver's AUTHORITY section
- **Xray user-add to all VLESS inbounds** — New users are added to both `vless-xhttp-reality` and `vless-xdns` inbounds (previously only XHTTP)
- **dns-router graceful exit** — Exits cleanly (exit 0) when no routes configured (XDNS mode), instead of fatal error

### Fixed
- **`moav migrate-ip` missing protocols** — Added IP migration for AmneziaWG, Telegram MTProxy, XHTTP, CDN, TrustTunnel, XDNS, and README.html user bundles
- **Bootstrap config permissions** — Generated configs now group-readable for non-root admin container (`chown 0:1000`, `chmod g+r`)

### Changed
- **telemt** updated to [3.3.23](https://github.com/telemt/telemt/releases/tag/3.3.23)
- **XDNS/dnstt mutual exclusion** — Port 53 can only be used by one DNS tunnel at a time; `moav doctor` and `moav start` warn about conflicts
- **ENABLE_XDNS defaults to false** — opt-in to avoid port 53 conflict with existing dnstt/Slipstream setups

## [1.6.2] - 2026-03-17

### Added
- **`moav donate` unified donation hub** — Shows all 3 services (MahsaNet, Conduit, Snowflake) with live stats, interactive wizard with action menu, setup for all services
- **`moav donate status`** — Live stats for all donation services: MahsaNet config counts, Conduit connected clients and bandwidth, Snowflake people served and bandwidth relayed
- **`moav donate setup`** — Configure Conduit bandwidth/max clients and Snowflake bandwidth/capacity from CLI, with automatic container restart
- **`moav donate info`** — Show Psiphon Conduit Ryve deep link and QR code with usage instructions
- **Telemt anti-DPI tuning documentation** — Collapsible reference in protocols.md with all 17 settings grouped by purpose
- **Grafana browser tab differentiation** — Title changed to "MoaV Grafana" to distinguish from admin dashboard tab; favicon copied to both `img/` and `build/img/` paths; HTML `<title>` tag patched as reliable fallback

### Fixed
- **MahsaNet 429 rate limiting** — Donate flow now detects HTTP 429 throttling, waits the specified cooldown, and retries automatically (no more lost configs during bulk donation)
- **Snowflake stats query** — Fixed `localhost` → `127.0.0.1` for Alpine BusyBox wget IPv6 resolution issue
- **Conduit stats query** — Use `curl` first (conduit has curl, not wget)
- **`_format_bytes_sh`** — Replaced `bc` dependency with portable `awk` arithmetic

### Changed
- **telemt** updated to [3.3.20](https://github.com/telemt/telemt/releases/tag/3.3.20) — draining writers threshold, max_connections limit, per-user IP limit inheritance, data path option

## [1.6.1] - 2026-03-15

### Fixed
- **Xray Stats API traffic parsing** — Output is JSON format, not protobuf text; replaced regex parser with `json.loads()` for correct per-user traffic metrics
- **Xray Stats API `-reset` flag** — Removed `-reset` flag that returned empty values when delta was 0; now reads cumulative values (Prometheus handles rate calculation)
- **sing-box Clash API authentication** — Fixed secret loading from state volume (`/state/keys/clash-api.env`) and auth method (`Authorization: Bearer` header)
- **Bootstrap `local` outside function** — `local` keyword on line 64 caused `bootstrap.sh` to fail in domainless mode ([#77](https://github.com/shayanb/MoaV/issues/77))
- **DNS port 53 check on `moav start all`** — No longer prompts to disable systemd-resolved when DNS tunnels are disabled (`ENABLE_DNSTT=false`)
- **Double monitoring prompt** — `moav start all` no longer asks "Enable monitoring?" twice when `ENABLE_MONITORING=false`
- **Grafana geo panels not rendering** — Moved nested panels to top-level (Grafana requires uncollapsed row children at top level)
- **Grafana geo table empty** — Changed table queries from ephemeral gauge (`active_users_by_country`) to cumulative counter (`connections_by_country`) for sing-box/xray; changed WG/AWG to `count by (country) (peer_active)` to show all peers

### Changed
- **Xray Grafana dashboard layout** — Reorganized panels: User Details table moved to same row as Connection Rate and Connections by User

## [1.6.0] - 2026-03-15

### Added
- **GeoIP country labeling** — Country-level user distribution on Grafana dashboards
  - DB-IP Lite database (free, no API key, local lookups, zero external API calls at runtime)
  - `geoip-updater` one-shot service downloads the MMDB database into shared volume
  - sing-box and xray exporters extract client source IPs from logs, expose `*_connections_by_country` and `*_active_users_by_country` metrics
  - WireGuard and AmneziaWG exporters add `country` label to per-peer metrics, expose `*_active_peers_by_country` aggregate
  - Grafana dashboards: "Geographic Distribution" row with donut pie chart and sorted country table on all 4 dashboards
  - Graceful degradation: missing GeoIP DB returns "XX", existing metrics unaffected
- **Non-root containers** (PR [#68](https://github.com/shayanb/MoaV/pull/68)) — All service containers run as non-root `moav` user
  - `setcap` for privileged port binding (sing-box, wstunnel, telemt, nginx, trusttunnel)
  - `gosu`/`su-exec` privilege drop pattern for services needing root-owned volume fixup
  - Docker socket proxy (`tecnativa/docker-socket-proxy:v0.4.2`) replaces raw socket mount for admin
  - `.dockerignore` prevents secrets from leaking into build context
- **Telemt anti-DPI tuning** — Configurable anti-censorship settings for MTProxy
  - Keepalive payload randomization, timing jitter, warmup jitter, pool hardswap
  - Fast reconnect backoff, config stability snapshots, STUN TCP fallback
  - All 17 settings configurable from `.env` with documentation and upstream doc links
  - Telemt REST API exporter with Grafana panels (ME pool, DC availability, upstream quality, NAT type)
- **Xray Stats API integration** — Per-user upload/download traffic metrics via `-reset` flag for correct incremental accumulation
- **Admin dashboard overhaul** — Collapsible MahsaNet/Users sections, Prometheus-backed aggregate stats (active users, total users, connections, traffic across all protocols), improved footer with server info and live uptime, toast notifications replacing browser alerts
- **`moav donate` command refactor** — Flat command structure (`moav donate`, `moav donate setup`, `moav donate list`, `moav donate delete`) replacing nested `moav donate mahsanet --flag` pattern; interactive wizard with service auto-selection
- **Bootstrap Docker optimization** — sing-box binary downloaded directly instead of pulling full container image (fixes hang in censored networks, [#75](https://github.com/shayanb/MoaV/issues/75)); scripts volume-mounted instead of COPY'd; cached image reuse on subsequent runs

### Fixed
- **Xray IPv6 "network unreachable" errors** — Added blackhole outbound + routing rule to silently drop IPv6 traffic (`::/0`), fixing slowness caused by clients sending raw IPv6 addresses
- **Xray per-user traffic Grafana panels empty** — `statsquery` without `-reset` returns cumulative values causing double-counting; added `-reset` flag and fallback binary path
- **Bootstrap invalidating user bundles** — `generate-user.sh` now guards each protocol with file existence checks, only regenerates when configs are missing or `FORCE_REGENERATE` is set
- **Bootstrap failing for all users on single failure** — Made `generate-user.sh` calls non-fatal (`|| log_error`) so one user's failure doesn't prevent server config generation
- **sing-box cert permission denied after non-root migration** — Entrypoint copies certs to `/tmp/certs/` and rewrites config paths before privilege drop
- **TrustTunnel `sed` on read-only filesystem** — Configs copied to `/tmp/trusttunnel/` before `sed` cert path rewrite
- **TrustTunnel `exec failed: operation not permitted`** — Added `cap_add: NET_ADMIN` to docker-compose for `gosu` + `setcap` to work
- **Conduit `/data` permission denied** — Added `gosu` privilege drop with `chown` for root-owned volumes from pre-migration runs
- **Admin outputs/bundles write permission** — Entrypoint `chown`s writable mounts before `su-exec` privilege drop
- **dnstt/slipstream `depends on undefined service`** — Removed cross-profile `depends_on: sing-box` that broke `moav start dnstunnel` without proxy profile
- **MahsaNet health display `{}%` / `[object Object]`** — Fixed CLI jq filter and dashboard JS to handle non-numeric `health_status_percent` from API
- **wstunnel missing `setcap`** — Added `setcap cap_net_bind_service` for port 443 binding as non-root
- **Xray user-add targeting wrong inbound** — `singbox-user-add.sh` added users to `inbounds[0]` (api-in) instead of the VLESS inbound; fixed to target by tag `vless-xhttp-reality`
- **sing-box GeoIP Clash API auth** — Fixed secret loading from state volume (`/state/keys/clash-api.env`) and auth method (Bearer header)

### Changed
- **Renamed** `telemt-api-exporter` to `telemt-exporter` across all files
- **Exporter build contexts** changed to `./exporters` for shared `geoip.py` module access
- **sing-box version** bumped to 1.13.2 for bootstrap container

## [1.5.1] - 2026-03-14

### Added
- **XHTTP protocol (VLESS+XHTTP+Reality)** — New protocol powered by Xray-core, enabled by default
  - Full bootstrap integration: Xray config generation, user management, bundle generation
  - `moav user add` generates XHTTP share links, human-readable config, and QR codes
  - Donate path support: XHTTP configs can be donated via MahsaNet (CLI and admin dashboard)
  - Client support: `moav client --test` and `moav client --connect` support XHTTP via Xray-core binary
  - Works in domainless mode (uses Reality TLS camouflage, no domain needed)
  - Independent `XHTTP_REALITY_TARGET` config for separate SNI from Reality
- **AWS CloudFront CDN documentation** — Alternative CDN option for regions where Cloudflare is blocked
  - sslip.io workaround for CloudFront's domain-only origin requirement
  - Both Web UI and CLI setup instructions
- **Reality target (SNI) selection guide** — New "Choosing a Reality Target" section in SETUP.md
  - TLS 1.3 + H2 verification command
  - Strategy guide for censored regions (prefer domestic, high-traffic domains)
  - Example targets for Iran (blubank.com, divar.ir, snapp.ir)
- **XHTTP in client Docker image** — Xray-core binary added to `Dockerfile.client` for XHTTP test/connect
- **Xray Grafana monitoring dashboard** — Per-user connection metrics for XHTTP via log-based exporter
  - Total Connections, Active Users, Total Users stat panels
  - Connections & Users over time, Connection Rate time series
  - Per-user connections breakdown and User Details table
  - New `xray-exporter` service (Prometheus metrics on port 9103)

### Fixed
- **XHTTP menu showing "disabled" despite `.env` being correct** — Logic bug in `moav.sh`: `xhttp_enabled` was initialized to `false` and the condition could never set it to `true`
- **XHTTP user bundles not generated on `moav user add`** — `singbox-user-add.sh` was completely missing XHTTP support; added Xray config addition, file generation, and container restart
- **XHTTP donate mode broken** — Both `user-add.sh` and `generate-single-user.sh` were missing XHTTP toggle in donate mode
- **`.env` variable reading with inline comments** — `get_env_val` returned values with trailing comments (e.g., `true # comment`), causing false negatives
- **Admin password reset not updating Grafana** — `moav admin password` now resets the password in Grafana as well
- **Bootstrap logging wrong message when Reality keys exist** — Incorrectly reported generating new keys when reusing existing ones
- **Regenerate block using raw `grep | cut`** — Replaced with `get_env_val` calls for consistent `.env` parsing
- **MahsaNet donate list column alignment** — Fixed URL truncation overflow and misaligned `Used` column
- **XHTTP share link naming** — Changed from `#username-xhttp` to `#MoaV-XHTTP-username` to match other protocols' naming convention

### Changed
- **XHTTP enabled by default** — `ENABLE_XHTTP=true` in `.env.example` (was opt-in `false`)
- **"domain-less" → "domainless"** — Consistent terminology across all docs, scripts, and UI
- **Xray-core** updated to 26.2.6
- **CloudFront docs** — Corrected origin setup (requires domain name, not IP), fixed CLI install link, added `aws sso login` option

## [1.4.7] - 2026-03-14

### Added
- **MahsaNet config donation** — Donate VPN configs to MahsaServer.com (Mahsa VPN app, 2M+ users in Iran) directly from the admin dashboard ([#69](https://github.com/shayanb/MoaV/issues/69))
  - Protocol selection via checkboxes (Reality, Hysteria2, Trojan, CDN, XHTTP, Telegram)
  - `MAHSANET_API_KEY`, `MAHSANET_PROTOCOLS`, `MAHSANET_POOL` config options in `.env`
  - "Donated" tag displayed on admin dashboard for donated configs
  - `DONATE_ONLY_PROTOCOLS` generated only when donation is active
  - Telegram proxy included in default donated protocols
- **`moav admin password` command** — Reset admin dashboard password from the CLI ([#70](https://github.com/shayanb/MoaV/issues/70))
- **MkDocs documentation site** — Project documentation now served via MkDocs with philosophy, protocols, quick-start, and OPSEC pages
- **MahsaNet documentation** — Setup guide for MahsaNet donation flow in SETUP.md and CLI.md

### Fixed
- **Admin dashboard double submission** — Prevented duplicate form submissions from the dashboard
- **Admin password in domainless mode** — Fixed password setup failing without a domain ([#70](https://github.com/shayanb/MoaV/issues/70))
- **Admin container not reflecting password reset** — Container now properly rebuilds to pick up new credentials
- **MahsaNet donation URL** — Fixed incorrect API endpoint for config donation
- **MahsaNet Telegram donation** — Fixed Telegram proxy submission and disabled it by default for MahsaNet
- **`moav build` with multiple services** — Fixed bug when building multiple services in one command
- **Admin dashboard auto-refresh removed** — No more 60-second auto-reload; replaced with manual "Refresh" button in MahsaNet section

### Changed
- **telemt** updated to 3.3.16
- **TrustTunnel** updated to 1.0.17
- **TrustTunnel Client** updated to 1.0.23
- **Admin dashboard** — Default ad URL changed to vahidonline; prefix handling uses `continue` instead of `rewrite`

## [1.4.5] - 2026-03-09

### Fixed
- **Snowflake build failing in Russia** — `git clone` from `gitlab.torproject.org` times out in countries where it's blocked; replaced with `go install` via Go module proxy (`proxy.golang.org`, Google CDN) which bypasses the block. Applies to both `Dockerfile.snowflake` (proxy) and `Dockerfile.client` (snowflake-client)

### Changed
- **DNS documentation refreshed** — New "Do I Need a Domain?" section, domain-less mode guide, split port forwarding tables (domain-less vs with domain), all protocols/ports updated, Raspberry Pi tips, CGNAT troubleshooting
- **telemt** updated to 3.3.14
- **TrustTunnel** updated to 1.0.13
- **TrustTunnel Client** updated to 1.0.19

## [1.4.4] - 2026-03-03

### Added
- **Auto-detect missing `.env` variables** — `moav update` now compares your `.env` with `.env.example` and offers to auto-add new variables with defaults (timestamped separator for easy review)
- **CDN WS path auto-generation** — Bootstrap generates a random realistic API-like path (e.g., `/api/v3/storage/download/update-bundle-4821.bin`) instead of the obvious `/ws`, persisted in state for consistency across regenerations
- **HTTPUpgrade as default CDN transport** — Less fingerprinted by DPI than WebSocket; configurable via `CDN_TRANSPORT` env var (`httpupgrade` or `ws`)
- **TLS fingerprint randomization** — All protocols now use `fp=random` (rotates real browser fingerprints: Chrome, Firefox, Safari, Edge) instead of hardcoded `chrome`
- **Domain naming strategy guide** — New section in DNS docs with good/bad domain name examples and CDN subdomain advice for DPI evasion
- **CDN split SNI/Address/Host** — Client configs now use root domain as TLS SNI (less suspicious to DPI than `cdn.domain.com`), with CDN subdomain only in the encrypted Host header for Cloudflare routing. Optional `CDN_ADDRESS` for full domain separation (`CDN_SNI`, `CDN_ADDRESS` env vars)
- **Cloudflare SSL Flexible requirement** — Added clear documentation about SSL mode requirement across DNS, Setup, and Troubleshooting docs (prevents 525 errors)
- **Shell autocompletion** — `moav install` now installs bash/zsh completions for all commands, subcommands, services, profiles, and protocols; `moav uninstall` removes them
- **Admin dashboard redesign** — Services displayed as cards with auto-fill grid layout, green border for running services; favicon and logo in browser tab/header; centered footer with version and GitHub link
- **`moav user revoke` telemt support** — Revoking a user now removes their MTProxy secret from all three telemt config sections and restarts telemt

### Fixed
- **`moav update` crashing silently** — `check_component_versions()` failed under `set -euo pipefail` when version variables (e.g., `TELEMT_VERSION`, `SLIPSTREAM_VERSION`) were missing from older `.env` files; grep returning exit code 1 killed the script before reaching `check_env_additions()`
- **`moav logs <service>` showing all containers** — Service names like `slipstream` were resolved as profile aliases (→ `dnstunnel`), causing `--profile dnstunnel` to show all DNS tunnel services; now checks exact profile names first, then falls back to service resolution
- **Domainless mode `unbound variable` crash** — `TROJAN_LINK`, `HY2_LINK`, and their IPv6 variants were referenced unconditionally but only set when a domain is configured; all references now guarded with `[[ -n "${VAR:-}" ]]`
- **`moav uninstall` aborting on root-owned files** — Docker-created files under `configs/`, `state/`, `outputs/` are owned by root; `set -euo pipefail` + `rm` = permission denied = script abort; now uses `_wrm()` helper with sudo fallback
- **Permission denied on `state/users/` and `configs/`** — Docker containers create directories as root; non-root users couldn't write when adding/revoking users; added sudo mkdir/chmod fallback in user-add and user-revoke scripts
- **`mv` interactive prompt on Debian/Ubuntu** — Default `mv -i` alias caused scripts to hang waiting for confirmation; all `mv` calls now use `mv -f` across all scripts
- **`xxd: command not found` on minimal systems** — Replaced all `xxd -p` usage with POSIX-portable `od -An -tx1 | tr -d ' \n'` (xxd requires vim package, not installed on minimal Raspberry Pi OS)
- **Docker Compose service status checks always returning true** — `docker compose ps --status running` returns exit code 0 with only a header row even when no containers match; all service-running checks now use `tail -n +2 | grep -q .` to skip the header and verify actual container output exists
- **User add failing when WireGuard not running** — Config file existing was enough to trigger WireGuard peer add attempt; now checks if the Docker service is actually running first, skips gracefully with info message if not
- **Snowflake dashboard false positive** — `check_service_status("snowflake")` was hardcoded to return `"running"`; changed to `"unknown"` with distinct `?` indicator and hover tooltip explaining host networking limitation
- **AmneziaWG `awg` binary missing from Docker image** — Built in multi-stage builder but never copied to final image; added `COPY --from=builder /usr/bin/awg /usr/bin/awg`
- **Grafana dashboard starring silently failing** — `star_dashboards()` used GNU wget flags (`--user`, `--password`, `--auth-no-challenge`) unsupported by BusyBox wget in the official Grafana Alpine image; replaced with `--header "Authorization: Basic ..."` which works everywhere. Also added missing `moav-amneziawg` to star list
- **Dashboard user protocol tags incomplete** — telemt detection checked wrong filename (`telegram-mtproxy.txt` instead of `telegram-proxy-link.txt`); added missing dnstt and Slipstream protocol detection

### Changed
- **CDN bundle files renamed** — `cdn-vless-ws-singbox.json` → `cdn-vless-singbox.json`, `cdn-vless-ws.txt` → `cdn-vless.txt` (reflects transport-agnostic naming)

## [1.4.1] - 2026-03-02

### Added
- **Telegram MTProxy (telemt)** — Rust-based MTProxy with Fake-TLS V2 for direct Telegram access in censored regions
  - New `telemt` service on port 993/tcp (IMAPS port — blends with expected TLS traffic)
  - Fake-TLS V2: real certificate emulation, timing simulation, ALPN enforcement (mimics `dl.google.com`)
  - Per-user 32-hex secrets with configurable connection limits (`TELEMT_MAX_TCP_CONNS`, `TELEMT_MAX_UNIQUE_IPS`)
  - `tg://proxy` and `https://t.me/proxy` links auto-generated in user bundles with QR codes
  - No domain required — works with IP address only (fake-TLS domain is for DPI evasion, not DNS)
  - No client binary needed — users connect via official Telegram app
  - Profile: `telegram` (aliases: `tg`, `mtproxy`, `telemt`)
  - `ENABLE_TELEMT=true` by default
- **Telegram MTProxy Grafana Dashboard** — Per-user connection monitoring
  - Active Users, Total/Bad Connections, Handshake Timeouts, Uptime stat panels
  - Connection Rate, Active Connections & Users, Bandwidth Rate time series
  - Per-user breakdown: Active Connections by User, Unique IPs by User
  - Per-User Details table and ME Health (Messaging Engine) charts
- **`moav user add` telemt integration** — New users automatically get MTProxy secrets and `tg://proxy` links

### Fixed
- **Grafana proxy 502 errors** — Race condition where grafana-proxy started before Grafana was ready; added readiness wait loop
- **Grafana dashboard starring fails on HTTPS** — `star_dashboards()` was using `http://` but Grafana runs HTTPS when certs are found; now uses matching protocol with `--no-check-certificate`
- **dnstt/Slipstream "cannot resolve sing-box" warning** — Race condition where DNS tunnels started before sing-box was registered in Docker DNS; added `depends_on: sing-box: condition: service_healthy`
- **telemt metrics not scraped by Prometheus** — telemt's `metrics_whitelist` defaults to localhost-only; added `metrics_whitelist = ["0.0.0.0/0"]` to generated config
- **`moav restart grafana` restarting entire monitoring stack** — Service names like `grafana`, `prometheus` were being resolved as profile aliases to `monitoring`; `restart`/`stop` now only match exact profile names
- **Slipstream build arguments** — Fixed build failures from incorrect argument passing

### Changed
- **Fake-TLS default domain** — Changed from `www.google.com` to `dl.google.com` (whitelisted during Iran's Jan-Feb 2026 shutdowns, less commonly used as proxy SNI fingerprint)
- **telemt per-user limits configurable** — `TELEMT_MAX_TCP_CONNS` (default: 100) and `TELEMT_MAX_UNIQUE_IPS` (default: 10) via `.env`

## [1.4.0] - 2026-03-01

### Added
- **Slipstream DNS Tunnel** — QUIC-over-DNS protocol (1.5-5x faster than dnstt)
  - New `slipstream` service using pre-built Rust binaries from [slipstream-rust](https://github.com/Mygod/slipstream-rust)
  - Resolver mode (default, ~63 KB/s, stealthier) and authoritative mode (~3.9 MB/s, exposes server IP)
  - ECDSA P-256 self-signed certificate generated during bootstrap
  - Full client support: cert distribution, client instructions, client-test, client-connect
  - Client guide (EN/FA) with protocol description and setup instructions
- **DNS Router** — Lightweight Go UDP forwarder for running multiple DNS tunnels on port 53
  - Routes DNS queries by domain suffix to dnstt or Slipstream backends
  - Supports single-backend mode (routes all traffic when only one tunnel is enabled)
- **`dnstunnel` Profile** — Unified profile for all DNS tunnel services (dns-router + dnstt + Slipstream)
  - Profile aliases: `dnstt`, `dns`, `slip`, `slipstream` all resolve to `dnstunnel`
  - Individual toggles: `ENABLE_DNSTT` and `ENABLE_SLIPSTREAM` control which backends are active
- **`moav logs` Profile Support** — `moav logs dnstunnel` now shows logs for all services in a profile (was silently failing for profile names)

### Fixed
- **Decoy Container Profile Mismatch** — `certbot` depends on `decoy`, but `decoy` was missing profiles (`wireguard`, `dnstunnel`, `trusttunnel`) causing `invalid compose project` errors when starting non-proxy profiles
- **Slipstream Binary on Alpine** — Pre-built Rust binaries are glibc-linked; Slipstream server switched to `debian:bookworm-slim`, client container uses `gcompat` + `libgcc` + `libc6-compat`

### Changed
- **`dnstt` Profile Renamed** — `dnstt` profile renamed to `dnstunnel` (backwards-compatible via alias)
- **dnstt Port Mapping** — dnstt no longer binds host port 53 directly; dns-router handles port 53 and routes to backends

## [1.3.8] - 2026-02-27

### Added
- **Decoy Website** — Interactive backgammon game replaces "Under Construction" page
  - Anti-fingerprinting: randomized titles, headings, footers, and color themes on each container start
  - 8 distinct color palettes, random hex comment to change file hash per deployment
  - Uses nginx `docker-entrypoint.d` mechanism with tmpfs for ephemeral randomized content
- **Connection Optimization Tips in User Bundle** — Inline per-protocol optimization guidance in README.html
  - Reality: TLS Fragment tip with Hiddify/v2rayNG settings, MUX warning (incompatible with Vision)
  - Trojan: TLS Fragment + MUX tips with app-specific values
  - CDN VLESS+WS: MUX tip, note that Fragment doesn't help (TLS at Cloudflare)
  - Hysteria2: no tips (QUIC, nothing to tweak)
- **Multi-user Revoke** — `moav user revoke` now accepts multiple usernames in one command
- **AmneziaWG Revoke** — User revoke now properly removes AmneziaWG peers

### Fixed
- **CDN Domain Empty in User Bundle** — `{{CDN_DOMAIN}}` in README.html was replaced with empty string
  - Root cause: `user-add.sh` and `generate-user.sh` didn't construct `CDN_DOMAIN` from `CDN_SUBDOMAIN` + `DOMAIN`
  - `singbox-user-add.sh` had the construction logic but it didn't propagate to the README generation
- **Certbot Port 80 Conflict** — Certbot standalone mode conflicted with decoy website on port 80
  - Switched certbot from `--standalone` to `--webroot` mode with shared ACME challenge volume
- **Decoy Container Not Picking Up Config** — `docker compose restart` doesn't apply compose file changes; documented need for `--force-recreate`

### Changed
- **sing-box** — Updated to v1.12.23
- **Decoy Website** — Now accessible on HTTP port 80 (was only internal)
- **Client Guide Docs** — Added Connection Optimization section to `docs/CLIENTS.md` (Fragment & MUX per-protocol table)

## [1.3.7] - 2026-02-27

### Added
- **Conduit v2.0.0 Upgrade** — Upgraded Psiphon Conduit to v2.0.0 with native Prometheus metrics
  - Native `/metrics` endpoint replaces custom log-parsing exporter and tcpdump-based GeoIP collector
  - Per-region client breakdown (`conduit_region_connected_clients`, `conduit_region_bytes_downloaded/uploaded`)
  - Ryve deep link displayed in container logs on startup for easy mobile import
  - Slimmed Dockerfile: removed `geoip-bin`, `tcpdump`, `iproute2`, `procps` (no longer needed)
- **Conduit Grafana Dashboard** — New panels for v2 native metrics
  - Live status panel (`conduit_is_live`), max clients panel (`conduit_max_common_clients`)
  - Connected clients by region timeseries chart
- **Build Optimization** — BuildKit cache mounts for Go compilation services
  - Go module and build caches persist across rebuilds (amneziawg, dnstt, snowflake, clash-exporter, client)
  - pip cache mount for admin image

### Fixed
- **Build Reliability** — Fixed Go services failing during parallel `moav build --no-cache`
  - Root cause: 13+ parallel builds saturated network, causing TLS handshake timeouts on Go module downloads
  - Fix: two-phase build — Go services built sequentially first, then remaining services in parallel
  - Phase 2 now filters to only buildable services (skips image-only services like certbot, grafana)
- **Go Version Pinning** — Fixed Dockerfile.amneziawg and Dockerfile.dnstt build failures
  - Pinned amneziawg-go to tag v0.2.16 (was cloning unpinned default branch)
  - Updated dnstt builder from `golang:1.21-alpine` to `golang:1.24-alpine` to match upstream `go.mod`

### Changed
- **Conduit Environment Variables** — `CONDUIT_MAX_CLIENTS` renamed to `CONDUIT_MAX_COMMON_CLIENTS` (backwards-compatible fallback in entrypoint)
- **Prometheus Scrape Target** — Conduit metrics now scraped directly from `psiphon-conduit:9090` (was `conduit-exporter:9101`)
- **Admin Dashboard** — Conduit stats section now shows per-region data from native metrics endpoint
- **Component Versions** — Updated Prometheus default to 3.10.0, sing-box 1.12.22, AmneziaWG tools 1.0.20260223

### Removed
- **conduit-exporter** service — Replaced by Conduit v2 native Prometheus endpoint
- `exporters/conduit/main.py` and `exporters/conduit/Dockerfile` — Custom log parser no longer needed
- `scripts/conduit-stats-collector.sh` — tcpdump-based GeoIP collector replaced by native per-region metrics
- `scripts/conduit-stats.sh` — Live CLI viewer replaced by Grafana dashboard

## [1.3.6] - 2026-02-19

### Added
- **Admin Dashboard User Creation** - Create users directly from the web dashboard
  - "Create User" button in User Bundles section with collapsible form
  - Single user creation by username
  - Batch mode with checkbox: enter username + count to create `name_01`, `name_02`, etc.
  - Real-time script output log with dismiss button
  - Auto-refresh paused during user creation to prevent timeouts on batch operations
  - Scalable timeout: 60s per user in batch mode
- **Admin Dashboard Docker Enhancements** - Admin container can now run user management scripts
  - Full project mount (`/project`) for running `user-add.sh` via API
  - Docker socket mount for `docker compose exec` commands within scripts
  - `qrencode` installed for QR code generation in user bundles
- **AmneziaWG Grafana Dashboard** - Monitoring panel for AmneziaWG connections

### Fixed
- **Bootstrap Key Preservation** - Bootstrap no longer regenerates existing keys on re-run
  - Reality, WireGuard, and AmneziaWG keys preserved across re-bootstrap
  - Prevents breaking existing user configs when re-bootstrapping
- **WireGuard/AmneziaWG User Addition** - Fixed multiple bugs in user-add flow
  - AWG peers now hot-reloaded into running container (previously required restart)
  - AWG IP allocation uses actual IPs from config + running interface (prevents collisions)
  - WG IP allocation checks both config file and running interface
  - Fixed stale peers with `allowed ips: (none)` after re-bootstrap
- **Reality Public Key Derivation** - Fixed empty `pbk=` in Reality client configs
  - Bootstrap no longer clobbers public key when `sing-box generate reality-keypair --private-key` is unavailable
  - Falls back to `wg pubkey` for x25519 key derivation (same curve as WireGuard)
  - `singbox-user-add.sh` auto-derives and saves public key if missing from state
- **dnstt Public Key in README.html** - Fixed empty dnstt pubkey in generated README.html
  - `generate-user.sh` was reading from `dnstt-server.pub` instead of `dnstt-server.pub.hex`
- **User Regeneration** - Fixed WG/AWG config regeneration after re-bootstrap

### Changed
- **Admin Dashboard UI** - Create User form moved from separate card to inline toggle in User Bundles header
- **Documentation** - Added admin dashboard user creation to SETUP.md and CLI.md

## [1.3.5] - 2026-02-18

### Added
- **AmneziaWG protocol** - DPI-resistant WireGuard fork with packet-level obfuscation ([#48](https://github.com/shayanb/MoaV/issues/48))
  - New `amneziawg` Docker service and profile (port 51821/udp)
  - Userspace Go implementation (`amneziawg-go`) for Docker compatibility
  - Random obfuscation parameters (Jc/Jmin/Jmax junk packets, S1/S2 padding, H1-H4 headers)
  - Separate subnet (10.67.67.0/24) from WireGuard (10.66.66.0/24)
  - Full client support: config generation, QR codes, client guide (EN/FA)
  - `awg` alias for `moav start amneziawg`
  - Client container includes `awg-tools` for AmneziaWG connections
- **Protocol Integration Checklist** - Developer documentation for adding new protocols to MoaV
- **Version Bump Checklist** - Developer documentation for release process

### Fixed
- **WireGuard MTU** - Added `MTU = 1280` to all WireGuard configs (server + client)
  - Fixes poor upload speeds on mobile networks behind CGNAT (e.g., Iranian carriers)
  - Applied to: direct, IPv6, and wstunnel-wrapped configs
- Grafana local build edge case fix
- DNS check before dnstt startup
- First start profile selection fix
- Bugfix [#38](https://github.com/shayanb/MoaV/issues/38)
- Bugfix [#44](https://github.com/shayanb/MoaV/issues/44)
- Local building bugfix

### Changed
- Default Snowflake/Conduit bandwidth lowered (due to high usage)
- `awg-tools` updated to v1.0.20250903
- Developer checklists moved to `docs/devdocs/`

## [1.3.4] - 2026-02-14

### Added
- **Local Image Building** - Build container images locally for regions with blocked registries
  - `moav build --local` - builds commonly blocked images (cAdvisor, clash-exporter)
  - `moav build --local SERVICE` - builds specific image (prometheus, grafana, etc.)
  - `moav build --local all` - builds ALL images locally (docker-compose + external)
  - Automatically updates .env to use local images
  - Available images: cadvisor, clash-exporter, prometheus, grafana, node-exporter, nginx, certbot
  - Uses pre-built binaries from GitHub releases (avoids compilation, works on 1GB servers)
  - Version control via `.env` variables (PROMETHEUS_VERSION, GRAFANA_VERSION, etc.)
- **Configurable Container Images** - All external images now configurable via .env
  - `IMAGE_PROMETHEUS`, `IMAGE_GRAFANA`, `IMAGE_NODE_EXPORTER`, `IMAGE_CADVISOR`, etc.
  - Allows use of mirror registries when default registries are blocked
- **Registry Troubleshooting Guide** - New section in TROUBLESHOOTING.md for blocked registries

### Changed
- **Dockerfile Organization** - All Dockerfiles moved to `dockerfiles/` directory
  - Cleaner root directory structure
  - All docker compose commands work unchanged
- **Alpine Base Image** - Updated all Dockerfiles to Alpine 3.21 (from 3.19/3.20)
- **Profile Support for Build** - `moav build monitoring` now works (builds all monitoring services)

### Fixed
- **Uninstall --wipe** - Now properly removes all Docker images
  - Fixed: images with non-default tags (e.g., `moav-nginx:local`) were not being removed
  - Now removes external images (prometheus, grafana, cadvisor, etc.)
  - Shows both built and pulled images before removal
- **Build Counter Bug** - Fixed `moav build --local` stopping after first image due to `set -e` with arithmetic

## [1.3.3] - 2026-02-13

### Added
- **Grafana CDN Proxy** - Access Grafana through Cloudflare CDN for faster loading
  - New `grafana-proxy` nginx service on port 2083 (Cloudflare-supported HTTPS port)
  - Configure with `GRAFANA_SUBDOMAIN` in .env (e.g., `grafana.yourdomain.com:2083`)
  - Dynamic SSL certificate detection (Let's Encrypt or self-signed fallback)
- **Grafana MoaV Branding** - Custom logo, favicon, and app title
  - Replaces default Grafana branding with MoaV logo/favicon
  - Dynamic app title: "MoaV - {DOMAIN}" or "MoaV - {SERVER_IP}" for PWA home screen
  - Note: Uses file replacement since GF_BRANDING_* is Grafana Enterprise-only
- **Dashboard Auto-Starring** - All MoaV dashboards automatically starred on Grafana startup
- **Conduit Peak Clients** - New stat panel showing maximum concurrent clients in time range

### Changed
- **Subdomain Configuration** - Cleaner .env format for CDN settings
  - `GRAFANA_ROOT_URL` → `GRAFANA_SUBDOMAIN` (just subdomain, URL constructed automatically)
  - `CDN_DOMAIN` → `CDN_SUBDOMAIN` (just subdomain, URL constructed automatically)
- **Monitoring Default** - `ENABLE_MONITORING` no longer set in .env.example
  - Users are now prompted when selecting "all" services
  - Prevents accidental monitoring on low-RAM servers
- **Service URLs in output** - `moav start` now shows Grafana CDN URL and VLESS+WS CDN URL when configured

### Fixed
- **Domainless Mode** - Fixed bootstrap failing when running without a domain
  - Now properly disables all TLS protocols including TrustTunnel
  - Handles missing ENABLE_* vars in .env (adds them if not present)
- **CLASH_API_SECRET Flow** - Fixed monitoring setup during bootstrap
  - Secret is now properly copied from state volume to .env
  - `ensure_clash_api_secret()` runs before starting services after bootstrap
- **Entrypoint Permissions** - Added missing executable bit to entrypoint scripts
  - Fixes "modified files" warning during `moav update`
- **sing-box User Connections Table** - Fixed column display
  - Shows: User, Connections, Active (in correct order)
  - Hides metadata fields: __name__, instance, job
- **Snowflake Bandwidth Clarification** - Added tooltips explaining why container metrics (cAdvisor) show higher values than Snowflake dashboard (WebSocket/TLS overhead, broker connections)

## [1.3.1] - 2026-02-11

### Added
- **Conduit Exporter** - Custom Prometheus exporter for Psiphon Conduit metrics
  - Parses `[STATS]` lines from conduit logs
  - Exposes: connected/connecting clients, upload/download totals, uptime
  - New Grafana dashboard: MoaV - Conduit
- **Sing-box User Exporter** - Custom Prometheus exporter for user tracking
  - Parses sing-box logs for `[username]` connection patterns
  - Tracks active users (5-minute window), total users, per-user connections
  - Protocol breakdown (Reality, Trojan, Hysteria2, etc.)
  - Updated sing-box dashboard with user metrics table and protocol pie chart

### Changed
- **Monitoring intervals reduced** - Less CPU overhead
  - cAdvisor housekeeping: 10s → 30s
  - Prometheus scrape interval: 15s → 30s
- **Snowflake dashboard fixed** - Deduplicated metrics using `max()` aggregation
- **Container dashboard improved** - Network traffic now excludes monitoring containers
  - Filters out: prometheus, grafana, cadvisor, node-exporter, all exporters
  - Shows only actual proxy/service traffic
- Snowflake/WireGuard exporters now only run with `monitoring` profile (not standalone)
- Removed `docker compose ps` output after start commands (cleaner output)

### Fixed
- Conduit exporter no longer has cross-profile `depends_on` issue
- Fixed duplicate metrics in Snowflake Grafana dashboard (3x values shown)
- **Snowflake exporter replaced** - Custom optimized version instead of third-party
  - Fixes high CPU usage (20-90%) from inefficient log parsing
  - Uses file position tracking instead of constant re-reading
  - Adaptive sleep intervals (1s when active, 5s when idle)
- **Snowflake dashboard labels fixed** - Now shows user perspective:
  - "Users Downloaded" = bandwidth users received (was confusingly labeled "Upload")
  - "Users Uploaded" = bandwidth users sent (was confusingly labeled "Download")

## [1.3.0] - 2026-02-10

### Added
- **Monitoring Stack** - Optional Grafana + Prometheus observability (`monitoring` profile)
  - Grafana dashboards on port 9444 (configurable via `PORT_GRAFANA`)
  - Prometheus with 15-day retention (internal only, port 9091)
  - Node Exporter for system metrics (CPU, RAM, disk, network)
  - cAdvisor for container metrics (per-container CPU, memory, network)
  - Clash Exporter for sing-box proxy metrics (connections, traffic)
  - WireGuard Exporter for VPN peer statistics (peers, handshakes, traffic)
  - Snowflake Exporter for Tor donation metrics (people served, bandwidth donated)
  - Pre-built dashboards: System, Containers, sing-box, WireGuard, Snowflake
  - Uses existing `ADMIN_PASSWORD` for Grafana authentication
  - `moav start monitoring` or combine with other profiles
- `PORT_GRAFANA` environment variable (default: 9444)
- `ENABLE_MONITORING` toggle in .env
- **Batch user creation** - Create multiple users at once:
  - `moav user add alice bob charlie` - Add multiple named users
  - `moav user add --batch 5` - Create user01, user02, ..., user05
  - `moav user add --batch 10 --prefix team` - Create team01..team10
  - Smart numbering: skips existing users (if user01-03 exist, creates user04, user05)
  - Services reload once at the end (not after each user) for efficiency
  - `--package` flag works with batch mode

### Changed
- Admin dashboard simplified (connection/memory metrics moved to Grafana):
  - Removed Active Connections card
  - Removed Memory Usage card
  - Removed Active Connections table
  - Added Grafana link button in header
  - Kept: Conduit stats, User bundles, Service status, Total upload/download

### Fixed
- **`moav user revoke` menu crash** - User list script was crashing when listing WireGuard peers after a user was revoked
  - Fixed grep pattern to only extract usernames from [Peer] blocks
  - Added proper error handling for missing peer IPs

### Documentation
- Added `docs/MONITORING.md` with complete monitoring stack guide
- Documented: TrustTunnel and dnstt do not have metrics APIs (container metrics still available via cAdvisor)
- Added "Apply .env changes" section to TROUBLESHOOTING.md explaining that containers must be recreated (not just restarted) to pick up `.env` changes

### Added
- **Batch user creation** - Create multiple users at once:
  - `moav user add alice bob charlie` - Add multiple named users
  - `moav user add --batch 5` - Create user01, user02, ..., user05
  - `moav user add --batch 10 --prefix team` - Create team01..team10
  - Smart numbering: skips existing users (if user01-03 exist, creates user04, user05)
  - Services reload once at the end (not after each user) for efficiency
  - `--package` flag works with batch mode

### Fixed
- **`moav user revoke` menu crash** - User list script was crashing when listing WireGuard peers after a user was revoked
  - Fixed grep pattern to only extract usernames from [Peer] blocks
  - Added proper error handling for missing peer IPs

### Documentation
- Added "Apply .env changes" section to TROUBLESHOOTING.md explaining that containers must be recreated (not just restarted) to pick up `.env` changes

## [1.2.5] - 2026-02-07

### Added
- **`moav uninstall` command** - Clean uninstallation with two modes:
  - `moav uninstall` - Remove containers, keep data (.env, keys, bundles)
  - `moav uninstall --wipe` - Complete removal including all configs, keys, and user data
  - Optional Docker images cleanup prompt during --wipe
  - Verbose output showing each file/directory being removed
- **Component version update checking** - `moav update` now compares versions:
  - Compares .env with .env.example after git pull
  - Shows available updates for sing-box, wstunnel, conduit, snowflake, trusttunnel
  - Prompts to update versions in .env
  - Shows rebuild command: `moav build <services> --no-cache`
- **Unified service selection menu** - Beautiful table-based menu for start/stop/restart
  - Consistent UI across all service operations
  - "ALL" option highlighted as "(Recommended)" in green
  - Shows v2ray app compatibility for proxy protocols
- `moav build --no-cache` flag for forcing container rebuilds
- Logs menu "Last 100 lines + follow" option (shows tail then continues following)
- Cloudflare Origin Rule documentation for CDN mode (required for port 2082 routing)

### Changed
- Service selection menu improvements:
  - Proxy description: "Reality, Trojan, Hysteria2 (v2ray apps)"
  - TrustTunnel description: "TrustTunnel VPN (HTTP/2 + QUIC)"
  - Donation services: "Donate bandwidth via Psiphon/Tor"
  - Cancel option dimmed to de-emphasize
- Start/stop/restart now use unified menu instead of separate implementations
- dnstt auto-dependency (adding proxy) only applies to start, not stop/restart operations

### Fixed
- **WireGuard key generation permissions warning** - Now uses `umask 077` to create private keys with secure permissions (owner-only read)
- **Bootstrap missing python3** - Added python3 to Dockerfile.bootstrap for placeholder replacement
- Stop/restart stopping extra services - Auto-adding proxy for dnstt now only happens during start

### Documentation
- Complete CLI.md reference with all moav commands and options
- SETUP.md: Added "Uninstalling MoaV" section, expanded "Breaking Changes" guidance
- TROUBLESHOOTING.md: Added "Breaking changes after update" section with solutions
- DNS.md: Added Cloudflare Origin Rule setup for CDN mode (fixes 521 errors)
- Updated uninstall documentation across all relevant docs

## [1.2.4] - 2026-02-06

### Added
- **TrustTunnel VPN protocol integration** - Modern VPN protocol from AdGuard using HTTP/2 and HTTP/3 (QUIC)
  - New `trusttunnel` Docker service and profile
  - TrustTunnel endpoint on port 4443 (TCP+UDP)
  - Full TOML config generation for CLI client
  - TrustTunnel section in client guide (HTML) with all app fields
  - Admin dashboard: TrustTunnel service status and "TT" protocol tag for users
- TrustTunnel CLI client (`trusttunnel_client`) in client container for testing
- `moav start trusttunnel` and service menu option
- User bundles now include `trusttunnel.toml`, `trusttunnel.txt`, and `trusttunnel.json`

### Changed
- Client test gracefully falls back to endpoint reachability check when TUN device unavailable
- TrustTunnel app store links updated to correct URLs

### Fixed
- **README.html placeholder replacement broken** - Multiple issues fixed:
  - `local` variable used outside function causing script exit with `set -e`
  - sed `&` character interpreted as "matched pattern" in replacement strings
  - awk escape sequence warnings (`\&` treated as plain `&`)
  - Multiline WireGuard configs breaking sed commands
  - Now uses Python-based replacement for reliable handling of special characters and multiline content
- TrustTunnel CLI client requires `--config` flag (was missing)
- TrustTunnel credentials format: `[[client]]` not `[[credentials]]`, `[[main_hosts]]` not `[[hosts]]`

## [1.2.3] - 2026-02-06

### Added
- **CDN-fronted VLESS+WebSocket inbound** - New protocol for Cloudflare CDN-proxied connections
  - sing-box `vless-ws-in` inbound on port 2082 (plain HTTP, Cloudflare terminates TLS)
  - Uses same user UUIDs as Reality (no extra credentials)
  - Client links generated when `CDN_DOMAIN` is set in `.env`
- `CDN_DOMAIN` config option - Set to your Cloudflare-proxied subdomain (e.g., `cdn.yourdomain.com`)
- `CDN_WS_PATH` config option - WebSocket path (default: `/ws`)
- `PORT_CDN` config option - CDN inbound port (default: `2082`, a Cloudflare-allowed HTTP port)
- User bundles now include `cdn-vless-ws.txt`, `cdn-vless-ws-singbox.json`, and QR code when CDN is configured
- Documentation: "Adding a Domain After Domainless Setup" guide in SETUP.md
- Documentation: Full CDN setup guide with Cloudflare configuration steps

### Changed
- `moav status` now displays CDN domain when configured
- User add message now mentions CDN VLESS+WS
- DNS.md Cloudflare section now includes optional `cdn` A record (Proxied)

### Fixed
- **`moav client connect` failing while `moav test` works** - Connect mode was missing IPv6 URI parsing, causing "invalid address" errors when IPv6 configs were present
  - `extract_host()` and `extract_port()` now handle IPv6 URIs (`@[addr]:port` format)
  - Config file discovery now prefers IPv4 configs (`reality.txt`) before falling back to globs (`reality*.txt`)
  - WireGuard endpoint parsing now handles IPv6 addresses
  - Added field validation with debug logging for all protocols
  - Added port numeric validation for Reality and Trojan (was only in test mode)

## [1.2.2] - 2026-02-04

### Breaking Changes
- **Fresh setup required**: This version includes protocol changes (Hysteria2 obfuscation, Reality target) that require regenerating both server configuration and all user configs. Existing users must receive new config files.

### Added
- **Hysteria2 Salamander obfuscation** - Disguises QUIC traffic as random UDP to bypass Iranian/Chinese censorship
- `HYSTERIA2_OBFS_PASSWORD` config option (auto-generated if empty)
- `moav config rebuild` - Regenerates server config and all users with new credentials
- Update available notification in CLI header and admin dashboard
- Admin dashboard: User bundles table now shows creation date, sorted newest first
- Internet accessibility check (exit IP verification) for all protocol tests
- Component version management via `.env` file

### Changed
- Default Reality target changed from `www.microsoft.com` to `dl.google.com` (less fingerprinted in censored regions)
- DNS fallback servers: removed Cloudflare DoH (failing), added Google UDP and Quad9 UDP
- `moav config rebuild` simplified - cleanly regenerates everything instead of complex state preservation
- Admin dashboard UI improvements

### Fixed
- **Critical: dnstt traffic not routing** - sing-box mixed inbound was localhost-only
- **Critical: Client container architecture mismatch** - Fixed arm64/amd64 binary downloads
- Admin dashboard crash on load (`connection_stats` undefined)
- `moav logs` Ctrl+C now returns to menu instead of exiting
- `moav logs proxy` and `moav logs reality` aliases for sing-box
- `moav regenerate-users` now passes Hysteria2 obfuscation password
- `moav test` various fixes for dnstt and validation
- `moav update` conflicts from generated files

### Security
- Hysteria2 obfuscation helps bypass QUIC fingerprinting and blocking in Iran/China

## [1.2.0] - 2026-02-03

### Added
- `moav update -b BRANCH` - switch git branches during update (e.g., `moav update -b dev`)
- Profile aliases for `moav start`: `sing-box`, `singbox`, `reality`, `trojan`, `hysteria` → `proxy`
- Service aliases for restart/stop/logs: `proxy`, `reality` → `sing-box`
- Branch display in header and status when not on `main` branch
- `moav test` verbose flag (`-v` or `--verbose`) for debugging connection issues
- Multiple fallback DNS servers in sing-box config (Google, Cloudflare, Quad9 UDP)

### Changed
- `moav update` now shows help with `--help` flag
- `moav test` now prefers IPv4 configs over IPv6 (tests `reality.txt` before `reality-ipv6.txt`)
- `moav test` treats IPv6 network failures as warnings instead of errors (IPv6 may not be available in container)
- Improved gitignore for generated WireGuard and dnstt files

### Fixed
- `moav update -b BRANCH` arguments not being passed correctly
- Double header display when running `moav` interactive menu
- Script permissions (755) for all shell scripts in repository
- Generated files (server.pub, wg_confs/, coredns/) no longer trigger update conflicts
- **WireGuard-wstunnel not forwarding traffic** - wstunnel was trying to forward to localhost instead of wireguard container (changed `127.0.0.1:51820` to `moav-wireguard:51820`)
- `moav test` now correctly parses IPv6 addresses in URIs (e.g., `[2400:6180::1]:443`)
- `moav test` now validates parsed URI fields before generating config
- `moav test` now shows actual sing-box error messages instead of generic "failed to start"
- `moav test` now validates generated JSON config before running sing-box

## [1.1.2] - 2026-02-02

### Added
- One-click VPS deployment buttons for Hetzner, Linode, Vultr, DigitalOcean
- Cloud-init script for automated VPS provisioning
- First-login welcome prompt for cloud-deployed servers
- Home VPN server documentation (Raspberry Pi, ARM64 support)
- Dynamic DNS (DDNS) guide for home servers (DuckDNS, Cloudflare)
- VPS deployment guide (docs/DEPLOY.md)
- Bootstrap confirmation prompt before running
- Domain-less mode support (WireGuard, Conduit, Snowflake without TLS)
- First-run loading indicator ("First run - checking prerequisites...")
- Disabled service indicators in status display (`*` suffix with legend)
- Disabled service indicators in service selection menu (`(disabled)` text)
- Install script `-b BRANCH` flag for testing feature branches
- Admin dashboard: User Bundles section with download functionality
- `moav update` now shows current branch and warns if not on main/master
- Admin dashboard URL shown in menu, status, and after starting services
- Admin dashboard now works in domain-less mode using self-signed certificates
- Certbot status explanation in `moav status` (clarifies "Exited (0)" is expected)
- Admin URL now shows server public IP instead of localhost
- Bootstrap now auto-detects and saves SERVER_IP to .env if not set

### Changed
- Improved sing-box performance: disabled `sniff_override_destination`, disabled multiplex padding, enabled TCP Fast Open, use local DNS by default
- WireGuard entrypoint bypasses wg-quick to avoid Docker 29 compatibility issues
- WireGuard peer IP assignment now based on peer count (fixes demouser getting server IP)
- Service selection "ALL" now respects ENABLE_* settings (only starts enabled services)
- `moav stop` now uses `docker compose stop` instead of `down` (preserves container state)
- Certbot exits gracefully when no domain configured (domain-less mode)

### Fixed
- Admin dashboard using self-signed cert instead of Let's Encrypt (now waits for certbot)
- Admin dashboard "sing-box API timeout" error (memory endpoint is streaming, now reads first line only)
- WireGuard traffic not flowing (missing iptables FORWARD rule for return traffic)
- WireGuard "Permission denied" error on Docker 29 with Alpine
- WireGuard config parsing stripping trailing "=" from base64 keys
- WireGuard QR code showing "Invalid QR Code" in app due to non-hex IPv6 address (`fd00:moav:wg::` → `fd00:cafe:beef::`)
- WireGuard-wstunnel QR code not being generated in wg-user-add.sh (missing in README.html)
- Conduit status showing "never" even when running ([#7](https://github.com/shayanb/MoaV/issues/7))
- Reality URL `&` characters replaced with placeholder in README.html ([#8](https://github.com/shayanb/MoaV/issues/8))
- Architecture mismatch in Dockerfile.client - now uses TARGETARCH for multi-arch support ([#4](https://github.com/shayanb/MoaV/issues/4))
- Bootstrap failing in domain-less mode (missing ENABLE_* exports, conditional config generation)
- generate-user.sh unconditionally sourcing reality.env (now conditional on ENABLE_REALITY)
- generate-user.sh peer count calculation failing when grep returns no matches

## [1.1.1] - 2025-01-31

### Added
- Website link badge in README
- GitHub issue templates (bug reports, feature requests)
- "Your Protocol?" CTA card in Multi-Protocol Arsenal section
- Server Management demo on website

### Changed
- Status table column widths to accommodate longer service names

## [1.0.2] - 2025-01-31

### Added
- Ctrl+C handler with friendly goodbye message
- README.html generation in user bundles using client-guide-template
- Demo user notice (bilingual EN/FA) for bootstrap demouser
- Server Management demo on website
- Support for comma separator in multi-option selection (e.g., `1,2,4`)

### Changed
- Bootstrap now creates "demouser" when INITIAL_USERS=1 (instead of user01)
- User management menu now loops back after listing users
- Package command now places zip files in `outputs/bundles/` consistently
- Status table widened to accommodate longer service names (psiphon-conduit)
- Removed README.md from user bundles (HTML-only now)

### Fixed
- Export and regenerate-users now correctly find users from bundles directory
- Demo notice placeholders properly removed from non-demo user HTML
- Awk escape sequence warnings in HTML generation
- Package user menu option creating zip in wrong directory

## [1.0.1] - 2025-01-30

### Fixed
- Minor bug fixes and improvements

## [1.0.0] - 2025-01-28

### Added
- Initial release of MoaV multi-protocol circumvention stack
- **Protocols:**
  - Reality (VLESS) - Primary protocol with TLS camouflage
  - Trojan - TLS-based fallback on port 8443
  - Hysteria2 - QUIC/UDP-based for fast connections
  - WireGuard - Full VPN mode (direct and wstunnel-wrapped)
  - DNS Tunnel (dnstt) - Last resort for restrictive networks
  - Tor/Snowflake - Standalone fallback via Tor network
- **Server features:**
  - Docker Compose-based deployment
  - Multi-user management with per-user credentials
  - Automatic TLS certificate management via Caddy
  - Decoy website for traffic camouflage
  - Admin dashboard for monitoring
  - Psiphon Conduit for bandwidth donation
  - Snowflake proxy for Tor network contribution
- **Client features:**
  - Built-in client container for Linux/Docker
  - Test mode for connectivity verification
  - Connect mode with local SOCKS5/HTTP proxy
  - Auto protocol fallback
- **CLI tool (moav.sh):**
  - Interactive menu and command-line interface
  - User management (add/list/revoke)
  - Service management (start/stop/restart/logs)
  - Global installation support
- **Documentation:**
  - Setup guide with prerequisites
  - Client configuration guides for all platforms
  - Troubleshooting guide
  - Farsi (Persian) README

### Security
- Per-user UUID and password generation
- Reality protocol with XTLS Vision flow
- uTLS fingerprint spoofing (Chrome)
- Automatic short ID generation for Reality

[Unreleased]: https://github.com/shayanb/MoaV/compare/v1.7.7...HEAD
[1.7.7]: https://github.com/shayanb/MoaV/compare/v1.7.6...v1.7.7
[1.7.6]: https://github.com/shayanb/MoaV/compare/v1.7.5...v1.7.6
[1.7.5]: https://github.com/shayanb/MoaV/compare/v1.7.4...v1.7.5
[1.7.4]: https://github.com/shayanb/MoaV/compare/v1.7.3...v1.7.4
[1.7.3]: https://github.com/shayanb/MoaV/compare/v1.7.2...v1.7.3
[1.7.2]: https://github.com/shayanb/MoaV/compare/v1.7.0...v1.7.2
[1.7.0]: https://github.com/shayanb/MoaV/compare/v1.6.2...v1.7.0
[1.6.2]: https://github.com/shayanb/MoaV/compare/v1.6.1...v1.6.2
[1.6.1]: https://github.com/shayanb/MoaV/compare/v1.6.0...v1.6.1
[1.6.0]: https://github.com/shayanb/MoaV/compare/v1.5.1...v1.6.0
[1.5.1]: https://github.com/shayanb/MoaV/compare/v1.4.7...v1.5.1
[1.4.7]: https://github.com/shayanb/MoaV/compare/v1.4.5...v1.4.7
[1.4.5]: https://github.com/shayanb/MoaV/compare/v1.4.4...v1.4.5
[1.4.4]: https://github.com/shayanb/MoaV/compare/v1.4.1...v1.4.4
[1.4.2]: https://github.com/shayanb/MoaV/compare/v1.4.1...v1.4.2
[1.4.1]: https://github.com/shayanb/MoaV/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/shayanb/MoaV/compare/v1.3.8...v1.4.0
[1.3.8]: https://github.com/shayanb/MoaV/compare/v1.3.7...v1.3.8
[1.3.7]: https://github.com/shayanb/MoaV/compare/v1.3.6...v1.3.7
[1.3.6]: https://github.com/shayanb/MoaV/compare/v1.3.5...v1.3.6
[1.3.5]: https://github.com/shayanb/MoaV/compare/v1.3.4...v1.3.5
[1.3.4]: https://github.com/shayanb/MoaV/compare/v1.3.3...v1.3.4
[1.3.3]: https://github.com/shayanb/MoaV/compare/v1.3.1...v1.3.3
[1.3.1]: https://github.com/shayanb/MoaV/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/shayanb/MoaV/compare/v1.2.5...v1.3.0
[1.2.5]: https://github.com/shayanb/MoaV/compare/v1.2.4...v1.2.5
[1.2.4]: https://github.com/shayanb/MoaV/compare/v1.2.3...v1.2.4
[1.2.3]: https://github.com/shayanb/MoaV/compare/v1.2.2...v1.2.3
[1.2.2]: https://github.com/shayanb/MoaV/compare/v1.2.0...v1.2.2
[1.2.0]: https://github.com/shayanb/MoaV/compare/v1.1.2...v1.2.0
[1.1.2]: https://github.com/shayanb/MoaV/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/shayanb/MoaV/compare/v1.0.2...v1.1.1
[1.0.2]: https://github.com/shayanb/MoaV/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/shayanb/MoaV/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/shayanb/MoaV/releases/tag/v1.0.0
