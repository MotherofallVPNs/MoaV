#!/bin/bash
# Regression test: the image cleanup at the end of `moav update` only ever
# removes DANGLING images, and the disk advice in `moav doctor` is safe.
#
# The owner's rule: remove only images nothing uses any more, never ones the
# stack will rebuild or reuse. `docker image prune -f` (no -a) keeps every
# tagged image (build bases, moav-client, moav-awg-client, moav-bootstrap) and
# everything a container references. `-a` would force a full rebuild, and
# `--volumes` would wipe grafana/prometheus data and user bundles.
#
# The cleanup must also wait until nothing is left to apply and the stack is
# healthy, and a failing prune must never fail the update.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "moav update: dangling-only image cleanup"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# Logs every docker call. FAKE_SICK = a filter that reports a container;
# FAKE_PRUNE_RC = exit code of `docker image prune`.
cat > "$TMP/docker" <<'STUB'
#!/bin/bash
echo "$*" >> "$ARGS_LOG"
case "$*" in
  "ps -q --filter "*) [ -n "${FAKE_SICK:-}" ] && [ "$4" = "$FAKE_SICK" ] && echo "abc123" ;;
  "image prune"*)
      [ "${FAKE_PRUNE_RC:-0}" = "0" ] || { echo "daemon error" >&2; exit "$FAKE_PRUNE_RC"; }
      printf 'Deleted Images:\ndeleted: sha256:deadbeef\n\nTotal reclaimed space: 1.2GB\n' ;;
esac
exit 0
STUB
chmod +x "$TMP/docker"

# Runs the real end of the update flow under moav.sh's strict mode.
# <env assignments...> -> output in $TMP/out, docker calls in $TMP/args, rc echoed
run_update_end() {
    : > "$TMP/args"
    [ -n "${KEEP_PENDING:-}" ] || rm -f "$TMP/pending"
    env PATH="$TMP:$PATH" ARGS_LOG="$TMP/args" PENDING="$TMP/pending" "$@" \
        bash -c 'set -euo pipefail; cd "$0"; SCRIPT_DIR="$0"
                 # moav.sh defines the colours; the libs only use them.
                 BLUE="" YELLOW="" CYAN="" WHITE="" DIM="" NC=""
                 # shellcheck disable=SC1091
                 source scripts/lib/common.sh >/dev/null 2>&1
                 # shellcheck disable=SC1091
                 source lib/common.sh >/dev/null 2>&1
                 # shellcheck disable=SC1091
                 source lib/update.sh >/dev/null 2>&1
                 APPLY_PENDING_FILE="$PENDING"   # never the checkout under test
                 print_post_update_apply_steps' "$ROOT" > "$TMP/out" 2>&1
    echo $?
}
pruned() { grep -q '^image prune' "$TMP/args"; }
UNSAFE='(^| )(-a|--all|--volumes)( |$)|system prune'

# --- healthy, nothing to apply: prune, dangling only -------------------------
rc=$(run_update_end)
if [ "$rc" = "0" ] && [ "$(grep -c '^image prune' "$TMP/args")" = "1" ] \
   && grep -qx 'image prune -f' "$TMP/args"; then
    ok "a healthy, fully applied update runs exactly 'docker image prune -f'"
else
    bad "expected one 'docker image prune -f' (rc=$rc), docker saw: $(tr '\n' ';' < "$TMP/args")"
fi
grep -qE -- "$UNSAFE" "$TMP/args" \
    && bad "an unsafe flag reached docker: $(grep -E -- "$UNSAFE" "$TMP/args" | tr '\n' ';')" \
    || ok "no -a / --all / --volumes / system prune reaches docker"
grep -q 'reclaimed 1.2GB' "$TMP/out" \
    && ok "the reclaimed space is logged in one line" \
    || bad "no reclaimed-space note in the output: $(cat "$TMP/out")"
# The health checks must come first, or the gate is decorative.
[ "$(grep -n '^image prune' "$TMP/args" | cut -d: -f1)" -gt "$(grep -n '^ps -q' "$TMP/args" | tail -1 | cut -d: -f1)" ] \
    && ok "container health is checked before the prune" \
    || bad "the prune ran before the health checks"

