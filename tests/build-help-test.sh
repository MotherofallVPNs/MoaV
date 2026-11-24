#!/bin/bash
# Regression test: `moav build --help` / `-h` print usage and build nothing.
#
# cmd_build passed every non-flag argument through as a service name, so
# `--help` went to resolve_services and on to `docker compose build`. This runs
# the real moav.sh in a scratch install with a fake docker that logs its calls.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "moav build --help"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
APP="$WORK/moav"; mkdir -p "$APP/scripts" "$WORK/bin"
cp "$ROOT/moav.sh" "$APP/moav.sh"; chmod +x "$APP/moav.sh"
ln -s "$ROOT/lib" "$APP/lib"
cp "$ROOT/VERSION" "$APP/VERSION"
for f in "$ROOT"/scripts/*; do ln -s "$f" "$APP/scripts/$(basename "$f")"; done
# A .env, so the old code went straight to the build instead of prompting.
printf 'DOMAIN=\n' > "$APP/.env"

cat > "$WORK/bin/docker" <<DOCKER
#!/bin/bash
echo "\$*" >> "$WORK/docker.log"
exit 0
DOCKER
chmod +x "$WORK/bin/docker"

for flag in --help -h; do
    : > "$WORK/docker.log"
    out=$(cd "$APP" && PATH="$WORK/bin:$PATH" MOAV_NONINTERACTIVE=1 bash ./moav.sh build "$flag" 2>&1 < /dev/null)
    rc=$?
    [ "$rc" -eq 0 ] && ok "build $flag exits 0" || bad "build $flag exited $rc"
    grep -q '^Usage: moav build' <<<"$out" \
        && ok "build $flag prints the build usage" \
        || bad "build $flag printed no usage: $(head -3 <<<"$out")"
    if grep -q 'build' "$WORK/docker.log"; then
        bad "build $flag ran a build: $(grep -m1 build "$WORK/docker.log")"
    else
        ok "build $flag builds nothing"
    fi
done

# Normal argument handling is unchanged: a service still reaches compose build.
: > "$WORK/docker.log"
(cd "$APP" && PATH="$WORK/bin:$PATH" MOAV_NONINTERACTIVE=1 bash ./moav.sh build xray --no-cache >/dev/null 2>&1 < /dev/null)
grep -qE 'compose .*build --no-cache xray' "$WORK/docker.log" \
    && ok "build xray --no-cache still builds xray" \
    || bad "build xray --no-cache: no compose build call (log: $(tr '\n' ';' < "$WORK/docker.log"))"

echo ""
if [ "$fail" -gt 0 ]; then echo "FAILED ($fail failed, $pass passed)"; exit 1; fi
echo "PASSED ($pass checks)"
