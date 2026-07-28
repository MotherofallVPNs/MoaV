# v2 Refactor Plan (Epic 3)

Code-quality refactor for v2.0.0: kill provisioning duplication, decompose the
`moav.sh` monolith, unify config loading, complete strict-mode coverage, and run
an adversarial security/edge-case pass. Everything here is **behaviour-preserving
and e2e-gated** — the green domain e2e (`readme` + per-protocol exit-IP checks),
the share-link golden test (`tests/singbox-links-test.sh`), and the CLI smoke test
(`tests/cli-smoke-test.sh`) are the regression net that makes this safe to do
incrementally. One workstream/PR at a time, lowest-risk first, accumulating on
`dev` toward v2.0.0.

**Principle:** no PR changes generated output or CLI behaviour. Where a refactor
*could* change behaviour (config load order — Workstream C), gate it behind a
parallel-run diff before deleting the old path.

---

## Workstream A — Provisioning unification

**Problem.** Two parallel provisioning stacks, built independently, hand-synced
ever since — the source of the SS/XHTTP placeholder gap, the CRLF-key bug, and the
subscription-coupling bug this cycle.

Originally (v1.9.x), the two stacks looked like this — the state the estimates
below were made against:

```
moav user add NAME            [HOST]         moav bootstrap / regenerate / donate  [CONTAINER]
  scripts/user-add.sh                          scripts/generate-user.sh
    ├ singbox-user-add.sh                         ├ lib/{wireguard,amneziawg,dnstt,…}
    ├ wg-user-add.sh (ignored lib/wireguard.sh)    ├ lib/sing-box.sh (links)
    ├ <inline> AmneziaWG (dup of lib)              └ <inline> reality/trojan/…/xhttp/xdns
    ├ <inline> dns-family text (dup of libs)
    └ <inline> README.html + subscription.txt      └ <inline> README.html + subscription.txt
```

(`scripts/generate-single-user.sh` was a third, **orphaned** copy of the container
driver — no callers, not mounted by compose, not `COPY`'d into the image, so it
could never run. Deleted in A7b. The container entry point is `generate-user.sh`,
called by `bootstrap.sh` and `moav regenerate-users`.)

Most `<inline>` markers above are now retired: A1 (keys), A2 (dns-family text),
A3+A3b (WG/AWG allocation **and** client-config rendering), A4 (server-config
mutation), A5 (README + subscription), A6 (XHTTP/XDNS).

~**1,100–1,300 duplicated lines**. The two README renders (~290 ln each), XDNS
(~150), host WG (~180) / AWG (~160), the dns-family instruction text (~200),
trusttunnel (~65), XHTTP (~45), plus 3 copies of every sing-box `jq` server
mutation and **5** key-gen implementations (4 patched for CRLF, 1 lib copy not).

**Target.** One provisioning library, each concern single-source; both entry
points become thin "mutate server config (lib) → render bundle (lib)" drivers.

**Sequenced PRs** (lowest-risk first; each verified by the test in its row):

