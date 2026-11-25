#!/bin/bash
# `moav apply`: build -> (bootstrap) -> regenerate-users -> start -> cleanup, as
# one unattended, re-runnable command with markers, exit codes and a status file.
#
# The real moav.sh runs in a scratch install against a docker stub that logs
# every call and fails on request, so the real cmd_build / cmd_regenerate_users
# / cmd_start are what gets driven. Only cmd_bootstrap is replaced by a recorder.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "moav apply"
if (( BASH_VERSINFO[0] < 4 )); then
    echo "SKIP: needs bash >= 4 (moav does too)"; exit 2
fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
APP="$WORK/moav"; mkdir -p "$APP/scripts" "$APP/lib" "$APP/configs" "$APP/outputs/bundles/alice" "$WORK/bin"
cp "$ROOT/moav.sh" "$APP/moav.sh"; chmod +x "$APP/moav.sh"
cp "$ROOT/VERSION" "$ROOT/docker-compose.yml" "$ROOT/.gitignore" "$APP/"
for f in "$ROOT"/scripts/*; do ln -s "$f" "$APP/scripts/$(basename "$f")"; done
for f in "$ROOT"/lib/*.sh; do ln -s "$f" "$APP/lib/$(basename "$f")"; done
# The bootstrap step is recorded, not run: it would touch the host.
rm "$APP/lib/bootstrap.sh"
cat > "$APP/lib/bootstrap.sh" <<EOF
source "$ROOT/lib/bootstrap.sh"
cmd_bootstrap() { echo "bootstrap \$*" >> "$WORK/docker.log"; return "\${FAKE_BOOTSTRAP_RC:-0}"; }
EOF
cat > "$APP/.env" <<'EOF'
DOMAIN=
SERVER_IP=203.0.113.10
SERVER_IPV6=disabled
DEFAULT_PROFILES="proxy xhttp telegram"
ENABLE_XDNS=false
ENABLE_DNSTT=false
ENABLE_SLIPSTREAM=false
EOF
echo '{}' > "$APP/configs/demo.json.template"
( cd "$APP" && git init -q && git add -A \
  && git -c user.name=t -c user.email=t@example.invalid commit -q -m base ) || { echo "git setup failed"; exit 1; }
BASE=$(git -C "$APP" rev-parse --short HEAD)

# Logs every call. FAKE_FAIL = a regex; a matching call exits 1.
cat > "$WORK/bin/docker" <<DOCKER
#!/bin/bash
echo "\$*" >> "$WORK/docker.log"
if [ -n "\${FAKE_FAIL:-}" ] && grep -qE -- "\$FAKE_FAIL" <<<"\$*"; then echo "stub: failing \$1 \$2" >&2; exit 1; fi
case "\$*" in
  "image prune"*) echo "Total reclaimed space: 0B" ;;
  *"ps --services --filter status=running"*) printf '%s\n' \${FAKE_RUNNING:-} ;;
  "compose run "*) [ -z "\${FAKE_SLEEP:-}" ] || sleep "\$FAKE_SLEEP" ;;
esac
exit 0
DOCKER
chmod +x "$WORK/bin/docker"

run_apply() { # [ENV=val ...] -- <apply args...>; output in $OUT, rc in $RC
    local envs=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    [ $# -gt 0 ] && shift
    : > "$WORK/docker.log"
    OUT=$(cd "$APP" && env PATH="$WORK/bin:$PATH" ${envs[@]+"${envs[@]}"} bash ./moav.sh apply "$@" 2>&1 < /dev/null)
    RC=$?
}
logged() { grep -qE -- "$1" "$WORK/docker.log"; }
line_of() { grep -nE -m1 -- "$1" "$WORK/docker.log" | cut -d: -f1; }
status() { (cd "$APP" && bash ./moav.sh apply --status "$@" 2>&1); }
dlog() { tr '\n' ';' < "$WORK/docker.log"; }

# --- help and usage -----------------------------------------------------------
: > "$WORK/docker.log"
out=$(cd "$APP" && PATH="$WORK/bin:$PATH" bash ./moav.sh apply --help 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grep -q '^Usage: moav apply' <<<"$out" && grep -q 'Exit codes' <<<"$out" && [ ! -s "$WORK/docker.log" ]; then
    ok "apply --help prints usage and the exit codes, runs nothing"
else
    bad "apply --help: rc=$rc docker=[$(dlog)]"
fi
out=$(cd "$APP" && bash ./moav.sh help 2>&1)
grep -qE '^  apply ' <<<"$out" \
    && ok "'moav help' lists apply" || bad "'moav help' does not list apply"
run_apply -- --bogus
{ [ "$RC" -eq 1 ] && [ ! -s "$WORK/docker.log" ]; } && ok "an unknown option exits 1 before anything runs" \
    || bad "apply --bogus: rc=$RC"
run_apply -- nosuchthing
{ [ "$RC" -eq 1 ] && grep -q 'Unknown service or profile: nosuchthing' <<<"$OUT" && ! logged ' build'; } \
    && ok "an unknown service exits 1 before anything runs" || bad "apply nosuchthing: rc=$RC"
[ "$(status | head -1)" = "state=idle" ] && ok "--status before any run: idle" || bad "--status: $(status | head -1)"

# --- the full apply -----------------------------------------------------------
run_apply --
[ "$RC" -eq 0 ] && ok "a full apply exits 0" || bad "full apply exited $RC: $(tail -5 <<<"$OUT")"
b1=$(line_of '^compose --profile proxy build'); b3=$(line_of '^compose --profile telegram build')
rg=$(line_of '^compose run --rm -T .* bootstrap -c'); up=$(line_of '^compose --profile proxy --profile xhttp --profile telegram up -d')
pr=$(line_of '^image prune -f$')
if [ -n "$b1" ] && [ -n "$b3" ] && [ -n "$rg" ] && [ -n "$up" ] && [ -n "$pr" ] \
   && [ "$b3" -lt "$rg" ] && [ "$rg" -lt "$up" ] && [ "$up" -lt "$pr" ]; then
    ok "order: build each default profile, regenerate-users, start, dangling-image prune"
else
    bad "wrong sequence (build=$b1,$b3 regen=$rg up=$up prune=$pr): $(dlog)"
fi
logged '^compose --profile xhttp build' && ok "the xhttp profile is built through moav build" \
    || bad "xhttp was not built"
logged '^bootstrap' && bad "bootstrap ran without a template change" || ok "no bootstrap when no config template changed"
grep -qE -- '(^| )(-a|--all|--volumes)( |$)|system prune' <(grep prune "$WORK/docker.log") \
    && bad "an unsafe prune reached docker" || ok "the cleanup is the dangling-only prune"
want='step 1/6: preflight|step 2/6: build|step 3/6: bootstrap (skipped: no config template changed)|step 4/6: regenerate-users|step 5/6: start|step 6/6: cleanup|'
got=$(grep '^\[moav-apply\] step ' <<<"$OUT" | sed 's/^\[moav-apply\] //' | tr '\n' '|')
[ "$got" = "$want" ] && ok "six step markers, in order, uncoloured" || bad "step markers: $got"
[ "$(tail -1 <<<"$OUT")" = "[moav-apply] exit=0 result=ok step=cleanup" ] \
    && ok "the last line is the result marker" || bad "last line: $(tail -1 <<<"$OUT")"
st=$(status)
{ grep -qx 'state=ok' <<<"$st" && grep -qx 'exit=0' <<<"$st" && grep -qx 'step=6' <<<"$st" && grep -qx 'scope=all' <<<"$st"; } \
    && ok "--status reports the finished run" || bad "--status: $(tr '\n' ' ' <<<"$st")"
if command -v python3 >/dev/null 2>&1; then
    status --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["state"]=="ok" and d["exit"]==0 and d["steps"]==6 and d["pending"] is False, d' 2>/dev/null \
        && ok "--status --json is one valid document" || bad "--status --json: $(status --json | tr '\n' ' ')"
fi
[ ! -e "$APP/.moav_apply.lock" ] && ok "the lock is released" || bad "the lock was left behind"
[ -z "$(git -C "$APP" status --porcelain)" ] && ok "the state files are gitignored (moav update sees a clean tree)" \
    || bad "apply left untracked files: $(git -C "$APP" status --porcelain | tr '\n' ' ')"

# Idempotent: the same run again is the same calls and the same result.
first=$(grep -vE 'docker\.log' "$WORK/docker.log"); run_apply --
{ [ "$RC" -eq 0 ] && [ "$first" = "$(cat "$WORK/docker.log")" ]; } && ok "a second run repeats the same steps and exits 0" \
    || bad "the re-run differed (rc=$RC)"

# --- options ------------------------------------------------------------------
run_apply -- --no-cache --no-regenerate
{ [ "$RC" -eq 0 ] && logged '^compose --profile proxy build --no-cache$' && ! logged '^compose run --rm -T'; } \
    && ok "--no-cache reaches the build, --no-regenerate skips the bundles" || bad "options: rc=$RC $(dlog)"
grep -q 'step 4/6: regenerate-users (skipped: not requested)' <<<"$OUT" \
    && ok "a skipped step is still announced" || bad "no skipped marker for regenerate-users"

# --- failures -----------------------------------------------------------------
run_apply FAKE_FAIL='--profile xhttp build' --
if [ "$RC" -eq 10 ] && ! logged ' up -d' && ! logged '^compose run --rm -T' && ! logged '^image prune'; then
    ok "a failed build exits 10 and nothing is regenerated, restarted or pruned"
else
    bad "failed build: rc=$RC $(dlog)"
fi
logged '^compose --profile telegram build' && bad "the build went on after a failure (errexit lost in the step)" \
    || ok "the build stops at the first failing profile"
[ "$(tail -1 <<<"$OUT")" = "[moav-apply] exit=10 result=failed step=build" ] \
    && ok "the result marker names the failed step" || bad "last line: $(tail -1 <<<"$OUT")"
{ grep -qx 'state=failed' <<<"$(status)" && grep -qx 'step_name=build' <<<"$(status)"; } \
    && ok "--status reports the failure" || bad "--status after a failed build: $(status | tr '\n' ' ')"

run_apply FAKE_FAIL='^compose run --rm -T' --
{ [ "$RC" -eq 12 ] && logged ' up -d --remove-orphans'; } \
    && ok "a failed regenerate-users still starts the services, then exits 12" || bad "failed regenerate: rc=$RC $(dlog)"

run_apply FAKE_FAIL=' up -d' --
{ [ "$RC" -eq 13 ] && ! logged '^image prune'; } && ok "a failed start exits 13, no cleanup" || bad "failed start: rc=$RC"

mv "$APP/.env" "$APP/.env.off"; run_apply --
{ [ "$RC" -eq 2 ] && ! logged ' build'; } && ok "no .env: preflight exits 2, nothing built" || bad "no .env: rc=$RC"
mv "$APP/.env.off" "$APP/.env"
sed -i.bak 's/^DEFAULT_PROFILES=.*/DEFAULT_PROFILES=""/' "$APP/.env"; run_apply --
{ [ "$RC" -eq 2 ] && ! logged ' build'; } && ok "empty DEFAULT_PROFILES: preflight exits 2" || bad "empty profiles: rc=$RC"
mv "$APP/.env.bak" "$APP/.env"

