# Changelog

All notable changes to MoaV will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Removed
- **The obsolete `scripts/wg-sync-keys.sh` workaround (E4-3).** It manually re-synced WireGuard server keys between the running container and the config files "if you have key mismatch issues after container restarts". It had zero callers, and the mismatch it patched no longer occurs: `wg-user-add.sh` reads the running container's public key and syncs `server.pub` inline on every peer add. The other half of the E4-3 card — retiring the fragile `_fix_perms` chmod dance — was already done in the world-writable-bundles fix, which replaced `chmod 777` with deterministic uid-2000 ownership; `_fix_perms` now sets owner=caller / group=admin / 2770 and is the correct handling, not a workaround, so it stays.


### Added
- **Agent entry points: root `llms.txt` and `AGENTS.md`.** `llms.txt` (llmstxt.org format, mirroring the moav-site one) is a concise project summary + curated index for AI agents landing on the repo; `AGENTS.md` is the deep agent guide (repo layout, build/run, testing, and the conventions that bite — strict mode, `get_env_val`, bash 3.2, host-vs-container paths, uid 2000, secrets-in-state). The `.claude/skills/` stay as operational tools.
- **CI test for nested env-var fallbacks.** `tests/env-fallback-test.sh` verifies every `${PRIMARY:-${SECONDARY:-DEFAULT}}` chain resolves correctly for primary-set / primary-empty+secondary-set / both-unset (XHTTP_REALITY_TARGET→REALITY_TARGET, CDN_ADDRESS→CDN_DOMAIN, CDN_SNI→DOMAIN, CONDUIT_MAX_COMMON_CLIENTS→CONDUIT_MAX_CLIENTS), pins the XHTTP→REALITY chain at all three call sites, and a coverage guard fails CI if a new nested fallback ships untested. Runs under bash 3.2.


### Fixed
- **`XHTTP_REALITY_TARGET` now actually defaults to `REALITY_TARGET`.** The comment claimed "default: same as REALITY_TARGET" but the value was hardcoded to `dl.google.com:443` in `.env.example` and every code path, so changing REALITY_TARGET silently did not change XHTTP's camouflage target. It is now empty in `.env.example` and falls back `XHTTP_REALITY_TARGET -> REALITY_TARGET -> dl.google.com:443` at all sites (bootstrap, xray config-gen, compose).

### Changed
- **The admin dashboard browser title is `MoaV - <domain> - Dashboard`** (falls back to the server IP, or just "MoaV - Dashboard" with no domain), instead of the static "MoaV Dashboard".


### Changed
- **`.env.example` is one reorganized file again, not a slim/full split.** The E4-1 split into `.env.example` + `.env.example.full` is replaced by a single file: the ~29 commonly-configured vars (domain, ACME email, admin password, server identity, protocol toggles, Reality target, common options) sit in a labeled block on top, then a hard `ADVANCED - only change things below if you know what you're doing` separator, then every other tunable with its original comments. Nothing is removed, so a fresh `cp .env.example .env` carries every variable at its intended value (this also un-does the four fresh-install default drifts the split had introduced: CDN on, conduit/snowflake bandwidth, client ports). `moav update`'s version-outdated check and new-variable auto-add read the single file again.


### Fixed
- **Grafana no longer crash-loops over cosmetic branding.** The entrypoint patches a logo into the grafana image's `public/img` dir; on images/hosts where that dir is not writable even as root (seen live on a DigitalOcean droplet with `grafana/grafana:latest`), the one unguarded `cat >` write failed with "Permission denied" and, under `set -e`, killed the entrypoint and restart-looped the container. The write is now best-effort (`if cat … else skip`), so branding degrades gracefully and grafana stays up. A restart-storming grafana was also starving the box's docker daemon, which is the likely trigger for the intermittent "no wg/awg key generator" on `moav user add` right after start.
- **`moav test` no longer warns "couldn't parse the wstunnel server".** It read the endpoint from a `wireguard-instructions.txt` that bundles do not contain; it now reads the `wstunnel client -L … wss://host:port` command from `README.html` (matching the command line, not the surrounding prose) and validates that endpoint.

### Changed
- **cAdvisor logs are quiet.** It logged a multi-line "Filesystem partitions" map (every overlayfs/tmpfs mount) on each housekeeping pass, flooding `docker logs`; added `--stderrthreshold=1 -v=0` so only warnings and up are emitted. Metrics unchanged.
- **The installer's completion banner shows the community links** (Telegram, Twitter/X, GitHub issues) alongside Documentation and Website.


