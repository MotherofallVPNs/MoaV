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
subscription), and runs 18+ transports plus an optional Prometheus/Grafana
monitoring stack. Protocol servers run as containers; provisioning and the CLI
are bash. The install lives in **`/opt/moav`** by default.

## Install & run

Install the global `moav` command, then run the guided setup (asks for domain,
ACME email, admin password, then bootstraps keys/certs and starts the stack):

```bash
curl -fsSL https://moav.sh/install.sh | bash    # or: git clone … && ./moav.sh install
moav                                             # guided config + bootstrap + start
```

The `moav.sh/install.sh` one-liner installs the latest **stable** release. To
fresh-install the **latest dev** code instead (e.g. to test an unreleased fix),
fetch and run `install.sh` from the branch and tell it to clone that branch:

```bash
curl -fsSL https://raw.githubusercontent.com/MotherofallVPNs/MoaV/dev/install.sh | bash -s -- -b dev
```

(Swap `dev` for a tag like `v2.0.0-rc.3` to install a specific release candidate.)

**Unattended install** (no prompts): set `MOAV_NONINTERACTIVE=1` and pass the
answers in the environment (`MOAV_DOMAIN`, `MOAV_EMAIL`, `MOAV_ADMIN_PASSWORD`,
`ENABLE_*`, `MOAV_DOMAINLESS=1` for no domain), or `bash install.sh --answers
FILE` with a `0600` KEY=VALUE file. The password is never accepted on the
command line; a missing required value aborts. `MOAV_BOOTSTRAP=1` also runs
`moav bootstrap --yes`, which uses the saved `DEFAULT_PROFILES` instead of
prompting for a service selection.

**Upgrade in place:** `moav update -b main && moav apply`, or in one command
`moav update -b main --yes --apply`
(see [docs/V2-MIGRATION.md](docs/V2-MIGRATION.md) for the 1.9.x → v2 path).
`moav apply` is the one post-update command and `moav update` ends by pointing
at it. Both it and `--apply` are **available from 2.5.1**: a server on 2.5.0 or
older does not know `--apply`, so there run `moav update` first, then
`moav apply`.

> **Legacy (pre-2.5.1), will be removed in a future release.** A checkout that
> stays on 2.5.0 or older has no `moav apply`. There, run the steps
> `moav update` prints by hand, in order: `moav build`, `moav bootstrap` (only
> if config templates changed), `moav regenerate-users` (only if told to),
> `moav start`. Do not script this sequence for 2.5.1 or newer.
<!-- LEGACY-PRE-2.5.1: remove together with the other legacy update guidance (CHANGELOG 2.5.1, Deprecated) -->

## Everyday operations

Run these as the owner's operator. Most take an optional service/profile name;
with none they act on the whole stack.

| Command | What it does |
|---|---|
| `moav` | Interactive menu (safe to explore; nothing changes until you pick an action) |
| `moav status` | Per-container health and which profiles are up. `--json` for a secret-free machine-readable document (also on `doctor`, `user list`, `user add`/`remove`, `test`) |
| `moav start [svc\|profile]` / `moav stop [svc]` / `moav restart [svc]` | Bring services up/down. `moav start all` = everything |
| `moav user list` | List provisioned users |
| `moav user add <name> [--package]` | Create a user (keys, configs, QR). `--package` also builds the downloadable zip |
| `moav user add --batch N [--prefix NAME] [--package]` | Bulk-create N users |
| `moav user package <name>` | (Re)build one user's downloadable **zip bundle** in `outputs/` |
| `moav user sub <name>` | Print that user's base64 **subscription** — the blob phone apps (Streisand, v2rayNG, NekoBox, Hiddify) import |
| `moav user base64 <name>` | Print that user's text-only bundle **zipped, then base64** — input for moav-client's e2e `bundle_b64`. **Not** a subscription; client apps reject it |
| `moav user revoke <name>` | **Destructive** — remove a user and their access. Confirm with the owner first |
| `moav regenerate-users` | Rebuild every bundle from stored state (keys unchanged); users just re-download |
| `moav logs [svc]` | Tail container logs — **first stop for debugging** |
| `moav doctor` | Diagnostics: DNS, ports, certs, service health. Run this when something's off. `moav doctor cert` = TLS cert days-left + renewal timer |
| `moav test <name>` | End-to-end protocol validation for a user (proves the tunnels actually pass traffic) |
| `moav cert` | Certificate status / renewal (Let's Encrypt) |
| `moav admin password` | Generate/reset the admin **and** Grafana password (`ADMIN_PASSWORD`) |
| `moav export` / `moav import` | Full backup / restore (keys, users, configs) — used for server migration |
| `moav apply [svc\|profile ...]` | Make the checkout live after an update or a `.env` edit: build, re-bootstrap if config templates changed, `regenerate-users`, recreate containers, prune dangling images. Never prompts, safe to re-run. Prints `[moav-apply] step N/6: …` markers and ends with `[moav-apply] exit=CODE result=…`; exit codes in `moav apply --help`. Run it detached (`nohup moav apply > apply.log 2>&1 &`) and poll `moav apply --status --json` |
| `moav update [--yes] [--apply]` | Pull new code (follow with `moav apply`, or pass `--apply` to chain into it). `--yes` (or `MOAV_NONINTERACTIVE=1`) never prompts: stashes local changes, applies `.env` version pins and new variables, does not restart services |

Full reference: [moav.sh/docs/CLI](https://moav.sh/docs/CLI/). Debugging flow when
a user reports "it stopped working": `moav status` → `moav doctor` →
`moav logs <svc>` → `moav test <user>`.

**Containers restarting in a loop after an update** (admin, Prometheus or
dns-router logging "Permission denied"): the checkout or an image was written
owner-only by a `umask 077` session. `moav doctor perms` reports it,
`moav doctor perms --fix` repairs the checkout, and `moav apply` rebuilds and
recreates the containers. Do not `chmod` by hand or re-clone.

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
| `docs/devdocs/` | E2E-TESTING, PROTOCOL-INTEGRATION-CHECKLIST, VERSION-BUMP-CHECKLIST, CLAUDE-REVIEW |

**Conventions that bite** (when editing bash): entrypoints run `set -eu` +
pipefail (subshell-probed — `set -o pipefail` is fatal in dash even with
`|| true`); `((x++))` returns 1 from 0 under `-e`. Use `get_env_val` (the single
`.env` accessor), never hand-rolled `grep|cut`. Scripts must run under **bash
3.2** (macOS): no `mapfile`/`${var^^}`. Secrets live in **state, not `.env`**
(renders re-source state via `load_state_secrets`). The admin container runs as
**uid/gid 2000**; state keys are `0600` root-owned (three non-root-daemon keys
stay `0644` inside the volume). The caller's umask may be `077` (the
Deploy app's SSH session): a Dockerfile gives every file it `COPY`s from the
checkout an explicit mode (`chmod 755`/`644`, never `chmod +x`), and host code
that writes a file a container mounts sets its mode.

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