# --- one apply at a time ------------------------------------------------------
(cd "$APP" && env PATH="$WORK/bin:$PATH" FAKE_SLEEP=6 bash ./moav.sh apply > "$WORK/bg.out" 2>&1 < /dev/null) &
bg=$!
for _ in $(seq 1 50); do grep -q 'step 4/6' "$WORK/bg.out" 2>/dev/null && break; sleep 0.2; done
cp "$WORK/docker.log" "$WORK/docker.bg"
grep -qx 'state=running' <<<"$(status)" && ok "--status while it runs: running" || bad "--status mid-run: $(status | head -3 | tr '\n' ' ')"
OUT=$(cd "$APP" && env PATH="$WORK/bin:$PATH" bash ./moav.sh apply 2>&1 < /dev/null); RC=$?
{ [ "$RC" -eq 3 ] && grep -q 'result=busy' <<<"$OUT"; } && ok "a second apply exits 3 while one is running" \
    || bad "concurrent apply: rc=$RC $(tail -2 <<<"$OUT")"
grep -qx 'state=running' <<<"$(status)" && ok "the refused run leaves the running one's status alone" \
    || bad "status was overwritten by the refused run"
wait "$bg"; bgrc=$?
[ "$bgrc" -eq 0 ] && ok "the first apply still finishes with 0" || bad "the first apply exited $bgrc"