| PR | Scope | Retires | Verify |
|----|-------|---------|--------|
| **A1** | `lib/keys.sh`: one CRLF-safe `wg_keypair()` + `gen_uuid/gen_password/ss_psk`. Replace all 5 key-gen sites + the 2 bare `lib/{wireguard,amneziawg}.sh` copies. | **CRLF bug class** | cli-smoke `user add`; e2e wireguard/amneziawg (fail on 45-char key) |
| **A2** | Route host `user-add.sh` dns-family text (dnstt/slipstream/masterdns/gooserelay/telemt, `459-718`) through the existing `lib/*_generate_client_instructions`. −~200 ln. | host↔container text drift | e2e dnstt/slipstream/masterdns/telemt + `test_readme_bundle` |
| **A3 + A3b (done)** | **A3:** unified the peer-IP allocator across all four WG/AWG sites onto `net_next_free_octet` (config scan ∪ live-interface octets, max+1) — fixed the lib count+1 collision bug (26 WG/28 AWG dupes on a live server); `net-alloc-test.sh` unit + isolation harness on live configs. **A3b:** both host paths now render client configs via the libs — `wg-user-add.sh` → `wireguard_generate_client_config`, the `user-add.sh` AmneziaWG block → `amneziawg_generate_client_config` (byte-equivalence proven for all five `.conf`); the redundant instruction `.txt` were dropped in favour of README.html, host WG gained `MTU`, and the AWG obfuscation params are read from the `awg0.conf` header on both paths. No inline WG/AWG conf templates remain in the host scripts. | WG/AWG triple-impl ✅ | e2e wireguard/wstunnel/amneziawg |
| **A4 (done)** | One canonical sing-box/xray server-config `jq` mutation: `singbox_add_user` (lib/sing-box.sh) + new `lib/xray.sh` `xray_add_user`, based on sync.sh's dual-dedup + field-adaptive form. Rewired the live sites (sync.sh reconcile + host singbox-user-add.sh); removed the dead lib helpers. `generate-single-user.sh`'s orphan copy left for A7. Verified: golden links test + isolation harness on a live 146-user config (0-change convergence = byte-identical to old output; drop+re-add reproduces membership incl SS). | srv-mutation drift | e2e per-protocol reachability; golden links test |
| **A5 ⭐** | `lib/bundle-readme.sh`: `render_bundle_readme <bundle> <key_src>` + **unconditional** `write_subscription <bundle>`. Delete both ~290-ln inline blocks. | **SS/XHTTP placeholder gap + subscription coupling** | `test_readme_bundle` (a: no leftover `{{}}`, b: every enabled link rendered) + new "subscription.txt exists after no-op regenerate" smoke check |
| **A6 (done)** | `lib/xray.sh`: `xray_write_xhttp_bundle` + `xray_write_xdns_bundle` (+ `xray_xdns_finalmask` python helper). Host + container both call them; container form canonical (byte-identical), host XDNS reconciled up to it (gains XDNS_METHOD + uuid fallback). −194 ln. Verified byte-equivalence harness (old container code vs new fns: all 5 emitted files identical) + golden links test. `generate-single-user.sh`'s dead XHTTP copy left for A7. Stacks on A4. | XHTTP/XDNS dup | e2e xhttp/xdns + `test_readme_bundle` |
| **A7 (RESCOPED — done)** | ~~Collapse `user-add.sh` + `generate-single-user.sh` into one driver behind a host/container flag~~ — **premise falsified, see below.** Shipped as four independent low-risk PRs, each e2e-gated: **A7a** fixed `--package` shipping an unrendered guide (26 raw placeholders) + guarded missing `zip` + added the first `--package` test coverage; **A7b** deleted the unrunnable `generate-single-user.sh` (−311) + corrected the docs that described it as live; **A7c** new `lib/trusttunnel.sh` — fixed `has_ipv6` emitting invalid TOML on dual-stack servers (and the host's hardcoded `false`), + a real TOML-parse gate in the e2e; **A7d** wired the host AmneziaWG block to `amneziawg_add_peer` (its `extra_used` param existed for this caller and had never been used), gaining idempotency. Three user-facing bugs fixed; the two-driver split kept deliberately. | the remaining real duplication ✅ | full e2e + cli-smoke |
| **A8 (done)** | One shared "materialize every user" path: `scripts/lib/provision.sh` `provision_all_users [force]` (mirror host state → per-user bundles → reconcile), called by **both** `bootstrap.sh` and `moav regenerate-users`. Retires the divergent `set -e` contract that caused two incidents (bootstrap aborted mid-reconcile where regenerate-users survived): every step is individually guarded, so behaviour is identical with or without `set -e` and the reconcile always runs. `regenerate-users` collapses from one `docker compose run` per user (~50 `-e` vars each) plus a separate reconcile run into a single run. Verified by running the real function in both shell modes against a seeded failing user + a credential-less user: identical output, reconcile reached in both. | bootstrap↔regenerate drift; divergent set-e contract ✅ | e2e: bootstrap **and** regenerate-users both yield reconciled configs (`tests/assert-users-reconciled.sh`); re-bootstrap on a many-user state never aborts |

**Highest ROI = A5** (retires 2 of 3 drift classes, largest single block, fully
machine-checked by `test_readme_bundle`). **A1 first** (near-zero risk, spans the
most files, retires the CRLF class).

### Why A7 was rescoped (survey, 2026-07-26)

The original A7 assumed the two entry points "differ only in paths + reload
strategy". After A1–A6 + A3b that is no longer true — and the survey showed it was
never quite true:

- `scripts/user-add.sh` (~610 ln) **generates** credentials, mutates six server
  configs, hot-reloads services, and owns batch / `--package` / donate mode plus
  the failure summary. It runs under three privilege models (CLI root, sudo user,
  unprivileged `moav` in the admin container against a `:ro` `/project`).
- `scripts/generate-user.sh` (~656 ln) **reads existing state only** (hard-exits if
  `credentials.env` is absent), creates no credentials, never touches
  sing-box/xray/trusttunnel/telemt server config, never reloads, and is
  force-idempotent per artifact for re-runs.
- Directly between the two, essentially **nothing** is still duplicated. The real
  remaining duplication sits in *sibling* files (trusttunnel client artifacts → A7c;
  the inline AmneziaWG peer-add → A7d).
- The two also carry **incompatible `set -e` contracts** — `user-add.sh` wraps each
  service in `if …`/subshells so one protocol failing is non-fatal; `generate-user.sh`
  fails fast and lets its callers absorb it.
- And `admin/main.py` **screen-scrapes `user-add.sh`'s stdout** (it regex-matches the
  `User '<name>' created` line to discover results), so the host driver's output is a
  load-bearing interface, not just logging.

