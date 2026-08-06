# AGENTS.md — MoaV server repo guide for AI agents

This is the deep guide for coding agents (Claude Code, Cursor, etc.) working in
the **MoaV server** repository. Humans: start with [README.md](README.md); the
public docs live at [moav.sh/docs](https://moav.sh/docs). A one-fetch index for
agents is [llms.txt](llms.txt).

## What MoaV is

A single-host, Docker-Compose, multi-protocol Internet-censorship-circumvention
stack. `moav.sh` is a bash dispatcher over `lib/*.sh` modules; it bootstraps
keys/certs, generates per-user bundles (configs, QR codes, a V2Ray
subscription), and runs 16+ transports plus an optional Prometheus/Grafana
monitoring stack. Protocol servers run as containers; provisioning and the CLI
are bash.

## Repository layout

| Path | What |
|---|---|
| `moav.sh` | CLI dispatcher (~1k lines). Subcommands: bootstrap, build, start, stop, restart, status, update, user(s), test, doctor, donate, conduit, admin, cert, install, uninstall, logs, export, import, profiles |
| `lib/*.sh` | Host-side CLI modules sourced by `moav.sh`: `service` (up/down), `users`, `bootstrap`, `build`, `update`, `doctor`, `donate`, `cert`, `nettune`, `peers`, `migrate`, `install`, `menu`, `dns`, `common` |
| `scripts/*-entrypoint.sh` | Container entrypoints (sing-box, xray, grafana, admin, wstunnel, trusttunnel, snowflake, …) |
| `scripts/user-add.sh`, `wg-user-add.sh`, `singbox-user-add.sh` | Per-user provisioning (host + container) |
| `scripts/lib/*.sh` | Provisioning libs, mounted into containers as `/app/lib`: `sing-box`, `xray`, `wireguard`, `amneziawg`, `telemt`, `dnstt`, `slipstream`, `masterdns`, `gooserelay`, `trusttunnel`, `keys`, `provision`, `sync`, `bundle-readme`, `common` |
| `configs/` | `*.template` files (tracked) → rendered `*.json`/`*.conf` (gitignored). Grafana dashboards in `configs/monitoring/grafana/provisioning/dashboards/*.json` |
| `dockerfiles/`, `exporters/`, `admin/` | Image builds; the Prometheus exporters; the FastAPI admin dashboard |
| `tests/*.sh` | The regression suite (see Testing) |
| `docs/devdocs/` | Contributor docs: E2E-TESTING, PROTOCOL-INTEGRATION-CHECKLIST, VERSION-BUMP-CHECKLIST |
| `.claude/skills/` | Operational Claude Code skills (e.g. running e2e) — tools, not this guide |

## Install & run

**Normal deployment** — how an operator (or an agent setting up a server) does it.
Installs the global `moav` command, then an interactive setup + bootstrap:

```bash
curl -fsSL https://moav.sh/install.sh | bash    # or: git clone … && ./moav.sh install
moav                                             # guided config + bootstrap + start
```

Everyday operation is then `moav <cmd>`: `moav status`, `moav user add alice`,
`moav doctor`, `moav update`. Full command reference: [moav.sh/docs/CLI](https://moav.sh/docs/CLI/).

**Working on the code** (no global install) — run the dispatcher directly:

```bash
cp .env.example .env      # DOMAIN, ACME_EMAIL, ADMIN_PASSWORD (top block)
./moav.sh build && ./moav.sh bootstrap && ./moav.sh start all
./moav.sh doctor
```

**Upgrade in place:** `moav update -b main && moav build && moav start`
(see [docs/V2-MIGRATION.md](docs/V2-MIGRATION.md) for the 1.9.x → v2 path).

## Testing

```bash
bash tests/<name>.sh            # any single suite
```
CI (`.github/workflows/ci.yml`) runs the bash suites: strict-mode, entrypoint-strict,
state-perms, bundle-perms, env-resolution, env-fallback, env-example, reality-desync,
grafana-branding, singbox-links, net-alloc, user-add-timeout, and more. **e2e**
(`.github/workflows/e2e.yml`, `workflow_dispatch`, self-hosted) builds the stack on
a real VPS + domain and probes every protocol end-to-end; the merge bar for
anything touching provisioning.

**Every bug found in dev gets a regression test in the same PR** — see the many
`tests/*-test.sh` named after the class they pin.

## Conventions that bite if you miss them

- **Strict mode.** Entrypoints run `set -eu` (+ pipefail probed in a subshell — `set -o pipefail` is fatal in dash regardless of `|| true`). `cmd1 && cmd2` does not trip `-e` on `cmd1`; a bare `cmd >file` does. `((x++))` returns 1 from 0 under `-e`.
- **`get_env_val`** is the single `.env` accessor (`lib/common.sh` + `scripts/lib/common.sh`, held byte-identical by a test). Uses `cut -d= -f2-` so base64 `=` isn't truncated. Don't hand-roll `grep|cut` scrapers.
- **bash 3.2.** macOS ships it; scripts and tests must run under it. No `mapfile`, no `declare -A` in hot paths, no `${var^^}`.
- **Host vs container paths.** `scripts/*-entrypoint.sh` use relative `configs/`; container lib functions may hardcode absolute `/configs`, `/state`. `state/users/` (host) ≠ the `moav_moav_state` volume (container reads the volume).
- **Generated configs are gitignored**; only `*.template` is tracked. `git pull` on update can't clobber a user's rendered config.
- **Admin container runs as uid/gid 2000**; bundles/state are chowned to it, never world-writable. State-key files are 0600 (root-owned) except the three read by non-root daemons (dnstt/masterdns/slipstream keys stay 0644 inside the volume).
- **Secrets live in state, not `.env`.** Renders re-source state right before writing (see `load_state_secrets`) so an empty `.env`-injected value can't blank a rendered secret.

## Common tasks

- **New CLI subcommand:** add a `case` in `moav.sh` dispatch + a `cmd_*` in the right `lib/*.sh`.
- **New protocol:** follow `docs/devdocs/PROTOCOL-INTEGRATION-CHECKLIST.md`; add a `scripts/lib/<proto>.sh`, wire provisioning, add a live e2e probe + a bundle section.
- **Version bump:** `docs/devdocs/VERSION-BUMP-CHECKLIST.md`; pinned `*_VERSION` vars default in compose build args.
- **Merge flow:** PRs via `gh pr merge` only; gate on `ci.yml` **and** `e2e.yml`; verify PR state `MERGED` before deleting the branch. Do not add AI-attribution trailers to commits/PRs.

## Where to look next

- [docs/devdocs/E2E-TESTING.md](docs/devdocs/E2E-TESTING.md) — the e2e harness, tiers, and how a green run is defined
- [CONTRIBUTING.md](CONTRIBUTING.md) — contributor workflow
- [CHANGELOG.md](CHANGELOG.md) — behavior changes per version
- [moav.sh/docs](https://moav.sh/docs) — the full public documentation
