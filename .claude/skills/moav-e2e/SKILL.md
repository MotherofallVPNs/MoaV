---
name: moav-e2e
description: >-
  Run and debug MoaV's end-to-end tests — real protocol connectivity (client-test.sh)
  and the moav CLI smoke test — against a LIVE server, via the self-hosted e2e workflow
  or a local test VPS. Use when validating a branch before release, diagnosing a protocol
  that won't connect, or checking that moav CLI commands still work after a change. Knows
  the domainless (no-cert) vs domain (full-protocol) modes, how to read the pass/warn/skip/fail
  matrix, and the known failure modes with their fixes.
---

# MoaV end-to-end testing

Two layers run against a live server (not mocks):

- **`tests/client-test.sh`** (`moav test <user> [--json] [-v]`) — stands up a client-side
  tunnel per protocol and checks the exit IP. This is the protocol matrix.
- **`tests/cli-smoke-test.sh`** — exercises the `moav` *tool* (help/status/users/doctor/cert/
  export→import/user add+revoke/admin password/…), each hang-guarded.

The per-PR CI (`ci.yml`) only lints + unit-tests; it never brings the stack up. Full e2e is
`.github/workflows/e2e.yml` on a **self-hosted runner** (a test VPS with a real test domain),
because it builds ~25 images and needs real TLS certs. Human setup doc:
`docs/devdocs/E2E-TESTING.md`.

## How to run

### Preferred: the self-hosted workflow

```bash
# domainless — no cert, no Let's Encrypt dependency. Fast to iterate, validates the
# IP-only protocols + the client image build. START HERE when debugging.
gh workflow run e2e.yml -R MotherofallVPNs/moav --ref <branch> -f verbose=true -f domainless=true

# domain — full matrix incl. the TLS-domain protocols (Trojan/Hysteria2/AnyTLS/CDN).
# Reuses the cert across runs; DON'T run more than ~5/week (LE limit).
gh workflow run e2e.yml -R MotherofallVPNs/moav --ref <branch> -f verbose=true

# full — also build --local + a second domainless phase + image-removal uninstall (slow).
gh workflow run e2e.yml -R MotherofallVPNs/moav --ref <branch> -f full=true
```

Then get the run id and watch it (watch in the background so tool output stays out of context):

```bash
sleep 8
gh run list -R MotherofallVPNs/moav --workflow e2e.yml --limit 1 --json databaseId,status
gh run watch <id> -R MotherofallVPNs/moav   # run in background; you're re-invoked on finish
```

The workflow must live on the **default branch** (`main`) for `workflow_dispatch` to show up;
dispatch then runs the *selected* branch's copy.

### Local (on the test VPS itself)

```bash
cp .env.example .env      # set DOMAIN, ACME_EMAIL, ADMIN_PASSWORD, SERVER_IP,
                          # INITIAL_USERS=1, DEFAULT_PROFILES=all  (empty DOMAIN = domainless)
./moav.sh build
./moav.sh bootstrap --yes
./moav.sh start all
sleep 45
./moav.sh user add e2e-test
./moav.sh test e2e-test --json   # machine-readable matrix; add -v for per-protocol debug
```

If moav ran as root in containers but you invoke the CLI as non-root, reclaim ownership first:
`sudo chown -R "$(id -u):$(id -g)" configs state outputs`.

## Reading the result

`moav test --json` emits `{ overall_status, summary:{pass,fail,warn,skip}, tests:{<proto>:{status}} }`.

- **pass** — connected, confirmed a real exit IP. **fail** — should have worked, didn't → **fails the run**.
- **warn** — reachable but not fully confirmed (throttled DNS tunnel, IPv6-only path, telemt w/o openssl). Does **not** fail.
- **skip** — not in the bundle (disabled / no client binary). Does **not** fail.

The workflow's *Evaluate* step fails only on `fail`. A domainless run correctly shows the
TLS-domain protocols (trojan/anytls/hysteria2/cdn) and DNS tunnels as **skip** (disabled), and
Reality/Shadowsocks/XHTTP/WireGuard/AmneziaWG/telemt as **pass**.