# A lock whose owner is gone (kill -9, reboot) does not block the next run.
mkdir "$APP/.moav_apply.lock"; echo 999999 > "$APP/.moav_apply.lock/pid"
run_apply -- --no-regenerate
[ "$RC" -eq 0 ] && ok "a stale lock is taken over" || bad "stale lock: rc=$RC"

# --- one service --------------------------------------------------------------
run_apply -- xray wstunnel
if [ "$RC" -eq 0 ] && logged '^compose --profile xhttp build$' && logged '^compose --profile all build wstunnel$' \
   && logged '^compose --profile xhttp up -d' && logged '^compose --profile all up -d wstunnel' && ! logged '^compose run --rm -T'; then
    ok "apply <profile> <service>: builds and starts just those, no regenerate"
else
    bad "scoped apply: rc=$RC $(dlog)"
fi
grep -q 'step 3/6: bootstrap (skipped' <<<"$OUT" && ok "a scoped apply never bootstraps" || bad "scoped apply bootstrap marker missing"
run_apply -- telegram --regenerate
{ [ "$RC" -eq 0 ] && logged '^compose run --rm -T'; } && ok "--regenerate adds the bundles to a scoped apply" \
    || bad "scoped --regenerate: rc=$RC"

# --- applying what `moav update` left -----------------------------------------
mkdir -p "$APP/configs/monitoring"
echo '{"a":1}' > "$APP/configs/demo.json.template"; echo 'x: 1' > "$APP/configs/monitoring/prometheus.yml"
( cd "$APP" && git add -A && git -c user.name=t -c user.email=t@example.invalid commit -q -m update )
echo "base=$BASE" > "$APP/.moav_apply.pending"
grep -qx 'pending=true' <<<"$(status)" && ok "--status shows an unapplied update" || bad "--status pending: $(status | tail -1)"

