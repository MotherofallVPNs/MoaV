#!/bin/bash
# Regression: `moav update` / `moav build` / `moav apply` under a restrictive
# umask must still leave files the non-root containers can read.
#
# Hit on a live server updated from the MoaV Deploy app, whose SSH/exec session
# carries umask 077: git wrote the checkout 0600/0700 and `docker build` COPY'd
# those modes into the images (`chmod +x` on 0700 gives 0711: no read bit).
#   admin (uid 2000)   PermissionError: /project/VERSION
#   prometheus (nobody) prometheus.yml: permission denied
#   dns-router (moav)   /app/entrypoint.sh: Permission denied
# The same update from a login shell (umask 022) was fine.
#
# Covered here: the umask chokepoints, the checkout repair on every path that
# can follow a bad pull, the Dockerfile mode pins, `moav doctor perms`, and a
# real image built from an owner-only checkout (needs docker; skipped without).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
finish() {
    echo ""
    echo "  passed: $pass   failed: $fail"
    [ "$fail" -eq 0 ]
    exit $?
}
mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
fn_body() { sed -n "/^$2()/,/^}/p" "$ROOT/$1"; }

echo "umask-safe update / build / apply"

# --- 1. static: where umask 022 is enforced -----------------------------------
u=$(grep -nE '^umask 022$' "$ROOT/moav.sh" | head -1 | cut -d: -f1)
s=$(grep -nE '^source ' "$ROOT/moav.sh" | head -1 | cut -d: -f1)
if [ -n "$u" ] && [ -n "$s" ] && [ "$u" -lt "$s" ]; then
    ok "moav.sh sets umask 022 before it sources any module"
else
    bad "moav.sh does not set umask 022 ahead of the modules (umask line: ${u:-none})"
fi
u=$(grep -nE '^umask 022$' "$ROOT/install.sh" | head -1 | cut -d: -f1)
c=$(grep -nE '^\s+git clone ' "$ROOT/install.sh" | head -1 | cut -d: -f1)
if [ -n "$u" ] && [ -n "$c" ] && [ "$u" -lt "$c" ]; then
    ok "install.sh sets umask 022 before the clone"
else
    bad "install.sh clones without setting umask 022 first"
fi
for spec in lib/update.sh:cmd_update lib/build.sh:cmd_build lib/build.sh:compose_build \
            lib/build.sh:build_local_images lib/apply.sh:cmd_apply; do
    f="${spec%%:*}"; fn="${spec#*:}"
    if grep -qE '^\s+umask 022(\s|$)' <<<"$(fn_body "$f" "$fn")"; then
        ok "$fn sets umask 022"
    else
        bad "$fn ($f) does not set umask 022"
    fi
done
# Every path that can follow a pull made under 077 has to repair the checkout.
for spec in lib/build.sh:compose_build lib/build.sh:build_local_images lib/apply.sh:cmd_apply \
            lib/update.sh:cmd_update lib/service.sh:ensure_perms_repaired; do
    f="${spec%%:*}"; fn="${spec#*:}"
    if grep -qE '^\s+repair_checkout_perms$' <<<"$(fn_body "$f" "$fn")"; then
        ok "$fn repairs the checkout permissions"
    else
        bad "$fn ($f) does not call repair_checkout_perms"
    fi
done
if grep -qE '^\s+repair_checkout_perms$' <<<"$(sed -n '/^        _post-update)/,/;;/p' "$ROOT/moav.sh")"; then
    ok "_post-update repairs what the previous moav's pull wrote"
else
    bad "_post-update does not call repair_checkout_perms (the pull runs in the OLD moav)"
fi
if grep -qE '\( umask 077; tar -czf "\$output_file"' "$ROOT/lib/migrate.sh"; then
    ok "moav export still writes its archive owner-only"
else
    bad "moav export archive follows the process umask (now 022): private keys world-readable"
fi
if grep -q 'except OSError' <<<"$(sed -n '/^CURRENT_VERSION = /,/^$/p' "$ROOT/admin/main.py")"; then
    ok "admin tolerates an unreadable VERSION instead of crash-looping"
else
    bad "admin/main.py only catches FileNotFoundError when reading VERSION"
fi

