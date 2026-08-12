#!/bin/bash
# Regression test: containers that inherit orphaned processes need a PID-1 reaper.
#
# Both live servers had zombies, and `ps -eo stat,ppid` named the parents:
# 28 under `python main.py` (moav-admin) and 11 under `grafana server` on one,
# 11 under grafana on the other. Both entrypoints `exec` their app, so PID 1 is
# the app, and neither python nor grafana reaps processes it did not spawn. A
# user-add script killed on timeout leaves its `docker`/`bash` grandchildren
# reparented to PID 1, where they stay forever.
#
# `init: true` puts tini at PID 1, which reaps orphans and forwards signals.
#
# Only these two are asserted: the other eleven entrypoints exec a proxy binary
# that spawns nothing, and neither live server had zombies under any of them.
# This is deliberately evidence-driven rather than a blanket init: true.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="$ROOT/docker-compose.yml"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "compose: PID-1 reaper on the containers that inherit orphans"

# Print one service's block. Service keys are the only 2-space-indented names.
service_block() {   # <service>
    awk -v want="  $1:" '
        $0 == want { inblock = 1; next }
        inblock && /^  [a-zA-Z0-9_-]+:$/ { exit }
        inblock { print }
    ' "$COMPOSE"
}

has_init() {        # <service>
    service_block "$1" | grep -qE '^[[:space:]]+init:[[:space:]]*true[[:space:]]*$'
}

for svc in admin grafana; do
    if [ -z "$(service_block "$svc")" ]; then
        bad "could not find the '$svc' service block (renamed?)"
    elif has_init "$svc"; then
        ok "$svc has init: true"
    else
        bad "$svc has no init: true — orphaned children become permanent zombies"
    fi
done

# --- the parser must be able to tell the difference --------------------------
# Without this, a broken service_block that returns nothing for every service
# would fail loudly above, but a grep that matched everything would pass silently.
if has_init xray; then
    bad "xray reports init: true — the block parser is matching other services"
else
    ok "the parser distinguishes services (xray, which has no init, reads as absent)"
fi

# --- and the reason must survive in the file ---------------------------------
# A future reader deleting "init: true" as noise is exactly how this regresses.
if service_block admin | grep -qi 'reap\|zombie'; then
    ok "admin's init: true carries the why"
else
    bad "admin's init: true has no comment — it will be removed as clutter"
fi

echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