Merging them would mean a `if [[ $MODE == host ]]` maze across credentials, server
mutation, reload, packaging, batch, donate, privilege handling and two error models —
for almost no line reduction, while six callers depend on the current behaviour. The
split is a genuine responsibility boundary (**mutate + reload** vs **render from
state**), so it is kept deliberately; A7 instead retires the duplication that is
actually left.

---

## Workstream B — `moav.sh` decomposition

**Problem.** 9,469 lines, 179 top-level functions, pure monolith (sources nothing).

**Target.** A new **top-level `lib/`** (distinct from `scripts/lib/`, which holds
protocol generators). Dispatcher `moav.sh` → **~200–260 lines**: globals +
`SCRIPT_DIR` + `$0` symlink resolution + `source lib/*.sh` + `main()` case +
`main "$@"`. Because modules are *sourced* (not sub-shelled), the `case` dispatch
never changes — only function definitions relocate.

**Modules** (~14): `common` (foundation, first) · `install` · `update` ·
`bootstrap` · `dns` · `nettune` · `doctor` (after nettune) · `service` (start/
stop/status/logs/profiles/clash) · `build` · `users` · `donate` · `migrate` ·
`schedulers` · `menu` (last — reaches everywhere).

**Hard constraints.** `SCRIPT_DIR` (used 126×) + `VERSION` (59×) + state globals
stay in the dispatcher/`common`, set **before** any source. `$0`/`BASH_SOURCE`
symlink resolution stays in the entrypoint (a lib's `BASH_SOURCE` points at the
lib). Source order: `common` first → `nettune` before `doctor` → `menu` last
(it calls into service/donate/doctor/admin/update/build/users).

**Sequenced PRs** (each: `bash -n` + `shellcheck --severity=error` + cli-smoke +
`moav <subcmd>` dispatch spot-check):

- **B0** ✅ — `lib/common.sh` + source scaffolding (17 fns). Establishes the pattern.
- **B1–B6** ✅ — `nettune`, `donate`, `cert`, `migrate`, `dns`, `update`. (`schedulers` was not a separate block in the end; `cert` took its slot.)
- **B7–B11** ✅ — `install`, `bootstrap`, `users`, `build`, `doctor`.
- **B12** ✅ — `service` (1,572 ln, densest, most-called — deferred as planned).
- **B13** ✅ — `menu` + misc `cmd_check/conduit/admin/user base64/test/client/usage` (**last**, as planned).
- **(bonus)** ✅ — `lib/peers.sh`: WG/AWG duplicate-peer-IP detection + repair (`moav doctor peers [--fix]`), added mid-stream in response to a live bug.
- **(optional, NOT done) B*** — extract a `compose()` wrapper into `common`. **Surveyed; premise is partly false — see below. Do not start this on the original description.**

### `compose()` wrapper — survey before starting (do not skip this)

The plan described "100+ inlined `docker compose` calls with ad-hoc
`--profile`/`sudo`" and called it the highest-leverage reduction item. Measured
on `dev`:

| | count |
|---|---|
| `docker compose` call sites | 149 |
| …using `sudo` | **0** |
| …using `--profile` | 29 (16 of them literally `--profile all`) |
| …using `-f`/`--file` | 6 |
| …ending in `2>/dev/null` | 37 |
| existing `compose()` wrapper | none |

**The `sudo` half of the premise is simply wrong** — no compose call uses it.
The rest are heterogeneous (`ps`, `exec`, `restart`, `up`, `run`, `logs`, each
with different flags, redirections and error handling), so a blanket wrapper
buys indirection more than it buys reduction. The genuinely repeated fragments
are narrow: `--profile all` (16) and `-f` handling (6).

