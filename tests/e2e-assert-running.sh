#!/usr/bin/env bash
# e2e harness: fail if a long-lived moav-* container is down or crash-looping.
# Usage: e2e-assert-running.sh <baseline-file> [--since-baseline]
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

baseline="${1:?usage: $0 <baseline-file> [--since-baseline]}"
since="${2:-}"

echo "::group::container states"
docker ps -a --filter 'name=^moav-' --format '{{.Names}}\t{{.State}}\t{{.Status}}'
echo "::endgroup::"
# One-shots are derived from docker-compose.yml (no restart policy), never hand-listed.
python3 -c 'import yaml; d=yaml.safe_load(open("docker-compose.yml"))["services"]; print("\n".join("moav-"+n for n,v in sorted(d.items()) if v.get("restart") is None))' > /tmp/oneshot.txt
echo "::group::one-shot services (exiting is correct)"; cat /tmp/oneshot.txt; echo "::endgroup::"

# `docker ps --format` has no .ExitCode field (a template using it inspected nothing);
# the exit code lives in .Status ("Exited (1) ...", "Restarting (2) ...").
bad=0; seen=0; failed=()
while IFS=$'\t' read -r name state status; do
    [ -n "$name" ] || continue
    seen=$((seen+1))
    exitcode=$(printf '%s' "$status" | sed -nE 's/^(Exited|Restarting) \(([0-9]+)\).*/\2/p')
    if grep -qxF "$name" /tmp/oneshot.txt; then
        # Exiting is correct, but exiting NON-ZERO never is.
        if [ "$state" != "running" ] && [ "${exitcode:-0}" != "0" ]; then
            echo "::error::$name is a one-shot job that failed (exit $exitcode: $status)"; bad=1; failed+=("$name")
        fi
        continue
    fi
    case "$state" in
        running) ;;
        restarting) echo "::error::$name is RESTARTING ($status) — crash loop"; bad=1; failed+=("$name") ;;
        *)          echo "::error::$name is $state ($status) — expected running"; bad=1; failed+=("$name") ;;
    esac
done < <(docker ps -a --filter 'name=^moav-' --format '{{.Names}}\t{{.State}}\t{{.Status}}')
[ "$seen" -gt 0 ] || { echo "::error::docker ps listed no moav-* containers (format/template error?)"; exit 1; }

# A crash-looping container samples as "running" most of the time. RestartCount
# grows only on crashes (a manual restart resets it to 0, so compare StartedAt too).
counts=$(docker ps -aq --filter 'name=^moav-' \
    | xargs -r docker inspect -f '{{.Name}} {{.RestartCount}} {{.State.StartedAt}}' | sed 's#^/##' | sort)
if [ "$since" = "--since-baseline" ]; then
    [ -f "$baseline" ] || { echo "::error::no restart baseline at $baseline"; exit 1; }
    while read -r name n started; do
        grep -qxF "$name" /tmp/oneshot.txt && continue
        [ "${n:-0}" -gt 0 ] || continue
        if ! grep -qxF "$name $n $started" "$baseline"; then
            echo "::error::$name crashed after the first health check (RestartCount $n, last start $started)"
            bad=1; failed+=("$name")
        fi
    done <<< "$counts"
else
    printf '%s\n' "$counts" > "$baseline"
fi
echo "::group::restart counts"; printf '%s\n' "$counts"; echo "::endgroup::"

if [ "$bad" -ne 0 ]; then
    echo "--- logs from the failed container(s) ---"
    printf '%s\n' "${failed[@]}" | sort -u | while read -r c; do
        echo "::group::$c"; docker logs --tail 30 "$c" 2>&1; echo "::endgroup::"
    done
    exit 1
fi
echo "All long-lived moav-* containers are running${since:+ with no crashes since the baseline}."
