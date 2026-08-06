# AGENTS.md — running & operating a MoaV server with an AI agent

This guide is **mainly for an agent operating a MoaV server** on the owner's
behalf — installing it, adding users, checking health, reading logs, handing the
owner their dashboards. If you are instead **editing the code** (fixing a bug,
adding a protocol), jump to [Developing MoaV](#developing-moav) and the dev docs.

Humans: start with [README.md](README.md); public docs are at
[moav.sh/docs](https://moav.sh/docs). A one-fetch index for agents is
[llms.txt](llms.txt).

> **Safety first.** Set the server up over an **SSH key**, never a password, and
> never paste the owner's `ADMIN_PASSWORD`, private keys, or a user's share-link
> into anything public (issues, PRs, pastebins). Treat everything under `state/`
> and `outputs/` as secret. Don't run destructive commands (`uninstall`,
> `user revoke`, `docker volume rm`) without the owner's explicit go-ahead.

## What MoaV is

A single-host, Docker-Compose, multi-protocol Internet-censorship-circumvention
stack. `moav.sh` is a bash dispatcher over `lib/*.sh` modules; it bootstraps
keys/certs, generates per-user bundles (configs, QR codes, a V2Ray
subscription), and runs 16+ transports plus an optional Prometheus/Grafana
monitoring stack. Protocol servers run as containers; provisioning and the CLI
are bash. The install lives in **`/opt/moav`** by default.

## Install & run

Install the global `moav` command, then run the guided setup (asks for domain,
ACME email, admin password, then bootstraps keys/certs and starts the stack):

```bash
curl -fsSL https://moav.sh/install.sh | bash    # or: git clone … && ./moav.sh install
moav                                             # guided config + bootstrap + start
```

**Upgrade in place:** `moav update -b main && moav build && moav start`
(see [docs/V2-MIGRATION.md](docs/V2-MIGRATION.md) for the 1.9.x → v2 path).

## Everyday operations

Run these as the owner's operator. Most take an optional service/profile name;
with none they act on the whole stack.

| Command | What it does |
|---|---|
| `moav` | Interactive menu (safe to explore; nothing changes until you pick an action) |
| `moav status` | Per-container health and which profiles are up |
| `moav start [svc\|profile]` / `moav stop [svc]` / `moav restart [svc]` | Bring services up/down. `moav start all` = everything |
| `moav user list` | List provisioned users |
| `moav user add <name> [--package]` | Create a user (keys, configs, QR). `--package` also builds the downloadable zip |
| `moav user add --batch N [--prefix NAME] [--package]` | Bulk-create N users |
| `moav user package <name>` | (Re)build one user's downloadable **zip bundle** in `outputs/` |
| `moav user base64 <name>` | Print that user's base64 **subscription** string |
| `moav user revoke <name>` | **Destructive** — remove a user and their access. Confirm with the owner first |
| `moav regenerate-users` | Rebuild every bundle from stored state (keys unchanged); users just re-download |
| `moav logs [svc]` | Tail container logs — **first stop for debugging** |
| `moav doctor` | Diagnostics: DNS, ports, certs, service health. Run this when something's off |
| `moav test <name>` | End-to-end protocol validation for a user (proves the tunnels actually pass traffic) |
| `moav cert` | Certificate status / renewal (Let's Encrypt) |
| `moav admin password` | Generate/reset the admin **and** Grafana password (`ADMIN_PASSWORD`) |
| `moav export` / `moav import` | Full backup / restore (keys, users, configs) — used for server migration |
| `moav update` | Pull new code (follow with `moav build && moav start`) |

Full reference: [moav.sh/docs/CLI](https://moav.sh/docs/CLI/). Debugging flow when
a user reports "it stopped working": `moav status` → `moav doctor` →
`moav logs <svc>` → `moav test <user>`.

## Dashboards & access — what to hand the owner

Both dashboards are HTTPS on their own ports and share the single
`ADMIN_PASSWORD` from `.env`. The URLs are derived from `DOMAIN` (falling back to
`SERVER_IP`); the CLI prints them after bootstrap, and you can reproduce them:

| Dashboard | URL | Login | Notes |
|---|---|---|---|
| **Admin dashboard** (FastAPI) | `https://<domain>:9443` (`PORT_ADMIN`) | HTTP Basic — **any username**, password = `ADMIN_PASSWORD` | Add/revoke users, download bundles, live stats. **Self-signed cert** (expect a browser warning). Optional `ADMIN_IP_WHITELIST` (comma-separated IPs/CIDRs) restricts access; empty = open. Locks itself (503) if `ADMIN_PASSWORD` is unset/insecure |
| **Grafana** (optional monitoring) | `https://<domain>:9444` (`PORT_GRAFANA`) | user `admin`, password = `ADMIN_PASSWORD` | Traffic/health dashboards. A TLS reverse proxy is also exposed on `:2083` (`PORT_GRAFANA_PROXY`) for a `GRAFANA_SUBDOMAIN` with a real cert |

So to give the owner access: confirm the ports are reachable, share the URL,
tell them the login (admin dashboard: any username + their admin password;
Grafana: `admin` + the same password), and warn about the self-signed cert on
the admin dashboard. If they've lost the password, `moav admin password` mints a
new one and restarts both. Prefer tightening `ADMIN_IP_WHITELIST` to the owner's
IP over leaving the admin dashboard open to the world.

## Where things live

- **`.env`** (in `/opt/moav`) — the one config file you edit: `DOMAIN`,
  `ACME_EMAIL`, `ADMIN_PASSWORD`, ports (`PORT_*`), and `ENABLE_*` protocol
  toggles. Chmod `600`. A structural change (ports, toggles) needs
  `moav restart` (some need `moav bootstrap` to re-render). `.env.example`
  documents every key, essentials first.
- **`state/`** and the `moav_moav_state` Docker volume — keys, per-user records,
  rendered secrets. Secret; backed up by `moav export`. Do not hand-edit.
- **`outputs/`** — generated user **bundles / zips** the owner distributes.
- **`configs/`** — `*.template` (tracked) rendered to `*.json`/`*.conf`
  (gitignored); `git pull` never clobbers a rendered config.

## Developing MoaV

Only when changing the code (bug fix / new feature), not for operating a server.

**Run from a clone without the global install:**
```bash
cp .env.example .env      # DOMAIN, ACME_EMAIL, ADMIN_PASSWORD (top block)
./moav.sh build && ./moav.sh bootstrap && ./moav.sh start all && ./moav.sh doctor
```

**Repository layout**

| Path | What |
|---|---|
| `moav.sh` | CLI dispatcher; subcommands map to `cmd_*` in `lib/*.sh` |
| `lib/*.sh` | Host-side CLI modules: `service`, `users`, `bootstrap`, `build`, `update`, `doctor`, `cert`, `migrate`, `common`, … |
| `scripts/*-entrypoint.sh`, `scripts/*-user-add.sh` | Container entrypoints + per-user provisioning |
| `scripts/lib/*.sh` | Provisioning libs mounted into containers as `/app/lib` |
| `configs/` | `*.template` → rendered configs; Grafana dashboards under `configs/monitoring/…` |
| `dockerfiles/`, `exporters/`, `admin/` | Image builds, Prometheus exporters, the FastAPI admin app |
| `tests/*.sh` | Regression suite (one file per bug class) |
| `docs/devdocs/` | E2E-TESTING, PROTOCOL-INTEGRATION-CHECKLIST, VERSION-BUMP-CHECKLIST |

**Conventions that bite** (when editing bash): entrypoints run `set -eu` +
pipefail (subshell-probed — `set -o pipefail` is fatal in dash even with
`|| true`); `((x++))` returns 1 from 0 under `-e`. Use `get_env_val` (the single
`.env` accessor), never hand-rolled `grep|cut`. Scripts must run under **bash
3.2** (macOS): no `mapfile`/`${var^^}`. Secrets live in **state, not `.env`**
(renders re-source state via `load_state_secrets`). The admin container runs as
**uid/gid 2000**; state keys are `0600` root-owned (three non-root-daemon keys
stay `0644` inside the volume).

**Testing:** `bash tests/<name>.sh` for one suite. CI (`ci.yml`) runs the bash
suites; **e2e** (`e2e.yml`, `workflow_dispatch`, self-hosted) builds on a real
VPS + domain and probes every protocol — the merge bar for provisioning changes.
**Every bug found gets a regression test in the same PR.**

**Common changes:** new subcommand → `case` in `moav.sh` + `cmd_*` in a
`lib/*.sh`. New protocol → `docs/devdocs/PROTOCOL-INTEGRATION-CHECKLIST.md`.
**Merge flow:** `gh pr merge`, gate on `ci.yml` **and** `e2e.yml`, verify
`MERGED` before deleting the branch. Do not add AI-attribution trailers to
commits/PRs.

**Found a bug or want to add a feature?** Open an issue / PR:
[github.com/MotherofallVPNs/MoaV/issues](https://github.com/MotherofallVPNs/MoaV/issues).
See [CONTRIBUTING.md](CONTRIBUTING.md) and
[docs/devdocs/E2E-TESTING.md](docs/devdocs/E2E-TESTING.md).

## Where to look next

- [moav.sh/docs](https://moav.sh/docs) — full public documentation
- [CHANGELOG.md](CHANGELOG.md) — behavior changes per version
- [docs/V2-MIGRATION.md](docs/V2-MIGRATION.md) — upgrading 1.9.x → v2
- The companion **local client**: [moav-client](https://github.com/MotherofallVPNs/moav-client)