**Revised recommendation:** skip the blanket wrapper. If it is done at all,
scope it to a `compose_all()` helper for the 16 `--profile all` sites, which is
mechanical and safe.

### `sudo` detection — also smaller than it looks

Four copies of the idiom exist (`_root_prefix()` in `moav.sh`, three inline in
`lib/nettune.sh`), but they are **not interchangeable**:

- `_root_prefix()` and `lib/nettune.sh:21` are best-effort — no sudo, return
  empty, let the privileged operation fail on its own.
- `lib/nettune.sh:83` and `:119` deliberately **error and `return 1`** when sudo
  is missing, with a specific message naming the file they cannot write.

Consolidating all four onto `_root_prefix()` would delete those two error paths
and replace a clear message with a later, vaguer failure. If unified, it needs
*two* helpers (best-effort and must-have), which is close to break-even on line
count. Left alone deliberately.

**General lesson from both surveys:** the reduction estimates in this plan were
made by grepping for a pattern, not by reading the call sites. Re-measure before
committing to any remaining reduction item.

**Outcome.** `moav.sh` **9,483 → 1,038 lines (−89%)**, a dispatcher over fifteen
modules: `common · nettune · donate · cert · peers · migrate · dns · update ·
install · bootstrap · users · build · doctor · service · menu` (8,833 lines in
`lib/`).

**Honest accounting.** Workstream B is *relocation, not deletion* — the repo
total is roughly flat. Genuine net reduction in this sprint came from
Workstream A (~1,000 lines) plus B4's dead `get_cdn_url`. If code reduction is
the goal, the remaining levers are the `compose()` wrapper above and a second
A-style dedup pass, not further decomposition.

**Method used for every B PR** (worth reusing): function count conserved across
`moav.sh` + `lib/*.sh`; zero duplicate definitions (catches a module left
defined in both places — this happened once, after a hunk-wise merge
resolution); affected subcommands diffed **byte-for-byte including exit codes**
against a clean worktree of the base, normalising the banner's
`v<version> (<branch>)` line; full e2e before merge. When a base branch is
squash-merged, **replay** the extraction on the new base rather than resolving
conflicts hunk-wise.

---

## Workstream C — Unified config loader (`lib/env.sh`)

**Problem.** Four coexisting config-load patterns: wholesale `source .env`;
`source state/keys/*.env`; ~40 ad-hoc `grep '^VAR=' .env | cut | tr` copies (with
subtle `tr` variance); and nested triple-fallback `${VAR:-$(grep… || echo DEF)}`.
Same var gets **two authored defaults** in two mechanisms (`PORT_SS`, `SS_METHOD`,
`CDN_TRANSPORT` — the latter defaults to `ws` in one path and empty in another).
State-vs-`.env` precedence is unspecified and **load-order-dependent** → the
Reality short_id desync bug class (an empty injected `.env`/compose var shadows the
authoritative `state/keys/reality.env` value, silently breaking every client). The
current fix is a defensive "re-source state right before render" hack.

**Target `lib/env.sh`:** `moav_load_config` (state-wins-when-nonempty),
`moav_get VAR [default]` (one accessor, one quote rule), `moav_load_keys` /
`moav_load_user <id>`, and a **single defaults table** validated against
`.env.example`. Precedence baked in: **state(nonempty) > .env(nonempty) >
compiled default** — which makes the "re-source before render" hack unnecessary
(emptiness can never shadow).

**Provable-equivalence gate (this is the risk):** load order changes behaviour, so
(1) snapshot the fully-resolved env (`env | sort` at each render point) for a
bootstrap + user-add run as golden files; (2) land `lib/env.sh` **in parallel** and
`diff` resolved values against the old path before deleting it; (3) the only
legitimate diffs are the empty-shadow cases — i.e. the bug — and they are the
regression guard (should appear only for short_id-class vars).

PRs: **C1** — introduce `lib/env.sh` + `moav_get` accessor, migrate the ~40
`grep .env` sites (mechanical, no order change). **C2** — migrate the `source .env`
+ state-sourcing sites to the state-wins loader behind the golden-diff gate; drop
the re-source hack. Interacts with Workstream A (the provisioning scripts are the
heaviest state/`.env` consumers) — sequence C after A4 or coordinate.

---

## Workstream D — `set -euo pipefail` hardening

Most scripts already have full strict mode; `scripts/lib/*.sh` intentionally omit
it (sourced → inherit the caller). The gap is the **container entrypoints** that
run under `sh`/bare `set -e`. Fix the landmines first, then add flags.

