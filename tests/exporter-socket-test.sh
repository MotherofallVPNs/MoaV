#!/bin/bash
# Tracks the removal of raw Docker socket mounts from the monitoring stack.
#
# A container with /var/run/docker.sock has UNRESTRICTED Docker API access: it
# can create a privileged container with arbitrary bind mounts and take the
# host. Five monitoring containers held one, purely to shell out to `docker
# logs` / `docker exec`. Each is being converted to a first-class data path.
#
# docker-proxy legitimately keeps its mount -- brokering that socket IS its job,
# and it is isolated on the internal moav_mgmt network (network-isolation-test).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "monitoring stack: raw Docker socket removal"

C="$ROOT/docker-compose.yml"
owner_of() { awk -v n="$1" 'NR<=n && /^  [a-z0-9_-]+:$/{s=$0} NR==n{gsub(/[ :]/,"",s); print s}' "$C"; }

# `mapfile` is bash 4+; macOS ships 3.2. Build the list portably.
holders=""
while read -r ln; do
    [ -n "$ln" ] || continue
    holders="$holders$(owner_of "$ln")
"
done <<< "$(grep -n '^      - /var/run/docker.sock' "$C" | cut -d: -f1)"

# Converted already -- these must never regain the socket.
for svc in singbox-exporter wireguard-exporter amneziawg-exporter xray-exporter; do
    if printf '%s' "$holders" | grep -qx "$svc"; then
        bad "$svc has a raw Docker socket again"
    else
        ok "$svc has no raw Docker socket"
    fi
done

# Only docker-proxy is allowed one indefinitely.
for h in $holders; do
    case "$h" in
        docker-proxy) ok "docker-proxy keeps its socket (brokering it is its purpose)" ;;
        cadvisor)
            printf '  todo  %s still holds a raw socket (tracked)\n' "$h" ;;
        *) bad "$h holds a raw Docker socket and is not an expected holder" ;;
    esac
done

# Converted exporters must not shell out to the container runtime at all.
for e in singbox wireguard amneziawg xray; do
    if grep -qE "\['docker'|\"docker\"," "$ROOT/exporters/$e/main.py"; then
        bad "$e exporter still shells out to the docker CLI"
    else
        ok "$e exporter makes no docker CLI calls"
    fi
    if grep -qE '^[[:space:]]*RUN .*docker-cli' "$ROOT/exporters/$e/Dockerfile"; then
        bad "$e exporter image still installs docker-cli"
    else
        ok "$e exporter image no longer installs docker-cli"
    fi
done

# The tunnel containers must actually publish the state their exporters read,
# atomically -- a scrape must never see a half-written file.
for pair in "wireguard:wg" "amneziawg:awg"; do
    svc="${pair%%:*}"; cli="${pair##*:}"
    ep="$ROOT/scripts/${svc}-entrypoint.sh"
    grep -q 'publish_state()' "$ep" \
        && ok "$svc entrypoint publishes $cli state for its exporter" \
        || bad "$svc entrypoint no longer publishes state — its exporter has no data source"
    grep -q 'mv -f "$METRICS_STATE_FILE.tmp" "$METRICS_STATE_FILE"' "$ep" \
        && ok "$svc publishes atomically (tmp then rename)" \
        || bad "$svc writes state non-atomically — a scrape can read a partial file"
done

# And the volume must be wired: producer rw, consumer ro.
grep -q '      - moav_metrics:/var/lib/moav-metrics$' "$C" \
    && ok "tunnel containers mount moav_metrics read-write" \
    || bad "no read-write moav_metrics mount — nothing can publish state"
grep -q 'moav_metrics:/var/lib/moav-metrics:ro' "$C" \
    && ok "exporters mount moav_metrics read-only" \
    || bad "exporters do not mount moav_metrics read-only"

# xray publishes its ACCESS log to the shared volume (its error log still goes to
# stdout, so `moav logs xray` is unchanged) and caps it from the same loop that
# publishes stats -- no separate rotation process.
grep -q '"access": "/var/lib/moav-metrics/xray-access.log"' "$ROOT/configs/xray/config.json.template" \
    && ok "xray writes its access log to the shared volume" \
    || bad "xray access log is not published — its exporter has no event source"
grep -q '"loglevel"' "$ROOT/configs/xray/config.json.template" \
    && ok "xray error log still goes to stdout (moav logs xray unaffected)" \
    || bad "xray loglevel missing — check the log block"
grep -q 'cap_access_log' "$ROOT/scripts/xray-entrypoint.sh" \
    && ok "xray caps its access log (no unbounded growth)" \
    || bad "xray access log has no size cap — it will fill the volume"
grep -q 'publish_stats' "$ROOT/scripts/xray-entrypoint.sh" \
    && ok "xray publishes stats snapshots for its exporter" \
    || bad "xray no longer publishes stats snapshots"

# xray runs as a NON-ROOT user, and a named volume only inherits image ownership
# while it is EMPTY. Sharing moav_metrics with the root wireguard container (which
# writes to it immediately) left it root-owned, and xray died with exit 23,
# "failed to initialize access logger". Hence a dedicated volume plus a
# pre-created, chowned mountpoint in the image. Both halves are required.
grep -q 'moav_xray_metrics' "$C" \
    && ok "xray has a dedicated metrics volume (not shared with a root writer)" \
    || bad "xray shares moav_metrics — a root container writing first makes it unwritable for xray"
grep -q 'chown -R moav:moav /etc/xray /state /var/lib/moav-metrics' "$ROOT/dockerfiles/Dockerfile.xray" \
    && ok "xray image pre-creates and chowns its metrics mountpoint" \
    || bad "xray image does not chown /var/lib/moav-metrics — a fresh volume will be root-owned and xray will exit 23"

echo
echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]
