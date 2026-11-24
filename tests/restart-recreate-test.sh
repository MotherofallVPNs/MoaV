#!/bin/bash
# `moav restart` must apply .env changes. `docker compose restart` keeps a
# container's old env (EGRESS_ISOLATION, ports, ...), so restart goes through
# compose_restart: `up -d --no-deps` on services that already have a container
# (recreates what changed), then a plain restart of the unchanged running ones.
#
# Hermetic: `docker` is a stub that keeps a fake container table in a file.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SVC="$ROOT/lib/service.sh"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "moav restart recreates on change"
if (( BASH_VERSINFO[0] < 4 )); then
    echo "SKIP: needs bash >= 4 (moav does too)"; exit 2
fi
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

# Container table: "<service> <id> <state>". STUB_CHANGED = services whose
# config differs from their container, so `up -d` recreates them (new id).
cat > "$work/bin/docker" <<'STUB'
#!/bin/bash
[[ "$1" == compose ]] || exit 1; shift
args=(); while [[ $# -gt 0 ]]; do
    case "$1" in --profile) shift 2 ;; *) args+=("$1"); shift ;; esac
done
set -- "${args[@]}"
echo "$*" >> "$STUB_DIR/calls"
case "$1" in
    config) printf '%s\n' $STUB_PROFILE_SERVICES ;;
    ps)
        if [[ "$*" == *State* ]]; then cat "$STUB_DIR/table"
        else awk '{print $1, $2}' "$STUB_DIR/table"; fi ;;
    up)
        shift; for s in "$@"; do
            [[ "$s" == -* ]] && continue
            if [[ " $STUB_CHANGED " == *" $s "* ]]; then
                sed -i.bak "s/^$s [^ ]* .*/$s new-$s running/" "$STUB_DIR/table"
            else
                sed -i.bak "s/^$s \([^ ]*\) .*/$s \1 running/" "$STUB_DIR/table"
            fi
        done ;;
    restart) ;;
esac
STUB
chmod +x "$work/bin/docker"

run_restart() { # table rows via stdin; args = moav restart args
    cat > "$work/table"; : > "$work/calls"
    (
        export PATH="$work/bin:$PATH" STUB_DIR="$work"
        info() { echo "INFO $*"; }; warn() { echo "WARN $*"; }
        error() { echo "ERR $*"; }; success() { :; }
        ensure_perms_repaired() { :; }
        resolve_services() { echo "$@"; }
        # shellcheck disable=SC2034  # read by the eval'd compose_profiles
        SCRIPT_DIR="$ROOT"
        eval "$(sed -n '/^compose_restart() {/,/^}/p; /^cmd_restart() {/,/^}/p
                        /^compose_profiles() {/,/^}/p; /^is_compose_profile() {/,/^}/p' "$SVC")"
        set -e
        cmd_restart "$@"
    ) > "$work/out" 2>&1
}
calls() { cat "$work/calls"; }

export STUB_PROFILE_SERVICES="sing-box xray wireguard grafana"

# 1. Nothing changed: running services are restarted, never recreated.
STUB_CHANGED="" run_restart <<'EOF'
sing-box id1 running
xray id2 running
EOF
grep -qx 'up -d --no-deps sing-box xray' "$work/calls" \
    && ok "restart all: up -d --no-deps on existing containers only" \
    || bad "restart all: unexpected up call: $(calls)"
grep -qx 'restart sing-box xray' "$work/calls" \
    && ok "unchanged running services are still restarted" \
    || bad "unchanged services not restarted: $(calls)"
grep -q 'wireguard\|grafana' "$work/calls" \
    && bad "a service with no container was brought up: $(calls)" \
    || ok "services with no container are left alone"

# 2. EGRESS_ISOLATION flipped for xray: it is recreated and not bounced again.
STUB_CHANGED="xray" run_restart <<'EOF'
sing-box id1 running
xray id2 running
EOF
grep -qx 'restart sing-box' "$work/calls" \
    && ok "changed service recreated by up -d, only the unchanged one restarted" \
    || bad "recreated service restarted again, or wrong set: $(calls)"
grep -q 'Recreated.*xray' "$work/out" \
    && ok "recreated services are reported" || bad "no recreate notice: $(cat "$work/out")"

# 3. A stopped container is started by up -d, not restarted a second time.
STUB_CHANGED="" run_restart <<'EOF'
sing-box id1 exited
xray id2 running
EOF
grep -qx 'restart xray' "$work/calls" \
    && ok "stopped container started once (no extra restart)" \
    || bad "stopped container handling: $(calls)"

# 4. Single service / profile paths go through the same helper.
STUB_CHANGED="" run_restart xray <<'EOF'
sing-box id1 running
xray id2 running
EOF
grep -qx 'up -d --no-deps xray' "$work/calls" && grep -qx 'restart xray' "$work/calls" \
    && ok "moav restart <service> touches only that service" \
    || bad "single-service restart: $(calls)"
STUB_CHANGED="" run_restart grafana <<'EOF'
sing-box id1 running
EOF
grep -q '^up\|^restart' "$work/calls" \
    && bad "restart of a service with no container brought it up: $(calls)" \
    || ok "moav restart <absent service> does not start it"
STUB_CHANGED="sing-box" run_restart proxy <<'EOF'
sing-box id1 running
xray id2 running
EOF
grep -q '^config --services' "$work/calls" && grep -qx 'up -d --no-deps sing-box xray' "$work/calls" \
    && ok "moav restart <profile> uses the profile's services" \
    || bad "profile restart: $(calls)"

# 5. No restart path may fall back to a bare `docker compose ... restart`,
# which would silently ignore .env again.
body=$(sed -n '/^cmd_restart() {/,/^}/p; /^restart_services() {/,/^}/p' "$SVC")
if grep -E 'docker compose.* restart' <<<"$body" >/dev/null; then
    bad "cmd_restart/restart_services call docker compose restart directly"
else
    ok "cmd_restart and the menu restart both go through compose_restart"
fi

echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]