Pull the matrix from a finished run:

```bash
gh run view <id> -R MotherofallVPNs/moav --json conclusion,jobs \
  --jq '.conclusion, (.jobs[].steps[] | select(.conclusion=="failure") | "FAILED: \(.name)")'
gh run view <id> -R MotherofallVPNs/moav --log | \
  awk -F'\t' '$2=="Evaluate results"' | sed 's/^[^\t]*\t[^\t]*\t//' | grep -E ': (pass|fail|warn|skip)|Failed protocols'
```

## Known failure modes → fixes

Fix the repo, don't paper over it in the test. Each of these was a real bug.

| Symptom in the log | Cause | Fix |
|---|---|---|
| `sing-box: cannot execute: required file not found` | Prebuilt sing-box is glibc-dynamic (`/lib64/ld-linux-x86-64.so.2`); client image is Alpine/musl | `Dockerfile.client` installs real glibc + the `/lib64` loader symlink. Verify: `docker run --rm moav-client sing-box version` |
| Protocol error unchanged after a client fix | `moav test` reused a **stale** `moav-client` image | `moav test` always rebuilds now; if editing older code, `docker rmi moav-client` first |
| `too many certificates … retry after <date>` | LE 5/week per-domain limit — a run re-issued the cert | Domain runs reuse the `moav_certs` volume; only `full` wipes it. Blocked? use `-f domainless=true`. |
| `certbot … exit 1` on first issue | Apex A record missing / port 80 closed / Cloudflare-proxied (HTTP-01 needs DNS-only) | Fix DNS; diagnostics step dumps the certbot log |
| `Skipping sing-box (not configured)` → empty bundle (only README.html) | Host CLI (non-root runner) can't read root-owned `configs/` | Reclaim step `chown`s configs/state/outputs before the CLI runs; assert bundle has ≥1 non-README file |
| Bootstrap `[y/N]` then `Bootstrap cancelled` (`/dev/tty: No such device`) | Re-bootstrap prompts; no TTY defaults to *no* | `moav bootstrap --yes` |
| `User '<u>' already exists` | State persisted from a prior run | Revoke-then-add: `moav user revoke <u> 2>/dev/null || true; moav user add <u>` |
| `moav test --json` output truncated (no `overall_status`) | `((count++))` returns 1 at 0→1 under `set -e`, killing the script | set-e-safe arithmetic (`x=$((x+1))`) — general bash-under-`set -e` gotcha |
| `moav export` → `Permission denied` on `state/keys/*.key` | Root containers stage root-owned files; host `tar` (non-root) can't read them | export chowns the staged copy via a root container before tarring |
| `tar: stdout: write error` late in export | `tar -tzf … \| head` SIGPIPE under `pipefail` (>30 files) | tolerate the broken pipe (`… \| head -30 \|\| true`) |
| `No such file or directory: …/config.json.template` after a wipe | Over-eager cleanup deleted repo-tracked templates in `configs/` | Wipe only the docker **volumes** (`down -v`), never `configs/` — it holds tracked `*.template` |

### Cross-run state coupling (important)

Preserving volumes for cert reuse **couples runs**: `moav_state` keeps `.bootstrapped` + keys, so a
re-bootstrap can skip regenerating host configs and leave `user add` with nothing — intermittently.
Rule of thumb: only DOMAIN runs keep state (they need the cert); **domainless/full runs start from a
clean slate** (`docker compose --profile all down -v` — volumes only). Known open follow-up:
re-bootstrap on existing state doesn't reliably regenerate host configs — a real `bootstrap.sh` bug
worth fixing so 2nd+ domain runs are repeatable.

## Client round-trip (moav-client — Epic 5, planned)

Server-side e2e is done. The client analogue is not built yet: provision a user on the server,
import the bundle into `MotherofallVPNs/moav-client`, connect per protocol, verify the exit IP, and
diff against the server's expected matrix. `moav-client` already has Go unit tests + CI
(`go test -race`, `tsc`+`vite build`, shellcheck); the gap is the live round-trip. Wire it here when
Epic 5 starts, sharing this file's result-interpretation + failure-mode tables.
