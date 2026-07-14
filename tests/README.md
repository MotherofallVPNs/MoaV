# MoaV tests

MoaV's test scripts. Three layers, cheapest first:

| File | Layer | Needs | Run by |
|---|---|---|---|
| `singbox-links-test.sh` | **Unit** — golden test for the sing-box share-link builders (pure string functions in `scripts/lib/sing-box.sh`) | nothing (no Docker, no server) | `ci.yml`, locally |
| `cli-smoke-test.sh` | **CLI smoke** — every `moav` command against a live stack (help/status/users/doctor/cert/export→import/user add+revoke/admin password/…), each hang-guarded | a running MoaV stack | `e2e.yml`, locally |
| `client-test.sh` | **Protocol e2e** — real connectivity per protocol, checking the exit IP. Runs **inside the `moav-client` container** (copied to `/app/` by `dockerfiles/Dockerfile.client`); invoked via `moav test <user>` | a live MoaV server + the client image | `e2e.yml` (`moav test`), locally |

Go unit tests live next to their package by Go convention (e.g. `dns-router/main_test.go`), not here.

## Running

```bash
# Unit (fast, no dependencies)
bash tests/singbox-links-test.sh

# CLI smoke — needs the stack up
./moav.sh start all && bash tests/cli-smoke-test.sh

# Protocol e2e — needs a live server + a provisioned user
./moav.sh user add e2e-test
./moav.sh test e2e-test --json     # runs client-test.sh inside the client container
```

The full end-to-end suite (build → bootstrap → start → provision → protocol matrix + CLI
smoke, on a self-hosted runner) is `.github/workflows/e2e.yml`. Setup + run modes
(domainless / domain / full) and result interpretation: [`docs/devdocs/E2E-TESTING.md`](../docs/devdocs/E2E-TESTING.md).
Agents: see the `moav-e2e` skill (`.claude/skills/moav-e2e/`).
