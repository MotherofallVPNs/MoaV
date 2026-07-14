# Contributing to MoaV

Thanks for helping build censorship-circumvention infrastructure. This is the
top-level guide; deeper references are linked at the bottom.

## Ground rules

- **PRs target `dev`, not `main`.** `main` is the released branch; `dev` is
  where work lands and is promoted to `main` at release time. A PR opened
  against `main` will be asked to retarget.
- **Never use `--no-verify`** to skip hooks.
- **One logical change per PR.** Smaller PRs review faster and revert cleanly.

## Dev setup

MoaV is a Docker Compose stack driven by the `moav` CLI (`moav.sh`). You need a
Linux host (a throwaway VPS is ideal — see [E2E testing](docs/devdocs/E2E-TESTING.md))
with Docker + Docker Compose.

```bash
git clone https://github.com/MotherofallVPNs/moav && cd moav
cp .env.example .env      # set DOMAIN, ACME_EMAIL, ADMIN_PASSWORD, INITIAL_USERS
./moav.sh build
./moav.sh bootstrap       # generates keys, obtains certs, creates the first user
./moav.sh start all
./moav.sh doctor          # sanity-check the running stack
```

For quick edits that don't need a live server (docs, link builders, config
generation), you can work locally — much of the logic is pure and unit-tested
(see below).

## Conventions

- **Comments stay terse** — state intent, a gotcha, or an error type. Narrative
  belongs in the CHANGELOG entry or PR description, not inline.
- **Track `CHANGELOG.md` incrementally** — add your entry under `[Unreleased]`
  in the same PR, grouped `Added` / `Changed` / `Fixed` / `Security` /
  `Documentation` / `Testing` / `Internal`. Don't batch changelog updates at
  release time.
- **No real test domains in release-facing text** — use `example.com` and
  friends. Real domains belong only in your local `.env`.
- **Match the surrounding style** — the codebase is `bash` + a little Go
  (`dns-router`) and Python (generators / inline bootstrap helpers). Shell
  scripts run under `set -euo pipefail`.

## Tests & CI

Every PR to `dev`/`main` runs the CI gate (`.github/workflows/ci.yml`):

- `shellcheck --severity=error` + `bash -n` across all shell scripts,
- `go test -race` for `dns-router`,
- `docker compose config` validation.

Run these locally before pushing:

```bash
git ls-files '*.sh' 'moav.sh' | xargs shellcheck --severity=error
( cd dns-router && go test ./... )
bash tests/singbox-links-test.sh          # share-link golden test
python3 scripts/gen-protocol-docs.py --check     # protocol-roster drift gate
```

The full connectivity test (`moav test`, every protocol against a live server)
runs on a self-hosted runner, not per-PR — see
[E2E testing](docs/devdocs/E2E-TESTING.md).

## The protocol roster is single-source

The protocol list is defined once in [`data/protocols.json`](data/protocols.json).
The server README is drift-checked against it; the human-readable overview table
and site copy live in the [moav-site](https://github.com/MotherofallVPNs/moav-site)
repo. If you add, remove, or rename a protocol:

```bash
# 1. edit data/protocols.json
# 2. add the protocol's `seo` token to README.md (prose)
python3 scripts/gen-protocol-docs.py --check    # must pass (CI enforces it)
```

## Adding a new protocol

Follow [`docs/devdocs/PROTOCOL-INTEGRATION-CHECKLIST.md`](docs/devdocs/PROTOCOL-INTEGRATION-CHECKLIST.md)
end-to-end (compose service, `ENABLE_*`/`PORT_*`, bootstrap, per-user
provisioning, client-test coverage, docs), and add the protocol to
`data/protocols.json` per the section above.

## Releasing

Maintainers follow [`docs/devdocs/VERSION-BUMP-CHECKLIST.md`](docs/devdocs/VERSION-BUMP-CHECKLIST.md).

## More references

- [Architecture](https://moav.sh/docs/architecture) — container topology, dns-router fan-out, security model
- [CLI reference](https://moav.sh/docs/CLI) — every `moav` command
- [Supported protocols](https://moav.sh/docs/protocols) — per-protocol detail
- [OPSEC](https://moav.sh/docs/OPSEC) — operator hardening + threat model