# --- 2. static: Dockerfiles pin the modes of what they COPY from the checkout --
DF=("$ROOT"/dockerfiles/Dockerfile.* "$ROOT"/exporters/*/Dockerfile)
hits=$(grep -nE 'chmod \+x .*(entrypoint\.sh|/app/\*\.sh)' "${DF[@]}" || true)
[ -z "$hits" ] && ok "no entrypoint relies on 'chmod +x' (0700 + x = 0711, unreadable)" \
               || bad "'chmod +x' on a COPY'd entrypoint: $hits"
for d in "${DF[@]}"; do
    name="${d#"$ROOT"/}"
    # Destinations of final-stage COPYs from the build context (no --from).
    while read -r dest; do
        [ -n "$dest" ] || continue
        case "$dest" in
            */entrypoint.sh)      want="chmod 755 [^&]*${dest}" ;;
            /app/|.)              want='chmod (755 /app/\*\.sh|644 /app/\*\.py|-R u=rwX,go=rX /app)' ;;
            *)                    want="chmod (644|755) [^&]*${dest}" ;;
        esac
        if grep -qE -- "$want" "$d"; then
            ok "$name pins the mode of $dest"
        else
            bad "$name COPYs $dest from the checkout without pinning its mode"
        fi
    done < <(awk '
        /^FROM /            { stage++; delete dests; n = 0 }
        /^COPY / && !/--from/ { n++; dests[n] = $NF }
        END                 { for (i = 1; i <= n; i++) print dests[i] }' "$d" | sort -u)
done

# --- 3. functional: an install cloned and updated under umask 077 --------------
if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    echo "  SKIP  functional part needs a git checkout"; finish
fi
# /bin/bash too: `moav update` re-execs moav.sh through its shebang.
RUN_CLI=1
if (( BASH_VERSINFO[0] < 4 )) || [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null || echo 0)" -lt 4 ]; then
    echo "  SKIP  CLI part needs bash >= 4, also as /bin/bash (moav does too)"; RUN_CLI=0
fi

WORK="$(mktemp -d)"
IMG="moav-umask-test-$$"
REAL_PATH="$PATH"
cleanup() {
    PATH="$REAL_PATH" docker rmi -f "$IMG" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT
chmod 755 "$WORK"

# Logs every call with the mode VERSION has at that moment; FAKE_* shape replies.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/docker" <<DOCKER
#!/bin/bash
m=\$(stat -c '%a' VERSION 2>/dev/null || stat -f '%Lp' VERSION 2>/dev/null)
echo "VERSION=\$m umask=\$(umask) \$*" >> "$WORK/docker.log"
case "\$*" in
  "image prune"*)           echo "Total reclaimed space: 0B" ;;
  *"config --images"*)      printf '%s\n' \${FAKE_IMAGES:-} ;;
  "image inspect"*)         [ -n "\${FAKE_INSPECT:-}" ] || exit 1; echo "\$FAKE_INSPECT" ;;
  "run --rm --network none --entrypoint /bin/sh"*) exit "\${FAKE_PROBE_RC:-0}" ;;
esac
exit 0
DOCKER
chmod 755 "$WORK/bin/docker"

# origin = this working tree as one commit; v2 changes what the bug report named.
SRC="$WORK/src"; mkdir -p "$SRC"
( cd "$ROOT" && git ls-files -z | xargs -0 tar cf - 2>/dev/null ) | ( cd "$SRC" && tar xf - )
g() { git -c user.name=t -c user.email=t@example.invalid -c init.defaultBranch=main "$@"; }
(
    umask 022
    cd "$SRC" && chmod -R u+rwX,go+rX . && g init -q && g checkout -q -b main 2>/dev/null
    g add -A && g commit -q -m v1
    g init -q --bare "$WORK/origin.git" && g remote add origin "$WORK/origin.git" && g push -q origin main
) || { echo "git setup failed"; exit 1; }
V1=$(git -C "$SRC" rev-parse --short HEAD)
(
    umask 022
    cd "$SRC"
    echo "9.9.9" > VERSION
    echo "# v2" >> configs/monitoring/prometheus.yml
    echo "# v2" >> lib/update.sh
    mkdir -p newdir && printf '#!/bin/sh\n' > newdir/tool.sh && chmod 755 newdir/tool.sh && echo data > newdir/data.txt
    g add -A && g commit -q -m v2
) || { echo "git setup failed"; exit 1; }

# A fresh install the way the app's session makes one: every path owner-only.
make_install() {  # <dir>
    ( umask 077; git clone -q "$WORK/origin.git" "$1" ) || return 1
    ( umask 077; cd "$1" && cp .env.example .env && chmod 600 .env \
        && mkdir -p state outputs && echo secret > state/key )
}
push_v2() { ( cd "$SRC" && g push -q origin main ); }