### Changed
- **User bundles show only the protocols the user actually has (#73).** The README guide used to render every protocol section, with "No X config available" filler for anything disabled — a 12-protocol wall where half the entries were dead. Each section and its table-of-contents entry (English and Farsi) is now hidden when the user's bundle has no artifact for that protocol, keyed on the same per-user files the config values already read. `subscription.txt` is untouched (same unconditional format, so `moav-client` and V2Ray apps see no change). Migration for existing users: `moav regenerate-users` — and `moav update` now detects bundle-guide/renderer changes and lists that step in its post-update instructions.


### Fixed
- **Hardened the whole state↔.env generated-secret desync class (the Reality short_id total-outage family).** Generated secrets live in `state/keys`, but docker-compose injects them into the bootstrap container from `.env` — usually empty, since the values are not in `.env`. A render that read the empty injected value silently blanked the secret; for the Reality short_id that rejected *every* client with no error anywhere (PR #152 fixed only Reality, only in two spots). Now a single `load_state_secrets` re-sources the entire class (reality, clash-api, cdn, shadowsocks PSK) from state right before every render, and a post-render assert aborts the bootstrap if state holds a Reality short_id or private key the rendered config does not contain — refusing to ship a config that would silently reject everyone. `moav doctor` gained a matching config↔state short_id check.


### Changed
- **`.env.example` slimmed from 118 vars / 475 lines to a curated 28-var first-run surface.** A new operator now sees only what they actually set (domain, ACME email, admin password, server IP, protocol toggles, and a few common options). Every advanced tunable (component versions, ports, Reality/XHTTP targets, DNS-tunnel subdomains, Telegram/telemt tuning, CDN, bandwidth donation, monitoring, client mode, registry overrides) has a working code/compose default and moved to a new complete reference, **`.env.example.full`** — copy any line into your `.env` to override it. Existing installs are unaffected (their `.env` is untouched; removed keys fall back to the same defaults). `moav update`'s version-outdated check now reads the full reference; its new-variable auto-add still reads the slim file, so an update never re-bloats your `.env` with the advanced set. A drift test keeps the slim file a strict subset of the reference and under a 40-var ceiling.


### Fixed
- **`moav user add` from the CLI could fail WireGuard/AmneziaWG right after `moav start`.** The key generator fell back to `docker compose exec` (which re-parses the whole compose file every call, three times per peer) under a 20s timeout; on a 1-vCPU/1-GB box still settling from a full start, that blew the budget and reported "no wg/awg key generator available" for a perfectly healthy container. It now uses `docker exec` by container name (no compose parse, ~2x faster idle and far more under load) with a 60s ceiling. The web admin was unaffected because it never hit the slow path. Found on the first live 1.9.1 upgrade.
- **`moav doctor` printed network buffers as "0 MiB".** The kernel default (~208 KiB) integer-divided to 0 MiB, reading like a broken probe instead of "buffer is small". Sub-MiB values now print in KiB. (The BBR/qdisc/buffer lines remain advisory until `moav net apply` is run.)
- **`moav test` reported WireGuard/AmneziaWG as a cryptic kernel error.** When the test host lacks the wg/awg kernel module the config is still validated, but the clear "no kernel module in this environment" note was overwritten by the raw `Unknown device type` text. The clear message is now primary and the raw error is demoted to context.

### Changed
- **`moav test` and the built-in client no longer bundle `snowflake-client`.** Snowflake is a Tor pluggable transport that belongs to the standalone `MotherofallVPNs/moav-client`; the server's built-in client exists to validate a user's bundle and the server's net perms. Dropping it removes a heavy Go build stage from every `moav test`.
- **`moav build` now caps the BuildKit cache when it finishes.** The cache had grown to ~4 GB on a live server (most of a "disk 81% full" scare) while images and logs were fine; nothing evicted it. It is *capped, not wiped* (keep ~4 GB of the most-recent layers via `--keep-storage`, tunable with `MOAV_BUILD_CACHE_KEEP`) so the next build stays fast and only unbounded accumulation is trimmed. Cache only — never images, which back the running stack and any rollback.
- **Community links in `moav start` / `moav status` / goodbye now include GitHub issues.** The start success block and the status footer show Telegram, X and the GitHub issues URL; the exit banner points to Telegram for questions and GitHub for bugs. The marketing-flavored "serving Psiphon users (incl. Iran) via the public pool" line after start is gone; the useful `moav conduit link` hint stays.


### Fixed
- **Four upgrade regressions found on the first live 1.9.1 → v2 upgrade.** The key-permissions repair normalized modes but not OWNERSHIP: live installs carry state keys owned by old per-container uids (uid 999 from the v1 dnstt image), and a `cap_drop: ALL` container without `DAC_OVERRIDE` cannot read a 0600 file it does not own even as in-container root. The repair now chowns to root. Second, dnstt, masterdns and slipstream run their daemons as `USER moav` and read their own key directly, so those three keys stay 644 inside the state volume (the mount boundary is the control) — 0600 silently killed all three tunnels. Third, the singbox-exporter crash-looped on the now-0600 Clash secret file: it reads the env var first now (compose already passed it) and any file-read failure is non-fatal. Fourth, the xray access-log tailer could never read the log (xray-core creates it 0600 under xray's non-root uid; the exporter has no DAC_OVERRIDE) — the xray entrypoint now keeps it 644 — and a leftover `result.stderr` reference raised NameError on every stats poll.

### Added
- **Community links in `moav start` and `moav status` output.** Telegram and X shown after "Services started!" and as a footer under the status table.

### Security
- **The Clash API secret file is now 0600 like every other key.** `clash-api.env` was the one deliberate world-readable exception under `state/keys` because the non-root admin app read it directly. The root admin entrypoint now reads it and hands the secret over via environment, so the exception (and the code that actively restored 0644 on every pass) is gone. Requires the admin image to be rebuilt, which `moav update` does.
- **The key-permissions repair now actually reaches existing installs.** The rc.2 fix that tightened `state/keys` to 0600 only ran at the end of a fresh bootstrap; already-bootstrapped installs exit earlier and upgrades never run the bootstrap container at all, so the installs the repair was written for never got it. The repair now also runs inside the early-exit guard and, host-side, on every `moav up`/`moav start`.
- **User bundles are no longer world-writable (or world-readable).** `outputs/bundles` and `state/users` were held together with `chmod 777` / `chmod -R a+rwX` so the non-root admin app and the root-run provisioning paths could both write — leaving every user's WireGuard private keys and share URIs readable *and modifiable* by any local account. The admin user is now pinned to uid 2000, root-run paths chown bundles to it (`grant_admin_rw`), protocol config dirs stay owner-root with group 2000 (`cap_drop: ALL` without `DAC_OVERRIDE` means in-container root reads only as owner), `configs/wireguard`+`configs/amneziawg` (server private keys, container-root consumers) are fully locked, and the sing-box/xray/telemt/trusttunnel config dirs — read by non-root daemons — keep world-read but lose world-write; existing installs are repaired by the admin entrypoint on each start and host-side on every `moav up`/`moav start`. `configs/monitoring` deliberately keeps world-read (grafana and prometheus run as non-root uids). Non-root operators who read bundles directly now need `sudo`.
- **cAdvisor's privileged mode documented as an accepted exception.** Per-container cpu/memory/disk stats require privileged + read-only host mounts (cAdvisor's upstream deployment mode). Scope limits are documented in compose and the README: all mounts `:ro`, metrics-only API, and the service exists only under the opt-in `monitoring` profile.

### Fixed
- **`moav user add` can no longer hang on a wedged container, on any protocol path (#220).** The AmneziaWG freeze fix (a hard deadline on every `docker compose exec/ps/restart`) only covered `user-add.sh`; `wg-user-add.sh` and `singbox-user-add.sh` still had bare calls that would block forever. `compose_timeout` moved to the shared lib and every container call in the three provisioning scripts now goes through it, pinned by a test that greps for bare calls and functionally verifies the deadline fires. e2e now also asserts the AmneziaWG and WireGuard client configs actually materialize when those protocols are enabled.

### Changed
- **`wg-user-add.sh` routed through the shared `wireguard_add_peer`.** The host script re-implemented the lib function and had drifted: it hard-errored on an existing peer instead of re-issuing idempotently, minted fresh keys on every run (invalidating the user's previous bundle), and lacked the incomplete-state-file and third-state (peer-without-state) guards. The orchestration extras (server-key sync from the running interface, hot-add, QR codes) stay in the script; keygen, IP allocation, state write and the `wg0.conf` append are now the same code the container path runs.

### Changed
- **Deduplicated the TrustTunnel... telemt user-add path.** `singbox-user-add.sh` had an inline copy of the telemt config mutation that duplicated `scripts/lib/telemt.sh` and drifted from it; the host caller now uses the shared `telemt_generate_secret` + `telemt_add_user_to_config` (the latter gained a config-path argument so host and container callers share it). Also fixes a latent bug: the inline version minted a fresh MTProxy secret on every re-run, invalidating the user's existing bundle; the lib path reuses the stored secret.

### Internal
- **Regression tests for two security fixes that had none.** The admin CIDR-whitelist matcher is now unit-tested (13 cases incl. IPv6, family mismatch, and malformed-fails-closed) after being lifted to a module-level `ip_matches` function; and `.env` being created `0600` is now asserted at both creation sites. The whitelist bug (every CIDR entry denied everyone) had shipped untested because the repo had no Python tests.

### Fixed
- **Five `.env` reads bypassed the config accessor, and the test that was supposed to catch them was quote-blind.** Workstream C's "no ad-hoc scrapers" gate grepped only the unquoted `cut -d= -f2`, so five sites written as `cut -d'=' -f2` passed it vacuously — including a `CLASH_API_SECRET` read that truncated any secret containing `=` (a routine base64 character), causing a perpetual "stale secret" resync. All five now use `get_env_val`; the gate matches both quoted and unquoted forms.

### Fixed
- **Three strict-mode crashes in cert-wait/fallback paths (grafana, grafana-proxy, trusttunnel).** D4c enabled `set -e`/`-u` on these but left code written for a tolerant shell in the branches that only run *before* Let's Encrypt has issued, invisible to the happy-path e2e. grafana-proxy had the unguarded `certs=$(find_certificates)` that was fixed in grafana but missed in its twin; grafana read `GF_SERVER_CERT_KEY` unbound on the no-cert path, making its HTTP fallback unreachable; and trusttunnel's `((CERT_WAIT_COUNT++))` returned non-zero from zero, killing its cert-wait one second in. Each crashed a fresh install until certbot succeeded.

### Added
- **Community links in the CLI and README.** The `moav` banner and `moav help` footer now show the Telegram support channel (t.me/motherofallvpns) and Twitter/X; the README gained badges and a Community & support section.

### Changed
- **Full strict mode (`set -eu` + pipefail) for every container entrypoint.** The last six (admin, sing-box, snowflake, wstunnel, grafana, grafana-proxy) had never run under `-e`, so each was reviewed per command and then executed in its real base image. Two real hazards were fixed on the way: grafana's certificate lookup returns non-zero before certbot has issued, and a plain `var=$(cmd)` assignment propagates that, so `-e` would have killed grafana on every fresh install; and its cosmetic branding edits could take the container down if the target layer were read-only.
- **Full strict mode for the admin, sing-box, snowflake and wstunnel entrypoints.** `-e` was previously held back on these because they had never run under it. Each was reviewed per command and then executed in its real base image (alpine/ash and debian/dash) to confirm it still reaches its `exec`, including the graceful-degradation branches such as snowflake continuing when it cannot detect a network interface.
- **The admin entrypoint now reports the certificate it will actually use.** It checked only `/certs/live`, so it printed "SSL: Disabled" even when a self-signed fallback existed and TLS was about to be served.

## [2.0.0-rc.2] - 2026-07-30

> ## ⚠️ EXPERIMENTAL. Do not run this on a production server.
>
> This is a release candidate published for testing. It has **not** been run on a long-lived server, and the upgrade path from 1.9.x is **untested**.
>
> If people depend on your server working, stay on **[v1.9.1](https://github.com/MotherofallVPNs/MoaV/releases/tag/v1.9.1)**. That is what `moav.sh` and the install script still serve by default, and this release does not change that.
>
> Use this on a throwaway VPS, and tell us what breaks.

### What this release is

rc.2 is the security and correctness pass on top of rc.1: roughly 60 commits, no new protocols, no new features. It is the result of going looking for what was quietly broken, and building the test infrastructure that found most of it.

**The theme is silent failure.** Several of these bugs produced no error at all:

- The DNS tunnel had not been genuinely tested in months. Its test looked for a bundle file that a refactor had deleted, and a skipped test is not a failed one, so the suite stayed green.
- The connectivity suite could report success while testing nothing. An empty user bundle made every protocol skip, and skips did not count against the result.
- A dead WireGuard tunnel and a healthy one were indistinguishable to the container checks, because nothing asserted that a container was still running.
- An AnyTLS test existed and had never once executed in CI.

Those gaps are the main reason this candidate exists. Finding them changed what a green run is allowed to mean: it now has to prove that specific protocols actually passed.

### Security

Two findings are worth understanding rather than just noting.

**`docker-proxy` was reachable from every container.** It is an unauthenticated Docker API endpoint. The socket proxy filters by URL path and HTTP method, never by request body, so anything able to reach it could create a privileged container with the host filesystem mounted. It sat on one flat network shared by all 29 containers, including every service that terminates untrusted traffic from the internet: sing-box, xray, wireguard, wstunnel, telemt, snowflake, trusttunnel. A memory-safety bug in any protocol server was therefore a path to host root. The proxy now lives on an internal network with only the admin dashboard, and no data-plane traffic changed: the wstunnel to WireGuard and DNS-tunnel to sing-box chains are untouched.

**The admin panel could serve plain HTTP.** If Let's Encrypt had not issued yet, it printed a warning and started anyway, sending the dashboard password (the same secret Grafana uses) in cleartext on a port published to the internet. This was not an edge case. The self-signed fallback was only generated in domainless mode, so every fresh install with a domain spent its first minutes there, and any install with a DNS, port-80 or rate-limit problem stayed there indefinitely. The panel now always has a certificate and refuses to start without TLS, while still preferring Let's Encrypt when it arrives.

Also fixed:

- Server private key material was world-readable at `0644`, including `reality.env` with the Reality private key, the Shadowsocks PSK, the MasterDNS and GooseRelay keys, and the wstunnel secret. Now `0600`, and repaired on existing installs.
- `.env` was created `0644`. It holds `ADMIN_PASSWORD`, `REALITY_PRIVATE_KEY`, `CLASH_API_SECRET` and the Hysteria2 obfuscation password. Now `0600`.
- All four monitoring exporters held unrestricted Docker API access purely to run `docker logs` and `docker exec`. They now read published state files instead.
- `ADMIN_IP_WHITELIST` set to a CIDR such as `10.0.0.0/8` silently denied everyone. It failed closed, so it was never a bypass, but operators who set one locked themselves out and most likely removed the whitelist entirely.
- Grafana gained `no-new-privileges` and `cap_drop: ALL`.

### Bugs you may have hit

- **`moav regenerate-users` failed for every user** if `ENABLE_REALITY=false`. XHTTP is Reality-over-XHTTP and defaults to on, so it still needed those keys. One config flag broke the whole command, with the cause buried in container logs.
- **WireGuard and AmneziaWG peers could be created with an empty public key.** When no key generator was available the peer was written anyway, and on bash 3.2 it did not even error. The peer simply never worked.
- **A Mahsanet API key containing `=` was silently truncated.** Base64 keys routinely end in `=`, and the `.env` reader cut at the first one, so authentication failed in a way that looked exactly like a wrong key.
- **`moav user add` could exit silently**, with no message and no error.
- **A half-written user state file wedged that user permanently.** If a previous run died mid-write, every retry failed the same way and never self-healed.
- **`moav` did not run on macOS at all**, failing with `declare: -A: invalid option` on bash 3.2.
- **The WireGuard peer count printed as `0 0`.**
- **`moav logs --tail` and `moav update -b` with no value** died with `$2: unbound variable` and no usage hint.

### Under the hood

`moav.sh` went from **9,483 lines to 1,038**, a reduction of 89%. It is now a dispatcher over fifteen focused modules rather than one monolith. Every extraction was verified by function-count conservation and byte-identical command output against the previous revision, so behaviour is unchanged by construction.

All 40 ad-hoc `.env` readers now share a single accessor, which is what surfaced the API-key truncation described above.

Container entrypoints were hardened with strict mode, which required fixing the landmines first. One of those is worth repeating: `set -o pipefail` is fatal in `dash` regardless of `|| true`, because `set` is a POSIX special builtin and a failed special builtin exits a non-interactive shell outright.

### Testing

- `moav test` genuinely exercises dnstt again, and AnyTLS has live coverage for the first time.
- The e2e refuses to report success unless the core protocols actually passed. Skips no longer masquerade as a green run.
- Every long-lived container must be running after startup, so a crash-looping service cannot hide behind a passing test.
- The admin panel is probed on each run to confirm that it speaks TLS and refuses cleartext.
- Nine test suites, roughly 150 assertions, run on every change.

### Known gaps, deliberately not fixed

- **The 1.9.x to 2.0 upgrade path is untested.** This is the single biggest unknown, and the main reason this is a candidate rather than a release.
- `cadvisor` still holds a raw Docker socket and runs privileged. It needs both for what it does, so there is no clean fix and it is documented rather than hidden. It only runs if you enable monitoring.
- Client bundles and generated configs are still world-readable on the host.
- AnyTLS provisioning breaks bootstrap when enabled, so it stays off by default.

### Testing this release

On a disposable VPS only:

```bash
git clone https://github.com/MotherofallVPNs/MoaV.git && cd MoaV
git checkout v2.0.0-rc.2
./moav.sh bootstrap
```

Afterwards, `moav doctor` and `moav test <user>` are the two commands worth running. They will tell you more than the install output does. Bug reports, logs, and "this broke on my setup" issues are all genuinely useful.

Full itemised list below.

### Added
- **`moav doctor peers`, duplicate peer-address detection, with `--fix`.** The pre-v2 allocator assigned peer IPs from the count of `[Peer]` blocks, so revoking a user made the next one reuse a live address. WireGuard's crypto-routing maps an address to exactly one peer, so the later claimant takes it and the earlier peer silently stops receiving traffic, a tunnel that handshakes and then passes nothing. The new check reports every duplicated address, the users claiming it, and which of them currently owns it on the running interface (on the reference server: 19 WireGuard addresses shared by 45 peers, 22 AmneziaWG addresses shared by 50). `moav doctor peers --fix [--yes]` keeps the live owner and resets the others, dropping their `[Peer]` block and per-protocol state so the allocator reassigns them on the next `moav regenerate-users`, then lists exactly who needs a new bundle. Read-only by default; the repair prompts unless `--yes`, and refuses non-interactively without it. Block removal was verified against a copy of a real 147-peer config: exactly one peer removed, `[Interface]`, server keys and PostUp rules intact.

### Changed
- **e2e now proves the admin panel is TLS-only**, functionally rather than by inspection: HTTPS must answer and a cleartext request must not be served. It also reports which certificate was bound, which was previously invisible, a domain install must prefer Let's Encrypt over the self-signed fallback.
- **The xray exporter no longer needs the Docker socket**, the last of the four. It ran both `docker exec … statsquery` and `docker logs -f`. xray now publishes stats snapshots to the shared `moav_metrics` volume and writes its **access** log there (its error log still goes to stdout, so `moav logs xray` is unchanged); the access log is size-capped from the same loop that publishes stats. **No monitoring container holds a raw Docker socket now except cadvisor.**
- **WireGuard and AmneziaWG exporters no longer need the Docker socket.** Each ran `docker exec … wg show`, which required unrestricted Docker API access for a read-only scrape. `wg show` needs the tunnel container's network namespace, so those containers now publish their interface state to a shared `moav_metrics` volume (atomically, from the monitor loop they already run) and the exporters read it. Raw socket mounts across the stack: 5 → 3.
- **The sing-box exporter no longer needs the Docker socket.** It tailed `docker logs` to attribute connections to users, which required unrestricted Docker API access. The Clash API already returns `metadata.inboundUser` per connection, and the exporter was already polling it for GeoIP, so counting moved there and the socket mount is gone. Note: polling cannot see a connection that opens *and* closes between samples, so very short bursts read low; the interval is now 15s and tunable via `SINGBOX_POLL_INTERVAL`.
- **Pinned the state-vs-`.env` precedence defences.** The three variables that are authoritative in `state/keys` but also injected by compose (`REALITY_SHORT_ID`, `REALITY_PRIVATE_KEY`, `CDN_WS_PATH`) each have a guard preventing the injected value from shadowing the real one; those guards are now asserted by tests so they cannot be removed as "redundant".
- **Refactor (C1b):** the provisioning tree's `.env` reads now use `get_env_val` too. Workstream C's single-accessor goal is complete for both trees, every `.env` read in the repo resolves values identically (last-wins duplicates, inline comments stripped, whitespace trimmed, `=` preserved).
- **Refactor (C1a):** the 24 ad-hoc `.env` scrapers in the `lib/` tree now use the single `get_env_val` accessor. Beyond removing duplication this fixes inline-comment, surrounding-whitespace and duplicate-key handling at every one of those sites (last-wins instead of emitting every matching line).
- **`set -u` + `pipefail` for the remaining six entrypoints** (admin, grafana, grafana-proxy, sing-box, snowflake, wstunnel), which previously had no `set` line at all. Three SIGPIPE landmines guarded first. `set -e` is deliberately deferred for these, they have never run under it, so every currently-tolerated non-zero exit would become fatal.
- **Strict mode for the conduit/dnstt/trusttunnel/xray entrypoints** (`set -eu` + `pipefail`, up from bare `set -e`). Two landmines fixed first: conduit's key extraction would have died under `pipefail` *before reaching its own empty-key check*, and xray's `xray version | head -1` raises SIGPIPE on a cosmetic line.
- **e2e now asserts every long-lived container is actually running.** `docker compose ps` previously appeared only in the failure-diagnostics step, so a service that crash-looped at startup went unnoticed on a green run, the protocol tests can still pass around it. One-shot jobs (certbot, bootstrap) are exempt; a failure now dumps the offending container's logs.
- **e2e: WireGuard and AmneziaWG are now tested live.** `moav test` grants the client container `NET_ADMIN` + `/dev/net/tun`, the client image gains `wireguard-tools`, and both tests bring up a real tunnel and fetch the exit IP through it. Previously WireGuard "passed" on a DNS resolve of the endpoint; degraded (no-TUN) runs now cap at *warn*.
- **e2e: AnyTLS live test enabled**, `ENABLE_ANYTLS=true` in the domain pass; its test existed but had never run in CI. **`moav regenerate-users` is now exercised as a command** (reconcile + zero-placeholder assertions). CLI smoke adds `doctor peers`, `user base64`, and the standalone packager.
- **Refactor (B13):** extracted the interactive menu and the small commands it fronts (`check`, `conduit`, `admin`, `user base64`, `test`, `client`, usage text) from `moav.sh` into `lib/menu.sh` (570 lines). `moav.sh` is now 1,038 lines, down from 9,483 at the start of the sprint (-89%), and is a dispatcher over fifteen modules. Relocation only; repo total is roughly flat.

### Fixed
- **The admin panel could serve plain HTTP.** If Let's Encrypt had not issued yet it printed a warning and started anyway, sending the operator's HTTP-Basic credential (the same secret as the Grafana password) in cleartext on an internet-published port, the state of every fresh install for its first minutes, and of any install with a DNS or rate-limit problem. The self-signed fallback is now generated in **every** mode (it was domainless-only), the admin container mints a last-resort certificate if none arrived, and the panel **refuses to start without TLS**. Let's Encrypt is still preferred.
- **dnstt was silently untested.** The connectivity test globbed for `dnstt-instructions.txt`, which was removed when the per-user instruction files were retired, so it found no config, reported `skip`, and since skip is not a failure the suite stayed green while the DNS tunnel went unexercised. It now reads the guide (the current carrier) and looks for the server key at `/dnstt`, which is where `moav test` actually mounts it.
- **`docker-proxy` was reachable from every container.** It is an unauthenticated Docker API endpoint, the socket proxy filters path and method, never the request body, so anything on the shared network could create a privileged container with arbitrary bind mounts and take the host. That included every service terminating untrusted internet traffic. It now sits on an internal `moav_mgmt` network with only the admin dashboard. **No data-plane change:** all 27 other services stay on `moav_net`, so the wstunnel→WireGuard and dnstt/Slipstream→sing-box chains are untouched.
- **`secure_state_keys` silently did nothing on BSD/macOS.** Its loose-permission check used `find -perm /077`, which is GNU-only; on BSD `find` errors, the check yields nothing and no key is tightened. Production was unaffected (it runs in a Linux container) but the helper no-opped for anyone running it on a Mac, and its test failed only there. Now reads the mode via `stat` with a GNU-then-BSD fallback.
- **Admin IP whitelist silently denied every CIDR entry.** `ADMIN_IP_WHITELIST=10.0.0.0/8` matched nothing, the old prefix-stripping comparison could never be true for a CIDR, so operators using one locked themselves out. Now matched with real network containment (IPv4 + IPv6). It failed closed, so this was never a bypass.
- **`.env` is now created 0600.** It holds `ADMIN_PASSWORD`, `REALITY_PRIVATE_KEY`, `CLASH_API_SECRET` and the Hysteria2 obfs password, and was created 0644.
- **Grafana gains `no-new-privileges` and `cap_drop: ALL`.** It stays root with a writable filesystem, the entrypoint patches branding into `/usr/share/grafana/public`, which uid 472 cannot write, but neither of those two hardening flags conflicts with that.
- **A `MAHSANET_API_KEY` containing `=` was silently truncated.** The ad-hoc `.env` scrapers use `cut -d= -f2`, which cuts at the *first* `=`, so base64 API keys lost their padding and authentication failed in a way that looked like a wrong key. The credential reads now use the `get_env_val` accessor (`cut -d= -f2-`). The `ADMIN_PASSWORD` read was migrated too; that one was benign (it only tested for empty/default) but shared the same flaw.
- **`set -o pipefail` cannot be guarded with `|| true` in `dash`.** `set` is a POSIX *special* builtin, so a failed `set -o pipefail` exits a non-interactive shell outright, `|| true` never runs. On debian-based images (`/bin/sh` = dash, no pipefail) this killed the entrypoint at line 3 with exit 2 and no output. All `#!/bin/sh` entrypoints now probe support in a subshell first.
- **WireGuard/AmneziaWG containers could report healthy with a dead tunnel.** Both entrypoints ran with no `set` line at all; an empty `PrivateKey` sailed past `wg set`/`awg set` into the monitor loop. They now run under `set -eu` + `pipefail` and fail loudly when required config is missing.
- **WireGuard peer count printed as `0 0`**, `grep -c` already prints `0` and exits 1 on no match, so the `|| echo 0` fallback appended a second zero.
- **Server private key material was world-readable (0644).** Files under `state/keys/` written via heredoc (`reality.env` holding `REALITY_PRIVATE_KEY`, `clash-api.env` with the Clash API secret and Hysteria2 obfs password, `shadowsocks-server.psk`, `masterdns-encrypt.key`, `gooserelay-tunnel.key`, `wstunnel-path.secret`, `cdn.env`, `amneziawg.env`) inherited umask 022, while the `*.key` files written under `umask 077` beside them were correctly 0600. Bootstrap now tightens all secret key material to 0600, this also repairs existing installs on the next bootstrap. Public counterparts (`*.pub`, certs) are left readable. `clash-api.env` is a deliberate exception, the admin container reads it as a non-root user, so it stays readable (tracked separately).
- **A truncated per-user WireGuard/AmneziaWG state file permanently wedged provisioning for that user.** If a previous run died between creating `state/users/<id>/` and writing the key material, the empty `wireguard.env` still won the "load existing keys" branch, so every retry died on `WG_PRIVATE_KEY: unbound variable` and never self-healed. The state file is now validated after sourcing; an incomplete one is ignored with a warning and the user falls through to the existing recovery paths.
- **`moav` failed on bash 3.2 with `declare: -A: invalid option`.** `moav.sh` now checks the bash version up front and prints an actionable message (stock macOS ships 3.2; supported servers ship 5.x). Set `MOAV_SKIP_BASH_CHECK=1` to bypass for read-only commands during development.
- **`moav logs --tail` and `moav update -b` with no value** died with `$2: unbound variable` and no usage hint; both now report which value is missing.
- **`moav regenerate-users` failed for every user when `ENABLE_REALITY=false`.** XHTTP is VLESS+Reality-over-xhttp and `ENABLE_XHTTP` defaults to `true`, but `generate-user.sh` only sourced `reality.env` when Reality itself was enabled, leaving `REALITY_PUBLIC_KEY` unset for a bundle that still read it. Reality/Hysteria2 key material is now sourced whenever it exists, and a missing required key reports which variable and where instead of `unbound variable`.
- **WireGuard/AmneziaWG peers could be created with an empty public key.** When no key generator was available (`wg_keypair` failing with no output), the paired `read` short-circuited and left `client_public_key` unset: a hard crash on bash >= 4, and silently an empty key written into the client config on bash 3.2. Both generators now fail with an actionable message.
- **`moav user add` could die silently.** Under `pipefail`, a `grep | cut` over an empty Reality volume read exited non-zero with no output, so `set -e` killed the command after `[1/3]` with no error.
- **Hardened `*_add_peer` against a state/config mismatch that would hand a user unusable credentials.** The function handled two cases, key material in state (reuse) and no state with no peer (create), but not the third: **no state while the server already has a peer for that user**. It minted a fresh keypair and address, then the "peer already in config, skipping" guard declined to install them, so the regenerated bundle would carry credentials the server has never seen. The private key only ever exists in the user's bundle, so it cannot be recovered. That state is now detected and **nothing is touched**: the existing peer and bundle are left exactly as they are and the operator is told the user can only be re-issued (`moav user revoke` + `moav user add`). **Latent, not active:** on the reference server every user's key material is present in the `moav_moav_state` volume that the container path reads (147/147 for both protocols), so no user was at risk, the host `state/users/` directory holds only the subset created via `moav user add`, which is a red herring when reasoning about this path. Pre-existing since at least 1.9.1; the v2 allocator work changed the address math, not this branch. Verified across all three states against a copy of that server's config: peer + no state returns 2 and mints nothing (server peer byte-identical afterwards), a brand-new user still allocates and appends, and an existing user with state is reused without duplicating the peer.
- **`moav regenerate-users` silently skipped bundles with no state entry.** The A8 shared provisioning path iterates `state/users/*/`, whereas the older command iterated `outputs/bundles/*/`, so a bundle whose credentials had been lost was passed over without a word (one such user existed on the reference server). It is now reported per user and summarised, with the re-issue command.

### Internal
- **`moav.sh` decomposition B12, `lib/service.sh`; the monolith is gone.** The service layer: docker-compose profile selection and persistence, start / stop / restart, status and version reporting, log viewing, and the `moav start|stop|restart|status|logs|profiles` commands with their profile/service name resolution, two slices, **1,572 lines**. This is the densest and most-called part of the old script, which is why the plan deferred it to the end. **`moav.sh` 3,178 → 1,607, down from 9,483 at the start of the sprint (−7,876, −83%)**, now a dispatcher over fourteen focused modules. Verified: function count conserved at 189, no duplicate definitions, and `version`/`help`/`status`/`profiles`/`doctor help`/`users`/`logs` byte-identical against a clean `dev` worktree once the git-branch string in the banner is normalised; the only remaining textual differences are the file path and line number quoted by two **pre-existing** errors (`declare -A` needs bash 4 and macOS ships 3.2; `/dev/tty` in a non-interactive shell), which is exactly what moving code does to an error message.
- **`moav.sh` decomposition B11, `lib/doctor.sh`.** The whole diagnostic suite in one contiguous slice: every `doctor_check_*`, the `DOCTOR_CHECKS` registry that names them, and `moav doctor` itself, **1,156 lines**, the largest extraction of the sprint. Sourced after `nettune` and `peers`, whose checks it calls. `moav.sh` **4,333 → 3,178**; cumulative **9,483 → 3,178 (−6,305, −66.5%)** across thirteen modules. The risk here was the dynamic dispatch, checks are invoked as `"doctor_check_${check_name}"` and so never appear as literal calls, meaning a botched move would fail only at runtime, so verification specifically exercised it: `moav doctor help` still lists all 16 checks, and `doctor net` / `doctor dns` still resolve **across module boundaries** into `lib/nettune.sh` and `lib/dns.sh`. Function count conserved at 189, no duplicate definitions, and all seven probed subcommands byte-identical against a clean `dev` worktree.
- **`moav.sh` decomposition B10, `lib/build.sh`.** Image building: the compose-build wrapper, `moav build` (including `--local`, which builds the monitoring images from source rather than pulling them), the local-build info banner, and the interactive build-services picker, two slices, 346 lines. `moav.sh` **4,678 → 4,333**; cumulative **9,483 → 4,333 (−5,150, −54.3%)** across twelve modules. Verified: function count conserved at 189, no duplicate definitions, and the usual subcommand set byte-identical against a clean `dev` worktree.
- **`moav.sh` decomposition B9, `lib/users.sh`.** User lifecycle from the CLI: the interactive user menu, listing, add / revoke / package, the `moav user` and `moav users` commands, and `moav regenerate-users`. Three non-contiguous slices (240 + 88 + 229 lines) removed in descending order so earlier line numbers stay valid. The provisioning itself stays in `scripts/` (`user-add.sh` on the host, `generate-user.sh` in the container), this is only the CLI surface over it. **`moav.sh` 5,234 → 4,678, now less than half its original size**; cumulative **9,483 → 4,678 (−4,805, −50.7%)** across eleven modules. Verified: function count conserved at 189, no duplicate definitions, and `version`/`help`/`users`/`doctor help`/`cert status` byte-identical against a clean `dev` worktree.
- **`moav.sh` decomposition B8, `lib/bootstrap.sh`.** The host-side wrapper around first-run setup: detecting whether a deployment has been bootstrapped, driving the bootstrap container, `moav bootstrap`, and `moav domainless` (switch to IP-only operation). Unlike the earlier modules this one was **not contiguous**, the state helpers sat ~3,000 lines above the commands, so it moves as two slices (148 + 159 lines), removing the later slice first so the earlier line numbers stay valid. The bootstrap container's own logic remains in `scripts/bootstrap.sh`; this is only the CLI side. `moav.sh` **5,540 → 5,234**; cumulative **9,483 → 5,234 (−4,249, −44.8%)** across ten modules. Verified: function count conserved at 189, no duplicate definitions, and `version`/`help`/`doctor help`/`update --help`/`cert status` byte-identical against a clean `dev` worktree.
- **`moav.sh` decomposition B7, `lib/install.sh`.** Making `moav` available as a command: the `/usr/local/bin` symlink, shell-completion install/removal, and `moav uninstall` (stop and remove containers, optionally images and data), 428 lines, moved verbatim. `moav.sh` **5,967 → 5,540**; cumulative **9,483 → 5,540 (−3,943, −41.6%)** across nine modules. The module header records why the dispatcher keeps its own `$0`/`BASH_SOURCE` resolution: this symlink is exactly what would break if that moved into a lib, since a lib's `BASH_SOURCE` points at the lib. Verified accordingly, a symlinked invocation still resolves `SCRIPT_DIR` and runs, plus function count conserved at 189, no duplicate definitions, and `version`/`help`/`update --help`/`doctor help` byte-identical against `dev`.
- **`moav.sh` decomposition B6, `lib/update.sh`.** `moav update` and the seven functions that work out what an operator must do after pulling a new revision: component-version comparison, detecting config templates that changed under a live deployment, detecting sources needing a rebuild, the post-update apply steps, new-variable detection against `.env.example`, and the dnstt→DNS-tunnel state migration older installs still need, 620 lines, moved verbatim. **`moav.sh` drops below 6,000 for the first time: 6,586 → 5,967.** Cumulative with B0-B5 the dispatcher is down **3,516 lines (−37%)** from 9,483, across eight focused modules. Verified: function count conserved at 189, no duplicate definitions, and `version`/`help`/`update --help`/`cert status`/`doctor help` byte-identical against `dev`.
- **`moav.sh` decomposition B5, `lib/dns.sh`.** DNS handling for the DNS-tunnel protocols moves verbatim: port-53 conflict detection and resolution, the declarative DNS-tunnel registry (metadata for the tunnels sharing port 53), `moav switch-dns`, `moav setup-dns` and zone-file generation, 527 lines. `moav.sh` **7,112 → 6,586**; cumulative with B0-B4 the monolith is down **2,897 lines (−30.5%)** from 9,483. Verified: function count conserved at 189, no duplicate definitions, and `version`/`help`/`cert status`/`doctor help`/`dns` byte-identical against `dev` with `moav doctor dns` still crossing correctly into the extracted module.
- **`moav.sh` decomposition B4, `lib/migrate.sh`, plus the first genuinely dead function removed.** `moav export` / `moav import` (state, configs and bundles as one archive) and `moav migrate-ip` (rewrite the server address across configs and bundles after a VPS move) move verbatim into `lib/migrate.sh`, 644 lines; `moav.sh` **7,755 → 7,112**. Also **deleted `get_cdn_url`**: one occurrence repo-wide, its own definition, while its three sibling URL getters are used 4-6 times each. Worth recording how that was established, because the obvious approach lies, a naive "defined but never called" scan flagged 15 functions and 14 were false positives, since every `doctor_check_*` is invoked as `"doctor_check_${check_name}"` from the registry and so never appears as a literal call. Verified: function count 190 → **189** (exactly the one deletion), no duplicate definitions, and `version`/`help`/`cert status`/`donate status`/`doctor help` byte-identical against `dev`, with `moav export` still dispatching into the extracted module.
- **`moav.sh` decomposition B3, `lib/cert.sh`.** TLS certificate auto-renewal scheduling (the systemd timer, the cron.d fallback, install/uninstall/status) plus the `moav cert` command and the `auto_setup_cert_renew` hook that `moav start` calls, 5 functions and their four path globals, move verbatim into `lib/cert.sh`. 142 lines; `moav.sh` **7,867 → 7,726**. Verified: function count conserved exactly (182 = 126 + 17 + 12 + 22 + 5), no duplicate definitions, and `moav cert status` (the extracted path) plus `version`/`help`/`donate status`/`net status` are all byte-identical in output and exit code against `dev`.
- **`moav.sh` decomposition B2, `lib/donate.sh`.** The MahsaNet config-donation block plus the Conduit/Snowflake donation setup and status views (22 functions, the API endpoint and the donations-ledger path) move verbatim into `lib/donate.sh`, the largest single extraction so far at 1,006 lines. `moav.sh` **8,872 → 7,867**; with B0 and B1 the monolith is down **1,616 lines (−15%)** from 9,483. Also corrected a B1 side effect: the `DOCTOR_CHECKS` registry sat inside the range B1 extracted and was carried into `lib/nettune.sh`, where it does not belong; it is back beside `cmd_doctor` in the dispatcher, ready for the doctor module to claim later. Verified: top-level function count conserved exactly (182 = 131 + 17 + 12 + 22) with no duplicate definitions, and `moav version`, `help`, `donate status`, `doctor help` and `net status` all produce byte-identical output and exit codes against `dev`.
- **`moav.sh` decomposition B1, `lib/nettune.sh`.** Second module out of the monolith (after B0's `lib/common.sh`): the self-contained network-tuning block, BBR/qdisc detection, socket-buffer sizing, the sysctl bundle render/apply/revert, `nt_status`, the PMTU/drops/CGNAT/MTU checks and the `moav net` command, moves verbatim into a top-level `lib/nettune.sh`, along with its only global (`NT_CONF_PATH`). Sourced right after `common` and before the doctor checks, since `doctor_check_net` calls `nt_status`/`nt_check_*` (modules are sourced into one shell, so this is documentation of intent rather than a hard requirement). `moav.sh` 9,257 → 8,872 lines. Verified: the top-level function count is conserved exactly (182 = 153 + 17 + 12) with no duplicate definitions; `moav net status`, `moav version` and `moav help` produce **byte-identical output and exit codes** to `dev`; and `moav doctor`, which calls across the new module boundary, differs only in the line number quoted by a pre-existing `set -u` error, exactly as expected after removing 380 lines. `bash -n` + `shellcheck --severity=error` clean.

## [2.0.0-rc.1] - 2026-07-26

First release candidate for v2.0.0. Please test on a non-critical server before
you rely on it, and report anything odd.

**Fixes you can feel.** Three bugs that quietly shipped broken configs to users
are gone. `moav user add --package` was handing out a zip whose guide still had
26 unfilled `{{PLACEHOLDER}}` markers, wiping out the correctly rendered one, and
it silently produced no archive at all on hosts without `zip`. TrustTunnel client
configs were invalid TOML on every IPv6 capable server, so the client refused to
load them. WireGuard and AmneziaWG peers could be handed an IP address that
another user already had, which is why two users sometimes fought over one
tunnel: on one real server this had already produced 26 duplicate WireGuard
addresses and 28 duplicate AmneziaWG ones.

**Sturdier user provisioning.** `moav bootstrap` and `moav regenerate-users` now
share one implementation for turning your user state into configs and bundles,
with one error contract. Previously they diverged, which is why
`regenerate-users` could heal a server that `bootstrap` silently aborted on.

**Internals.** The provisioning code that was duplicated between the host and
container paths (keys, WireGuard and AmneziaWG, the client guide, the sing-box
and xray server mutations, XHTTP and XDNS, TrustTunnel) is now single sourced in
`scripts/lib/`, and the 9,500 line `moav.sh` has started splitting into modules.
Bundles ship one guide, `README.html`, instead of a pile of per protocol
instruction text files.

**Testing.** The end to end suite now installs its own tooling and refuses to
skip a check when something is missing, which is how several of the bugs above
were found. New gates cover the packaged bundle, the peer IP allocator, and
TrustTunnel config validity.

### Internal
- **Provisioning refactor A8 — one shared "materialize every user" path (`scripts/lib/provision.sh`); completes Workstream A.** `bootstrap` and `moav regenerate-users` both have to make the server match the user state, and both implemented it separately — with **different shell-safety contracts**, which is the divergence behind two incidents this cycle. `bootstrap.sh` sourced `lib/sync.sh` under `set -euo pipefail`, so a single user's failed field-parse aborted the whole reconcile silently; `moav regenerate-users` ran the same code in a `docker … -c` shell **without** `set -e` and therefore survived — which is exactly why "regenerate-users fixes it but bootstrap doesn't" was a real thing operators hit. Both now call `provision_all_users [force]`: mirror host state (authoritative — the import loops skip existing dirs, so a stale/partial one is otherwise never repaired) → materialize a bundle for every user that has credentials → reconcile into the sing-box/xray configs. **Every step is individually guarded**, so the function behaves identically whether or not the caller uses `set -e`: one user's failure never aborts the run, and the reconcile *always* gets a chance to run (a partial bundle is recoverable; an unreconciled server config means users cannot connect at all). Verified with a harness that runs the real function twice — once under `set -euo pipefail`, once without — against a seeded state containing a user whose bundle generation fails and a user with no credentials: **identical output in both modes**, the failing user is reported and skipped, the credential-less user is ignored without error, and the reconcile runs in both cases. `moav regenerate-users` also gets simpler and faster: it was doing one `docker compose run` **per user** (re-passing ~50 `-e` variables each time) plus a second, separate run for the reconcile; it is now a single run that provisions and reconciles, then reloads the proxies. Bootstrap additionally now heals a user that exists in state but never got a bundle. Net +112/−32 lines (a new 82-line lib against inline duplication).
- **Provisioning refactor A7d — host AmneziaWG peer-add via the shared lib; completes A7 and Workstream A's WG/AWG unification.** The host `moav user add` path still generated the AmneziaWG keypair, allocated the client IP and appended the `[Peer]` block itself, even though `lib/amneziawg.sh`'s `amneziawg_add_peer` did exactly that — and had been written *for this caller*: its trailing `extra_used` octet arguments exist so the host can pass the octets scraped from a live `awg show awg0 allowed-ips`, and that parameter had never been wired up. A3b moved the host to the lib's *client-config* renderer; this moves the *peer-add* half, so the host now only scrapes the live octets, calls the lib, reads back the allocated values and keeps its own hot-add (`awg set`) and bundle copy. Two behaviour improvements come with it: the insert is now **idempotent** (the lib skips a user already present in `awg0.conf`; the inline block would have appended a duplicate `[Peer]`), and a keypair already in state is reused instead of silently regenerated. Verified with a harness on a seeded config containing both a revoked-user gap and live-only octets: the allocated address is `max(config, live)+1`, the `amneziawg.env` field set/order and the appended `[Peer]` block are unchanged, and a repeat call adds no second peer. Net −24 lines. **Workstream A's WG/AWG duplication is now fully retired** — both protocols, both halves (allocation + rendering), on both paths.
- **Provisioning refactor A7c — `scripts/lib/trusttunnel.sh` (client bundle single-sourced).** The host `moav user add` path and the container bundle generator each carried their own copy of the TrustTunnel client artifacts (`trusttunnel.toml` + `trusttunnel.json`, ~47 lines) — the largest remaining un-libified duplicate, and it had drifted in a user-visible way (`has_ipv6`, see Fixed above). Both now call `trusttunnel_write_client_bundle <out> <user> <password>`. Container output is otherwise **byte-identical** (verified against the pre-refactor render; passwords containing `&` survive, which the removed `sed`-based paths were fragile about, and the JSON validates). Also removed the dead `trusttunnel_add_user`/`trusttunnel_remove_user` pair from `lib/sing-box.sh` — zero callers repo-wide (leftovers of the same class as the dead `singbox_*` helpers A4 removed; the real server-side `credentials.toml` mutation is inline in `singbox-user-add.sh` on the host and comes from the bootstrap template in the container). Net −43 lines. Third of the four rescoped A7 items.
- **Provisioning refactor A7 rescoped; deleted the dead third user-generator (A7b).** `scripts/generate-single-user.sh` (311 lines) is removed. It was not merely uncalled but **unrunnable**: nothing invoked it anywhere in the tree, `docker-compose.yml` mounts only `bootstrap.sh` / `generate-user.sh` / `scripts/lib` into the bootstrap image, and `Dockerfile.bootstrap` deliberately `COPY`s no scripts — yet the file sourced `/app/lib/*.sh` and exec'd `/app/generate-user.sh`, paths that exist only inside a container where the file itself was absent. It also held the last orphan copies of the server-config mutation and XHTTP client blocks that A4/A6 deferred to A7. The docs that described it as a live path are corrected: `docs/devdocs/PROTOCOL-INTEGRATION-CHECKLIST.md` had a whole "3c" section prescribing edits to it plus a callout claiming it was the container path that "both paths must handle" — replaced with the real topology (container = `generate-user.sh`, host = `user-add.sh`, shared work belongs in `scripts/lib/<proto>.sh`) — and its pre-A5 `sed -i.bak` / `qr_to_base64` / `replace_placeholder` recipes now point at `lib/bundle_readme.py`'s placeholder map, since those mechanisms no longer exist anywhere in the tree. **A7 itself is rescoped:** its premise ("the two entry points differ only in paths + reload strategy") is false — `user-add.sh` generates credentials, mutates six server configs, reloads services and owns batch/`--package`/donate under three privilege models, while `generate-user.sh` only renders a bundle from existing state, never reloads, and is force-idempotent; they share almost nothing directly, carry incompatible `set -e` contracts, and `admin/main.py` screen-scrapes `user-add.sh`'s stdout. The split is a real responsibility boundary and is kept deliberately; the rationale and the replacement items (A7a done, A7b done, A7c `lib/trusttunnel.sh`, A7d host AWG → `amneziawg_add_peer`) are recorded in `docs/devdocs/V2-REFACTOR-PLAN.md`.
- **`moav.sh` decomposition B0 — new top-level `lib/common.sh` + source scaffolding.** First step of retiring the 9,483-line `moav.sh` monolith (which sourced nothing): the file's own "Helper Functions" block — 17 foundation helpers (`check_for_updates`, `get_latest_version`, `version_gt`, `print_header`, `print_section`, `info`/`success`/`warn`/`error`, `prompt`, `confirm`, `press_enter`, the four service-URL getters, `run_command`) — moves verbatim into a new **top-level `lib/`** (distinct from `scripts/lib/`, which holds the protocol generators), and the dispatcher sources it. Modules are *sourced*, not sub-shelled, so the dispatch `case` and every command function are untouched; the top-level function count is conserved exactly (182 = 165 + 17, no duplicate or lost definitions). Per the plan's hard constraints, the colors / `SCRIPT_DIR` / `VERSION` / state globals and the `$0`+`BASH_SOURCE` **symlink resolution stay in the entrypoint, set before the source** — a lib's own `BASH_SOURCE` would point at the lib, and `moav install` symlinks the script into `/usr/local/bin`, so that path is load-bearing. `moav.sh` 9,483 → 9,257 lines. Verified with `bash -n` + `shellcheck --severity=error` on both files, a **symlinked-invocation** run (the resolution hazard), and live `moav version` / `moav help` dispatch spot-checks rendering lib-provided output; the one non-zero exit found (`moav usage`, state-dependent) reproduces identically on `dev`, so it predates this change. See `docs/devdocs/V2-REFACTOR-PLAN.md` (Workstream B).
- **Provisioning refactor A3b (AmneziaWG) — host renders AWG client configs via the shared lib; completes A3b.** The host AmneziaWG block inline in `user-add.sh` re-read the obfuscation params and server key itself and carried its own copies of the two `.conf` templates (direct + IPv6). It now calls `amneziawg_generate_client_config`, matching the WireGuard side: the block already writes `amneziawg.env` with exactly the fields the lib reads, and since the lib takes its obfuscation params from the `awg0.conf` header (see the config-path cleanup below) the output is byte-identical. Three supporting fixes: `lib/amneziawg.sh` is now sourced by `user-add.sh`; `STATE_DIR` + the host `AWG_CONFIG_DIR`/`GOOSERELAY_CONFIG_DIR` overrides are hoisted **above** the per-user loop (they were previously set only *after* the AmneziaWG block, so the lib would have defaulted to the container paths); and the credentials copy now writes to `$STATE_DIR/users/<user>/` instead of a hardcoded `./state/...`, so the generator reads back the same file. Byte-equivalence verified (pre-refactor inline output vs the lib: both `.conf` identical) + `shellcheck --severity=error`; gated by the e2e amneziawg checks. Net −49 lines. Host and container now share one renderer for **both** WireGuard and AmneziaWG.
- **Provisioning refactor A3b (WireGuard) — host renders WG client configs via the shared lib.** The host `moav user add` path (`wg-user-add.sh`) carried its own copies of the three WireGuard `.conf` templates (direct / IPv6 / wstunnel) — byte-identical to `lib/wireguard.sh`'s `wireguard_generate_client_config` once #169 aligned the host `MTU`. It now calls that lib function (reading the `wireguard.env` it already writes + the `server.pub` it already syncs, honoring `SERVER_IPV6`/`PORT_WIREGUARD`), so host and container WireGuard bundles have a single source. Byte-equivalence verified (pre-refactor inline output vs the lib: all three `.conf` identical) + `shellcheck --severity=error`; gated by the e2e wireguard/wstunnel checks. Net −54 lines. (The AmneziaWG host block is inline in `user-add.sh` with a hardcoded `./state` and no lib sourcing — folded in a follow-up.)
- **Bundles: removed the last 5 instruction `.txt`; consumers now read canonical config sources.** The follow-up to the 4-file cleanup: the remaining `slipstream`/`masterdns`/`gooserelay`/`dnstt`/`trusttunnel` instruction files weren't redundant guides — they were **consumed as data** (`bundle_readme.py` embedded three of them into the README, `user-package.sh` parsed the dnstt pubkey out of one, `admin/main.py` detected protocols by their presence). Each consumer is now repointed to a canonical artifact, and the `.txt` are gone: **masterdns** — the lib writes `masterdns-client_config.toml` (the client config; the README embeds that and `admin` detects it); **gooserelay** — the README embeds the already-generated `gooserelay-client_config.json`; **slipstream** — the README section is keyed on `slipstream-cert.pem` (this also fixes a latent bug where `CONFIG_SLIPSTREAM` held the instructions text but was wired into the section's `style=""` display toggle), and a minimal `slipstream-client.conf` now carries the tunnel domain that `client-connect.sh` + the connectivity test read; **dnstt** — the README already rendered from `RB_DNSTT_PUBKEY`/`RB_DNSTT_DOMAIN` env, so `user-package.sh` now reads the pubkey from `outputs/dnstt/server.pub` (fallback `state/keys/dnstt-server.pub.hex`), `admin` detects it server-level (`outputs/dnstt/server.pub`), and the now-unused `dnstt_generate_client_instructions` + its two call sites are removed; **trusttunnel** — the README password comes from `RB_USER_PASSWORD` (fallback now names `trusttunnel.json`), and `client-connect.sh`/`admin` use `.toml`/`.json`. Net −300 lines. Verified with a README render harness (positive: masterdns TOML + gooserelay JSON embedded, dnstt/trusttunnel from env, slipstream section shown, no `instructions.txt` references, no leftover `{{…}}`; negative: absent protocols hide their sections without error) + `shellcheck --severity=error`. Gated by the e2e `test_readme_bundle` + per-protocol checks.
- **Bundles: README.html is the single client guide — dropped 4 redundant instruction `.txt` files.** Each bundle shipped human-readable setup guides (`xhttp.txt`, `xdns.txt`, `wireguard-instructions.txt`, `telegram-proxy-instructions.txt`) that duplicated the per-protocol sections already in `README.html`. They're now removed; the **importable data stays** in its own files (`xhttp-vless.txt`, `xdns-config.json`/`xdns-direct-config.json`, the WireGuard `.conf`s, `telegram-proxy-link.txt`). Before deletion, the template was diffed against each guide — the only content not already present was the XDNS **MTU-tuning tips**, now backfilled into the XDNS section (EN + FA). Two consumers updated: `client-connect.sh` no longer falls back to `xhttp.txt` (the link lives in `xhttp-vless.txt`), and the WG terminal summary drops the stale line. Also, per the same "consistent config paths" cleanup: **WireGuard client configs now carry `MTU = 1280`** on the host `moav user add` path too (the container/lib path already did — host and container WG bundles now match), and `amneziawg_generate_client_config` reads the obfuscation params from the **`awg0.conf` `[Interface]` header** (present on both host and container) instead of `state/keys/amneziawg.env` (container-only) — one config-read path, byte-identical output (the two sources hold identical values, verified against a live server). **Scope:** only the 4 pure-guide files. Five other instruction `.txt` (`slipstream`/`masterdns`/`gooserelay`/`dnstt`/`trusttunnel`) are **consumed as data** — `bundle_readme.py` embeds them into the README, `user-package.sh` parses the dnstt pubkey, `admin/main.py` detects protocols by their presence — so removing those needs a follow-up that first repoints each consumer to the canonical config source. Verified on a live server (removed files absent, kept links/configs present, `xdns` JSON valid, AWG params match the `awg0.conf` header, WG/AWG MTU present) + golden `tests/singbox-links-test.sh` + `shellcheck --severity=error`. Gated by the e2e xhttp/xdns/wireguard/amneziawg + `test_readme_bundle` checks.
- **Provisioning refactor A6 — XHTTP/XDNS client-bundle generation into `lib/xray.sh`.** The host `moav user add` path (`singbox-user-add.sh`) and the container bundle generator (`generate-user.sh`) each carried a near-identical ~195-line copy of the XHTTP + XDNS client-config generation (share link, QR, the `xhttp.txt`/`xdns.txt` guides, the two `xdns-*.json` configs, and the embedded Python that builds the FinalMask `resolvers`). The XHTTP copies were byte-identical; the **XDNS copies had drifted** — the host block lagged the container's `XDNS_METHOD` (txt/aaaa) support and `uuid.env` fallback, and emitted differently-formatted JSON plus three redundant Telegram lines in `xdns.txt`. Both now call `xray_xhttp_link` / `xray_write_xhttp_bundle` / `xray_write_xdns_bundle` (+ the `xray_xdns_finalmask` Python helper) in `lib/xray.sh`, mirroring the `lib/sing-box.sh` share-link builder pattern. The **container form is canonical**, so its output is byte-for-byte unchanged and the host bundle is reconciled up to it (gaining `XDNS_METHOD` + the uuid fallback, losing the redundant lines) — the host↔container de-drift. `generate-user.sh` now sources `lib/xray.sh`; the dead XHTTP copy in the orphan `generate-single-user.sh` is left for A7. Net −194 lines. Verified with a byte-equivalence harness (the pre-refactor container code vs the new lib functions, identical env: all five emitted files — `xhttp-vless.txt`, `xhttp.txt`, `xdns-config.json`, `xdns-direct-config.json`, `xdns.txt` — **byte-identical**, JSON valid) plus the golden `tests/singbox-links-test.sh` and `shellcheck --severity=error`. Gated by the e2e xhttp/xdns + `test_readme_bundle` checks. Stacks on A4 (shares `lib/xray.sh`). See `docs/devdocs/V2-REFACTOR-PLAN.md`.
- **Provisioning refactor A4 — one canonical sing-box/xray server-config mutation (`singbox_add_user` + new `lib/xray.sh`).** Inserting a user's inbound entries into `configs/sing-box/config.json` / `configs/xray/config.json` existed in **five** divergent copies — three different `jq` idioms, three dedup strategies, and three xray-field behaviours — of which two were already **dead code** (`lib/sing-box.sh`'s `singbox_add_user`/`singbox_remove_user`/`singbox_reload`, which also missed AnyTLS + Shadowsocks and had no dedup; and `generate-single-user.sh`'s inline copy). The only correct copy was `sync_server_users` in `lib/sync.sh`: per-inbound-independent idempotency (UUID inbounds dedup by uuid, password inbounds by name — the fix for the SS "invalid request" orphan bug) and a field-adaptive xray insert (`has("clients")` → `clients` else `users`, since Xray v26.5.9 renamed the field). That logic is now the canonical `singbox_add_user <config> <user> <uuid> <pass> <ss_psk>` in `lib/sing-box.sh` and `xray_add_user <config> <uuid> <user>` in a new `lib/xray.sh`; both `sync_server_users` and the host `singbox-user-add.sh` call them (the host previously always wrote xray `settings.users`, silently wrong on a legacy `clients`-field config — now adaptive). The dead lib helpers are removed; `generate-single-user.sh`'s orphan copy is left for A7, which owns collapsing that file. `xray.sh` is sourced by `bootstrap.sh`, the host add path, and the `moav regenerate-users` reconcile shell. Net −80 lines (−168/+88). Verified with the golden `tests/singbox-links-test.sh` (link-gen half untouched) and an isolation harness running the real canonical reconcile against **copies of a live 146-user server's sing-box + xray configs**: the canonical produced **zero changes** against the config the old code built (byte-identical output across every user × inbound), a drop-and-re-add restored the exact inbound membership including the Shadowsocks path, and a second reconcile pass was a no-op (convergent). Gated by the e2e per-protocol reachability checks + `tests/assert-users-reconciled.sh`. See `docs/devdocs/V2-REFACTOR-PLAN.md`.
- **Provisioning refactor A3 — one collision-safe WireGuard/AmneziaWG peer-IP allocator (`net_next_free_octet`).** Peer-IP assignment was implemented four times: the two host paths (`wg-user-add.sh`; the AmneziaWG block inline in `user-add.sh`) scanned the config **and** the running interface for the highest octet and used max+1, while the two `lib/{wireguard,amneziawg}.sh` copies used the peer's `[Peer]`-block **count**+1. The count scheme reused revoked users' addresses: any gap in the peer list handed a still-live IP to a new user. On a real 147-peer server this had already produced **26 duplicate WireGuard octets and 28 duplicate AmneziaWG octets** — up to three users sharing one tunnel IP. All four sites now call a single `net_next_free_octet <config> <prefix> [live_octet …]` in `lib/common.sh`, which merges the config scan with any live-interface octets and returns max+1 (or fails when the /24 is exhausted). `wireguard_add_peer`/`amneziawg_add_peer` drop their `peer_num` argument; `generate-user.sh` no longer computes a peer count; the host loops collapse to the same call with byte-identical output. **Scope:** allocation only — the per-path client-config *rendering* still differs in bundle contents (MTU line, `instructions.txt`/QR, and the AmneziaWG obfuscation-param source: host reads the `awg0.conf` header, the lib reads `state/keys/amneziawg.env`), so folding those bodies is a follow-up. Net +150/−44. Verified with a new `tests/net-alloc-test.sh` unit (9 cases in `ci.yml`: empty/contiguous/gap/dual-stack/live-merge/AWG-prefix/garbage/exhaustion) plus an isolation harness that ran the **real** lib functions against copies of a live server's `wg0.conf`/`awg0.conf` (fresh add = collision-free max+1; the gap case where the old scheme collided on an occupied `.5` now yields `.6`; idempotent re-add reuses the stored IP), and confirmed the host old-loop and new function pick the identical octet on live data. Gated by the e2e wireguard/wstunnel/amneziawg checks. See `docs/devdocs/V2-REFACTOR-PLAN.md`.
- **Provisioning refactor A2 — host DNS-family + Telegram instructions via the shared libs.** The host `user-add.sh` carried its own ~250-line copies of the dnstt / Slipstream / MasterDNS / GooseRelay / telemt client-instruction text (each literally commented "keep in sync with lib/*"), reading keys from `outputs/<proto>/*` while the container path already used the canonical `$STATE_DIR/keys/*`. The host now sources and calls the same `lib/<proto>.sh` `*_generate_client_instructions` the container uses, so host and container bundles can no longer drift; keys come from `$STATE_DIR/keys/*` and GooseRelay's config dir is pointed at the host `configs/gooserelay`. Guards emit a file only when the protocol is enabled and its key/config is present, and each call is `set -e`-safe. Net −219 lines. Verified with a host-context render harness (dnstt/slipstream/masterdns/telemt: files present, keys + server IP rendered, no leftover `KEY_NOT_GENERATED`/`{{}}`) plus the e2e dnstt/slipstream/masterdns/telemt + `test_readme_bundle` gates. Second step of the v2 provisioning unification — see `docs/devdocs/V2-REFACTOR-PLAN.md`.
- **Provisioning refactor A5 — single-source bundle README + subscription (`scripts/lib/bundle-readme.sh` + `bundle_readme.py`).** The ~290-line block that renders each user's client-guide `README.html` from the template and writes `subscription.txt` was duplicated in `user-add.sh` (host) and `generate-user.sh` (container) and had drifted — the two used different `sed` flavors (`-i` vs `-i.bak`), different variable names, and diverging fallbacks. Both are now thin callers of one `render_bundle_readme`, which does **all** substitution in a single Python pass: no `sed` (so no BSD/GNU split), and multiline configs + passwords with shell-special chars (`|`, `&`) are handled natively instead of silently corrupting the guide. `subscription.txt` is now written **unconditionally** (empty when the bundle has no V2Ray-compatible links), fixing the coupling where a bundle could lack the file. Net −576 lines across the two scripts. Verified with a render harness (full/minimal/no-proxy bundles, host + container contexts: no leftover `{{}}`, correct fallbacks, special-char passwords intact, subscription always present) and the e2e `test_readme_bundle` gate. See `docs/devdocs/V2-REFACTOR-PLAN.md`.
- **e2e: 3 named tiers + fix a stale smoke-test path.** The e2e `workflow_dispatch` now takes a single `tier` choice — `default` (domain only), `full` (domain + domainless), `mega` (full + `build --local` + image removal) — replacing the old `full`/`domainless` booleans; a `domainless_only` toggle keeps the Let's-Encrypt-free path. Also fixed `tests/cli-smoke-test.sh`, which still ran `bash site/install.sh` after the installer moved to the repo root — the only failure in the post-cutover e2e (unrelated to bundle generation). (A future tier will drive a real moav-client connection test.)
- **Provisioning refactor A1 — single-source key generation (`scripts/lib/keys.sh`).** The five WireGuard/AmneziaWG client-keypair generators (`user-add.sh`, `wg-user-add.sh`, `generate-single-user.sh`, and the two `lib/{wireguard,amneziawg}.sh` copies) each carried their own tool-selection + CRLF handling — four were patched for the CRLF-key bug, one lib copy was not. They now all call one CRLF-safe `wg_keypair()` (prefers a local `wg`/`awg`, else a running `wireguard`/`amneziawg` container bounded by `timeout -k`, else a throwaway image). No behaviour change — WireGuard/AmneziaWG keys are interchangeable standard Curve25519 keys; verified by the e2e wireguard/amneziawg checks + the share-link golden test. First step of the v2 provisioning unification — see `docs/devdocs/V2-REFACTOR-PLAN.md`.
- **Telegram release notifier** (`.github/workflows/telegram-notify.yml`) — auto-posts to the MoaV Telegram channel when a GitHub Release is published (title + notes excerpt + release/site links), and when an issue is labeled `announce` (title + link — not every issue). Manual `workflow_dispatch` sends a plain test message, or — with a `release_tag` input — fires a **real** notification for any past release (fetched via `gh api`), so the formatting can be tested against a known release. A small `curl` to the Telegram Bot API (no third-party action in the release path); message built + HTML-escaped by `.github/scripts/telegram_format.py`. Needs repo secrets `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID`; sends are skipped cleanly when unset. Release notes render in a monospace code box, and posts are product-labeled (`PRODUCT` env → `MoaV` / `moav-client`) so server and client releases are distinct in the shared channel.

### Changed
- **No-IPv6 servers: proxied traffic now prefers IPv4, silencing "network is unreachable" spam.** On a host without IPv6, clients still hand sing-box AAAA targets (happy-eyeballs), so the `direct` outbound tried to dial IPv6 addresses it can't route — a burst of `network is unreachable` errors and a wasted dial per connection before the client fell back to IPv4. When `SERVER_IPV6` is empty, bootstrap now injects a `resolve` route rule (`strategy: prefer_ipv4`) so sniffed domains re-resolve to IPv4 first. **Only** when there's no server IPv6 — dual-stack servers are untouched — and `prefer_ipv4` still falls back to IPv6, so it can never strand a destination. Validated with `sing-box check` on a fully-rendered config.

- **User docs + website moved to [`moav-site`](https://github.com/MotherofallVPNs/moav-site)** — the end-user documentation (`docs/*.md`), the marketing site (`site/`), `mkdocs.yml`, and the `deploy-site` workflow now live in the `moav-site` repo (served at `https://moav.sh/docs/`); they're removed from the server repo to end the multi-surface doc drift. README/CONTRIBUTING links and the `moav`/`bootstrap` doc hints now point at `moav.sh/docs/…`. The contributor/agent-facing dev docs stay in-repo under `docs/devdocs/`. Runtime files that lived under the moved trees were relocated, not deleted: the client-bundle template `docs/client-guide-template.html` → **`templates/`**, the Grafana/admin branding assets `site/assets/{favicon,logo}` → **`branding/`** (bundle generation and dashboard favicons are unchanged), and the installer `site/install.sh` → repo root **`install.sh`** (its natural source-of-truth home — it clones and versions this repo). The release workflow now attaches `install.sh` as a release asset, and moav-site publishes it at `moav.sh/install.sh` by fetching the latest release at deploy time, so the `curl … | bash` one-liner downloads from the vanity domain (never redirected to a GitHub host that may be blocked in censored networks). The old **`cloud-init.sh` one-click deploy path was dropped** — it duplicated install.sh's prereq/Docker/clone logic (and had already drifted: no low-RAM swapfile guard) while never doing the real config, which always required an interactive SSH session anyway; the deploy-provider flow is now just "create the VPS, SSH in, run the install one-liner." The protocol-roster gate (`gen-protocol-docs.py`) now drift-checks the server README only; the generated overview table lives on the site.

### Fixed
- **TrustTunnel client configs were unparseable on IPv6-capable servers.** `trusttunnel.toml` set `has_ipv6` from `${SERVER_IPV6:+true}${SERVER_IPV6:-false}`, which reads like a ternary but is not one: when `SERVER_IPV6` is set, `:+` yields `true` **and** `:-` yields the address, so the file contained `has_ipv6 = true2001:db8::1` — invalid TOML that the client rejects outright (`TOMLDecodeError`), meaning TrustTunnel simply could not be configured from a MoaV bundle on any dual-stack server. It rendered correctly (`false`) only on IPv4-only hosts, which is why it went unnoticed — including by the e2e, whose TrustTunnel check greps individual fields with `sed`/`grep` and therefore "succeeds" on a syntactically broken file, on a runner that has no IPv6. Now computed as a real boolean. The **host** path had the mirror-image bug: it hardcoded `has_ipv6 = false`, so a user provisioned by `moav user add` never got IPv6 even on a dual-stack server. Both paths now share one renderer (see A7c below), and the e2e TrustTunnel check gained a real TOML **parse** (via `tomllib`) plus a bare-boolean assertion over `has_ipv6`/`killswitch_enabled`/`post_quantum_group_enabled`/`skip_verification`/`anti_dpi`, so this class fails the suite instead of shipping (verified: the guard rejects the old malformed value and accepts the fixed one).
- **`moav user add --package` shipped users a broken client guide.** The zip's `README.html` went out with **~26 raw `{{PLACEHOLDER}}` markers** — including the entire Shadowsocks, XHTTP, AmneziaWG, Telegram-MTProxy, XDNS, CDN, MasterDNS, GooseRelay and Slipstream config blocks — so anyone handed a packaged bundle saw literal `{{CONFIG_SHADOWSOCKS}}` where their connection details belonged. Cause: `scripts/user-package.sh` still carried a **pre-A5 `sed -i.bak`/`awk` renderer** of its own that substituted only 19 of the template's 45 placeholders, and it *overwrote* the correct guide — its file-copy loop (`*.txt *.conf *.yaml *.json`) never copied the `README.html` that `render_bundle_readme` had already rendered correctly into the bundle, then it wrote its own broken render to the same path. This is the exact bug class the A5 single-source README refactor retired; it survived because A5 unified the two provisioning entry points and this third renderer sat behind `--package`. The packager now **copies the bundle's finished artifacts and renders nothing** (and fails loudly if `README.html` is missing rather than shipping a guide-less zip). As a bonus the zip now also carries the **QR images** and the `.pem`/`.toml`/`.gs` files, which the old `.txt/.conf/.yaml/.json` filter silently dropped. Net −273 lines, including the last `sed -i.bak` render path and `qr_to_base64` copy in the tree. **The `--package` path had no test coverage at all** — which is why this shipped — so `tests/cli-smoke-test.sh` now runs `moav user add --package` and asserts the **zip's** guide contains zero unsubstituted placeholders (verified to pass on a good zip and fail on a placeholder-bearing one). Before/after measured on a rendered bundle: 26 placeholders + guide overwritten → 0 placeholders + guide byte-identical to the bundle's.
- **`--package` silently produced no archive on hosts without `zip`.** Found by the new smoke assertion above, on the first run: `zip` is **not** an install prerequisite (`check_prerequisites` covers docker/qrencode, not zip) and `scripts/user-package.sh` never checked for it — while `moav user package` and `moav user base64` both do. Because `user-add.sh` invokes the packager inside an `if`, the non-zero exit was absorbed and `moav user add --package` reported success for a user who got no zip; the success line even named a file (`<user>.zip`) that this script never creates (it writes `<user>-configs.zip`). The packager now checks `zip` up front and fails with install instructions per platform, the success message names the real path, and the failure message notes the user itself was still created. (`moav user add --package` deliberately still exits 0 when only the archive fails — the account and its bundle are complete; the missing extra is reported loudly rather than fatally.) The **e2e preflight now installs the tooling the suite itself needs** (`zip`, `unzip`, `qrencode`) and hard-fails if it cannot, so a missing tool can never become a silently skipped test; the packaged-guide assertion therefore never skips, and when the archive is absent it re-runs the packager inline to surface the reason (the `--package` call sits inside an `if`, so its failure is otherwise invisible).
- **Bootstrap no longer aborts mid-reconcile on servers with SS-less users.** `sync_server_users` is sourced into `bootstrap.sh`, which runs under `set -euo pipefail`. Its per-user parse `ss=$(sed … shadowsocks.env …)` exited non-zero for any user without a `shadowsocks.env` (common on older/large deployments) — `pipefail` turned that into a fatal `set -e` abort, and the `2>/dev/null` hid it, so bootstrap failed with no real error right after "sing-box configuration written" (reproduced on a 145-user server). `moav regenerate-users` was unaffected because it runs the reconcile in a shell without `set -e` — which is why it kept working. Every per-user field parse is now guarded (`|| true` / file-exists check), so a missing file or empty field is a skip, never fatal.
- **Bootstrap reconcile now heals a stale user-state volume — completes the 1.9.1 fix.** The 1.9.1 reconcile read the Docker state volume (`/state`), but `moav user add` writes to the host state dir (`/host-state`); bootstrap's import loop *skips* volume dirs that already exist, so a stale/partial dir (e.g. an aborted run's user missing `credentials.env`) was never repaired and the reconcile skipped that user — leaving `moav update`/`moav bootstrap` still emitting `unknown UUID` for them even on 1.9.1. Bootstrap now force-mirrors host state → volume immediately before the reconcile (as `moav regenerate-users` already did), so host state is authoritative and every user is re-inserted. (`moav regenerate-users` remains the manual heal for an already-running server.)
- **Reconcile now repairs every protocol inbound independently, not just the UUID ones.** `sync_server_users` gated *all* sing-box inserts on `grep -q "$uuid"` — but Shadowsocks/Trojan/AnyTLS/Hysteria2 entries carry only a password, not the UUID. So once Reality re-added a user's UUID, that guard treated the user as fully present and skipped repairing the password inbounds — leaving them in Reality but **missing from Shadowsocks** (client saw `shadowsocks: invalid request`), and likewise Trojan/AnyTLS/Hysteria2. Each insert is now independently idempotent (UUID inbounds dedup by uuid, password inbounds by name), and the xray insert is per-inbound idempotent too. The e2e suite now force-re-bootstraps after `moav user add` and asserts every user is present in **every** enabled inbound (`tests/assert-users-reconciled.sh`).

## [1.9.1] - 2026-07-14

### Fixed
- **`moav update` / re-bootstrap silently orphaned every non-initial user's proxy access.** Bootstrap regenerates the sing-box + xray configs from templates (`envsubst`), which drops the per-user entries `moav user add` inserts incrementally — and the re-add loop never re-inserted them into those proxy configs. So after an update, every user created via `moav user add` failed with `unknown UUID` on Reality/Trojan/AnyTLS/Hysteria2/CDN/XHTTP (the TLS handshake succeeded, then auth rejected them). New `scripts/lib/sync.sh` `sync_server_users` re-inserts **every** user from state into the sing-box + xray configs using their **stored** credentials — idempotent, so already-distributed bundles keep working (no fresh UUIDs) — and it now runs automatically at the end of bootstrap and from `moav regenerate-users` (which also reloads the proxies). Also detects the xray `settings.clients` vs `settings.users` field so it matches whatever the running config uses. **If you're already affected:** `moav regenerate-users` reconciles the running server.
- **`moav test`'s `readme` check false-failed on CDN** — it grepped the rendered README for a "…not configured" sentinel to detect an unfilled section, but the template's CDN QR fallback contains the literal static text `or CDN not configured`, so an enabled-and-filled CDN section still matched (the first post-1.9.0 domain e2e reported `readme: fail` with every protocol passing). The check now positively asserts each enabled protocol's actual **share link** is present in the README instead — immune to static sentinel text, and it still catches the unfilled-placeholder class.

## [1.9.0] - 2026-07-14

### Changed
- **Repository moved to the `MotherofallVPNs` org** — `shayanb/MoaV` is now [`MotherofallVPNs/moav`](https://github.com/MotherofallVPNs/moav), joining `moav-client` and `moav-site` under one org. GitHub 301-redirects the old paths (clones, issues, PRs, releases) so existing installs and links keep working. Swept the hardcoded `shayanb/MoaV` references across the repo (install one-liner `REPO_URL`, README badges, docs, issue templates, CHANGELOG links, the `dns-router` Go module path) to the new home; the personal GitHub Sponsors link is intentionally unchanged.

### Added
- **`moav uninstall` non-interactive flags** — `--yes`/`-y` skips the confirmation prompts, and `--remove-images` also deletes the Docker images (otherwise `--yes` keeps the image cache). Makes uninstall scriptable for automation/CI; interactive behavior is unchanged when no flag is given.
- **`moav bootstrap --yes`** — skips the confirmation prompts, including the "already bootstrapped, re-run?" one. Re-bootstrap is already idempotent (keeps keys/users, regenerates configs), but without a TTY the prompt defaulted to *no* and silently cancelled — so bootstrap was unscriptable. Makes it usable from automation/CI; interactive behavior is unchanged.
- **`moav user base64 <user>`** — emits base64 of a **text-only** bundle (the config files + `subscription.txt`; excludes the QR PNGs and `README.html`, which are the bulk). Paste it into the `moav-client` e2e's `bundle_b64` dispatch input to validate a deployed server against the current client, or use it for a quick client import (`moav user base64 alice | pbcopy`).
- **Single-source protocol roster** (`data/protocols.json` + `scripts/gen-protocol-docs.py`) — the protocol list had drifted across 6+ surfaces (README, `docs/protocols.md`, `site/index.html` meta/JSON-LD, `site/llms.txt`), most visibly AnyTLS and Shadowsocks-2022 missing from some. There is now one canonical roster: the `docs/protocols.md` overview table is **generated** from it (marker-delimited, idempotent), and `site/index.html` + `README.md` + `site/llms.txt` are **drift-checked** against it — `gen-protocol-docs.py --check` fails if any protocol is missing from a surface (run in CI). Fixed the current drift: added the missing **AnyTLS** to the site's meta/OG/JSON-LD/keywords strings and named **wstunnel** in `llms.txt`.
- **CI pipeline** (`.github/workflows/ci.yml`) — runs on every PR to `dev`/`main`: `shellcheck --severity=error` across all 54 shell scripts, `bash -n` parse checks, `go vet` + `go test -race` for `dns-router`, `docker compose config` validation, the share-link golden test, and the protocol-roster drift gate. First automated regression gate for the repo (previously only release/site-deploy workflows existed). Fixed the one error-severity shellcheck finding it surfaced — an unquoted array expansion (`SC2068`) in `moav.sh`'s build path that could re-split service names.
- **Manual/per-release end-to-end test** (`.github/workflows/e2e.yml`) — stands up the full Compose stack on a **self-hosted runner** (a test VPS with a real test domain), provisions a user, and runs `moav test` (`client-test.sh`) against the live server across every enabled protocol, plus the CLI smoke test. Triggered manually (`workflow_dispatch`) and on published releases (nightly is available but disabled by default). Inputs: `verbose`, `full` (see below), and **`domainless`** — a domain-less run that skips Let's Encrypt entirely, so it validates the IP-only protocols and the client-image build without touching the LE rate limit (and needs no test domain). Standard domain runs reuse the `moav_certs` volume across runs (issue once, reuse — LE allows only 5 certs/week per domain); domainless/full runs start from a clean slate. Not on the per-PR path because it builds ~25 images and needs TLS certs. Setup + manual-run instructions in `docs/devdocs/E2E-TESTING.md`.

### Testing
- **`moav test` now covers Shadowsocks-2022 and XDNS** — the two protocols that are **on by default** but previously had no connectivity test. `test_ss` decodes the bundle's `ss://` SIP002 URI (base64url `method:server_psk:user_psk`) and drives a sing-box shadowsocks outbound over a local SOCKS port; `test_xdns` runs the bundle's own Xray client config (`xdns-direct-config.json`, falling back to the via-DNS config) and checks its SOCKS inbound, with a longer timeout and warn-on-failure since DNS tunnels are slow. Both appear in the human + JSON result summaries.
- **`moav test` now covers the remaining protocols** — `test_cdn` drives a real sing-box VLESS+WebSocket outbound through the Cloudflare-fronted endpoint (warn-on-fail, since it depends on the operator's Cloudflare proxied-record + Origin-Rule + SSL setup); `test_wstunnel` validates the WireGuard-over-wstunnel config and verifies the tunnel port actually speaks `wss://` TLS (the 1.9.0 hardening); `test_telemt` was upgraded from a bare `nc -z` to a **Fake-TLS handshake probe** (it decodes the fronted domain from the `tg://` secret and confirms telemt answers a TLS hello, not just an open socket). `test_masterdns` and `test_gooserelay` `skip` honestly with what to check manually — MasterDNS has no standalone client in the harness (MahsaNG v16), and GooseRelay needs a user-deployed Google Apps Script forwarder to reach its exit. Also fixed a latent gap: **`xhttp` was being tested but omitted from the result summaries** — it (and `cdn`/`wstunnel`/`masterdns`/`gooserelay`) now appear in both the human and JSON output. This completes the protocol-test matrix; the e2e runner validates it end-to-end.
- **`moav` CLI smoke test** (`tests/cli-smoke-test.sh`) — beyond the protocol tunnels, this exercises the *tool itself* against the live stack: `help`/`version`/`status`/`users`/`profiles`/`cert status`/`logs`/`check`/`doctor`/`net status`/`conduit-offsets status`, a `user add` → `revoke` lifecycle plus `user add --batch`, `admin password` (non-interactive), `restart`, an `export` → `import` round-trip, `update --help`, `donate status` (display only — never actually donates), `install.sh --help`, and a non-interactive TUI-menu launch — each with a hang-guard timeout, asserting read/report commands exit clean and diagnostics don't crash. Wired into the e2e workflow so a broken CLI command fails the run.
- **e2e FULL mode** — a `full` workflow input that, on top of the standard domain-mode run, also runs the **domainless-mode** lifecycle (reconfigure without a domain, bootstrap → start → provision → test the domainless protocols), `moav build --local` (monitoring images from source), and exercises the **image-removal** path of `moav uninstall`. The standard (default) run stays fast; FULL is opt-in for release/thorough validation.
- **`moav test` now validates the generated bundle `README.html`** — a `test_readme_bundle` check asserts the client guide is fully rendered: no template placeholder (`{{TOKEN}}`) survives substitution, and no protocol whose config file is present in the bundle (i.e. enabled) still shows its "…not enabled/available" sentinel. This catches template↔generator drift — a new `{{CONFIG_X}}` wired into one generation path but not the other (exactly the Shadowsocks/XHTTP gap fixed above) — that connectivity tests can't see. Appears in the human + JSON summaries under `readme` and fails the e2e run.

### Internal
- **Consolidated the test scripts into `tests/`** — `client-test.sh` (protocol harness), `cli-smoke-test.sh` (CLI smoke), and the share-link golden test (`tests/singbox-links-test.sh`) now live in one `tests/` directory with a README describing the three layers, instead of scattered across `scripts/` + `scripts/lib/`. Updated the references (`Dockerfile.client` COPY, `ci.yml`/`e2e.yml`, CONTRIBUTING, docs). Go unit tests stay next to their package (`dns-router/main_test.go`) per Go convention. No behavior change.
- **Deduplicated sing-box share-link construction into `lib/sing-box.sh`** — the Reality/Trojan/AnyTLS/Hysteria2/CDN/Shadowsocks-2022 link templates (plus their IPv6 variants, and the SS SIP002 `base64url(method:server_psk:user_psk)` userinfo encoding) were built identically in two places, `scripts/singbox-user-add.sh` (host add-user path) and `scripts/generate-user.sh` (bundle generator), and had to be kept in sync by hand. They're now single-source builder functions (`singbox_reality_link`, `singbox_trojan_link`, `singbox_anytls_link`, `singbox_hysteria2_link`, `singbox_cdn_link`, `singbox_ss_userinfo`, `singbox_ss_link`) that both scripts call. A pure-function golden test (`tests/singbox-links-test.sh`, 12 cases) locks the exact output, so the extraction is provably byte-identical — no change to any generated link. First step of the v2 provisioning-code consolidation (the server-config `jq` mutations and the `generate-single-user.sh` merge follow next).

### Documentation
- **`CONTRIBUTING.md`** — top-level contributor entry point: dev setup, the PRs-target-`dev` rule, comment/CHANGELOG/test-domain conventions, the local CI commands (shellcheck, go test, the share-link golden test, the roster drift gate), how the single-source protocol roster works, and how to add a protocol. Cross-links the devdocs checklists.
- **v2 docs & compatibility sweep** — reconciled the docs with the shipped 1.8.5 feature set: added a Certificates section to `docs/CLI.md` (`moav cert status/renew/install/uninstall`, `CERT_AUTORENEW`); added the missing **Shadowsocks-2022** section + overview-table row and an **`XDNS_METHOD`** (txt/aaaa) row to `docs/protocols.md`, and updated the wstunnel entry to describe `wss://` + the path secret; added **AnyTLS** to `docs/architecture.md` (plus a new Security & isolation / Service lifecycle section) and to the human-visible/structured surfaces of `site/index.html`, and fixed a stale "version 1.8.2" string there; documented the admin empty-password **fail-closed (503)** behavior in `docs/OPSEC.md`; refreshed `site/llms.txt`

### Changed
- **wstunnel now wraps WireGuard in real TLS (`wss://`) instead of plain `ws://`** — the Let's Encrypt cert was already mounted into the container but unused, so the WebSocket upgrade travelled in cleartext and was trivially DPI-fingerprintable (defeating the whole point of tunnelling WireGuard through "HTTPS"). The entrypoint now serves `wss://` using that cert when `DOMAIN` is set (runs as root to read the root-owned cert, copies it to a tmpfs, then drops to the unprivileged `moav` user via `setpriv` — same pattern sing-box uses), and falls back to plain `ws://` only in domainless mode. Additionally, a per-install **HTTP-upgrade path secret** (`state/keys/wstunnel-path.secret`, generated at bootstrap) is enforced server-side (`--restrict-http-upgrade-path-prefix`) and emitted in every client bundle (`--http-upgrade-path-prefix`), so a scanner probing `:8080` can't complete the upgrade without knowing the path. Generated client commands (bundle instructions + HTML guide, which previously showed an incorrect `wss://` command with the wrong forwarding target) now come from a single shared helper. `moav cert renew` restarts wstunnel alongside the other cert consumers. **Existing installs:** re-run `moav bootstrap` (or `moav update` then restart wstunnel) to generate the secret and pick up `wss://`; until then it degrades gracefully to the previous `ws://` behavior. Requires rebuilding the wstunnel image (`moav build wstunnel`)

### Added
- **XDNS record-mode selector `XDNS_METHOD` (`txt` default, `aaaa` opt-in)** — Xray's finalmask XDNS client can tunnel over AAAA records instead of TXT (upstream [#6123](https://github.com/XTLS/Xray-core/pull/6123)), which is meaningfully higher-throughput per query. Generated client bundles stay on `txt` for the widest client compatibility; set `XDNS_METHOD=aaaa` to emit `x.<domain>:aaaa+udp://…` resolvers. Requires an Xray client core ≥ v26.6.1 (Happ / Xray CLI); server side needs nothing
- **Opt-in telemt anti-DPI knobs** — `TELEMT_CLIENT_MSS` / `TELEMT_CLIENT_MSS_BULK` expose telemt's handshake-MSS clamping (telemt ≥ 3.4.15/3.4.19): fragmenting the MTPROTO handshake defeats MSS-based DPI fingerprinting (e.g. Iran's TSPU), while the `_BULK` value restores MSS for bulk data so throughput isn't tanked. Both default empty (off) — this is a targeted counter to MSS-fingerprinting networks, not a universal default, and upstream ships it off. `TELEMT_CONFIG_STRICT` (default false) makes telemt fail fast on an unknown/typo'd generated key instead of silently ignoring it. Stale upstream doc links in the generated config's comments were refreshed
- **`MASTERDNS_PUBLIC_SUBDOMAIN` — optional alternate MasterDNS subdomain for client bundles** (PR [#112](https://github.com/MotherofallVPNs/moav/pull/112), thanks @vibecodegits) — lets operators hand out a different delegation label than the server's base one (useful when the base label is burned or for staged rotation); the server accepts both, the zone-file generator emits both NS records, and `moav doctor dns` now checks both delegations when the public alias is set

### Fixed
- **`moav user add` could hang at "Adding to AmneziaWG…", and generated a broken AmneziaWG key when it didn't.** Two bugs: (1) `compose_timeout` ran `timeout N` **without `-k`**, so if `docker compose exec` wedged against a stuck container and ignored the SIGTERM, the deadline never fired and `user add` hung until Ctrl-C — now `timeout -k 5` force-kills it. (2) The amneziawg container's `awg genkey` emits **CRLF**, and `$()` strips only the trailing `\n`; the leftover `\r` made the key 45 chars, so `awg pubkey` rejected it (`Key is not the correct length or format`) and the peer was written with a **broken public key** (AmneziaWG then silently failed for that user). All container/host `wg`/`awg` key generation + Reality pubkey derivation (`user-add.sh`, `wg-user-add.sh`, `singbox-user-add.sh`, `generate-single-user.sh`) now strip `\r`. **Existing users** created before this fix have an invalid AmneziaWG key — regenerate them (`moav user revoke NAME` + `moav user add NAME`, or `moav regenerate-users`).
- **Bootstrap-generated bundles left raw `{{…}}` placeholders in the Shadowsocks + XHTTP sections of `README.html`** — the two paths that fill the bundle guide had drifted: `user-add.sh` (`moav user add`) substituted the `{{CONFIG_SHADOWSOCKS}}` / `{{CONFIG_XHTTP}}` / `{{QR_*}}` / `{{PORT_SS}}` placeholders, but `generate-user.sh` (the `moav bootstrap` / `INITIAL_USERS` path) never did — even though it generates the `shadowsocks.txt` / `xhttp-vless.txt` configs + QR codes. So the very first users created at install time got a guide showing literal `{{CONFIG_SHADOWSOCKS}}` for two **on-by-default** protocols. `generate-user.sh` now substitutes the same placeholders; a new bundle-integrity test guards against this class of regression (see Testing).
- **`moav export` failed for a non-root operator** — the state/conduit/cert data is staged into the backup by root containers (so it's root-owned), and the final host-side `tar` (run without `sudo`) then couldn't read `state/keys/*.key` or the conduit datastore (`Permission denied`), aborting the export. It now hands the staged copy back to the invoking user (via a root container) before archiving. A second, separately-triggered failure is also fixed: the post-archive contents listing (`tar -tzf … | head`) took a `SIGPIPE` once a backup had >30 entries — any real deployment — which under `set -o pipefail` failed the whole command; the broken pipe is now tolerated.
- **The `moav-client` image couldn't run `sing-box` at all** — the prebuilt sing-box release is glibc-dynamic (interpreter `/lib64/ld-linux-x86-64.so.2`), but the client image is Alpine/musl, so every sing-box-based protocol test failed `cannot execute: required file not found`. The image now installs real glibc alongside musl (each binary uses its own loader, so the Alpine-musl tools like amneziawg-tools keep working) and creates the loader symlink the binaries name. Affects `moav test` and `moav client connect`.
- **`moav test` reused a stale client image** — it only (re)built `moav-client` when the image was missing, so after a `moav update` bumped a pinned client version (sing-box/xray/wstunnel), `moav test` kept testing the *old* client. It now always builds (Docker's layer cache keeps it cheap when nothing changed).
- **`moav test --json` emitted truncated JSON** — `client-test.sh` runs under `set -euo pipefail` and counted results with `((count++))`, which returns exit 1 when a counter goes 0→1 (bash 4/5), killing the script before it finished printing the JSON. Any run with at least one result tripped it. Uses arithmetic that always succeeds now.
- **Bootstrap could silently blank the Reality `short_id`, breaking every Reality/XHTTP client after an `update` + `bootstrap`.** The sing-box/xray config templates interpolate `${REALITY_SHORT_ID}`, and docker-compose injects `REALITY_SHORT_ID=${REALITY_SHORT_ID:-}` from `.env` into the bootstrap container — but the short_id's source of truth is the **state** (`state/keys/reality.env`), not `.env`. So if `.env`'s `REALITY_SHORT_ID` is empty (it ships empty in `.env.example`, and an update can reset it), that empty value **shadowed the real one at render time**, producing `short_id: [""]`. The server then rejected every client (which sends the real `sid`) with `REALITY: processed invalid connection` (clients saw `received real certificate`) — even though keys, bundles, and services were all intact and unchanged. Both render blocks now **re-source `state/keys/reality.env` immediately before `envsubst`** so the authoritative state value always wins. (The private key was never affected — it isn't passed through `.env`.) **Recovery without updating:** put the real `REALITY_SHORT_ID` (from `state/keys/reality.env`) into `.env`, `rm configs/{sing-box,xray}/config.json`, `moav bootstrap --yes`, `moav restart sing-box xray` — existing user bundles keep working, nothing to re-issue.
- **`moav build` / `moav update` could fail on `Dockerfile.gooserelay` (and `Dockerfile.clash-exporter`) when `proxy.golang.org` TLS-handshake-timed-out** — those two Go builders were missing the `GOPROXY` pipe-fallback (`proxy.golang.org|goproxy.cn|direct`) that xray/dns-router/dnstt/snowflake already had, so a transient failure reaching Google's module CDN aborted the whole build with `net/http: TLS handshake timeout` instead of falling through to the mirror. Reported hitting this on a 1.7.x → 1.8.5 upgrade. The fallback is now baked into both Dockerfiles' `ARG GOPROXY` default (works even if compose doesn't pass it) and the gooserelay compose build block forwards the operator's `.env` `GOPROXY`/`GOSUMDB` overrides
- **DNS tunnel user-bundle drift + dns-router hardening** (PR [#112](https://github.com/MotherofallVPNs/moav/pull/112), thanks @vibecodegits) — dns-router now parses the full DNS question (type/class), answers authoritative NS/SOA at route apexes (some resolvers refuse to follow delegations without them), derives the default NS from the root `DOMAIN`, and derives the SOA serial from `VERSION`; table-driven Go tests added (golden-byte NS/SOA responses, malformed-packet handling). dnstt key provisioning now hard-fails instead of falling back to a world-readable key file. `moav.sh`'s port-53 conflict check no longer flags MoaV's own dns-router listener. Doctor's Reality TCP probe gained nc/curl/bash fallbacks (the `/dev/tcp` probe always failed under `sh`). All `docker compose` calls in `user-add.sh` are timeout-bounded so a wedged Docker daemon can't hang user creation. User revoke now finds users that exist only in Xray/TrustTunnel/telemt inbounds, not just sing-box
## [1.8.6] - 2026-07-13

### Upgrading
- After updating, run **`moav cert install`** if `moav doctor` reports *"Cert auto-renewal is NOT scheduled"* — the auto-renewal shipped in 1.8.5 but has to be installed once (it sets up the systemd timer / cron.d job). Without it a valid cert silently expires at ~90 days and the TLS protocols (Trojan/Hysteria2/AnyTLS/CDN) go down. `moav cert status` shows the current expiry.

### Fixed
- **Reality/XHTTP could break for every client after an `update` + `bootstrap` (silent short_id blanking).** The sing-box/xray config templates interpolate `${REALITY_SHORT_ID}`, and docker-compose passes `REALITY_SHORT_ID=${REALITY_SHORT_ID:-}` from `.env` into the bootstrap container — but the short_id's source of truth is the **state** (`state/keys/reality.env`), not `.env`. `.env.example` ships `REALITY_SHORT_ID=` empty, and an update can reset it, so that empty value **shadowed the real one at render time** and produced `short_id: [""]`. The server then rejected every client (which sends the real `sid`) with `REALITY: processed invalid connection` (clients saw `received real certificate`) — while keys, bundles, services, and certs were all intact and *unchanged*, making it baffling to diagnose. The private key was never affected (it isn't passed through `.env`). Both render blocks now **re-source `state/keys/reality.env` immediately before `envsubst`**, so the authoritative state value always wins. **If you're already hit** (without updating): put the real `REALITY_SHORT_ID` (from `state/keys/reality.env`) into `.env`, `rm configs/{sing-box,xray}/config.json`, `moav bootstrap --yes`, `moav restart sing-box xray` — existing user bundles keep working, nothing to re-issue.

## [1.8.5] - 2026-07-11

### Fixed
- **TLS certificates expired after 90 days because nothing ever renewed them** — two stacked bugs: (1) `scripts/cert-renew.sh` was never scheduled (its cron line was only a comment; no installer, `moav.sh`, or docs step created the job), and (2) the script itself couldn't have worked anyway — the compose `certbot` service overrides `entrypoint: /bin/sh` for one-shot issuance, so `docker compose run --rm certbot renew` executed `/bin/sh renew` instead of certbot (the manual command in TROUBLESHOOTING.md had the same flaw). Fixes: `cert-renew.sh` now forces `--entrypoint certbot`, skips cleanly in domainless mode, and restarts the cert-consuming services (sing-box, trusttunnel, admin, grafana, grafana-proxy — they copy certs at container start, so reload isn't enough) only when the cert actually changed. New `moav cert {status,renew,install,uninstall}` command manages a daily systemd timer (`moav-cert-renew.timer`, cron.d fallback for non-systemd hosts), and `moav start` auto-installs it once when `DOMAIN` is set (opt out: `CERT_AUTORENEW=false`). Existing domain deployments pick this up on the next `moav update` + `moav start` — or immediately via `moav cert install`; if the cert already expired, `moav cert renew` recovers it in place

### Security
- **Admin dashboard now refuses to authenticate any request if `ADMIN_PASSWORD` is empty, unset, or one of the known-insecure defaults** (issue [#126](https://github.com/MotherofallVPNs/moav/issues/126), thanks @raminrez) — not a regression in 1.8.4 (the auth code path has been unchanged since 2026-01-25), but the report surfaced a real defense-in-depth gap: `secrets.compare_digest("", "")` returns `True`, so if `ADMIN_PASSWORD` ever ended up empty (manually edited `.env`, container started before bootstrap completed, etc.) an attacker sending `Authorization: Basic Og==` (base64 of `:`) would bypass auth. `verify_auth` now fails closed with HTTP 503 and a remediation message naming the `.env` key when `ADMIN_PASSWORD` is `""`, `"admin"`, or `"change_me_to_something_secure"`. The most likely cause behind the original report was browser-cached HTTP Basic auth credentials from a previous install — but the empty-password edge case is genuinely exploitable and now closed regardless of whether the reporter's specific install had it

### Changed
- **Monitoring-stack opt-in default is now RAM-aware** — both confirm prompts (first-time + re-enable) default to `N` on hosts with `<2 GB` RAM, `Y` otherwise. Matches the doctor's existing "<2 GB + monitoring = hang risk" warning and the build-concurrency tier model. Operators on 2 GB+ hosts see no change; operators on small VPSes no longer get a default-yes monitoring stack competing for memory with the proxy containers
- **Hysteria2 inbound now sets `ignore_client_bandwidth: true`** (PR [#131](https://github.com/MotherofallVPNs/moav/pull/131)) — with `up_mbps`/`down_mbps` left unset the server uses BBR; this flag keeps clients on BBR too, preventing a client-advertised bandwidth from switching the link to Brutal congestion control and saturating a low-RAM VPS. Note: this is Hysteria2's own QUIC-layer BBR inside sing-box, unrelated to the kernel `tcp_bbr` module — no host dependency.
- **Component bumps: wstunnel 10.5.5 → 10.6.1, telemt 3.4.11 → 3.4.23, Xray-core v26.5.9 → v26.6.27** — each upstream diff reviewed against MoaV's exact configs/CLI/API usage before bumping; no config changes required. Headline reasons: **wstunnel 10.6.1** fixes a process-abort panic (erebe/wstunnel#523) triggerable by a single malformed probe against our public plain-`ws://` port 8080 — every crash dropped all active WireGuard-over-wstunnel sessions and only `restart: unless-stopped` was papering over it (10.6.0 still has the bug; 10.6.1 is the floor). **telemt 3.4.23** brings the 3.4.13–3.4.18 Fake-TLS realism fixes (ServerHello cipher/extension fidelity, ALPN no longer a plaintext marker, synthetic key shares) that directly harden our `tls_emulation = true` mode with zero config change; config keys, `healthcheck --mode liveness`, and all 8 exporter REST endpoints verified unchanged. **Xray v26.6.27** ignores spoofed `X-Forwarded-For` on XHTTP inbounds unless explicitly trusted (XTLS/Xray-core#6309 — closes an IP-spoofing vector for stats/routing), fixes a finalmask UDP buffer/ordering bug that affects XDNS reliability (#6331), and adds XDNS A/AAAA record modes (#6123, client-side opt-in — our generated links stay on TXT for client compatibility). Existing installs: `moav update` maps the `.env` version changes to the matching image rebuilds

### Added
- **AnyTLS protocol (opt-in)** (PR [#132](https://github.com/MotherofallVPNs/moav/pull/132), thanks @ibeezhan) — sing-box-native protocol that defeats TLS-in-TLS fingerprinting for higher stealth than Trojan. Mirrors the Trojan path end-to-end: reuses the existing sing-box container and the Trojan TLS certificate/domain (no new image), listens on TCP `8445` (`PORT_ANYTLS`), off by default (`ENABLE_ANYTLS=false`) because client support is narrower (Hiddify, sing-box SFA/SFI, NekoBox, mihomo, Shadowrocket 2.2.65+). Full provisioning wired: per-user `anytls.txt` + `anytls://` URI + QR + sing-box client JSON in bundles, revoke, client-connect/client-test coverage, EN/FA docs
- **`net.ipv4.tcp_max_syn_backlog = 8192` in the network-tuning bundle** — Linux default is 1024 (128 on small hosts), which drops SYNs under coordinated reconnect bursts (post-censorship-blip waves) or Reality probe floods. Adding it to `/etc/sysctl.d/99-moav-net.conf` and to the installer's first-time bundle. Picked up on next `moav net apply`
- **`moav net apply` prints a verification summary after applying** — calls `nt_status` at the end so the operator sees `✓ bbr active ✓ fq active ✓ rmem_max=32 MiB ...` immediately instead of having to run a second command to confirm the sysctl reload worked
- **`moav doctor net` extended with packet-drop / PMTU / CGNAT / MTU checks** — reads `/proc/net/snmp` + `/proc/net/netstat` for TCP `ListenDrops` + `ListenOverflows` (SYN queue overflow → recommends raising `somaxconn`/`tcp_max_syn_backlog`) and UDP `RcvbufErrors` + `SndbufErrors` (Hysteria2/WireGuard buffer overflow → recommends raising `{r,w}mem_max`). Verifies `tcp_mtu_probing` is on (silent PMTU black-hole recovery). Detects CGNAT (100.64/10 on the default route — hard failure for inbound proxy traffic) and RFC1918 (NAT — warns with the `SERVER_IP` from `.env` for forwarding context). Prints egress + WireGuard MTU with the WG-1420 / Hysteria-1450-1472 recommendations. When the sysctl bundle isn't applied (or kernel doesn't support BBR), the extended checks skip silently rather than fail-flagging a fresh install

## [1.8.4] - 2026-06-05

### Added
- **BBR + kernel network tuning behind an install-time prompt** (task #38) — real-world Portugal→Vilnius test on a Time4VPS box showed BBR ~3× single-flow TCP throughput vs the Linux default (CUBIC 5.45 → BBR 14.8 Mbps), and dramatically faster recovery from packet loss (CUBIC stuck at 2 Mbps for seconds, BBR jumped to 43 Mbps in the next second). UDP buffer bumps also help Hysteria2 and WireGuard at high throughput (quic-go needs ≥7.5 MiB). New `site/install.sh` `maybe_offer_net_tuning()` step asks once during first install, applies on yes (default), skips silently on kernels <4.9 / OpenVZ guests / already-applied installs. Writes to a single dedicated file `/etc/sysctl.d/99-moav-net.conf` so revert is clean (`moav net revert` removes that file and reloads sysctl). Buffer max is auto-capped at 16 MiB on hosts with <2 GB RAM, 32 MiB otherwise. Deliberately excludes `tcp_fastopen` (hostile in censored networks — China Mobile firewalls and ~5% of paths drop SYN+data, so TFO server-side *adds* latency for the exact users this project targets). New `moav net {status,apply,revert}` subcommand and `moav doctor net` check for ongoing visibility. Full per-knob rationale + sources in `docs/OPSEC.md` → "Network tuning"

### Fixed
- **VLESS Reality on `:443` returned RST/0-bytes for every TLS hello when `REALITY_TARGET` host wasn't a real public hostname** (issue [#115](https://github.com/MotherofallVPNs/moav/issues/115), thanks @ibeezhan) — Reality is supposed to fall through to the configured `handshake.server` for any non-Reality TLS hello, so an outside observer sees a real ServerHello from a legit CDN. When the configured host was NXDOMAIN (the bug report had `update.samsung.com:443` set; Samsung doesn't publish that name publicly), sing-box couldn't dial the fallback and dropped the connection — clients saw RST, passive scanners saw a visibly dead `:443`. Same trap exists for `XHTTP_REALITY_TARGET` on Xray's `:2096`. Wiring is now: (1) `run_bootstrap` validates both targets resolve via `getent hosts` before invoking the bootstrap container and prompts for a replacement on NXDOMAIN (up to 3 attempts) with a vetted list; (2) new `moav doctor reality` check `exec`s into the relevant container and `getent hosts` + TCP-probes each configured target, so the next operator hits this at `moav doctor` instead of after issuing broken bundles; (3) `docs/OPSEC.md` gained a "Reality fallback target" section listing vetted globals (`www.cloudflare.com`, `www.apple.com`, `cdn.kernel.org`) and Iran-friendly SNI cover (`www.aparat.com`, `digikala.com`, `taghche.com`).
- **`tcp_fast_open: true` removed from sing-box Reality and Trojan inbounds** — TFO is actively hostile in heavily-censored networks. China Mobile firewalls and ~5% of paths drop SYN+data, so enabling TFO server-side *adds* latency for the exact users this project targets. Unrelated to #115's RST symptom (TCP accept succeeded in the report) but the audit surfaced it as the same "client-facing inbound has middlebox-hostile feature on by default" category and we're explicitly excluding TFO from the BBR/sysctl bundle for the same reason. Existing installs pick up the change on the next bootstrap config regeneration
- **Admin dashboard misreported container status for several services** (issue [#117](https://github.com/MotherofallVPNs/moav/issues/117), thanks @sacredx72) — `admin/main.py:check_service_status` was deciding state by DNS-resolving the container hostname on `moav_net`, but xray was missing from the lookup dict and fell through to a default `"unknown"`; snowflake (host networking, no `moav_net` DNS record) was hardcoded to `"unknown"` regardless of state. The earlier v1.8.4 attempt added a Docker `healthcheck:` block to `docker-compose.yml` for xray (corrected from `xray test -c` to `xray run -test -c` by @ibeezhan in PR #120) — that still helps `docker ps` show a proper Health.Status, but the admin UI never consumed Docker's healthcheck data so the dashboard kept rendering xray as unknown. **Actual fix:** the entire status-detection path was refactored to use a single `/containers/json` call against the docker-socket-proxy (admin already had `DOCKER_HOST=tcp://docker-proxy:2375` env set and `CONTAINERS=1` capability but neither was consumed). One round-trip per dashboard refresh now lists every running container; xray, snowflake, and host-networked services all detect uniformly with no per-service special cases. Same refactor added three previously-missing cards: **masterdns** (4th DNS tunnel, default-on since 1.8.0), **dns-router** (without which all four DNS tunnels silently break since they all route through it on `:53`), and **gooserelay** (opt-in SOCKS5-over-Apps-Script exit). Existing installs pick this up on the next `moav update` + `moav restart admin`
- **telemt logged `Failed to flush beobachten snapshot error=Read-only file system path=beobachten.txt` every ~15 s since v1.8.2** (issue [#117](https://github.com/MotherofallVPNs/moav/issues/117)) — telemt v3.4.x writes a runtime observability snapshot (`beobachten.txt`) relative to its working directory. The container has `read_only: true` with targeted `tmpfs` mounts at `/app/tlsfront`, `/app/cache`, and `/tmp`, but the entrypoint was `cd /app` — and `/app` itself is the read-only image root, so every flush failed. Non-fatal (telemt kept proxying traffic) but log-noisy. Fix: entrypoint now `cd /app/cache` (existing tmpfs) so `beobachten.txt` lands in a writable filesystem. The `tls_front_dir` config key flipped from cwd-relative `"tlsfront"` to absolute `/app/tlsfront` so the cwd change doesn't break TLS fronting. Existing installs pick this up on the next `moav update` + `moav build telemt --no-cache` + `moav restart telemt` (entrypoint is baked into the image)
- **BBR detection missed module-based kernels (skipped network tuning entirely on Ubuntu 24.04)** (PR [#120](https://github.com/MotherofallVPNs/moav/pull/120), thanks @ibeezhan) — most distro kernels ship `tcp_bbr` as a loadable module, absent from `/proc/sys/net/ipv4/tcp_available_congestion_control` until something loads it. The original detection read that list on a fresh boot and concluded "BBR not available," silently skipping the entire network-tuning offer on kernels that fully support it (6.8 / Ubuntu 24.04). Now `modprobe tcp_bbr` runs before the availability check, and the module is persisted across reboots via `/etc/modules-load.d/moav-bbr.conf` (removed on `moav net revert`).
- **`install.sh` failed under `setsid` / non-interactive bootstrap with `bash: /dev/tty: No such device or address`** (PR [#120](https://github.com/MotherofallVPNs/moav/pull/120), thanks @ibeezhan) — the interactive-vs-not guard used `[[ -e /dev/tty ]]`, which is true under setsid (the device node exists) even though opening it returns ENXIO. Detection now actually opens the device, and the `read` redirect is grouped so the open-error is captured instead of leaking to stderr.
- **`moav` aborted at `clear` when `TERM` was unset** (PR [#120](https://github.com/MotherofallVPNs/moav/pull/120), thanks @ibeezhan) — every `cmd_*` called `print_header` → `clear`, and ncurses `clear` exits non-zero and prints `TERM environment variable not set.` when `TERM` is empty. Under `set -e` that tore the script down. `clear` now only runs when stdout is a TTY.
- **`moav` aborted in `ensure_admin_password` on closed stdin** (PR [#120](https://github.com/MotherofallVPNs/moav/pull/120), thanks @ibeezhan) — `read -r input_password` returns non-zero on EOF (e.g. `</dev/null`), and `set -e` aborted before the auto-generate fallback ran. The empty case is meant to be valid; `read` now tolerates EOF and lets the fallback fire.
- **`moav install` exited 1 sourcing `completions/moav.bash` under nounset** (PR [#120](https://github.com/MotherofallVPNs/moav/pull/120), thanks @ibeezhan) — the completion's first line tested `[[ -n "$ZSH_VERSION" ]]`; under bash with `set -u`, `$ZSH_VERSION` is unset and the test aborted the parent shell before the `source ... || true` rescue could catch it. Changed to `${ZSH_VERSION:-}`.

## [1.8.3] - 2026-06-02

### Added
- **Architecture overview page** ([`docs/architecture.md`](docs/architecture.md)) — container topology grouped by Compose profile, dns-router fan-out, bundle generation flow (bootstrap container → state volume → host bundle writer), and the monitoring stack. Registered in the MkDocs nav under About.
- **`site/llms.txt`** at the site root (served at `https://moav.sh/llms.txt`) — [llmstxt.org-spec](https://llmstxt.org/) discovery file with project summary plus categorized links so AI assistants can navigate the docs. Deploys via the existing GitHub Pages workflow.
- **TUI main menu** expanded with four high-value commands previously only reachable via CLI: **Donate configs** (`moav donate`), **Doctor** (`moav doctor`), **Admin password reset** (`moav admin password`), and **Update MoaV** (`moav update`). Existing items 7 and 8 (build/rebuild, export/import) shift to 11 and 12; slots 1–6 unchanged for muscle memory. Menu grouped into "Services / Users & donations / System" with dim headers.
- **New `moav users` sections** for AmneziaWG, Xray (XHTTP + XDNS), TrustTunnel, and Telegram MTProxy — previously the listing only showed sing-box, WireGuard, and bundles, so operators couldn't see who had access to four of the eight per-user services. Each new section reads from the appropriate config file (jq for xray, awk for telemt's TOML, etc.) and shows totals.

### Changed
- **Default CDN transport flipped to WebSocket** — `.env.example`'s `CDN_TRANSPORT` changed from `httpupgrade` to `ws`, and the three matching shell fallback defaults (`scripts/bootstrap.sh`, `scripts/singbox-user-add.sh`, `scripts/generate-user.sh`) now also fall back to `ws` so older installs that lack the `.env` line still pick up the new default. WebSocket is universally supported across V2Ray-family clients, battle-tested in heavy-censorship contexts (Iran/China), and first-class on Cloudflare. Newer Xray clients (≥ v26.x) emit a deprecation warning for `httpupgrade`. Overhead difference (~50 bytes/frame) is negligible. **Existing installs keep their current setting** — only fresh installs / re-bootstraps pick up the new default. Operators specifically needing httpupgrade (CloudFront edge cases) can flip it back.
- **Bootstrap domain prompt re-asks on invalid input** — previously, an unparseable hostname (like `foo bar`) was saved with just a warning. The prompt now loops up to 3 attempts, explaining what a valid hostname needs (a dot, only letters/digits/dots/hyphens). After 3 invalid tries it saves the last value with a warning so the operator can fix `.env` manually. Empty input still means domainless mode.
- **Interactive bootstrap surfaces Cloudflare's required SSL/TLS Flexible setting** — the DNS records prompt previously listed only the Origin Rule as a CDN requirement; operators commonly missed that Cloudflare must also be in **Flexible** SSL/TLS mode (port 2082 is plain HTTP) and got a confusing `525` error after. The prompt now lists both settings up-front, with the 521/525 error decoder inline. `docs/DNS.md`'s Cloudflare CDN section is restructured the same way (Flexible up-front, response-code table for verification).
- **TUI add-user preview lists every service** — the "This will add 'X' to:" screen was stuck on the 1.7-era list (sing-box + WireGuard). Replaced with a grouped 5-line list reflecting what `user-add.sh` actually provisions: proxies (Reality / Trojan / Hysteria2 / SS-2022 / XHTTP / CDN VLESS+WS), VPN (WireGuard direct + wstunnel / AmneziaWG / TrustTunnel), DNS tunnels (dnstt / Slipstream / MasterDNS / XDNS), Telegram MTProxy, and GooseRelay if enabled. Also shows the bundle output path.
- **TUI Admin item goes straight to password reset** — was calling `cmd_admin` (which only prints usage from the menu context); now calls `cmd_admin password` directly, since that's the only useful interactive subcommand. Menu label updated to "Admin password reset." The admin URL is already shown in the main-menu status header.
- **Bootstrap container build message** says "may take a few minutes" instead of "may take a minute" — the first-time build is typically 2–5 minutes on a small VPS.
- **Documentation pass for v1.8.2 drift**: 
  - `docs/CLI.md` profiles table rewritten (was 11 rows missing the `dnstunnel` composite, `telegram`, `xhttp`, `gooserelay`, `amneziawg`, `monitoring`, and `setup` profiles); new "Disabled profiles" subsection under `moav start`; new `moav conduit-offsets` section (was 100% undocumented since 1.7.9).
  - `docs/DNS.md` consolidates the four separate NS-delegation Steps + two redundant "all 4 tunnels coexist on port 53" notes into a single table-based section, and the Cloudflare records table gains the missing `m` and `x` NS rows.
  - `docs/SETUP.md` drops the duplicated profile bullet list (cross-links to CLI.md); the 1.8.2 implementation-detail callout (cleaning behavior, readline, Ctrl-C recovery) replaced with a short user-facing note that the prompt accepts any input format and re-running picks up where you left off.
  - `docs/MONITORING.md` new "Conduit lifetime bandwidth" section documenting the offset watcher, recording rules, and auto-install behavior (1.7.9+ feature that was missing from docs).
  - `docs/philosophy.md` rewritten to integrate the article-derived narrative ("This Is Ours to Build", "What Infrastructure Actually Means", "The Internet Is Closing", "A Global Pattern", "The Arms Race Gets Creative", "You Are Donating Bandwidth", "The Window Is Open") with the existing institutional sections (Human Rights, Why Multi-Protocol Matters, Iran's Shutdown History), plus a cite-ready sources appendix.
  - `docs/client-guide-template.html` (bundle viewer): Telegram MTProxy section 9 now has a clickable "Open in Telegram" button on top of the copy-pastable link; Tor (10) + Psiphon (11) sections converted to collapsible `<details>` to match the V2Ray-compatible cards; WireGuard-over-WebSocket subsection inside WireGuard (6) also collapsible. EN + FA mirrors.

### Fixed
- **Dashboard user-add silently broke after CLI user-revoke** — when an operator ran `sudo moav user revoke X`, `wg-user-revoke.sh` and `awg-user-revoke.sh` did `mktemp + awk > tmp; mv -f tmp orig`. `mv -f` swaps inodes, so the rewritten config ended up `-rw------- root:root`. The admin container (running as `moav:moav`) then couldn't write the same config on the next dashboard user-add → permission denied. Same pattern existed in the sing-box, Xray, and TrustTunnel rewrite paths. Replaced every `mv -f tmp orig` with `cat tmp > orig; rm -f tmp` so the original file's inode (and thus mode + owner) survives. `user-add.sh` and `user-revoke.sh` also run a `chmod a+rw` sweep over the six config files at the top of every invocation, so legacy installs whose perms were already broken self-heal on the next CLI op (no admin container restart required).
- **`moav user revoke` reported "User not found in sing-box (skipping)" for users that did exist** — the outer check used `grep -q "\"name\":\"$USERNAME\"" configs/sing-box/config.json`, which requires `"name":"X"` with no whitespace between `:` and `"`. But `jq -S` (which renders the config) always emits `"name": "X"` with a space. Grep returned false-negative every time, the revoke skipped the sing-box cleanup (and its chain of TrustTunnel + telemt + xray), bundles got deleted but users stayed in the configs. Three checks (`user-revoke.sh`, `singbox-user-revoke.sh`, `singbox-user-add.sh`) replaced with the same jq query `user-list.sh` uses — whitespace-insensitive, source-of-truth consistent.
- **Xray (XHTTP + XDNS) revoke was completely missing.** `singbox-user-revoke.sh` cleaned sing-box, TrustTunnel, and telemt but never touched `configs/xray/config.json`. Revoked users' XHTTP `vless://...?type=xhttp` and XDNS configs kept working. New jq-deletion block in `singbox-user-revoke.sh` removes the user from both `.settings.clients[]` and `.settings.users[]` (the v26.5.9 schema rename made these aliases — bootstrap writes the new `users` field, legacy add wrote `clients`, so we now check + delete in both). Restarts xray to apply.
- **Xray users/clients alias split-brain.** Related to the previous: `moav users` showed "(no users)" for Xray on a working install, because bootstrap-added users live in `.settings.users` (template path) and the listing only checked `.settings.clients`. Fixed in `user-list.sh` (reads both); fixed in `singbox-user-add.sh` (exists-check now scans both; new users now written to the canonical `.settings.users` to match the template).
- **`user-add.sh` GOPROXY auto-heal failed on read-only `.env`** — when the admin container called `user-add.sh`, `sed -i.bak .env` errored with "Read-only file system" because `/project` is mounted read-only inside the admin service. Now heals into a tempfile, sources the tempfile (so env vars load correctly), and only `cat`'s the heal back to `.env` when it's writable (the CLI path). The admin-container path no longer trips on the leading sed failure.
- **Main-menu status line leaked `.env` inline comments** — the admin URL rendered as `https://t7d.my:9443      # Admin dashboard` because `get_admin_url`'s parser (`grep | cut -d= -f2 | tr -d '"'`) stripped quotes but not trailing `# comments`. Routed all four URL helpers (`get_admin_url`, `get_grafana_url`, `get_grafana_cdn_url`, `get_cdn_url`) through the existing `get_env_val` helper which strips both comments and whitespace.

## [1.8.2] - 2026-05-29

### Fixed
- **`moav bootstrap` exited silently right after `✓ .env file exists` on the second run** — moav.sh runs under `set -euo pipefail` and `ensure_admin_password` returned `1` when the password was already set (intended as "no change needed"), which `errexit` turned into a silent abort. The two pre-existing call sites only ran right after `.env` was copied from `.env.example` (so the password was always the insecure default and the function took the prompt+return-0 path), masking the bug. The new `existing-.env` validation hit the "already set" branch. Changed to `return 0` — "already set" is the happy path; no caller inspected the return code
- **Interactive bootstrap accepted `https://t7d.my/` as DOMAIN and wrote it verbatim to `.env`** — broke Let's Encrypt, DNS routing, Reality, and CDN. New `sanitize_domain` helper strips scheme / user@ / path / port / whitespace and lowercases; `is_valid_domain` validates the cleaned result (has a dot, valid chars, no consecutive dots, no leading/trailing punctuation). On a mismatch the bootstrap prints `Cleaned input: 'X' → 'Y'` so the operator sees what landed in `.env`. The same auto-clean runs against any existing malformed `DOMAIN=` on subsequent bootstraps. Domain + email prompts also switched from `read -r` to `read -r -e` so readline editing (arrow keys, ctrl-A/E, backspace) works — previously arrow keys printed raw `ESC[D` sequences
- **Aborted bootstrap left `.env` half-configured; next run skipped the whole prompt block** — pressing Ctrl-C after typing the domain (but before the email prompt) left `DOMAIN` set but `ACME_EMAIL` and `ADMIN_PASSWORD` at their defaults. The next `moav bootstrap` saw `.env file exists` and silently proceeded with missing email and the insecure default password. The existing-.env branch now re-prompts for `ACME_EMAIL` when `DOMAIN` is set but email isn't, and always runs `ensure_admin_password` (idempotent)
- **`update_env_var` left a duplicate `ENABLE_MONITORING=true` at the end of `.env`** — the helper recognized `# X=` (space after `#`) for the uncomment path but not `#X=` (no space). `.env.example:73` ships `#ENABLE_MONITORING=` (no space), so the placeholder was treated as not-present and a new line appended. Regex relaxed to `^#[[:space:]]*X=`. Routed 4 other ad-hoc `grep+sed-or-append` patterns through `update_env_var` (interactive monitoring confirm, monitoring re-enable in `ensure_clash_api_secret`, both domainless disable loops, the `confirm_disabled_profile` flip) — removed an inline `OSTYPE` darwin/linux sed branch as a side effect
- **`moav start <name>` prompt was unclear for `monitoring` and other profiles** — option 1 read `(n/a — covers multiple ENABLE_* flags)` for `monitoring`, even though monitoring is single-flag (`ENABLE_MONITORING`). Added monitoring to the case map. For genuine multi-flag profiles (`proxy`, `dnstunnel`) option 1 now names the underlying flags (e.g. `'proxy' covers ENABLE_REALITY, ENABLE_TROJAN, ENABLE_HYSTERIA2, ENABLE_SS — set one to true in .env, then re-run`). Picking option 1 on a multi-flag profile now prints remediation and skips instead of silently falling through to start-once. All three option labels reworded with action-first wording
- **Disabled services could still start via `DEFAULT_PROFILES` / `--profile all`** (issue [#106](https://github.com/MotherofallVPNs/moav/issues/106), thanks @vibecodegits / Codex) — six code paths hard-coded a profile list that always appended `conduit` and `snowflake`, so `ENABLE_SNOWFLAKE=false` / `ENABLE_CONDUIT=false` were silently overridden and the Snowflake relay actively relayed traffic. New `profile_enabled` / `derive_enabled_profiles` / `filter_disabled_profiles` helpers map each Compose profile to its `ENABLE_*` flag(s); every hard-coded literal now calls the helper. `moav start` filters whatever `DEFAULT_PROFILES` says (stale literals self-heal with a one-line "Skipping disabled profiles: …" note). `moav start all` expands `all` to the derived enabled set instead of `docker compose --profile all up`. Explicit `moav start <name>` with `ENABLE_*=false` now prompts: (1) enable in .env and start, (2) skip, (3) start once without persisting; non-interactive defaults to skip, `--force` bypasses. `snowflake-exporter` moved from `[monitoring, all]` to `[snowflake, all]`. Action: stale `DEFAULT_PROFILES` entries are dropped on next start automatically
- **Domainless bootstrap errored with "DOMAIN is required" right after the operator opted into domainless mode** — both domainless disable loops in moav.sh were only flipping 5 vars; `ENABLE_MASTERDNS` was added in 1.8.0 (default-on) but never propagated, and `scripts/bootstrap.sh` hard-errors when it's on without a domain. Both loops now include `ENABLE_MASTERDNS`; the bootstrap's error message lists all 6 cert-requiring vars (was missing `ENABLE_SLIPSTREAM` + `ENABLE_MASTERDNS`); the domainless "Running in (…)" notice is now derived from `ENABLE_*` so the listed protocols stay accurate. The interactive prompt and standalone `moav domainless` screen also gained the two domainless protocols they'd been omitting: XHTTP and Shadowsocks-2022
- **Domainless mode left `ENABLE_XDNS=true`, triggering a port-53 / systemd-resolved conflict prompt for a router with nothing to route** — XDNS itself doesn't need TLS, but the `dnstunnel` Compose profile pulls in `dns-router`, which is useless without a domain to delegate subdomains against. Domainless disable loop now also flips `ENABLE_XDNS=false`; direct-mode XDNS (port 5356, no subdomain delegation) can be re-enabled manually. The "DNS tunnels" lines in the prompt + `moav domainless` screen now list XDNS alongside dnstt/Slipstream/MasterDNS

## [1.8.1] - 2026-05-28

### Upgrade Notes
- **Shadowsocks-2022 is now on by default.** Existing installs that explicitly set `ENABLE_SS=false` (or any explicit value) in `.env` are unaffected — the explicit value wins. Existing installs with `ENABLE_SS=true` already enabled also see no change. **Fresh installs** (and existing installs that *removed* the `ENABLE_SS` line entirely) now get Shadowsocks generated by default, matching the rest of the on-by-default proxies (Reality, Trojan, Hysteria2, WireGuard, AmneziaWG, TrustTunnel, XHTTP, dnstt, Slipstream, MasterDNS, Telegram MTProxy).
- **No re-bootstrap required.** The Dockerfile-base and per-user-add fixes below take effect on `moav update` → `moav build bootstrap` → next `moav bootstrap` / `moav user add` run. No config regeneration needed for existing users.

### Changed
- **Shadowsocks-2022 enabled by default** — `ENABLE_SS=true` in `.env.example`, matching the other on-by-default proxy protocols. Script fallbacks (`${ENABLE_SS:-false}` → `${ENABLE_SS:-true}` in `bootstrap.sh`, `singbox-user-add.sh`, `generate-user.sh`, `generate-single-user.sh`) align so removing the `.env` line gives the same on-by-default behavior. The deliberate `export ENABLE_SS=false` inside the donate-only branch of `generate-single-user.sh` is unchanged — that's an explicit filter (SS only included in a donation when the operator picked it), not a default. Docs (`README.md`, `README-fa.md`, `docs/SETUP.md`) drop the now-misleading "(when `ENABLE_SS=true`)" qualifier from the port tables, ufw command, and bundle-file listing so the SS row reads plainly like every other default-on protocol

### Fixed
- **`moav bootstrap` failed with `/usr/local/bin/sing-box: cannot execute: required file not found`** — `Dockerfile.bootstrap` was based on `alpine:3.21` (musl), but the prebuilt sing-box 1.13.x binary from upstream releases is glibc-linked — its `PT_INTERP` is `/lib64/ld-linux-x86-64.so.2`, which doesn't exist on Alpine, so `exec` failed with the cryptic "required file not found" (the *interpreter* is missing, not the binary). Switched the bootstrap image base to `debian:bookworm-slim` (matching `Dockerfile.sing-box`) and translated the apk packages to apt-get equivalents (`libqrencode-tools` → `qrencode`, `gettext` → `gettext-base`, adds `ca-certificates`, `tar`). Run `moav build bootstrap --no-cache` after updating to rebuild the image
- **DNS records prompt during `moav bootstrap` was missing the MasterDNS NS row (`m`)** — the on-screen table that tells the operator which DNS records to add at their registrar listed `t.` / `s.` / `x.` (dnstt / Slipstream / XDNS) but not `m.` (MasterDNS), so a fresh install with all four DNS tunnels enabled by default wouldn't know to delegate MasterDNS to the server. Added the missing NS row and updated the section header to mention MasterDNS. The generated BIND zone file (`outputs/dns-records.txt`) and `docs/DNS.md` were already correct — only the interactive prompt was missing the line
- **`moav user add` silently produced an incomplete bundle when `ENABLE_SS=true` was set in `.env` *after* the initial bootstrap** — enabling Shadowsocks in `.env` without re-bootstrapping leaves the server with no `shadowsocks-server.psk` and no `shadowsocks-in` inbound, but `singbox-user-add.sh` was silently skipping SS generation in that state (via two paths — the `jq -e` inbound check and the bundle-gen warn), so a freshly added user's bundle was missing `shadowsocks.txt` / `shadowsocks-qr.png` with no error. Added a loud precondition check that verifies both the server PSK (`/state/keys/shadowsocks-server.psk` in the moav_state volume) and the `shadowsocks-in` inbound exist before generating the per-user PSK; when either is missing it errors with the exact remediation (re-bootstrap with `ENABLE_SS=true`, then re-run the add). Existing users with Shadowsocks already provisioned are unaffected
- **`moav user revoke` reported failure after a successful files-only cleanup** — the success-or-error decision only flipped a `REVOKED` flag when the user was found inside a sing-box / WireGuard / AmneziaWG service entry; pure file cleanup (removing `users/<name>/`) didn't update it, so revoking a user whose service entries had already been cleared (or who only ever existed as files) printed file cleanup successes and *then* errored "User not found — nothing to revoke." Added a `CLEANED_FILES` tracker alongside `REVOKED`; the post-loop summary now distinguishes the three real states — found in services (`"User X has been revoked"`), files-only cleanup (`"User X files cleaned up (no active service entries)"`), or nothing anywhere (the genuine "not found" error). The per-service `[INFO]` skips ("not found in WireGuard / AmneziaWG / …") stay — those are valid for users who were added when those services were disabled

## [1.8.0] - 2026-05-28

### Upgrade Notes
- **Re-bootstrap required; existing installs change behavior.** This release (PR [#102](https://github.com/MotherofallVPNs/moav/pull/102)) adds two services and flips DNS-tunnel defaults, so upgrading an existing install is a breaking change in practice:
  - **MasterDNS and XDNS are now enabled by default** (`ENABLE_MASTERDNS=true`, `ENABLE_XDNS=true`). On `moav update`, an install that didn't have these set will pick up the new defaults via `check_env_additions` and start the new containers. To keep them off, set `ENABLE_MASTERDNS=false` / `ENABLE_XDNS=false` in `.env` before updating.
  - **The new services need keys/configs generated by bootstrap** — MasterDNS and GooseRelay won't function until you re-bootstrap (generates `state/keys/masterdns-encrypt.key` / `gooserelay-tunnel.key` and their configs), rebuild the new images, and recreate containers. Bootstrap is idempotent and preserves existing keys/users.
  - **XDNS direct-mode port moved 53 → 5356.** xray's XDNS inbound is now a dns-router backend (`xray:5355`); the host port for *direct* XDNS access is `PORT_XDNS` (default `5356`). Existing XDNS users on direct-mode bundles must regenerate (`moav regenerate-users`) to pick up the new port; resolver-mode (NS-delegated `x.<domain>`) is unaffected.
  - Apply order: `moav update` → `moav build masterdns gooserelay --no-cache` (serial on low-RAM VPS) → `moav bootstrap` → `moav regenerate-users` → `moav start`.

### Changed
- **sing-box 1.12.23 → 1.13.12** — bumped the multi-protocol core (the Reality / Trojan / Hysteria2 / Shadowsocks / CDN inbounds) to the latest 1.13.x release, and aligned the version across `.env.example`, all Compose build args, and the sing-box / client / bootstrap Dockerfiles (the fallback defaults had drifted to a mix of `1.12.23` / `1.13.2` / `1.12.17`). MoaV regenerates the sing-box config on bootstrap, so `moav bootstrap` after updating; this is a 1.12 → 1.13 minor jump, so verify the stack comes up healthy before relying on it.
- **Snowflake uses the official prebuilt image by default** — `Dockerfile.snowflake` now pulls the `proxy` binary from `thetorproject/snowflake-proxy:v<version>` (matching `SNOWFLAKE_VERSION`) instead of compiling from source, removing one of the heaviest builds (a frequent OOM casualty on small VPSes). The from-source compile is kept as an automatic-fallback stage selectable with `SNOWFLAKE_BINARY=source` (e.g. if Docker Hub is unreachable for the prebuilt image). Our runtime still layers `iproute2` (for `tc` bandwidth limiting) and our entrypoint on top. (`trusttunnel`/`psiphon-conduit` already use prebuilt release binaries; `amneziawg` has no upstream prebuilt and still compiles.)
- **All 4 DNS tunnels enabled by default** — dnstt, Slipstream, MasterDNS, and XDNS all run in parallel on port 53 via `dns-router`, which fans queries out by subdomain suffix (`t.` → dnstt, `s.` → Slipstream, `m.` → MasterDNS, `x.` → XDNS). No `moav switch-dns` is needed; the v1.7.5 port-group mutual exclusion model is retired. XDNS requires a FinalMask-aware client (Happ, Xray CLI) — the container runs regardless; set `ENABLE_XDNS=false` to opt out.
- **XDNS no longer binds host port 53 directly** — xray's XDNS inbound is now an internal dns-router backend (`xray:5355`). The host port for xray shifts to `PORT_XDNS` (default `5356`, was `53`). `PORT_DNS=53` is the single public-facing DNS port, owned by dns-router.
- **`moav switch-dns` reframed** — all four tunnels are in the same group; any combination is valid. Command now described as "enable/disable tunnel daemons" rather than "pick which group owns port 53." Dead port-group conflict check removed. `moav switch-dns dnstt+slipstream+masterdns+xdns` activates all four simultaneously.
- **`moav doctor conflicts`** updated — multi-group conflict checks removed (all tunnels same group); now reports enabled tunnels and checks port 53 availability cleanly.
- **`moav start`** — removed hard-block port-group conflict guard; port 53 check now covers all four tunnels.
- **`moav doctor env`** — removed stale XDNS-vs-dnstt conflict warning; port 53 check unified to cover any enabled tunnel.
- **`docs/TROUBLESHOOTING.md`** — "Port 53 conflict" section rewritten to reflect all-four coexistence; `.env` snippet updated.
- **`docs/DNS.md`** — "Which DNS tunnel" table updated with Default column; all remaining switch-dns/mutual-exclusion notes removed.

### Added
- **One-tap "Import everything" V2Ray subscription in every bundle** — each user bundle now ships a standard **V2Ray subscription** (base64 of the compatible share-links — Reality, CDN, XHTTP, Trojan, Shadowsocks, Hysteria2, IPv4 + IPv6) both as a click-to-copy block at the top of `README.html` (EN + FA) and as a standalone `subscription.txt` file. Paste it once into **MahsaNG v16, v2rayNG, Hiddify, Streisand, or any V2Ray app** to import every proxy protocol at once — it isn't MahsaNG-specific. The DNS tunnels and GooseRelay (their own app tabs) are intentionally excluded; auto-hidden when the bundle has no compatible configs. This makes two things redundant, both removed: the separate per-user "MahsaNG" download button in the admin dashboard (the `.zip` now carries the subscription + all instructions), and the `moav user mahsanet` CLI command + `scripts/user-mahsanet.sh` (its output is now the bundled subscription). The MahsaNet community-network donation API in the dashboard is a separate feature and is unaffected.
- **Optional swapfile prompt in the installer** — on a low-RAM host (≤ ~2.5 GB) with no swap configured, `install.sh` now offers (opt-in) to create and enable a 2 GB `/swapfile` (persisted in `/etc/fstab`), since image builds can briefly exceed RAM and get OOM-killed without swap. Skipped on fully non-interactive installs (cloud-init/CI) — never a silent host change. `moav doctor` now also flags missing swap on low-RAM hosts with the same remedy.
- **MasterDNS DNS tunnel** (PR [#102](https://github.com/MotherofallVPNs/moav/pull/102), thanks @ibeezhan) — `masterking32/MasterDnsVPN` server (ARQ + resolver load-balancing, the DNS tunnel bundled in MahsaNG v16), fronted by dns-router on `m.<domain>`. Enabled by default. The prebuilt binary download is verified against the release's `SHA256SUMS.txt` at build time.
- **GooseRelay exit server** (PR [#102](https://github.com/MotherofallVPNs/moav/pull/102), thanks @ibeezhan) — `kianmhz/GooseRelayVPN` SOCKS5-over-Google-Apps-Script tunnel exit (AES-256-GCM, domain-fronted via google.com), pinned to **v1.7.1** (interoperable with the GooseRelay client in MahsaNG v16). Each user bundle ships **ready-made setup files** so there's nothing to hand-edit: `gooserelay-AppsScript.gs` (the vendored v1.7.1 `Code.gs`, MIT © Kian Haddad, with the `RELAY_URLS` array already pointed at this server) and `gooserelay-client_config.json` (full client config; only the Apps Script Deployment ID is left blank, since it only exists after the user deploys). The user's only manual steps are paste → Deploy → copy the Deployment ID into the config. v1.7.x renamed the single `RELAY_URL` to a `RELAY_URLS` array — reflected throughout. Opt-in (`ENABLE_GOOSERELAY=true`), host port `PORT_GOOSE` (default `8444`). **Note:** MasterDNS and GooseRelay use a single *shared* tunnel key per server (not per-user) — anyone with a bundle that contains the key can use, and decrypt, that tunnel; rotate by re-bootstrapping after regenerating the key.
- **`dns-router` XDNS routing** — `ENABLE_XDNS=true` adds an `x.<domain>` → `xray:5355` route to dns-router, enabling XDNS to coexist with the other three tunnels on port 53. Closes [#99](https://github.com/MotherofallVPNs/moav/issues/99).
- **`dns-router` test suite expanded** — all four tunnels covered: `TestDomainRouting` and `TestDomainIsolation` now verify the full 4-tunnel parallel configuration; `TestBuildRoutes` validates the XDNS-off default (3 routes) and the all-on case (4 routes). Run with `cd dns-router && go test ./... -v`
- **`dns-router/README.md`** — architecture note explaining subdomain-based fan-out and why all four DNS tunnels can coexist on port 53

### Fixed
- **sing-box config rejected by 1.13.0 (legacy inbound fields removed)** — sing-box 1.13 removed the inbound-level `sniff` field (deprecated since 1.11), so the server failed to start: `decode config: inbounds[0]: legacy inbound fields are deprecated in sing-box 1.11.0 and removed in sing-box 1.13.0`. Migrated the config template to the rule-action model: dropped `"sniff": true` from every inbound and added a single `{"action": "sniff"}` route rule, and removed the now-removed legacy `"type": "block"` outbound (it was unused; the `reject` action replaces it). `config.json` regenerates from the template on `moav bootstrap`.
- **`moav doctor` reported a *lower* version as an available update** — the update check only tested the running version against the latest GitHub release *tag* for string inequality, so once VERSION ran ahead of the newest tag (e.g. `v1.8.0` vs the `v1.7.8` tag, since 1.7.9/1.8.0 weren't tagged) it printed "Update available: v1.7.8". It now does a real semver comparison (`version_gt`) — only a genuinely newer release flags an update; running ahead of the latest tag reports "ahead of latest release" and passes
- **Low-RAM build failures (`context deadline exceeded` / OOM-killed compiles)** — `docker compose build` defaults to the bake builder, which fans every image out in parallel; on a 1–2 GB VPS the simultaneous Go compiles (snowflake, amneziawg, sing-box, …) exhaust memory, the box swap-thrashes, and BuildKit's solve deadline expires (`target …: failed to solve: Internal: context deadline exceeded`). All build call-sites now route through a `compose_build()` wrapper that tiers concurrency to detected RAM: ≤3 GB builds serially (`COMPOSE_BAKE=false COMPOSE_PARALLEL_LIMIT=1`), 3–6 GB builds 2-at-a-time, >6 GB keeps Docker's defaults. Override with `MOAV_BUILD_PARALLEL=N`. The post-update apply step no longer hard-codes `--no-cache` (it forced full recompiles; a version bump already busts only the relevant layer) — pass `--no-cache` explicitly when you want a clean rebuild. The `dns-router` Go compile is also pinned to single-package builds (`go build -p=1`, `GOMAXPROCS=1`) so its peak RAM stays low on tiny build hosts.
- **`moav update` now rebuilds source-built services when their code changes** — previously only version-pinned components (xray, telemt, sing-box, …) were queued for rebuild after an update, so a source change to a service with no version pin would land in git but never reach the running container until a manual rebuild. This is exactly how a `dns-router` source change (the all-4-tunnels routing) left old 2-route routers running after updating to 1.8.0 — and why MasterDNS/XDNS got no traffic. A new post-update check diffs the pulled commits and queues any service whose **baked** build inputs changed (its `Dockerfile`, its `COPY`'d entrypoint, or the `dns-router/` Go source); bind-mounted scripts (`bootstrap.sh`, `generate-user.sh`, `lib/`) are correctly ignored since they take effect on the next run without a rebuild
- **Xray crash-loop with XDNS enabled on v26.5.9 (`The feature domain has been removed`)** — Xray v26.x removed the singular `domain` field from the xdns finalmask mask and split it into `domains` (server) / `resolvers` (client). The server inbound (`bootstrap.sh`) and both client config generators still emitted `domain`, so xray refused to load its config and crash-looped — taking down Reality/Trojan/XHTTP along with XDNS. Server now emits `"domains": ["x.<domain>"]`; client configs emit `"resolvers": ["x.<domain>+udp://<server>:<port>"]` (the documented `domain[:method]+udp://server:port` form). **Requires re-bootstrap** (`moav bootstrap`) to regenerate `xray/config.json`, plus `moav regenerate-users` to refresh user XDNS bundles. Needs an Xray v26.4+ client (e.g. MahsaNG v16 / Happ)
- **`moav user add` produced an incomplete bundle for MasterDNS/GooseRelay** — the fast host-side add path generated dnstt/Slipstream/XDNS instructions but not MasterDNS (enabled by default) or GooseRelay, so a freshly added user's bundle was missing `masterdns-instructions.txt` until a follow-up `moav regenerate-users`. `moav user add` now generates both directly (reading the shared per-server tunnel keys from `outputs/`, since the host can't see the `/state` volume), so bundles are complete in one step. The text mirrors `lib/masterdns.sh` / `lib/gooserelay.sh`, so a bundle reads identically whichever path built it
- **`moav update` blocked by generated MasterDNS/GooseRelay config files** — bootstrap writes runtime files into `configs/masterdns/` (`server_config.toml`, `server.domain`) and `configs/gooserelay/` (`server_config.json`), but only the `*_config.*` names were gitignored, so `configs/masterdns/server.domain` showed up as an untracked change and `moav update` refused to pull. `.gitignore` now ignores **everything** generated in those two dirs (keeping only `.gitkeep` and the vendored `Code.gs.template`), so new generated files can't reintroduce the problem
- **`moav user add` failing with `.env: line N: https://goproxy.cn: No such file or directory`** — the `GOPROXY` default (added in 1.7.9) is pipe-separated (`proxy|proxy|direct`), and `scripts/user-add.sh` does `set -a; source .env`. Unquoted, bash parsed the `|` as shell pipes and tried to run the URLs as commands, aborting user creation. `.env.example` now **quotes** the value (Docker Compose strips the quotes when passing it as a build arg), and `user-add.sh` **auto-quotes** an unquoted `GOPROXY` line in place before sourcing — so existing `.env` files self-heal on the next `moav user add`
- **`moav update` blocked by a runtime-modified `conduit_lifetime.rules.yml`** — the Conduit lifetime rules file (added in 1.7.9) was tracked in git but is rewritten at runtime by `update-conduit-offsets.sh` (it bakes the per-install OFFSET values into the file), so `moav update` kept reporting "Local changes detected" and refused to pull. The live file is now **gitignored**; the repo ships `configs/monitoring/conduit_lifetime.rules.yml.template` (offsets at 0) and `moav start` materializes the live file from it on first monitoring start (never clobbering existing offsets). This matches how `xray/config.json`, `telemt/config.toml`, etc. are handled. Existing installs hitting the prompt: pick **Discard** (the watcher re-banks offsets from Prometheus history on the next Conduit restart, or run `scripts/update-conduit-offsets.sh`) — after this update lands, the prompt won't recur

## [1.7.9] - 2026-05-26

### Fixed
- **`get_env_val` 2-argument miscalls in `moav start`** — six call sites passed the *default value* where the function expects the *.env file path* (`get_env_val "ENABLE_DNSTT" "true"` → the literal `true` was grepped as a filename, always returning empty). Effects: the fallback profile builder (used when `DEFAULT_PROFILES` is unset) never added the `dnstunnel`/`amneziawg` profiles, and the v1.7.5 DNS port-group conflict hard-block was silently weakened (`dnstt_enabled`/`slipstream_enabled`/`xdns_start_enabled` always read empty). All now pass `$SCRIPT_DIR/.env` so the flags are read correctly and the conflict check works as intended. Also fixed the same miscall in the new Conduit auto-updater guard (it caused `auto_setup_conduit_offsets` to no-op, so the watcher never auto-installed on `moav start`)
- **`moav regenerate-users` now actually refreshes existing bundles** (issue [#98](https://github.com/MotherofallVPNs/moav/issues/98), thanks @vibecodegits) — it ran `bootstrap /app/generate-user.sh <user>`, but the bootstrap image's `ENTRYPOINT` is `bootstrap.sh`, so the `generate-user.sh` argument was ignored and a *full bootstrap* ran instead. Bootstrap regenerates bundles **without** `force`, so existing files were skipped and stale IP/domain/port values persisted (nothing in the codebase ever passed `force`, so there was no working refresh path). It now invokes `generate-user.sh <user> force` directly (via `--entrypoint /bin/sh`), syncs `/host-state/users` → `/state/users` first so users created with `moav user add` are found during regeneration, and passes the full DNS-tunnel env set (`DNSTT_SUBDOMAIN`, `ENABLE_XDNS`, `XDNS_SUBDOMAIN`, `XDNS_MTU`, `XDNS_RESOLVERS`, `PORT_DNS`, `PORT_XDNS`) so regenerated bundles match the active `.env` instead of falling back to defaults (`t`/`x`/`53`)
- **XDNS bundle UUID could regenerate empty** (issue [#98](https://github.com/MotherofallVPNs/moav/issues/98)) — `generate-user.sh` sources `USER_UUID` from `credentials.env`, but the XDNS block then reset it to empty and only re-read a separate `uuid.env` that doesn't exist on current installs, yielding an XDNS config with a blank `id`. It now prefers the already-loaded `USER_UUID` and lets `uuid.env` override only if present
- **Stale `xdns.txt` after regeneration** (issue [#98](https://github.com/MotherofallVPNs/moav/issues/98)) — `generate-user.sh` rewrote `xdns-config.json`/`xdns-direct-config.json` but not the human-readable `xdns.txt`, so its instructions (domain, resolvers) could drift from the JSON after a config change. It now emits `xdns.txt` from the same values, consistent with `singbox-user-add.sh`

### Added
- **Conduit lifetime bandwidth tracking** (PR [#97](https://github.com/MotherofallVPNs/moav/pull/97), thanks @jSFBay) — `conduit_bytes_downloaded`/`conduit_bytes_uploaded` are in-memory gauges that reset on every Conduit restart, so cumulative contribution was impossible to see in Grafana. New Prometheus recording rules (`configs/monitoring/conduit_lifetime.rules.yml`) maintain `*_lifetime` totals by adding a per-install offset to the live counters, and two **Lifetime Download / Lifetime Upload** stat panels were added to the Conduit dashboard. After a Conduit restart, `scripts/update-conduit-offsets.sh` recovers the pre-restart running total and rewrites the offset, then reloads Prometheus (SIGHUP). Offsets start at 0 for new installs. By default the script reaches Prometheus through the running container (`docker compose exec prometheus`), so it works without publishing port 9091 to the host; set `PROM_URL` to override with a host-reachable address or an external Prometheus. It preflights connectivity and fails with a clear message if Prometheus is unreachable. The offset is derived from the `*_lifetime` metric's high-water mark (not the raw gauge) so it accumulates correctly across multiple restarts
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
- **Shadowsocks-2022 protocol** — New `ENABLE_SS=true` toggle adds a Shadowsocks-2022 inbound to the existing sing-box service (no new container, no new daemon). Defaults to `2022-blake3-aes-128-gcm` for multi-user support (sing-box's SS-2022 multi-user mode only supports the AES variants; `chacha20-poly1305` is single-user only). Per-user PSKs are generated at bootstrap and persisted under `state/users/<id>/shadowsocks.env`; the server PSK lives at `state/keys/shadowsocks-server.psk`. Bootstrap auto-regenerates the SS state if `SS_METHOD` changes and the saved PSK no longer matches the cipher key length. User bundles emit a standard `ss://` URI + QR + sing-box JSON, compatible with NekoBox / Hiddify / Streisand / sing-box clients and the Outline mobile app. Off by default; enable via `ENABLE_SS=true` in `.env` and re-bootstrap. Refs [#93](https://github.com/MotherofallVPNs/moav/issues/93)
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
- **Grafana Conduit dashboard** — Region panels now show `CODE: Country Name` (full ISO 3166-1 set, 249 mappings) instead of bare 2-letter codes; *Connected Clients by Region* enlarged and joined by a sortable Mean/Max/Last stats table (PR [#91](https://github.com/MotherofallVPNs/moav/pull/91), thanks @jSFBay)

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
- **Admin user creation permission error** ([#85](https://github.com/MotherofallVPNs/moav/issues/85)) — `configs/sing-box/` and other config directories now get `chmod a+rwX` in admin entrypoint; `user-add.sh` uses `su-exec root` fallback when `sudo` is unavailable (admin container)
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
- **Docker Compose security hardening** (PR [#81](https://github.com/MotherofallVPNs/moav/pull/81)) — `cap_drop: ALL` with selective `cap_add`, `read_only: true`, `no-new-privileges`, resource limits per service; removed `privileged: true` from WireGuard/AmneziaWG; `gosu` → `setpriv` for capability retention through user switch
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
- **`moav doctor` command** (PR [#79](https://github.com/MotherofallVPNs/moav/pull/79)) — 9 diagnostic checks:
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
- **Bootstrap `local` outside function** — `local` keyword on line 64 caused `bootstrap.sh` to fail in domainless mode ([#77](https://github.com/MotherofallVPNs/moav/issues/77))
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
- **Non-root containers** (PR [#68](https://github.com/MotherofallVPNs/moav/pull/68)) — All service containers run as non-root `moav` user
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
- **Bootstrap Docker optimization** — sing-box binary downloaded directly instead of pulling full container image (fixes hang in censored networks, [#75](https://github.com/MotherofallVPNs/moav/issues/75)); scripts volume-mounted instead of COPY'd; cached image reuse on subsequent runs

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
- **MahsaNet config donation** — Donate VPN configs to MahsaServer.com (Mahsa VPN app, 2M+ users in Iran) directly from the admin dashboard ([#69](https://github.com/MotherofallVPNs/moav/issues/69))
  - Protocol selection via checkboxes (Reality, Hysteria2, Trojan, CDN, XHTTP, Telegram)
  - `MAHSANET_API_KEY`, `MAHSANET_PROTOCOLS`, `MAHSANET_POOL` config options in `.env`
  - "Donated" tag displayed on admin dashboard for donated configs
  - `DONATE_ONLY_PROTOCOLS` generated only when donation is active
  - Telegram proxy included in default donated protocols
- **`moav admin password` command** — Reset admin dashboard password from the CLI ([#70](https://github.com/MotherofallVPNs/moav/issues/70))
- **MkDocs documentation site** — Project documentation now served via MkDocs with philosophy, protocols, quick-start, and OPSEC pages
- **MahsaNet documentation** — Setup guide for MahsaNet donation flow in SETUP.md and CLI.md

### Fixed
- **Admin dashboard double submission** — Prevented duplicate form submissions from the dashboard
- **Admin password in domainless mode** — Fixed password setup failing without a domain ([#70](https://github.com/MotherofallVPNs/moav/issues/70))
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
- **AmneziaWG protocol** - DPI-resistant WireGuard fork with packet-level obfuscation ([#48](https://github.com/MotherofallVPNs/moav/issues/48))
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
- Bugfix [#38](https://github.com/MotherofallVPNs/moav/issues/38)
- Bugfix [#44](https://github.com/MotherofallVPNs/moav/issues/44)
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
- Conduit status showing "never" even when running ([#7](https://github.com/MotherofallVPNs/moav/issues/7))
- Reality URL `&` characters replaced with placeholder in README.html ([#8](https://github.com/MotherofallVPNs/moav/issues/8))
- Architecture mismatch in Dockerfile.client - now uses TARGETARCH for multi-arch support ([#4](https://github.com/MotherofallVPNs/moav/issues/4))
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

[Unreleased]: https://github.com/MotherofallVPNs/moav/compare/v1.9.1...HEAD
[1.9.1]: https://github.com/MotherofallVPNs/moav/compare/v1.9.0...v1.9.1
[1.9.0]: https://github.com/MotherofallVPNs/moav/compare/v1.8.5...v1.9.0
[1.8.6]: https://github.com/MotherofallVPNs/moav/compare/v1.8.5...v1.8.6
[1.8.5]: https://github.com/MotherofallVPNs/moav/compare/v1.8.4...v1.8.5
[1.8.4]: https://github.com/MotherofallVPNs/moav/compare/v1.8.3...v1.8.4
[1.8.3]: https://github.com/MotherofallVPNs/moav/compare/v1.8.2...v1.8.3
[1.8.2]: https://github.com/MotherofallVPNs/moav/compare/v1.8.1...v1.8.2
[1.8.1]: https://github.com/MotherofallVPNs/moav/compare/v1.8.0...v1.8.1
[1.8.0]: https://github.com/MotherofallVPNs/moav/compare/v1.7.9...v1.8.0
[1.7.9]: https://github.com/MotherofallVPNs/moav/compare/v1.7.8...v1.7.9
[1.7.8]: https://github.com/MotherofallVPNs/moav/compare/v1.7.7...v1.7.8
[1.7.7]: https://github.com/MotherofallVPNs/moav/compare/v1.7.6...v1.7.7
[1.7.6]: https://github.com/MotherofallVPNs/moav/compare/v1.7.5...v1.7.6
[1.7.5]: https://github.com/MotherofallVPNs/moav/compare/v1.7.4...v1.7.5
[1.7.4]: https://github.com/MotherofallVPNs/moav/compare/v1.7.3...v1.7.4
[1.7.3]: https://github.com/MotherofallVPNs/moav/compare/v1.7.2...v1.7.3
[1.7.2]: https://github.com/MotherofallVPNs/moav/compare/v1.7.0...v1.7.2
[1.7.0]: https://github.com/MotherofallVPNs/moav/compare/v1.6.2...v1.7.0
[1.6.2]: https://github.com/MotherofallVPNs/moav/compare/v1.6.1...v1.6.2
[1.6.1]: https://github.com/MotherofallVPNs/moav/compare/v1.6.0...v1.6.1
[1.6.0]: https://github.com/MotherofallVPNs/moav/compare/v1.5.1...v1.6.0
[1.5.1]: https://github.com/MotherofallVPNs/moav/compare/v1.4.7...v1.5.1
[1.4.7]: https://github.com/MotherofallVPNs/moav/compare/v1.4.5...v1.4.7
[1.4.5]: https://github.com/MotherofallVPNs/moav/compare/v1.4.4...v1.4.5
[1.4.4]: https://github.com/MotherofallVPNs/moav/compare/v1.4.1...v1.4.4
[1.4.2]: https://github.com/MotherofallVPNs/moav/compare/v1.4.1...v1.4.2
[1.4.1]: https://github.com/MotherofallVPNs/moav/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/MotherofallVPNs/moav/compare/v1.3.8...v1.4.0
[1.3.8]: https://github.com/MotherofallVPNs/moav/compare/v1.3.7...v1.3.8
[1.3.7]: https://github.com/MotherofallVPNs/moav/compare/v1.3.6...v1.3.7
[1.3.6]: https://github.com/MotherofallVPNs/moav/compare/v1.3.5...v1.3.6
[1.3.5]: https://github.com/MotherofallVPNs/moav/compare/v1.3.4...v1.3.5
[1.3.4]: https://github.com/MotherofallVPNs/moav/compare/v1.3.3...v1.3.4
[1.3.3]: https://github.com/MotherofallVPNs/moav/compare/v1.3.1...v1.3.3
[1.3.1]: https://github.com/MotherofallVPNs/moav/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/MotherofallVPNs/moav/compare/v1.2.5...v1.3.0
[1.2.5]: https://github.com/MotherofallVPNs/moav/compare/v1.2.4...v1.2.5
[1.2.4]: https://github.com/MotherofallVPNs/moav/compare/v1.2.3...v1.2.4
[1.2.3]: https://github.com/MotherofallVPNs/moav/compare/v1.2.2...v1.2.3
[1.2.2]: https://github.com/MotherofallVPNs/moav/compare/v1.2.0...v1.2.2
[1.2.0]: https://github.com/MotherofallVPNs/moav/compare/v1.1.2...v1.2.0
[1.1.2]: https://github.com/MotherofallVPNs/moav/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/MotherofallVPNs/moav/compare/v1.0.2...v1.1.1
[1.0.2]: https://github.com/MotherofallVPNs/moav/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/MotherofallVPNs/moav/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/MotherofallVPNs/moav/releases/tag/v1.0.0
