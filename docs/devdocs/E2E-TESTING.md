# End-to-End Testing (self-hosted runner)

`moav test` (`scripts/client-test.sh`) verifies real connectivity through each
protocol by standing up client-side tunnels against a **live** MoaV server and
checking the exit IP. The per-PR CI (`.github/workflows/ci.yml`) only lints and
unit-tests — it never brings the stack up. Full e2e is a separate workflow
(`.github/workflows/e2e.yml`) that runs on a **self-hosted runner**, because it:

- builds ~25 container images,
- needs a **real domain + Let's Encrypt certs** for the TLS protocols (Trojan,
  Hysteria2, AnyTLS, CDN), which a stock GitHub-hosted runner can't provide, and
- exercises UDP/QUIC/DNS transports that ephemeral CI networks block.

It runs **manually**, **on each published release**, and **nightly** (the
"overnight" run). GitHub-hosted runners are intentionally not used.

---

## What you need

- A **test VPS** you can wipe freely (a $5 box is fine; monitoring off).
- A **test domain** with DNS pointing at that VPS (A record, plus the DNS-tunnel
  NS records if you want those protocols to pass — see [DNS.md](../DNS.md)).
- Docker + Docker Compose on the VPS.
- Admin access to the GitHub repo (to add a runner + secrets).

> Use a **dedicated throwaway domain**, not your production `moav.sh` — the e2e
> run issues real certs and reconfigures the whole stack.

---

## 1. Register the self-hosted runner

On GitHub: **repo → Settings → Actions → Runners → New self-hosted runner**,
pick **Linux / x64**, and follow the shown commands on the VPS. They look like:

```bash
# on the test VPS, as a non-root user in the docker group
mkdir -p ~/actions-runner && cd ~/actions-runner
curl -o actions-runner-linux-x64.tar.gz -L \
  https://github.com/actions/runner/releases/download/vX.Y.Z/actions-runner-linux-x64-X.Y.Z.tar.gz
tar xzf actions-runner-linux-x64.tar.gz

# configure — IMPORTANT: add the `moav-e2e` label the workflow targets
./config.sh --url https://github.com/shayanb/MoaV \
  --token <TOKEN_FROM_GITHUB_UI> \
  --labels moav-e2e \
  --name moav-e2e-vps
```

The workflow selects this runner via `runs-on: [self-hosted, moav-e2e]`, so the
`moav-e2e` label is required.

### Run it as a service (survives reboots)

```bash
sudo ./svc.sh install
sudo ./svc.sh start
sudo ./svc.sh status
```

The runner user must be able to run Docker without sudo:
`sudo usermod -aG docker $USER` (re-login afterwards).

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
sets `INITIAL_USERS=e2e-test` + `DEFAULT_PROFILES=all`.

---

## 3. Run it

- **Manually:** repo → **Actions → e2e → Run workflow** (optionally tick
  *Verbose*). This is the recommended way to validate a branch before release.
- **On release:** fires automatically when a GitHub Release is published.
- **Nightly:** `03:00 UTC` via the `schedule` trigger.

The **e2e-results** artifact (JSON + raw log) is attached to every run. The job
fails if any protocol reports `fail`; `warn`/`skip` (e.g. an unconfigured
DNS-tunnel NS record, or IPv6 unavailable) do not fail the build.

---

## Running e2e by hand (no CI)

You can reproduce exactly what the workflow does directly on the test VPS:

```bash
git clone https://github.com/shayanb/MoaV && cd MoaV
cp .env.example .env
# edit .env: set DOMAIN, ACME_EMAIL, ADMIN_PASSWORD, SERVER_IP,
#            INITIAL_USERS=e2e-test, DEFAULT_PROFILES=all

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