# Everything outside .git that "other" cannot read (files) or enter (dirs).
unreadable() {  # <dir>
    ( cd "$1" && find . -path ./.git -prune -o \
        \( -type d ! -perm -005 -print \) -o \( -type f ! -perm -004 -print \) | sort | tr '\n' ' ' )
}
# What must stay private however the checkout is repaired.
PRIVATE="./.env ./outputs ./state ./state/key "
moav() {  # <dir> <args...>: the real moav.sh, called from a umask-077 session
    local d="$1"; shift
    OUT=$( cd "$d" && umask 077 && env PATH="$WORK/bin:$REAL_PATH" MOAV_NONINTERACTIVE=1 \
            bash ./moav.sh "$@" 2>&1 < /dev/null ); RC=$?
}
assert_readable() {  # <label> <dir>
    local label="$1" d="$2" left
    left=$(unreadable "$d")
    [ "$left" = "$PRIVATE" ] \
        && ok "$label: every checkout path is readable; .env, state/ and outputs/ stay private" \
        || bad "$label: owner-only paths left (want only: $PRIVATE): $left"
}

if [ "$RUN_CLI" = "1" ]; then
# 3a. precondition: the simulation really produces the reported state.
A="$WORK/a"; make_install "$A" || { echo "install setup failed"; exit 1; }
[ "$(mode "$A/VERSION")" = "600" ] && [ "$(mode "$A/lib")" = "700" ] && [ "$(mode "$A/moav.sh")" = "700" ] \
    && ok "a clone under umask 077 is owner-only (VERSION 600, lib/ 700, moav.sh 700)" \
    || bad "setup: expected an owner-only clone, got VERSION=$(mode "$A/VERSION") lib=$(mode "$A/lib")"

# 3b. `moav update --yes` from that session: pull + re-exec into _post-update.
push_v2
moav "$A" update --yes
[ "$RC" = "0" ] && ok "update under umask 077: exit 0" || bad "update under umask 077: rc=$RC"$'\n'"$OUT"
[ "$(cat "$A/VERSION")" = "9.9.9" ] && ok "update pulled v2" || bad "update did not pull v2"$'\n'"$OUT"
assert_readable "update under umask 077" "$A"
for spec in VERSION:644 docker-compose.yml:644 lib/update.sh:644 configs/monitoring/prometheus.yml:644 \
            moav.sh:755 newdir:755 newdir/tool.sh:755 newdir/data.txt:644 .env:600; do
    f="${spec%%:*}"; want="${spec#*:}"
    [ "$(mode "$A/$f")" = "$want" ] && ok "after update: $f is $want" \
                                    || bad "after update: $f is $(mode "$A/$f"), want $want"
done
[ "$(mode "$A")" = "755" ] && ok "after update: the install dir itself can be entered (admin mounts it)" \
                           || bad "after update: install dir is $(mode "$A")"

# 3c. the pull was made by an OLDER moav (no umask fix): only _post-update is new.
B="$WORK/b"; make_install "$B"   # origin is at v2 now: rewind, then pull as old code would
( cd "$B" && umask 077 && git reset -q --hard "$V1" && git pull -q origin main ) >/dev/null 2>&1
[ "$(mode "$B/VERSION")" = "600" ] || bad "setup: old-moav pull should leave VERSION 600"
moav "$B" _post-update "$V1"
[ "$RC" = "0" ] && ok "_post-update after an old moav's pull: exit 0" || bad "_post-update: rc=$RC"$'\n'"$OUT"
assert_readable "_post-update after an old moav's pull" "$B"

# 3d. build: the checkout is repaired BEFORE docker reads the build context.
C="$WORK/c"; make_install "$C"
: > "$WORK/docker.log"
moav "$C" build dns-router
[ "$RC" = "0" ] && ok "build under umask 077: exit 0" || bad "build under umask 077: rc=$RC"$'\n'"$OUT"
line=$(grep -E ' build( |$).*dns-router' "$WORK/docker.log" | head -1)
case "$line" in
    "VERSION=644 umask=0022 "*) ok "docker build ran with umask 022 on a readable context" ;;
    "")                         bad "build never reached docker: $(cat "$WORK/docker.log")" ;;
    *)                          bad "docker build saw an owner-only context or a 077 umask: $line" ;;
esac
assert_readable "build under umask 077" "$C"

# 3e. `moav start`/`restart` heal bind mounts too (ensure_perms_repaired).
D="$WORK/d"; make_install "$D"
moav "$D" doctor perms
[ "$RC" = "1" ] && ok "doctor perms fails on an owner-only checkout" || bad "doctor perms: rc=$RC, want 1"$'\n'"$OUT"
grep -q 'owner-only' <<<"$OUT" && grep -q 'VERSION' <<<"$OUT" \
    && ok "doctor perms names the unreadable paths" || bad "doctor perms did not list the paths:"$'\n'"$OUT"
grep -q 'moav doctor perms --fix && moav restart' <<<"$OUT" \
    && ok "doctor perms prints the fix" || bad "doctor perms did not print the fix"