run_apply -- xray
[ -f "$APP/.moav_apply.pending" ] && ok "a scoped apply does not clear the pending update" || bad "scoped apply cleared the marker"

run_apply FAKE_FAIL='^compose run --rm -T' -- --no-bootstrap
{ [ "$RC" -eq 12 ] && logged ' up -d' && [ -f "$APP/.moav_apply.pending" ]; } \
    && ok "exit 12 keeps the update pending, although the start succeeded" || bad "exit 12 with a pending update: rc=$RC"

# Applying by hand ends in a full `moav start`; a scoped start is not that.
moav_start() { : > "$WORK/docker.log"; (cd "$APP" && env PATH="$WORK/bin:$PATH" MOAV_NONINTERACTIVE=1 bash ./moav.sh start "$@" > /dev/null 2>&1 < /dev/null); }
moav_start proxy
[ -f "$APP/.moav_apply.pending" ] && ok "moav start <profile> leaves the update pending" || bad "a scoped start cleared the marker"
moav_start
[ ! -e "$APP/.moav_apply.pending" ] && ok "a full moav start clears the pending update (applied by hand)" \
    || bad "a full start left the marker"
echo "base=$BASE" > "$APP/.moav_apply.pending"

run_apply FAKE_BOOTSTRAP_RC=1 --
{ [ "$RC" -eq 11 ] && ! logged ' up -d' && [ -f "$APP/.moav_apply.pending" ]; } \
    && ok "a failed bootstrap exits 11, restarts nothing, keeps the update pending" || bad "failed bootstrap: rc=$RC $(dlog)"

run_apply -- --no-bootstrap --no-regenerate
{ [ "$RC" -eq 0 ] && ! logged '^bootstrap'; } && ok "--no-bootstrap skips the re-bootstrap" || bad "--no-bootstrap: rc=$RC"
echo "base=$BASE" > "$APP/.moav_apply.pending"

run_apply FAKE_RUNNING=prometheus --
bs=$(line_of '^bootstrap --yes$'); bl=$(line_of '^compose --profile telegram build'); rg=$(line_of '^compose run --rm -T')
if [ "$RC" -eq 0 ] && [ -n "$bs" ] && [ -n "$bl" ] && [ -n "$rg" ] && [ "$bl" -lt "$bs" ] && [ "$bs" -lt "$rg" ]; then
    ok "changed config templates: bootstrap --yes runs between the build and regenerate-users"
else
    bad "template change: rc=$RC build=$bl bootstrap=$bs regen=$rg"
fi
logged '^compose --profile all up -d --no-deps --force-recreate prometheus$' \
    && ok "a changed mounted config recreates its running service" || bad "no force-recreate: $(dlog)"
[ ! -e "$APP/.moav_apply.pending" ] && ok "a successful full apply clears the pending update" || bad "the marker survived a full apply"

echo "base=$BASE" > "$APP/.moav_apply.pending"
run_apply --
logged 'force-recreate' && bad "force-recreated a service that is not running" \
    || ok "a service that is not running is not brought up by the recreate"

# --- moav update --apply ------------------------------------------------------
grep -q -- '--apply' <<<"$(cd "$APP" && bash ./moav.sh update --help 2>&1)" \
    && ok "update --help documents --apply" || bad "update --help does not mention --apply"
