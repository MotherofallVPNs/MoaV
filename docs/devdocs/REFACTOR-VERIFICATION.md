# Refactor Verification Checklist

The mechanical gate every v2-refactor PR ran through. Written down so any
contributor — human or model, including cheaper models than the one that ran
the sprint — can follow it verbatim. **Every rule here exists because its
absence caused a real incident during the v2 sprint**; the incident is cited so
the rule doesn't decay into cargo cult.

Most of it is automated:

```bash
tests/refactor-verify.sh                    # static checks (also run by ci.yml)
tests/refactor-verify.sh compare origin/dev # + conservation & behaviour diff
```

## The rules

### 1. Everything parses, tests pass locally
`bash -n` every changed file; run `tests/strict-mode-test.sh` and
`tests/net-alloc-test.sh`. Automated by `refactor-verify.sh`.

### 2. No duplicate function definitions across `moav.sh` + `lib/*.sh`
A duplicate means an extraction left a copy behind — the sourced module
silently shadows the dispatcher copy or vice versa.
*Incident:* a hunk-wise merge resolution left the nettune block in **both**
files (11 shadowed functions); only this check caught it. Automated.

### 3. Behaviour diffs vs a clean worktree, byte-for-byte including exit codes
Compare affected subcommands against a `git worktree` of the base ref — never
against a stash or an in-place checkout.
*Incident:* a `git stash`-based harness swapped the untracked `.env` between
runs and manufactured a phantom regression.

Two hard sub-rules:
- **Non-mutating commands only.** Bare `moav` and `moav bootstrap --help` are
  not read-only — both create a `.env` in the clone. (Happened twice.)
- **Normalise the banner** (`v<ver> (<branch>)`): a detached worktree prints
  `(HEAD)` and the box padding shifts with branch-name length.

Automated for the common commands by `compare` mode.

### 4. Gate merges on BOTH `ci.yml` AND `e2e.yml`; verify the merge landed
Poll both workflows, and afterwards check `gh pr view N --json state` says
`MERGED` — never trust the merge call's exit status or your own script's
happy path.
*Incidents:* (a) a gate script echoed "#195 MERGED" unconditionally over a
merge-conflict error; (b) four D-series PRs merged over a **red CI** because
the gate polled e2e only. Both in one sprint.

### 5. On squash-merge conflicts: replay, don't resolve
When your base branch was squash-merged into dev, your branch's parents no
longer exist and the PR shows conflicts. **Re-apply the change onto fresh
`dev` and force-push** (`--force-with-lease`); do not resolve hunks.
*Incident:* hunk-wise resolution is what produced the duplicate-module bug in
rule 2. The replay for B13 came out byte-identical to the original — that
equality is itself a useful check.

### 6. A new test must fail on unfixed dev before it counts
Run the test against a clean worktree of pre-fix `dev` and watch it fail; then
watch it pass on your branch. A test that passes everywhere proves nothing.
*Incidents:* this rule caught a grep pattern being parsed as a grep option
(assertions silently vacuous) and a wrong helper name in a guard.

### 7. Bash tests run on bash 5 too, not just your shell
macOS ships bash 3.2 and its semantics differ in ways that matter
(`local x` unassigned reads as *set*; `declare -A` doesn't exist).

```bash
docker run --rm -v "$PWD":/r -w /r bash:5.2 bash tests/strict-mode-test.sh
```

*Incident:* the strict-mode control test enumerated only the 3.2 outcome and
a bare-read crash; CI's bash 5 produced a third outcome and **CI was red for
four merged PRs** before anyone noticed.

### 8. Verify in the environment the code actually runs in

Before editing anything that runs inside a container, establish **which image and
therefore which shell** it uses. Before changing file permissions, establish
**which user the process actually runs as**.

```bash
grep -m1 '^FROM' dockerfiles/Dockerfile.<svc>      # base image -> /bin/sh flavour
grep -nE 'USER|su-exec|setpriv|gosu' dockerfiles/Dockerfile.<svc> scripts/<svc>-entrypoint.sh
```

*Incidents, all in one sprint:*

- **`set -o pipefail` is fatal in dash.** `set` is a POSIX **special builtin**, so
  a failed `set -o pipefail` exits a non-interactive shell **immediately** —
  `|| true` never runs. dash (debian's `/bin/sh`) has no pipefail. Verified on
  alpine, where busybox ash *does* support it, so the guard never fired and it
  looked correct; on debian it killed the conduit container at line 3 with exit 2
  and **no output at all**. Portable form:
  ```sh
  if ( set -o pipefail 2>/dev/null ); then set -o pipefail; fi   # probe in a subshell
  ```
- **The compose `user:` field does not tell you who the process runs as.**
  Entrypoints drop privileges themselves — admin via `su-exec moav`, conduit via
  `setpriv --reuid=moav`. Reading the compose field and concluding "root"
  produced a `chmod 600` that crash-looped the admin container with
  `PermissionError`, and it shipped to `dev`.
- **A skip is not a repair.** State volumes persist across upgrades, so a fix that
  only handles fresh installs leaves damaged ones broken. Repair must be
  bidirectional: the first attempt at the above `continue`d past the file,
  leaving it at the bad mode it already had.

*The shape common to all three: verifying at the layer that is convenient rather
than the layer where the behaviour lives.*

### 9. Re-measure any plan estimate before acting on it
Grep counts are not call-site reading.
*Incidents:* the plan's `compose()` item claimed "100+ calls with ad-hoc
`--profile`/`sudo`" — measured: 149 calls, **zero** sudo. The four "duplicate"
sudo-detection copies turned out to have deliberately different error
behaviour. Both items were descoped after measurement.

## Also worth knowing (sprint folklore that cost time)

- `lib/` modules use `error`/`warn`/`info` from `lib/common.sh`;
  `log_error`/`log_warn`/`log_info` belong to `scripts/lib/common.sh`. Mixing
  them turns an error message into `command not found`. (Checked by the
  harness.)
- Host `state/users/` ≠ the `moav_moav_state` docker volume. Container paths
  read the **volume**. Measuring the host dir once produced a false alarm that
  ~110 users would break.
- `set +e` cannot catch a `set -u` violation — the shell exits outright. Tests
  for that class must assert on process survival, not return codes.
- A `${VAR:-}` default is not automatically the right fix for an unbound-variable
  crash: in a bundle generator it trades a loud failure for a silently broken
  client config. Prefer a required-value assertion with a remediation hint.
- Merges to dev: use `gh pr merge` (local `git merge` is blocked). Docs-only
  PRs gate on CI; anything touching runtime code gates on CI **and** e2e
  (`gh workflow run e2e.yml --ref <branch> -f tier=default`).
