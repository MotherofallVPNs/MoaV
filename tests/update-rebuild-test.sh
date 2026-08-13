#!/bin/bash
# Regression test: `moav update` must tell the operator to rebuild any image
# whose BAKED-IN inputs changed in the pull.
#
# Services built from source have no version pin in .env, so
# check_component_versions cannot see them. A change to a COPY'd entrypoint or a
# Dockerfile ships in git and then never reaches a running container until
# someone rebuilds by hand — that is how a dns-router source change left old
# routers running before 1.8.0.
#
# The 2.1.0 admin-secrets change is the sharpest case: compose stopped passing
# ADMIN_PASSWORD because admin-entrypoint.sh now reads .env itself. If the image
# is not rebuilt, the OLD entrypoint runs against the NEW compose, the password
# is unset, and the dashboard fail-closes with 503. The rebuild prompt is the
# only thing standing between an upgrade and a locked-out operator.
#
# Bind-mounted scripts must NOT trigger a rebuild: on a 1 GB VPS a needless
# build is slow and can OOM, and those take effect on the next run anyway.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "moav update: rebuild prompts for baked-in changes"

# Drive the real function against a synthetic diff by stubbing the git call.
# <changed-paths...> -> prints the queued service list
queued_for() {
    local tmp; tmp=$(mktemp)
    printf '%s\n' "$@" > "$tmp"
    (
        SCRIPT_DIR="$ROOT"
        # shellcheck disable=SC1091
        source "$ROOT/scripts/lib/common.sh" >/dev/null 2>&1
        # shellcheck disable=SC1091
        source "$ROOT/lib/common.sh"        >/dev/null 2>&1
        # shellcheck disable=SC1091
        source "$ROOT/lib/update.sh"        >/dev/null 2>&1
        # Stand in for `git diff --name-only`; the -C form means we can intercept
        # by name without touching the repo.
        git() {
            case " $* " in
                *" diff --name-only "*) cat "$tmp" ;;
                *) command git "$@" ;;
            esac
        }
        POST_UPDATE_REBUILD_SERVICES=""
        check_source_rebuilds "SOMECOMMIT"
        printf '%s' "${POST_UPDATE_REBUILD_SERVICES:-}"
    )
    rm -f "$tmp"
}

# --- baked inputs MUST queue a rebuild ---------------------------------------
must_queue() {  # <label> <service> <path...>
    local label="$1" svc="$2"; shift 2
    local got; got=$(queued_for "$@")
    case " $got " in
        *" $svc "*) ok "$label queues '$svc'" ;;
        *)          bad "$label did NOT queue '$svc' (got '${got:-none}') — the change would never reach a container" ;;
    esac
}
must_queue "admin entrypoint change"   admin       "scripts/admin-entrypoint.sh"
must_queue "admin app change"          admin       "admin/main.py"
must_queue "admin Dockerfile change"   admin       "dockerfiles/Dockerfile.admin"
must_queue "dns-router source change"  dns-router  "dns-router/main.go"
must_queue "sing-box entrypoint"       sing-box    "scripts/sing-box-entrypoint.sh"
must_queue "conduit name mismatch"     psiphon-conduit "scripts/conduit-entrypoint.sh"

# --- bind-mounted / infra paths must NOT ------------------------------------
must_not_queue() {  # <label> <path...>
    local label="$1"; shift
    local got; got=$(queued_for "$@")
    [ -z "$got" ] && ok "$label queues nothing" \
                  || bad "$label queued '$got' — a needless build can OOM a 1 GB VPS"
}
must_not_queue "bind-mounted bootstrap.sh"   "scripts/bootstrap.sh"
must_not_queue "bind-mounted lib/ change"    "lib/update.sh"
must_not_queue "bind-mounted grafana entry"  "scripts/grafana-entrypoint.sh"
must_not_queue "a docs change"               "README.md" "CHANGELOG.md"

# A deleted service must not be suggested. Removing exporters/snowflake left its
# files in the diff, so the prompt said `moav build snowflake-exporter` for a
# service that no longer exists in compose.
must_not_queue "a deleted exporter"          "exporters/snowflake/main.py"
# ...but the mapping itself must still work for the exporters that remain.
must_queue "a live exporter change"  singbox-exporter  "exporters/singbox/main.py"

