# End-to-End Testing (self-hosted runner)

> **Using Claude Code?** The `moav-e2e` skill (`.claude/skills/moav-e2e/`) is an
> agent-facing runbook for this: how to trigger/watch the workflow, read the
> pass/warn/skip/fail matrix, and a table of known failure modes → fixes. This
> page is the human setup guide.


`moav test` (`tests/client-test.sh`) verifies real connectivity through each
protocol by standing up client-side tunnels against a **live** MoaV server and
checking the exit IP. The per-PR CI (`.github/workflows/ci.yml`) only lints and
unit-tests — it never brings the stack up. Full e2e is a separate workflow
(`.github/workflows/e2e.yml`) that runs on a **self-hosted runner**, because it:

- builds ~25 container images,
- needs a **real domain + Let's Encrypt certs** for the TLS protocols (Trojan,
  Hysteria2, AnyTLS, CDN), which a stock GitHub-hosted runner can't provide, and
- exercises UDP/QUIC/DNS transports that ephemeral CI networks block.

It runs **manually** (`workflow_dispatch`) and **on each published release**.
(A nightly `schedule` trigger is available but disabled by default — re-add the
`schedule:` block to `e2e.yml` to enable it.) GitHub-hosted runners are
intentionally not used.

> **The workflow must live on the repo's *default* branch** (`main`) for GitHub
> to show "Run workflow" and to fire the `release`/`schedule` triggers — that's
> a GitHub rule for `workflow_dispatch`. When you dispatch it, pick the branch
> to test (e.g. `dev`) as the ref; `actions/checkout` runs that branch's code.

---

## What you need

- A **dedicated test VPS** you can wipe freely, with **no other MoaV install on
  it** — the e2e job binds the standard MoaV host ports and would collide with a
  running stack. **≥ 2 vCPU / 4 GB RAM** (it builds ~25 images, several compiled
  from Go — 1 GB will OOM).
- **Docker + Docker Compose installed on the VPS.** The e2e job runs
  `moav build`/`docker compose` directly on the runner; **it does not install
  Docker for you** — that's a host prerequisite (see step 0 below).
- A **test domain** with DNS pointing at that VPS (A record, plus the DNS-tunnel
  NS records if you want those protocols to pass — see [DNS.md](../DNS.md)).
- Admin access to the GitHub repo (to add a runner + secrets).

> Use a **dedicated throwaway domain**, not your production `moav.sh` — the e2e
> run issues real certs and reconfigures the whole stack.

---

## 0. Install Docker (prerequisite)

The e2e job needs Docker on the runner, and the `docker` group must exist
**before** you add the runner user to it. On a fresh Ubuntu box:

```bash
# as root
curl -fsSL https://get.docker.com | sh      # installs Docker + the compose plugin
docker --version && docker compose version  # verify both
```

If you skip this you'll see `usermod: group 'docker' does not exist` in the next
step — that means Docker isn't installed, not that the e2e run will install it.

## 1. Register the self-hosted runner

### Permissions

- To reach **repo → Settings → Actions → Runners → New self-hosted runner** you
  need **Admin** on the repo. That page shows a **registration token** —
  auto-generated, scoped to registering one runner, and it **expires in ~1 hour**.
  You don't create or manage this token yourself; generate a fresh one right
  before you run `./config.sh`. (If you script registration via the API instead,
  a PAT with the `repo` scope can mint a registration token — but the UI is
  simpler.)

### Do NOT run as root