[ "$(mode "$D/VERSION")" = "600" ] && ok "doctor perms (no --fix) changes nothing" \
                                  || bad "doctor perms without --fix modified the checkout"
moav "$D" doctor perms --json
[ "$RC" = "1" ] && grep -q '"id": "perms", "status": "fail"' <<<"$OUT" \
    && ok "doctor perms --json reports status fail" || bad "doctor perms --json: rc=$RC"$'\n'"$OUT"
moav "$D" doctor perms --fix
[ "$RC" = "0" ] && ok "doctor perms --fix: exit 0" || bad "doctor perms --fix: rc=$RC"$'\n'"$OUT"
assert_readable "doctor perms --fix" "$D"
moav "$D" doctor perms
[ "$RC" = "0" ] && ok "doctor perms passes after the fix" || bad "doctor perms after fix: rc=$RC"$'\n'"$OUT"

# 3f. doctor perms: a locally built non-root image with an unreadable entrypoint.
FAKE_IMAGES="moav-dns-router prom/prometheus:v3@sha256:abc" FAKE_INSPECT="moav|/app/entrypoint.sh" FAKE_PROBE_RC=1
export FAKE_IMAGES FAKE_INSPECT FAKE_PROBE_RC
: > "$WORK/docker.log"
moav "$D" doctor perms
[ "$RC" = "1" ] && grep -q "moav-dns-router: /app/entrypoint.sh is not readable or executable by its user 'moav'" <<<"$OUT" \
    && ok "doctor perms flags a baked entrypoint its user cannot read" \
    || bad "doctor perms missed the unreadable baked entrypoint: rc=$RC"$'\n'"$OUT"
grep -q 'Fix: moav apply dns-router --no-cache' <<<"$OUT" \
    && ok "doctor perms prints the rebuild fix for the image" || bad "no rebuild fix printed:"$'\n'"$OUT"
grep -q 'image inspect.*prom/prometheus' "$WORK/docker.log" \
    && bad "doctor perms probed a registry image (only locally built ones can be affected)" \
    || ok "doctor perms leaves registry images alone"
FAKE_PROBE_RC=0
moav "$D" doctor perms
[ "$RC" = "0" ] && grep -q 'non-root image(s) are readable' <<<"$OUT" \
    && ok "doctor perms passes when the image user can read its entrypoint" \
    || bad "doctor perms with a healthy image: rc=$RC"$'\n'"$OUT"
FAKE_INSPECT="|/entrypoint.sh"
: > "$WORK/docker.log"
moav "$D" doctor perms
grep -q 'run --rm' "$WORK/docker.log" \
    && bad "doctor perms probed an image that runs as root" || ok "doctor perms skips images that run as root"
unset FAKE_IMAGES FAKE_INSPECT FAKE_PROBE_RC
fi

# --- 4. a real image built from an owner-only checkout -------------------------
PATH="$REAL_PATH"
if [ "${MOAV_TEST_SKIP_DOCKER:-0}" = "1" ] || ! docker info >/dev/null 2>&1; then
    echo "  SKIP  image build (docker unavailable or MOAV_TEST_SKIP_DOCKER=1)"; finish
fi
E="$WORK/e"; make_install "$E"
[ "$(mode "$E/scripts/dns-router-entrypoint.sh")" = "700" ] && [ "$(mode "$E/VERSION")" = "600" ] \
    || bad "setup: build context should be owner-only"
# Raw docker build, no repair first: the Dockerfile alone has to hold.
if ! out=$(docker build -q -f "$E/dockerfiles/Dockerfile.dns-router" -t "$IMG" "$E" 2>&1); then
    bad "docker build of dns-router from an owner-only checkout failed:"$'\n'"$out"; finish
fi
probe=$(docker run --rm --network none --entrypoint /bin/sh "$IMG" -c \
    'id -u; test -r /app/entrypoint.sh && test -x /app/entrypoint.sh && echo ENTRYPOINT_OK; test -r /VERSION && echo VERSION_OK' 2>&1)
uid=$(head -1 <<<"$probe")
[ -n "$uid" ] && [ "$uid" != "0" ] && ok "dns-router image runs as a non-root user (uid $uid)" \
                                   || bad "dns-router image does not run as non-root: $probe"
grep -q ENTRYPOINT_OK <<<"$probe" \
    && ok "image built from an owner-only checkout: its user can read and run /app/entrypoint.sh" \
    || bad "/app/entrypoint.sh is not readable/executable by the image user (the reported crash-loop): $probe"
grep -q VERSION_OK <<<"$probe" && ok "its user can read /VERSION" || bad "/VERSION is not readable by the image user: $probe"

finish
