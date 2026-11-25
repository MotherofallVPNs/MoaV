#!/bin/bash
# lib/apply.sh — `moav apply`: make the checkout live in one unattended run.
# Rebuilds the images, re-bootstraps when an update changed config templates,
# refreshes the user bundles, recreates the containers and removes dangling
# images. It is the sequence `moav update` prints, run through the same
# cmd_build / cmd_bootstrap / cmd_regenerate_users / cmd_start an operator would.
#
# Built to be wrapped: plain "[moav-apply]" marker lines on stdout, a fixed
# exit-code table, a lock against a second run, and a small status file for a
# caller that runs it detached and polls (`moav apply --status [--json]`).
#
# Sourced by moav.sh after lib/common.sh.

# APPLY_PENDING_FILE (lib/update.sh) is the note `moav update` leaves for us.
APPLY_STATUS_FILE="$SCRIPT_DIR/.moav_apply.status"
APPLY_LOCK_DIR="$SCRIPT_DIR/.moav_apply.lock"
APPLY_STEPS=6

show_apply_help() {
    echo "Usage: moav apply [SERVICE|PROFILE ...] [--no-cache] [--regenerate|--no-regenerate]"
    echo "                  [--no-bootstrap]"
    echo "       moav apply --status [--json]"
    echo ""
    echo "Make the current checkout live: rebuild the images, refresh the user"
    echo "bundles and recreate the containers. Run it after 'moav update' (or use"
    echo "'moav update --apply'), or after editing .env."
    echo ""
    echo "Never prompts, and is safe to re-run: an unchanged image is a cache hit"
    echo "and a container whose image and config did not change keeps running."
    echo ""
    echo "Steps, each announced as '[moav-apply] step N/${APPLY_STEPS}: NAME':"
    echo "  1 preflight         .env, docker, bootstrap done, what to apply"
    echo "  2 build             the saved default profiles, or the named services"
    echo "  3 bootstrap         only when the last update changed config templates"
    echo "  4 regenerate-users  refresh the user bundles (keys stay the same)"
    echo "  5 start             recreate containers on the new images"
    echo "  6 cleanup           remove dangling images (tagged and in-use ones stay)"
    echo ""
    echo "Arguments:"
    echo "  SERVICE|PROFILE   Apply only these (as for 'moav build'). Skips bootstrap,"
    echo "                    and regenerate-users unless --regenerate is given."
    echo ""
    echo "Options:"
    echo "  --no-cache        Build without the Docker layer cache"
    echo "  --regenerate      Run regenerate-users (default for a full apply)"
    echo "  --no-regenerate   Skip regenerate-users"
    echo "  --no-bootstrap    Never re-bootstrap, even if config templates changed"
    echo "  --status          Print the state of the current or last apply and exit 0"
    echo "  --json            With --status: one JSON document"
    echo "  -h, --help        Show this help"
    echo ""
    echo "Exit codes:"
    echo "   0  applied"
    echo "   1  usage error"
    echo "   2  preflight failed, nothing was changed"
    echo "   3  another apply is running, nothing was changed"
    echo "  10  build failed, nothing was restarted"
    echo "  11  bootstrap failed, nothing was restarted"
    echo "  12  regenerate-users failed; services were still started on the new images"
    echo "  13  start failed"
    echo "  130 / 143  interrupted (SIGINT / SIGTERM)"
    echo ""
    echo "Detached (survives the SSH session):"
    echo "  nohup moav apply > apply.log 2>&1 < /dev/null &"
    echo "  moav apply --status --json      # state: running|ok|failed|interrupted|idle"
    echo "The last line of the output is always '[moav-apply] exit=CODE result=...'."
}

# Marker lines for a caller reading the log: uncoloured, one per line.
_apply_mark() {
    printf '[moav-apply] %s\n' "$*"
}

