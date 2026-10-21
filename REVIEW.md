# Review rubric

Instructions for the automated PR reviewer (Claude Code `code-review` plugin).
Read this together with **`AGENTS.md`** (this repo uses AGENTS.md, not CLAUDE.md)
and the dev docs under `docs/devdocs/`. MoaV is a single-host, Docker-Compose,
multi-protocol censorship-circumvention server: `moav.sh` is a bash dispatcher
over `lib/*.sh`, provisioning is bash + config templates, and the transports run
as containers. Review spans shell correctness, the security/opsec posture, and
the Docker/deploy surface — there is no application UI here.

## Output

- Post findings as **inline comments** on the exact `file:line`, and one
  **grouped summary** comment organized by the dimensions below.
- Lead the summary with a one-line verdict and the counts per dimension.
- Cap **Nits at 5**; if there are more, say "plus N similar" in the summary.

## Severity

- **Important** — breaks behavior, corrupts state, or is unsafe to ship:
  a destructive command without a guard, a config-file write that swaps
  inode/owner and locks a daemon out, a broken revoke/reload path, unquoted
  expansion that word-splits a path, or **any secret / admin password / private
  key / server IP / share-URI reaching logs, a committed file, or an issue/PR**.
- **Nit** — style, naming, small refactors, non-load-bearing comments.
- **Pre-existing** — a real problem the PR did not introduce; report separately,
  don't block on it.

## Verification bar

A finding must cite the `file:line` it's grounded in, not an inference from a
name. If you can't point at the code, drop it or mark it a question. Prefer
false negatives over confident false positives.

---

# Dimensions

Each dimension is self-contained on purpose: the plan is to later split them into
separate review agents/jobs, one per section. Keep findings tagged by dimension.

## 1. Security & opsec

This is a server people run to bypass censorship. Treat leaks as Important.

- **No secrets in output or the repo**: `ADMIN_PASSWORD`, API keys, Reality/WG
  private keys, `.env` values, a user's UUID/password or full share-URI, and
  real server IPs must never be `echo`/`log`'d to stdout, baked into a committed
  file, or printed where CI logs capture them. Everything under `state/` and
  `outputs/` is secret.
- **File permissions & ownership**: config writes preserve the original
  inode/mode/owner (overwrite in place with `cat >`, not `mv`), never go
  world-writable, and drop world-read on private-key files. Watch the admin
  container (non-root uid) vs host-root (sudo) DAC interplay — a swapped owner
  locks out the next write.
- **Destructive actions are guarded**: `uninstall`, `user revoke`,
  `docker volume rm`, `rm -rf` on a derived path — confirm intent, and never
  widen a path that could `rm` outside the install dir.
- Input that reaches a listener or a template is validated; no injection into a
  generated config, no unquoted user-supplied value in a shell command.
- No new fingerprintable surface (predictable ports/banners/timing) without
  reason; new dependencies/images are justified and pinned.

## 2. Correctness & bash safety

Does the change do what the PR says, and hold up when a step fails?

- Scripts keep `set -euo pipefail` (or justify not); no unquoted `$var`, no
  `[ $x = ... ]` on possibly-empty values, arrays quoted as `"${arr[@]}"`.
- **Idempotent & re-runnable**: add/revoke/regenerate can run twice without
  corrupting configs or duplicating peers; a partial failure leaves a recoverable
  state.
- Error paths propagate (`|| return`/`exit`), no silent failure on a path that
  matters; `set -e` isn't defeated by an unchecked pipeline.
- `jq`/`awk`/`sed` edits produce valid output and are validated before replacing
  the live file (the existing revoke/add scripts validate JSON before swap —
  keep that).
- Edge cases: empty user list, missing config, a service that isn't running,
  IPv6, first-run vs upgrade.

## 3. Tests

- **Every bug fix ships a regression test in the same PR** (project policy —
  see AGENTS.md). Tests live in `tests/` and are wired into `.github/workflows/ci.yml`.
- Prefer a fast static/unit check (source a lib function, assert on a fixture, or
  grep the behavior into place) over nothing when a full stack run isn't possible.
- Assert the failure mode the fix addresses, not just the happy path.
- Don't weaken or skip an existing test to make a change pass — fix the cause.
  New tests must be registered in `ci.yml`, not just added to `tests/`.

## 4. Docker & deploy

- **Compose**: services land in the right profile; a new long-running service is
  classified correctly (not treated as a one-shot), depends_on/healthchecks are
  sound, and it's added to any service-count/classification test.
- **Bind mounts**: single-file mounts have the inode-reload trap — the container
  needs a restart, not a HUP, to see a replaced file. Flag config swaps that
  assume live reload.
- `.env` / `.env.example` stay in sync (a gated test enforces drift); version
  vars and the `VERSION` file move together where required.
- Entrypoints are re-entrant and don't chown/chmod host-owned paths in a way that
  breaks the admin container or a sudo-less operator.
- No image or port exposed to the host beyond what the change needs.

---

## Skip

- Generated / vendored code, `outputs/`, `state/`, `configs/*/` runtime data,
  `geoip/` data, build output, `*.min.*`, `__pycache__`.
- Anything CI already enforces (shellcheck, the bash/python test suite, drift
  gates) — don't re-litigate formatting.
- Pure dependency/lockfile churn, unless a dependency itself is the concern.
