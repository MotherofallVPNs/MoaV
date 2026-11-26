#!/bin/bash
# Regression test: every compose profile and service is known to `moav build`,
# and the profile list has one source (docker-compose.yml).
#
# `moav build` kept its own profile list, which had drifted: xhttp, telegram,
# gooserelay, client and setup were missing, so `moav build xhttp` reached
# compose as a service name and failed. stop/restart had a third list.
# Runs the real moav.sh in a scratch install with a docker that logs its calls.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "moav build: profiles and services come from docker-compose.yml"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
APP="$WORK/moav"; mkdir -p "$APP/scripts" "$WORK/bin"
cp "$ROOT/moav.sh" "$APP/moav.sh"; chmod +x "$APP/moav.sh"
ln -s "$ROOT/lib" "$APP/lib"
ln -s "$ROOT/docker-compose.yml" "$APP/docker-compose.yml"
ln -s "$ROOT/dockerfiles" "$APP/dockerfiles"   # image-only services build --local
cp "$ROOT/VERSION" "$APP/VERSION"
for f in "$ROOT"/scripts/*; do ln -s "$f" "$APP/scripts/$(basename "$f")"; done
printf 'DOMAIN=\n' > "$APP/.env"

REAL_DOCKER="$(command -v docker 2>/dev/null || true)"
cat > "$WORK/bin/docker" <<DOCKER
#!/bin/bash
echo "\$*" >> "$WORK/docker.log"
exit 0
DOCKER
chmod +x "$WORK/bin/docker"

# The lists as moav sees them (the functions under test).
moav_list() { # <function>
    bash -c 'SCRIPT_DIR="$0"; source "$0/lib/service.sh"; "$1"' "$ROOT" "$1" | sort
}
PROFILES=$(moav_list compose_profiles)
SERVICES=$(moav_list compose_services)

[ "$(wc -l <<<"$PROFILES")" -ge 10 ] && [ "$(wc -l <<<"$SERVICES")" -ge 20 ] \
    && ok "compose_profiles / compose_services read docker-compose.yml ($(wc -l <<<"$PROFILES" | tr -d ' ') profiles, $(wc -l <<<"$SERVICES" | tr -d ' ') services)" \
    || bad "the compose parsers returned too little: profiles=[$(tr '\n' ' ' <<<"$PROFILES")]"

# --- the awk parsers agree with a real YAML reading of the file ---------------
want_p=""; want_s=""; via=""
if [ -n "$REAL_DOCKER" ] && want_p=$(cd "$ROOT" && "$REAL_DOCKER" compose config --profiles 2>/dev/null | sort) \
   && [ -n "$want_p" ]; then
    via="docker compose"
    flags=""; for p in $want_p; do flags="$flags --profile $p"; done
    # shellcheck disable=SC2086
    want_s=$(cd "$ROOT" && "$REAL_DOCKER" compose $flags config --services 2>/dev/null | sort)
elif python3 -c 'import yaml' 2>/dev/null; then
    via="PyYAML"
    want_p=$(python3 -c 'import sys,yaml
d=yaml.safe_load(open(sys.argv[1]))
print("\n".join(sorted({p for s in d["services"].values() for p in s.get("profiles", [])})))' "$ROOT/docker-compose.yml")
    want_s=$(python3 -c 'import sys,yaml
print("\n".join(sorted(yaml.safe_load(open(sys.argv[1]))["services"])))' "$ROOT/docker-compose.yml")
fi
if [ -n "$via" ]; then
    [ "$PROFILES" = "$want_p" ] && ok "compose_profiles matches $via" \
        || bad "compose_profiles differs from $via: [$(tr '\n' ' ' <<<"$PROFILES")] vs [$(tr '\n' ' ' <<<"$want_p")]"
    [ -n "$want_s" ] && [ "$SERVICES" = "$want_s" ] && ok "compose_services matches $via" \
        || bad "compose_services differs from $via: [$(tr '\n' ' ' <<<"$SERVICES")] vs [$(tr '\n' ' ' <<<"$want_s")]"
else
    echo "  skip  no docker compose or PyYAML to cross-check the parsers"
fi

run_moav() { # <args...> -> output in $OUT, rc in $RC, docker calls in docker.log
    : > "$WORK/docker.log"
    OUT=$(cd "$APP" && PATH="$WORK/bin:$PATH" MOAV_NONINTERACTIVE=1 bash ./moav.sh "$@" 2>&1 < /dev/null)
    RC=$?
}
logged() { grep -qE -- "$1" "$WORK/docker.log"; }

# --- every compose profile builds as a profile --------------------------------
missing=""
for p in $PROFILES; do
    run_moav build "$p"
    { [ "$RC" -eq 0 ] && logged "^compose --profile $p build"; } || missing="$missing $p"
done
[ -z "$missing" ] && ok "moav build <profile> runs 'compose --profile <profile> build' for every profile" \
                  || bad "profiles moav build does not know:$missing"

# The three that were missing, named so a reshuffle cannot drop them.
for p in xhttp telegram gooserelay; do
    run_moav build "$p" --no-cache
    logged "^compose --profile $p build --no-cache$" \
        && ok "moav build $p --no-cache builds the $p profile" \
        || bad "moav build $p: $(tr '\n' ';' < "$WORK/docker.log")"
done
for pair in xray:xhttp telemt:telegram tg:telegram sing-box:proxy awg:amneziawg; do
    run_moav build "${pair%%:*}"
    logged "^compose --profile ${pair##*:} build" \
        && ok "alias ${pair%%:*} builds the ${pair##*:} profile" \
        || bad "alias ${pair%%:*}: $(tr '\n' ';' < "$WORK/docker.log")"
done

# --- every compose service is accepted ----------------------------------------
missing=""
for s in $SERVICES; do
    run_moav build "$s"
    { [ "$RC" -eq 0 ] && logged '(^| )build( |$)' && ! grep -q 'Unknown service' <<<"$OUT"; } || missing="$missing $s"
done
[ -z "$missing" ] && ok "moav build <service> is accepted for every compose service" \
                  || bad "services moav build does not know:$missing"
run_moav build goose
logged '^compose --profile all build gooserelay$' \
    && ok "a service alias (goose) still builds that one service" \
    || bad "moav build goose: $(tr '\n' ';' < "$WORK/docker.log")"

# --- an unknown name fails before docker is asked to build --------------------
run_moav build xhttp nosuchthing
if [ "$RC" -ne 0 ] && grep -q 'Unknown service or profile: nosuchthing' <<<"$OUT" && ! logged '(^| )build( |$)'; then
    ok "an unknown name is rejected with exit $RC and nothing is built"
else
    bad "moav build nosuchthing: rc=$RC, docker saw: $(tr '\n' ';' < "$WORK/docker.log")"
fi
grep -q 'gooserelay' <<<"$OUT" && ok "the error lists the valid profiles and services" \
                               || bad "the error does not list what is valid"

# --- the same list drives stop / restart / logs / start -----------------------
run_moav stop xhttp
logged '^compose --profile xhttp stop$' && ok "moav stop xhttp stops the profile" \
    || bad "moav stop xhttp: $(tr '\n' ';' < "$WORK/docker.log")"
run_moav logs gooserelay -n
logged '^compose --ansi never --profile gooserelay logs' && ok "moav logs gooserelay reads the profile" \
    || bad "moav logs gooserelay: $(tr '\n' ';' < "$WORK/docker.log")"

# --- static: no second list, and the per-profile tables are complete ----------
hits=$(grep -nE '(profiles|valid_profiles)="[a-z]+ [a-z]+ ' "$ROOT"/lib/*.sh "$ROOT/moav.sh" || true)
[ -z "$hits" ] && ok "no hardcoded profile list is left in moav.sh / lib/" \
               || bad "hardcoded profile list: $hits"
for fn in cmd_build cmd_start cmd_stop cmd_restart cmd_logs; do
    body=$(sed -n "/^$fn()/,/^}/p" "$ROOT"/lib/build.sh "$ROOT"/lib/service.sh)
    grep -qE 'build_target|is_compose_profile|compose_profiles' <<<"$body" \
        && ok "$fn takes its profiles from docker-compose.yml" \
        || bad "$fn does not use compose_profiles"
done

enabled_fn=$(sed -n '/^profile_enabled()/,/^}/p' "$ROOT/lib/service.sh")
derive_fn=$(sed -n '/^derive_enabled_profiles()/,/^}/p' "$ROOT/lib/service.sh")
completion=$(grep -m1 'local profiles=' "$ROOT/completions/moav.bash")
no_flag=""; no_derive=""; no_completion=""
for p in $PROFILES; do
    case "$p" in all|setup|client) ;; *)
        grep -qE "^ +$p\)" <<<"$enabled_fn" || no_flag="$no_flag $p"
        # monitoring is opt-in at start time, never part of the derived default.
        [ "$p" = monitoring ] || grep -qE "for p in .*\b$p\b" <<<"$derive_fn" || no_derive="$no_derive $p" ;;
    esac
    # setup holds the bootstrap one-shots; not something to tab-complete.
    [ "$p" = setup ] || grep -qE "[\" ]${p}[\" ]" <<<"$completion" || no_completion="$no_completion $p"
done
[ -z "$no_flag" ] && ok "profile_enabled maps every service profile to its ENABLE_* flag" \
                  || bad "profile_enabled has no case for:$no_flag"
[ -z "$no_derive" ] && ok "derive_enabled_profiles covers every service profile" \
                    || bad "derive_enabled_profiles misses:$no_derive"
[ -z "$no_completion" ] && ok "shell completion offers every profile" \
                        || bad "completions/moav.bash misses:$no_completion"

echo ""
if [ "$fail" -gt 0 ]; then echo "FAILED ($fail failed, $pass passed)"; exit 1; fi
echo "PASSED ($pass checks)"