# --- bind-mounted single files need a RECREATE, not a restart ----------------
# A single-file mount follows the inode; git replaces the file, so the container
# reads the old copy until recreated. Measured on a live server: host inode
# 508739 vs container 523302, leaving prometheus on a stale scrape config.
recreate_for() {  # <changed-paths...> -> the services to recreate
    local tmp; tmp=$(mktemp); printf '%s\n' "$@" > "$tmp"
    (
        SCRIPT_DIR="$ROOT"
        # shellcheck disable=SC1091
        source "$ROOT/scripts/lib/common.sh" >/dev/null 2>&1
        # shellcheck disable=SC1091
        source "$ROOT/lib/common.sh"        >/dev/null 2>&1
        # shellcheck disable=SC1091
        source "$ROOT/lib/update.sh"        >/dev/null 2>&1
        git() { case " $* " in *" diff --name-only "*) cat "$tmp" ;; *) command git "$@" ;; esac; }
        POST_UPDATE_CONFIG_RECREATE=""
        check_source_rebuilds "SOMECOMMIT" >/dev/null 2>&1
        printf '%s' "${POST_UPDATE_CONFIG_RECREATE:-}"
    )
    rm -f "$tmp"
}
got=$(recreate_for "configs/monitoring/prometheus.yml")
case " $got " in
    *" prometheus "*) ok "a prometheus.yml change asks for a recreate" ;;
    *) bad "prometheus.yml changed but no recreate was suggested (got '${got:-none}') — the container keeps the old config silently" ;;
esac
# --- a compose change alone must still tell the operator to apply it ---------
# It maps to no service, so the whole summary used to be skipped and the pull
# looked like a no-op -- even though `up -d` is exactly what applies it.
compose_flag_for() {  # <changed-paths...> -> 1 when the summary should fire
    local tmp; tmp=$(mktemp); printf '%s\n' "$@" > "$tmp"
    (
        SCRIPT_DIR="$ROOT"
        # shellcheck disable=SC1091
        source "$ROOT/scripts/lib/common.sh" >/dev/null 2>&1
        # shellcheck disable=SC1091
        source "$ROOT/lib/common.sh"        >/dev/null 2>&1
        # shellcheck disable=SC1091
        source "$ROOT/lib/update.sh"        >/dev/null 2>&1
        git() { case " $* " in *" diff --name-only "*) cat "$tmp" ;; *) command git "$@" ;; esac; }
        POST_UPDATE_COMPOSE_CHANGED=""
        check_source_rebuilds "SOMECOMMIT" >/dev/null 2>&1
        printf '%s' "${POST_UPDATE_COMPOSE_CHANGED:-}"
    )
    rm -f "$tmp"
}
[ -n "$(compose_flag_for "docker-compose.yml")" ] \
    && ok "a docker-compose.yml change asks the operator to run moav start" \
    || bad "a compose change printed nothing — the pull looks like a no-op"
[ -z "$(compose_flag_for "README.md")" ] \
    && ok "a docs change does not ask for a start" \
    || bad "a docs change asked for a start"

got=$(recreate_for "README.md")
[ -z "$got" ] && ok "a docs change asks for no recreate" \
              || bad "a docs change suggested recreating '$got'"

# --- the real 2.1.0 range, if the tag is present -----------------------------
# The guarantee that matters is not synthetic: upgrading from 2.0.1 must prompt
# the admin rebuild, or the dashboard locks out.
if git -C "$ROOT" rev-parse -q --verify "v2.0.1^{}" >/dev/null 2>&1; then
    real=$(
        SCRIPT_DIR="$ROOT"
        # shellcheck disable=SC1091
        source "$ROOT/scripts/lib/common.sh" >/dev/null 2>&1
        # shellcheck disable=SC1091
        source "$ROOT/lib/common.sh"        >/dev/null 2>&1
        # shellcheck disable=SC1091
        source "$ROOT/lib/update.sh"        >/dev/null 2>&1
        POST_UPDATE_REBUILD_SERVICES=""
        check_source_rebuilds "v2.0.1" >/dev/null 2>&1
        printf '%s' "${POST_UPDATE_REBUILD_SERVICES:-}"
    )
    case " $real " in
        *" admin "*) ok "upgrading from v2.0.1 prompts the admin rebuild (live diff)" ;;
        *)           bad "v2.0.1 -> HEAD does not prompt an admin rebuild (got '${real:-none}') — the dashboard would 503" ;;
    esac
else
    echo "  note  v2.0.1 tag not present; skipped the live-range check"
fi

echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