**Needs work (fix landmines → add `-uo pipefail`):**
- **Breaks today:** `amneziawg-entrypoint.sh`, `wireguard-entrypoint.sh` — `grep KEY file | head -1 | cut` config-scrapers return nonzero when a key is legitimately absent (add `|| true`/`|| echo ""`); `-u` breaks optional AWG params.
- **Risky:** `sing-box`, `snowflake`, `admin`, `grafana`, `grafana-proxy`, `wstunnel`, `conduit`, `dnstt`, `trusttunnel`, `xray` entrypoints — `cmd | head` SIGPIPE under pipefail; optional `${VAR}` reads break under `-u` (esp. the `/bin/sh` ones).
- **Keep as-is:** `conduit-offsets-watch.sh` (`set -uo` without `-e` on purpose — a daemon loop shouldn't die on a transient failure).

**Landmine classes:** (1) `grep -c … || echo 0` / `grep KEY | head -1 | cut`
scrapers; (2) `cmd | head -N` SIGPIPE; (3) optional `${VAR}` under `-u`. No
`((x++))` 0→1 traps in the unset entrypoints (verify in `moav.sh` separately).

PR: **D1** — harden the ~8 entrypoints (guard scrapers, quote/guard optional
reads), then add strict mode. Verify via the compose-up smoke + e2e (every service
must still start and pass its protocol check).

---

## Workstream E — Security / edge-case review

Run as an **adversarial review pass** (dedicated code-review agent) against the
concentrated targets, then land fixes as small PRs. Several overlap Epic 4
(`&hardened` anchor / grafana-root) — coordinate so a fix lands once.

**High:**
- `docker-compose.yml` grafana `user:"0"` + no `read_only`/`no-new-privileges` — root, wide blast radius *(overlaps E4 `&hardened`)*.
- `GF_SECURITY_ADMIN_PASSWORD=${ADMIN_PASSWORD}` in env → visible via `docker inspect`; same var reused for Grafana + admin.
- `docker-proxy` with `POST=1 EXEC=1` → host-root-equivalent if admin is compromised; audit the auth in front of it.
- `admin/main.py` HTTP-Basic `verify_auth` is the sole gate for user-create/download/donate — review brute-force/rate-limit + TLS enforcement (empty-password fail-closed already handled).
- `bootstrap.sh` writes `state/keys/*.env` (reality private key, clash secret, hy2 obfs) with **no `chmod 600`**; `chmod -R g+r /configs /outputs` makes client bundles (per-user keys) group-readable.

**Medium:**
- `admin/main.py:895` request-body `protocols` flows into `DONATE_ONLY_PROTOCOLS` env (shell-consumed) **without the whitelist validation** that `prefix` gets — confirm no token/flag injection.
- `moav.sh:289` `eval "$cmd"` — confirm no user/state data reaches `$cmd`.
- secrets appended to `.env` / read via `docker run alpine cat` — audit perms + no `set -x` leak.
- `snowflake-entrypoint.sh` unquoted `${RATE_KBIT}` in a privileged `tc`.

**Positives (record, don't touch):** username regex `^[A-Za-z0-9_-]+$` enforced on
both Python + shell sides; download path-traversal guard; most services already
`no-new-privileges` + `read_only` + `cap_drop`; Reality "state wins" hardening in place.
*(Verify no entrypoint bypasses the username regex when invoked directly.)*

PRs: **E1** — key/bundle perms (`chmod 600` state keys, tighten bundle perms).
**E2** — validate the `protocols` input + audit secret-in-env exposure. **E3** —
grafana non-root + secret handling *(with E4)*. Review pass produces the exact list.

---

## Cross-workstream sequencing

1. ✅ **A1** (keys) + **B0/B1** (common + nettune) — warm-ups, established the lib pattern for both trees.
2. ✅ **A5 ⭐** (bundle-readme) — earliest big win; retired the most bug risk.
3. ✅ **A2–A4, A6** (provisioning dedup) interleaved with **B2–B11** — independent files, as planned.
4. ⬜ **C** (env loader) — next up. A4 is done, so the heaviest consumers are stabilised.
5. 🔄 **D** (strict mode) + ⬜ **E** (security fixes) — D in progress; three concrete defects already logged (below).
6. ✅ **A7** (collapse entry points) + **B12–B13** (service/menu) — done last, as planned.
7. ⬜ Cut **v2.0.0** once C/D/E close. **v2.0.0-rc.1** is published.

### D — DONE. Audit pass + three fix PRs.

| # | Defect | Trigger | Outcome |
|---|---|---|---|
| 1 | `REALITY_PUBLIC_KEY: unbound variable` — **every user fails to regenerate** | `ENABLE_REALITY=false` (XHTTP is Reality-over-xhttp and defaults on) | ✅ D1 |
| 2 | `client_public_key` — empty key silently written (bash 3.2) / hard crash (bash ≥ 4) | `wireguard_add_peer` / `amneziawg_add_peer` when keygen fails | ✅ D1 |
| 3 | `moav user add` dies **silently** | `grep\|cut` under `pipefail` when the Reality volume read is empty | ✅ D1 |
| 4 | `declare -A` requires bash ≥ 4 | any `moav` run on stock macOS (bash 3.2) | ✅ D2 |
| 5 | `--tail` / `-b` with no value → `$2: unbound variable` | `moav logs --tail`, `moav update -b` | ✅ D2 |
| 6 | truncated per-user WG/AWG state file wedges that user permanently | a prior run died between `mkdir` and the key write | ✅ D3 |
| 7 | empty-array expansion `"${arr[@]}"` on bash ≤ 4.3 | RHEL/CentOS 7 (bash 4.2) — `moav start`, `moav build` | ⛔ **declined** |
| 8 | bare `${DOMAIN}` / `${SERVER_IP}` in bundle generators | a hand-written `.env` missing the key entirely | ⛔ **declined** |

**Why 7 is declined:** README.md:245 supports Debian 12 / Ubuntu 22.04/24.04,
which ship bash 5.x. RHEL 7 (bash 4.2) is EOL. Revisit only if an older distro
enters scope.

**Why 8 is declined:** not reachable from any first-party path — `.env.example`
always defines both keys, and `docker-compose.yml` supplies them in-container.
More importantly the obvious fix is wrong: `${DOMAIN:-}` would trade a loud
crash for a **silently broken client bundle**. If touched, it should become a
required-value assertion, not a default.

**Where the risk was, and wasn't.** `lib/*.sh` and `moav.sh` came out clean —
185 `get_env_val` call sites, **zero** bare `.env` reads. All real exposure was
in `scripts/` and `scripts/lib/`.

**Recurring shape** behind defects 1–3 and 6: *a value is loaded conditionally*
(a `source` behind `[[ -f ]]`, or a paired `read` that can short-circuit) *and
then read unconditionally.* Worth grepping for on any new generator.

**Retracted:** an earlier entry claimed `moav doctor` dies with
`ENABLE_REALITY: unbound variable` when no `.env` is present. It does not
reproduce — every `ENABLE_*` read in `lib/doctor.sh` goes through
`get_env_val "<KEY>" "$env_file" "<default>"`. Logged in error or fixed earlier
in the sprint.

**Testing note worth keeping:** `set +e` cannot catch a `set -u` violation — the
shell exits outright. A test for this class must assert on *process survival*,
not on a return code. `tests/strict-mode-test.sh` (15 cases, wired into
`ci.yml`) does that, and every case in it was verified to **fail against
unfixed `dev`** — a test that passes everywhere proves nothing.

**Retracted:** an earlier entry here claimed `moav doctor` dies with
`ENABLE_REALITY: unbound variable` when no `.env` is present. The audit could not
reproduce it and neither could I — every `ENABLE_*` read in `lib/doctor.sh` goes
through `get_env_val "<KEY>" "$env_file" "<default>"`, and `doctor_check_env`
bails out cleanly when `.env` is missing. It was either fixed earlier in the
sprint or logged in error. Removed rather than left to send someone hunting.

**Where the risk actually lives.** `lib/*.sh` and `moav.sh` are clean: 185
`get_env_val` call sites and **zero** bare `.env`-sourced reads. The remaining
strict-mode exposure is concentrated in `scripts/` and `scripts/lib/`.

**Recurring shape** behind defects 1–3: *a value is loaded conditionally* (a
`source` behind `[[ -f ]]`, or a paired `read` that can short-circuit) *and then
read unconditionally.* The systemic guard is an explicit
`: "${VAR:?<remediation>}"` at the top of each generator, which turns an opaque
`unbound variable` into an actionable "run `moav bootstrap` first".

**Every PR:** `bash -n` + `shellcheck --severity=error` + the relevant e2e/golden/
smoke gate, behaviour-preserving, one concern at a time.
