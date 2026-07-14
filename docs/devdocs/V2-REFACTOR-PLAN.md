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

```
moav user add NAME            [HOST]         moav bootstrap / regenerate / donate  [CONTAINER]
  scripts/user-add.sh                          scripts/generate-single-user.sh
    ├ singbox-user-add.sh                         └ generate-user.sh
    ├ wg-user-add.sh (ignores lib/wireguard.sh)      ├ lib/{wireguard,amneziawg,dnstt,…}
    ├ <inline> AmneziaWG (dup of lib)                ├ lib/sing-box.sh (links)
    ├ <inline> dns-family text (dup of libs)         └ <inline> reality/trojan/…/xhttp/xdns
    └ <inline> README.html + subscription.txt        └ <inline> README.html + subscription.txt
```

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
| **A3** | Route host WG/AWG through `lib/wireguard.sh`/`lib/amneziawg.sh` (move the host live-IP-scan into the lib as a strategy). −~340 ln. | WG/AWG triple-impl | e2e wireguard/wstunnel/amneziawg |
| **A4** | One canonical sing-box/xray server-config `jq` mutation (`lib/sing-box.sh` + new `lib/xray.sh`); collapse the 3 divergent copies. | srv-mutation drift | e2e per-protocol reachability; golden links test |
| **A5 ⭐** | `lib/bundle-readme.sh`: `render_bundle_readme <bundle> <key_src>` + **unconditional** `write_subscription <bundle>`. Delete both ~290-ln inline blocks. | **SS/XHTTP placeholder gap + subscription coupling** | `test_readme_bundle` (a: no leftover `{{}}`, b: every enabled link rendered) + new "subscription.txt exists after no-op regenerate" smoke check |
| **A6** | `lib/xray.sh`: `xhttp_generate_client` + `xdns_generate_client` (incl. the duplicated embedded python). −~195 ln. | XHTTP/XDNS dup | e2e xhttp/xdns + `test_readme_bundle` |
| **A7** | Collapse `user-add.sh` + `generate-single-user.sh` into one driver behind a host/container flag (differs only in paths + reload strategy). **Last — touches orchestration/reload.** | the two-stacks split itself | full e2e + cli-smoke |
| **A8** | Split `bootstrap` vs `regenerate-users` responsibilities and share the provisioning/reconcile path. `bootstrap` should own **first-run infra only** (keys, certs, state init, config templates from `envsubst`) and then **delegate** "materialize every user into configs + bundles" to the *same* implementation `moav regenerate-users` calls — one code path, one shell-safety contract. Today they overlap and diverge: both regen bundles and both reconcile, but bootstrap runs the reconcile sourced under `set -euo pipefail` while regenerate runs it in a `docker … -c` shell **without** `set -e`. That divergence caused two prod incidents this cycle — the stale-volume orphan and the set-e silent bootstrap abort (bootstrap died exactly where regenerate-users survived). Builds on A4/A7 (shared server-mutation + single user driver). | bootstrap↔regenerate drift; divergent set-e contract | e2e: fresh bootstrap **and** `regenerate-users` both yield identical reconciled configs (`tests/assert-users-reconciled.sh`); re-bootstrap on a many-user + SS-less state never aborts |

**Highest ROI = A5** (retires 2 of 3 drift classes, largest single block, fully
machine-checked by `test_readme_bundle`). **A1 first** (near-zero risk, spans the
most files, retires the CRLF class).

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

- **B0** — `lib/common.sh` + source scaffolding (21 helpers + domain/env helpers). Establishes the pattern.
- **B1–B6** — self-contained/contiguous blocks, near-zero risk: `nettune`, `donate`, `schedulers`, `migrate`, `dns`, `update`.
- **B7–B11** — `install`, `doctor` (gated on nettune), `bootstrap`, `users`, `build`.
- **B12** — `service` (~1,500 ln, densest, most-called — deferred).
- **B13** — `menu` + misc `cmd_admin/test/client/check/profiles/usage` (**last**).
- **(optional) B*** — extract a `compose()` wrapper into `common` (100+ inlined `docker compose` calls with ad-hoc `--profile`/`sudo`). High-leverage; touches every service/build/doctor module — do as its own PR, either early (before B12) or fold into B12.

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

1. **A1** (keys) + **B0/B1** (common + nettune) — warm-ups, near-zero risk, establish the lib pattern for both trees.
2. **A5 ⭐** (bundle-readme) — earliest big win; retires the most bug risk.
3. **A2–A4, A6** (provisioning dedup) interleaved with **B2–B11** (moav.sh modules) — independent files, parallelisable.
4. **C** (env loader) after A4 — heaviest consumers stabilised first; golden-diff gated.
5. **D** (pipefail) + **E** (security fixes) — anytime; D pairs with the compose-up smoke, E with the review pass.
6. **A7** (collapse entry points) + **B12–B13** (service/menu) — last, highest-risk, after the net has proven the rest.
7. Cut **v2.0.0** once the tree is decomposed, deduplicated, and the security pass is closed.

**Every PR:** `bash -n` + `shellcheck --severity=error` + the relevant e2e/golden/
smoke gate, behaviour-preserving, one concern at a time.