# --- not healthy: keep everything (old image may be the rollback) ------------
for sick in health=unhealthy health=starting status=restarting; do
    rc=$(run_update_end FAKE_SICK="$sick")
    if [ "$rc" = "0" ] && ! pruned; then
        ok "a container with $sick blocks the cleanup"
    else
        bad "pruned (rc=$rc) while a container had $sick"
    fi
done

# --- steps still to apply: containers are not on the new images yet ----------
for pending in POST_UPDATE_REBUILD_SERVICES=admin POST_UPDATE_CONFIG_RECREATE=prometheus \
               POST_UPDATE_COMPOSE_CHANGED=1 POST_UPDATE_BOOTSTRAP_TEMPLATES=configs/x.json; do
    rc=$(run_update_end "$pending")
    if [ "$rc" = "0" ] && ! pruned; then
        ok "no cleanup while ${pending%%=*} is still to be applied"
    else
        bad "pruned (rc=$rc) before ${pending%%=*} was applied"
    fi
done

# --- pending steps are remembered for `moav apply` ---------------------------
rc=$(run_update_end POST_UPDATE_REBUILD_SERVICES=admin POST_UPDATE_BASE_COMMIT=abc1234)
grep -qx 'base=abc1234' "$TMP/pending" 2>/dev/null \
    && ok "pending steps are recorded for 'moav apply' with the pre-update commit" \
    || bad "no pending-apply marker was written (rc=$rc)"
rc=$(KEEP_PENDING=1 run_update_end POST_UPDATE_REBUILD_SERVICES=xray POST_UPDATE_BASE_COMMIT=def5678)
grep -qx 'base=abc1234' "$TMP/pending" 2>/dev/null \
    && ok "a second unapplied update keeps the earlier base" \
    || bad "the earlier base was overwritten: $(cat "$TMP/pending" 2>/dev/null)"
rm -f "$TMP/pending"

# --- best-effort: a failing prune must not fail the update -------------------
rc=$(run_update_end FAKE_PRUNE_RC=1)
[ "$rc" = "0" ] && ok "a failing prune leaves the update exit code at 0 (under set -e)" \
                || bad "a failing prune failed the update (rc=$rc)"
grep -q 'Skipped image cleanup' "$TMP/out" \
    && ok "a failing prune is reported in one line" \
    || bad "a failing prune was silent: $(cat "$TMP/out")"

# --- every update exit path ends in the step that carries the cleanup --------
n=$(grep -c '^ *print_post_update_apply_steps$' "$ROOT/lib/update.sh")
[ "$n" = "2" ] && grep -A9 '_post-update)' "$ROOT/moav.sh" | grep -q 'print_post_update_apply_steps' \
    && ok "tag, up-to-date and _post-update paths all end in the apply-steps/cleanup step" \
    || bad "an update path no longer reaches print_post_update_apply_steps (update.sh calls: $n)"

# --- static: nothing destructive in the update or doctor code ----------------
for f in lib/update.sh lib/doctor.sh; do
    # docker lines only: `git fetch --all --prune` is not an image prune.
    if grep -nE 'docker .*prune' "$ROOT/$f" | grep -qE -- "$UNSAFE"; then
        bad "$f contains a destructive prune: $(grep -nE 'docker .*prune' "$ROOT/$f" | grep -E -- "$UNSAFE" | tr '\n' ';')"
    else
        ok "$f has no prune with -a / --all / --volumes / system prune"
    fi
done
grep -q -- '--volumes' "$ROOT/lib/doctor.sh" \
    && bad "moav doctor still mentions --volumes (wipes grafana/prometheus/bundle data)" \
    || ok "moav doctor never suggests --volumes"
grep -q 'docker image prune -f' "$ROOT/lib/doctor.sh" && grep -q 'journalctl --vacuum-size=200M' "$ROOT/lib/doctor.sh" \
    && ok "moav doctor suggests the dangling-image prune and a journal vacuum" \
    || bad "moav doctor lost the safe disk advice"

echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