The runner's `./config.sh` **refuses to run as root or under `sudo`**
(`Must not run with sudo`). If you're logged in as `root`, create a dedicated
non-root user first — it needs Docker access (the e2e job builds/starts the
stack) and passwordless `sudo` (moav's host-side steps occasionally call it):

```bash
# as root
adduser --disabled-password --gecos "" gh-runner
usermod -aG docker gh-runner
echo 'gh-runner ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/gh-runner
```

### Download + configure

Get the latest runner version from
<https://github.com/actions/runner/releases/latest> (the "New self-hosted
runner" page also prints the exact current commands). Then, **as the non-root
user**:

```bash
su - gh-runner                       # NOT root, NO sudo for config.sh
mkdir -p ~/actions-runner && cd ~/actions-runner
curl -o actions-runner-linux-x64.tar.gz -L \
  https://github.com/actions/runner/releases/download/vX.Y.Z/actions-runner-linux-x64-X.Y.Z.tar.gz
tar xzf actions-runner-linux-x64.tar.gz

# configure — IMPORTANT: add the `moav-e2e` label the workflow targets.
# Use a FRESH token (the UI one expires in ~1h).
./config.sh --url https://github.com/MotherofallVPNs/moav \
  --token <FRESH_REGISTRATION_TOKEN> \
  --labels moav-e2e \
  --name moav-e2e-vps
```

The workflow selects this runner via `runs-on: [self-hosted, moav-e2e]`, so the
`moav-e2e` label is required.

> Escape hatch: `RUNNER_ALLOW_RUNASROOT=1 ./config.sh ...` lets it configure as
> root, but running Actions as root is discouraged — prefer the dedicated user.

### Reclaim-workspace pre-job hook (REQUIRED for repeat runs)

MoaV's containers run as root and write root-owned files into the bind-mounted
host dirs (`configs/`, `state/`, `outputs/`). The runner user can't delete those,
so the **next** run's `actions/checkout` fails to clean the workspace
(`Error: EACCES: permission denied, rmdir .../configs/amneziawg`). The e2e job's
teardown chowns the workspace back, but that only helps if a run *reaches*
teardown — a run that fails or is cancelled early leaves the mess, and the next
checkout then can't self-heal.

The robust fix is a **pre-job hook** that reclaims ownership *before* checkout,
every job. Set it up once:

```bash
cat > /home/gh-runner/reclaim-workspace.sh <<'EOF'
#!/bin/bash
sudo chown -R "$(id -u):$(id -g)" "$HOME/actions-runner/_work" 2>/dev/null || true
EOF
chmod +x /home/gh-runner/reclaim-workspace.sh

grep -q ACTIONS_RUNNER_HOOK_JOB_STARTED /home/gh-runner/actions-runner/.env \
  || echo 'ACTIONS_RUNNER_HOOK_JOB_STARTED=/home/gh-runner/reclaim-workspace.sh' \
       >> /home/gh-runner/actions-runner/.env
```

(The hook relies on the runner user's passwordless `sudo`, set up above.) Restart
the service after adding it so it picks up the new `.env`.

### Run it as a service (survives reboots)

Unlike `config.sh`, the service installer **does** use `sudo`, and takes the
runner's username so the service runs as that user:

```bash
sudo ./svc.sh install gh-runner
sudo ./svc.sh start
sudo ./svc.sh status
```

Verify the runner shows up **Idle** under Settings → Actions → Runners, then
trigger the workflow (§3).

---

## 2. Add the repo secrets

**repo → Settings → Secrets and variables → Actions → New repository secret:**

| Secret | Value |
|---|---|
| `E2E_DOMAIN` | the test domain (e.g. `test.example.com`) |
| `E2E_ACME_EMAIL` | email for Let's Encrypt on the test domain |
| `E2E_ADMIN_PASSWORD` | any strong password (the run sets it in `.env`) |
| `E2E_SERVER_IP` | *(optional)* the VPS public IP; auto-detected if omitted |

The workflow writes these into a fresh `.env` (copied from `.env.example`) and
sets `INITIAL_USERS=1` + `DEFAULT_PROFILES=all` (`INITIAL_USERS` is a **count**,
not a name; the run then adds a named `e2e-test` user to also exercise
`moav user add`).

---

## 3. Run it

- **Manually:** repo → **Actions → e2e → Run workflow**, choose the branch to
  test (e.g. `dev`), then optionally tick the inputs below. The recommended way
  to validate a branch before release. If you don't see "e2e" in the Actions
  list, the workflow isn't on the **default branch** yet (see the note at the top).
- **On release:** fires automatically when a GitHub Release is published.
- **Nightly:** disabled by default (re-add the `schedule:` block to enable).

**Run inputs:**

| Input | Effect |
|---|---|
| `verbose` | Per-protocol debug output from `client-test.sh` (`-v`). |
| `domainless` | **No DOMAIN / no cert** — certbot self-skips, so this **never touches the Let's Encrypt rate limit**. Runs the IP-only protocols (Reality, XHTTP, Shadowsocks, WireGuard…) and still builds the client image, so it's the fast way to validate everything *except* the TLS-domain protocols. Needs no `E2E_DOMAIN`/`E2E_ACME_EMAIL`. |
| `full` | Also runs `build --local` (monitoring images from source), a second **domainless** phase after the domain phase, and `uninstall --wipe --remove-images` on teardown. Much slower, and it **does** re-issue a cert (see below). |

**Cert reuse & the LE rate limit.** Let's Encrypt allows only **5 certs/week per
exact domain**. A standard (domain) run therefore **keeps the `moav_certs`
volume** on teardown (`uninstall --yes`, `down` without `-v`), so the next run
reuses the existing cert instead of re-issuing — you can run it many times a day.
Only `full` runs wipe the volume (fresh issuance); don't run `full` more than a
few times a week against the same domain or you'll hit the limit
("*too many certificates … retry after …*"). If you do get blocked, use
`domainless` to keep testing in the meantime.

The **e2e-results** artifact (JSON + raw log) is attached to every run. The job
fails if any protocol reports `fail`; `warn`/`skip` (e.g. an unconfigured
DNS-tunnel NS record, or IPv6 unavailable) do not fail the build.

---

## Running e2e by hand (no CI)

You can reproduce exactly what the workflow does directly on the test VPS:

```bash
git clone https://github.com/MotherofallVPNs/moav && cd moav
cp .env.example .env
# edit .env: set DOMAIN, ACME_EMAIL, ADMIN_PASSWORD, SERVER_IP,
#            INITIAL_USERS=1, DEFAULT_PROFILES=all
#            (leave DOMAIN empty to reproduce a domainless run — no cert)

./moav.sh build
./moav.sh bootstrap        # generates keys, obtains certs, creates the user
./moav.sh start all
sleep 45                   # let services settle

./moav.sh test e2e-test          # human-readable results
./moav.sh test e2e-test --json   # machine-readable (what CI evaluates)

./moav.sh stop                   # teardown
```

Add `-v` to `moav test` for per-protocol debug output when a protocol fails.

---

## Interpreting results

`moav test` reports one of `pass` / `warn` / `skip` / `fail` per protocol:

- **pass** — connected and confirmed a real exit IP.
- **warn** — reachable but not fully confirmed (e.g. XDNS over a throttled
  resolver, or an IPv6-only config on an IPv4-only path). Does not fail CI.
- **skip** — the protocol isn't in the bundle, or a required client binary
  isn't present. Does not fail CI.
- **fail** — a protocol that should work didn't. **Fails CI.**

If a DNS-tunnel protocol (dnstt/Slipstream/MasterDNS/XDNS) warns or fails,
first check the NS delegation for its subdomain (`moav doctor dns`) and that the
resolver in the bundle is reachable from the runner — DNS tunnels are the most
environment-sensitive transports.