_apply_write_status() { # <state>
    local tmp="${APPLY_STATUS_FILE}.tmp.$$"
    if {
        printf 'state=%s\n' "$1"
        printf 'exit=%s\n' "${APPLY_EXIT:-}"
        printf 'step=%s\n' "${APPLY_STEP_N:-0}"
        printf 'steps=%s\n' "$APPLY_STEPS"
        printf 'step_name=%s\n' "${APPLY_STEP_NAME:-}"
        printf 'scope=%s\n' "${APPLY_SCOPE:-all}"
        printf 'pid=%s\n' "$$"
        printf 'started=%s\n' "${APPLY_STARTED:-}"
        printf 'updated=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$APPLY_STATUS_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
    fi
}

_apply_step() { # <n> <name> [note]
    APPLY_STEP_N="$1"
    APPLY_STEP_NAME="$2"
    echo ""
    _apply_mark "step $1/${APPLY_STEPS}: $2${3:+ ($3)}"
    _apply_write_status running
}

# Is <pid> a live moav process? A pid recycled after a reboot is not.
_apply_pid_alive() {
    local pid="${1:-}"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    if [[ -r "/proc/$pid/cmdline" ]]; then
        tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep moav >/dev/null
        return
    fi
    kill -0 "$pid" 2>/dev/null
}

# One apply at a time. A lock left by a killed run is taken over.
_apply_lock() {
    APPLY_LOCK_HOLDER=""
    if ! mkdir "$APPLY_LOCK_DIR" 2>/dev/null; then
        APPLY_LOCK_HOLDER=$(cat "$APPLY_LOCK_DIR/pid" 2>/dev/null || true)
        if _apply_pid_alive "$APPLY_LOCK_HOLDER"; then
            return 1
        fi
        APPLY_LOCK_HOLDER=""
        rm -rf "$APPLY_LOCK_DIR" 2>/dev/null || true
        mkdir "$APPLY_LOCK_DIR" 2>/dev/null || return 1
    fi
    echo "$$" > "$APPLY_LOCK_DIR/pid"
    APPLY_LOCKED=1
}

# Every way out ends here: the result marker, the status file, the lock.
_apply_on_exit() {
    local rc=$?
    trap - EXIT INT TERM
    local result="failed"
    case "$rc" in
        0)       result="ok" ;;
        3)       result="busy" ;;
        130|143) result="interrupted" ;;
    esac
    APPLY_EXIT="$rc"
    # Without the lock the status file belongs to the run that holds it.
    if [[ -n "${APPLY_LOCKED:-}" ]]; then
        _apply_write_status "$result"
        rm -rf "$APPLY_LOCK_DIR" 2>/dev/null || true
    fi
    echo ""
    _apply_mark "exit=$rc result=$result step=${APPLY_STEP_NAME:-preflight}"
}

# One step in a subshell: its `exit` calls end the step, and errexit stays live.
# Call it as a plain command: inside `if`/`||` bash would ignore the `set -e`.
_apply_exec() {
    set +e
    ( set -e; "$@" ) < /dev/null
    APPLY_RC=$?
    set -e
}

# `moav apply --status`: the status file, corrected for a run that died silently.
apply_status() { # [--json]
    local -A st=()
    local k v state="idle" pending="false"
    if [[ -f "$APPLY_STATUS_FILE" ]]; then
        while IFS='=' read -r k v; do
            if [[ -n "$k" ]]; then st[$k]="$v"; fi
        done < "$APPLY_STATUS_FILE"
        state="${st[state]:-idle}"
        # kill -9 or a reboot leaves "running" behind with nobody running.
        if [[ "$state" == "running" ]] && ! _apply_pid_alive "${st[pid]:-}"; then
            state="interrupted"
        fi
    fi
    if [[ -f "$APPLY_PENDING_FILE" ]]; then pending="true"; fi

    if [[ "${1:-}" != "--json" ]]; then
        echo "state=$state"
        for k in exit step steps step_name scope pid started updated; do
            echo "$k=${st[$k]:-}"
        done
        echo "pending=$pending"
        return 0
    fi

    local num
    printf '{\n  "state": %s,\n' "$(json_str "$state")"
    for k in exit step steps pid; do
        num="${st[$k]:-}"
        [[ "$num" =~ ^[0-9]+$ ]] || num="null"
        printf '  "%s": %s,\n' "$k" "$num"
    done
    for k in step_name scope started updated; do
        printf '  "%s": %s,\n' "$k" "$(json_str "${st[$k]:-}")"
    done
    printf '  "pending": %s\n}\n' "$pending"
}

