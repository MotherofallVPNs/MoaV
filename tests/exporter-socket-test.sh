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
for svc in singbox-exporter; do
    if printf '%s' "$holders" | grep -qx "$svc"; then
        bad "$svc has a raw Docker socket again — it should use the Clash API"
    else
        ok "$svc has no raw Docker socket (uses the Clash API)"
    fi
done

# Only docker-proxy is allowed one indefinitely.
for h in $holders; do
    case "$h" in
        docker-proxy) ok "docker-proxy keeps its socket (brokering it is its purpose)" ;;
        cadvisor|xray-exporter|wireguard-exporter|amneziawg-exporter)
            printf '  todo  %s still holds a raw socket (tracked)\n' "$h" ;;
        *) bad "$h holds a raw Docker socket and is not an expected holder" ;;
    esac
done

# The converted exporter must not shell out to docker at all.
if grep -qE "\['docker'|\"docker\"," "$ROOT/exporters/singbox/main.py"; then
    bad "singbox exporter still shells out to the docker CLI"
else
    ok "singbox exporter makes no docker CLI calls"
fi
if grep -qE '^[[:space:]]*RUN .*docker-cli' "$ROOT/exporters/singbox/Dockerfile"; then
    bad "singbox exporter image still installs docker-cli"
else
    ok "singbox exporter image no longer installs docker-cli"
fi

echo
echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]