chain() { # <old commit> [ENV=val ...]: the re-exec `moav update` ends in after a pull
    local old="$1"; shift
    : > "$WORK/docker.log"
    OUT=$(cd "$APP" && env PATH="$WORK/bin:$PATH" "$@" bash ./moav.sh _post-update "$old" 2>&1 < /dev/null); RC=$?
}
HEAD_NOW=$(git -C "$APP" rev-parse --short HEAD)
rm -f "$APP/.moav_apply.pending"
chain "$HEAD_NOW" MOAV_UPDATE_APPLY=1
{ [ "$RC" -eq 0 ] && grep -q 'Nothing to apply' <<<"$OUT" && ! logged ' build'; } \
    && ok "update --apply with nothing to apply builds nothing" || bad "chain, nothing pending: rc=$RC $(dlog)"
chain "$BASE"
{ [ "$RC" -eq 0 ] && ! logged ' build' && grep -q 'moav apply' <<<"$OUT" && grep -qx "base=$BASE" "$APP/.moav_apply.pending"; } \
    && ok "without --apply the update prints the steps, points at moav apply and records the base" \
    || bad "plain update end: rc=$RC $(tail -3 <<<"$OUT")"
# `moav apply` is the recommendation: it comes before the by-hand steps, and last.
first_apply=$(grep -n 'moav apply' <<<"$OUT" | head -1 | cut -d: -f1)
first_step=$(grep -nE '^ +[^ ]*1\.[^ ]* moav ' <<<"$OUT" | head -1 | cut -d: -f1)
{ [ -n "$first_apply" ] && [ -n "$first_step" ] && [ "$first_apply" -lt "$first_step" ] \
  && grep -q 'moav update --apply' <<<"$OUT" && tail -1 <<<"$OUT" | grep -q 'moav apply'; } \
    && ok "the update's closing message leads and ends with moav apply, steps in between" \
    || bad "moav apply is not the primary recommendation: apply@${first_apply:-none} step@${first_step:-none}"
chain "$HEAD_NOW"
{ [ "$RC" -eq 0 ] && grep -q 'has not been applied yet' <<<"$OUT" && grep -q 'moav apply' <<<"$OUT" \
  && grep -qx "base=$BASE" "$APP/.moav_apply.pending"; } \
    && ok "an update with nothing new still reminds about an unapplied earlier one" \
    || bad "no reminder for the pending apply: rc=$RC $(tail -3 <<<"$OUT")"
chain "$BASE" MOAV_UPDATE_APPLY=1 FAKE_FAIL=' build'
{ [ "$RC" -eq 10 ] && [ -f "$APP/.moav_apply.pending" ]; } && ok "update --apply exits with the apply's code" \
    || bad "chain failure: rc=$RC"
chain "$BASE" MOAV_UPDATE_APPLY=1
{ [ "$RC" -eq 0 ] && logged '^compose --profile xhttp build' && logged '^bootstrap --yes$' && logged ' up -d --remove-orphans' \
  && grep -q 'exit=0 result=ok' <<<"$OUT" && [ ! -e "$APP/.moav_apply.pending" ]; } \
    && ok "update --apply runs the whole apply for what the update changed" || bad "chain: rc=$RC $(tail -3 <<<"$OUT")"

# --- static -------------------------------------------------------------------
grep -qE '^\.moav_apply\.\*$' "$ROOT/.gitignore" && ok ".gitignore covers the apply state files" \
    || bad ".gitignore does not cover .moav_apply.*"
body=$(sed -n '/^cmd_apply()/,/^}/p' "$ROOT/lib/apply.sh")
miss=""
for fn in cmd_build cmd_bootstrap cmd_regenerate_users cmd_start prune_dangling_images; do
    grep -q "$fn" <<<"$body" || miss="$miss $fn"
done
[ -z "$miss" ] && ok "apply reuses cmd_build / cmd_bootstrap / cmd_regenerate_users / cmd_start / prune_dangling_images" \
               || bad "apply does not call:$miss"
grep -qE 'docker compose .*(build|up -d --remove-orphans)' <<<"$body" \
    && bad "apply carries its own build/start compose call" || ok "apply has no build or start logic of its own"

echo ""
if [ "$fail" -gt 0 ]; then echo "FAILED ($fail failed, $pass passed)"; exit 1; fi
echo "PASSED ($pass checks)"