# shellcheck disable=SC2120  # arguments come from the dispatcher; the update chain passes none
cmd_apply() {
    local no_cache="" regenerate="" bootstrap=true want_status=false want_json=false
    local targets=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)        show_apply_help; return 0 ;;
            --no-cache)       no_cache="--no-cache" ;;
            --regenerate)     regenerate=true ;;
            --no-regenerate)  regenerate=false ;;
            --no-bootstrap)   bootstrap=false ;;
            --status)         want_status=true ;;
            --json)           want_json=true ;;
            -y|--yes)         ;;   # always unattended; accepted for callers that pass it
            all)              ;;   # the default scope
            -*)
                error "Unknown apply option: $1"
                echo "Use 'moav apply --help' for usage"
                return 1
                ;;
            *)                targets+=("$1") ;;
        esac
        shift
    done

    if $want_status; then
        if $want_json; then apply_status --json; else apply_status; fi
        return 0
    fi
    if $want_json; then
        error "--json is only available with --status"
        return 1
    fi

    # Named targets: the same names `moav build` takes, split the way
    # `moav start` needs them (it cannot mix profiles and single services).
    local start_profiles=() start_services=() unknown=() arg target
    for arg in ${targets[@]+"${targets[@]}"}; do
        if ! target=$(build_target "$arg"); then
            unknown+=("$arg")
        elif [[ "$target" == "profile "* ]]; then
            start_profiles+=("${target#profile }")
        else
            start_services+=("$arg")
        fi
    done
    if [[ ${#unknown[@]} -gt 0 ]]; then
        error "Unknown service or profile: ${unknown[*]}"
        echo "Profiles: $(compose_profiles_help 68 10)"
        echo "Use 'moav apply --help' for usage"
        return 1
    fi

    local full=true
    if [[ ${#targets[@]} -gt 0 ]]; then full=false; fi
    if [[ -z "$regenerate" ]]; then regenerate=$full; fi

    # From here on: unattended, and every exit goes through _apply_on_exit.
    export MOAV_NONINTERACTIVE=1
    export APPLY_KEEP_PENDING=1   # cmd_start must not drop the update note mid-apply
    APPLY_SCOPE="all"
    if ! $full; then APPLY_SCOPE="${targets[*]}"; fi
    APPLY_STEP_N=0
    APPLY_STEP_NAME="preflight"
    APPLY_STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    APPLY_LOCKED=""
    APPLY_EXIT=""
    APPLY_RC=0
    trap _apply_on_exit EXIT
    trap 'echo "Interrupted (SIGINT)"; exit 130' INT
    trap 'echo "Interrupted (SIGTERM)"; exit 143' TERM

    local nc=0
    if [[ -n "$no_cache" ]]; then nc=1; fi
    echo ""
    _apply_mark "begin scope=${APPLY_SCOPE// /,} no_cache=$nc regenerate=$regenerate pid=$$"

    if ! _apply_lock; then
        if [[ -n "$APPLY_LOCK_HOLDER" ]]; then
            error "Another 'moav apply' is running (pid $APPLY_LOCK_HOLDER). Follow it with: moav apply --status"
            exit 3
        fi
        error "Cannot create $APPLY_LOCK_DIR (is $SCRIPT_DIR writable for $(id -un)?)"
        exit 2
    fi

    # --- 1. preflight ---------------------------------------------------------
    _apply_step 1 preflight
    if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
        error "No .env in $SCRIPT_DIR. Install and bootstrap first: moav bootstrap"
        exit 2
    fi
    if ! docker compose version >/dev/null 2>&1; then
        error "docker compose is not available for $(id -un)."
        exit 2
    fi
    if ! check_bootstrap; then
        error "Bootstrap has not been run, so there is nothing to apply. Run: moav bootstrap"
        exit 2
    fi

    local profiles="" templates="" setup_jobs="" recreate="" base=""
    if $full; then
        profiles=$(filter_disabled_profiles "$(get_default_profiles)")
        if [[ -z "$profiles" ]]; then
            error "DEFAULT_PROFILES in .env is empty (or every profile in it is disabled)."
            echo "  Choose the services once with 'moav profiles' or 'moav start', then re-run."
            exit 2
        fi
        info "Profiles: $profiles"

        # What the unapplied update(s) changed, worked out the way `moav update` does.
        if [[ -f "$APPLY_PENDING_FILE" ]]; then
            base=$(sed -n '/^base=/{s///p;q;}' "$APPLY_PENDING_FILE" 2>/dev/null || true)
            if [[ "$base" =~ ^[0-9a-f]{4,40}$ ]] \
               && git -C "$SCRIPT_DIR" cat-file -e "${base}^{commit}" 2>/dev/null; then
                info "Applying the update pulled since $base"
                check_source_rebuilds "$base"
                check_config_template_changes "$base"
            fi
        fi
        templates="${POST_UPDATE_BOOTSTRAP_TEMPLATES:-}"
        setup_jobs="${POST_UPDATE_SETUP_JOBS:-}"
        recreate="${POST_UPDATE_CONFIG_RECREATE:-}"
    else
        info "Scope: ${targets[*]}"
    fi

    # --- 2. build -------------------------------------------------------------
    _apply_step 2 build
    local build_args=()
    if $full; then
        # shellcheck disable=SC2206  # a word list of profile names
        build_args=($profiles)
    else
        build_args=("${targets[@]}")
    fi
    if [[ -n "$no_cache" ]]; then build_args+=("--no-cache"); fi
    _apply_exec cmd_build "${build_args[@]}"
    if [[ $APPLY_RC -ne 0 ]]; then
        error "Build failed (exit $APPLY_RC). Nothing was restarted: services keep running on the previous images."
        exit 10
    fi

    # --- 3. bootstrap (config templates changed) ------------------------------
    if ! $full; then
        _apply_step 3 bootstrap "skipped: not part of a single-service apply"
    elif [[ -z "$templates" ]]; then
        _apply_step 3 bootstrap "skipped: no config template changed"
    elif ! $bootstrap; then
        _apply_step 3 bootstrap "skipped: --no-bootstrap"
        warn "Config templates changed; the configs on disk stay as they are until 'moav bootstrap' is run."
    else
        _apply_step 3 bootstrap
        info "Config templates changed since $base: regenerating server configs (keys and users are kept)"
        _apply_exec cmd_bootstrap --yes
        if [[ $APPLY_RC -ne 0 ]]; then
            error "Bootstrap failed (exit $APPLY_RC). Nothing was restarted."
            exit 11
        fi
    fi

    # --- 4. regenerate-users --------------------------------------------------
    local regen_rc=0
    if $regenerate; then
        _apply_step 4 regenerate-users
        _apply_exec cmd_regenerate_users
        regen_rc=$APPLY_RC
        if [[ $regen_rc -ne 0 ]]; then
            warn "regenerate-users failed (exit $regen_rc); continuing so the services still move to the new images."
        fi
    else
        _apply_step 4 regenerate-users "skipped: not requested"
    fi

    # --- 5. start -------------------------------------------------------------
    _apply_step 5 start
    if $full; then
        _apply_exec cmd_start
    else
        APPLY_RC=0
        if [[ ${#start_profiles[@]} -gt 0 ]]; then
            _apply_exec cmd_start "${start_profiles[@]}"
        fi
        if [[ $APPLY_RC -eq 0 && ${#start_services[@]} -gt 0 ]]; then
            _apply_exec cmd_start "${start_services[@]}"
        fi
    fi
    if [[ $APPLY_RC -ne 0 ]]; then
        error "Start failed (exit $APPLY_RC)."
        exit 13
    fi

    # A volume this release added: its setup job never ran here. Best effort.
    local job
    for job in $setup_jobs; do
        info "Running setup job: $job"
        docker compose --profile setup run --rm "$job" < /dev/null \
            || warn "Setup job $job failed; re-run: docker compose --profile setup run --rm $job"
    done
    # A changed bind-mounted config file is only picked up by a recreate.
    if [[ -n "$recreate" ]]; then
        local running svc todo=()
        running=$(docker compose --profile all ps --services --filter status=running 2>/dev/null || true)
        for svc in $recreate; do
            if grep -qxF -- "$svc" <<< "$running"; then todo+=("$svc"); fi
        done
        if [[ ${#todo[@]} -gt 0 ]]; then
            info "Recreating for a changed mounted config: ${todo[*]}"
            if ! docker compose --profile all up -d --no-deps --force-recreate "${todo[@]}" < /dev/null; then
                error "Could not recreate: ${todo[*]}"
                exit 13
            fi
        fi
    fi

    # --- 6. cleanup -----------------------------------------------------------
    _apply_step 6 cleanup
    prune_dangling_images

    if [[ $regen_rc -ne 0 ]]; then
        error "Services are on the new images, but the user bundles were not regenerated. Re-run: moav regenerate-users"
        exit 12
    fi
    if $full; then rm -f "$APPLY_PENDING_FILE" 2>/dev/null || true; fi
    success "Applied: services are running on the current images."
    exit 0
}
