#!/bin/bash
# Regression test: one-shot containers must not be read as dead services.
#
# The e2e run failed on `moav-geoip-updater is exited (Exited (0)) — expected
# running`. geoip-updater downloads a database and exits 0; that is correct.
# The e2e step carried a hand-written list of one-shot jobs which had not been
# updated when geoip-updater and tor-geoip-updater were added, so a green stack
# failed the build.
#
# The list is derived from docker-compose.yml now. This test checks the rule
# still holds, and that the two other places which reason about one-shot jobs
# agree with it, because a hand-kept list is exactly what drifted.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "one-shot services: exiting is correct for them"

ONESHOT=$(python3 -c '
import yaml
d = yaml.safe_load(open("'"$ROOT"'/docker-compose.yml"))["services"]
print(" ".join(sorted(n for n, s in d.items() if s.get("restart") is None)))')

# --- the rule itself ----------------------------------------------------------
for want in bootstrap certbot geoip-updater tor-geoip-updater; do
    case " $ONESHOT " in
        *" $want "*) ok "$want is derived as one-shot" ;;
        *)           bad "$want has a restart policy, so e2e will require it to be running" ;;
    esac
done

# A long-lived service must never fall into the set, or a crash-looped proxy
# would be silently tolerated.
for must_run in sing-box xray wireguard prometheus grafana singbox-exporter; do
    case " $ONESHOT " in
        *" $must_run "*) bad "$must_run has no restart policy — e2e would stop checking it" ;;
        *)               ok "$must_run is still required to be running" ;;
    esac
done

# --- e2e must derive the list, not carry one ---------------------------------
E2E="$ROOT/.github/workflows/e2e.yml"
# The health check lives in a script the workflow calls (twice: start + after the mid-run steps).
E2E_CHECK=("$E2E" "$ROOT/tests/e2e-assert-running.sh")
grep -q 'tests/e2e-assert-running.sh' "$E2E" \
    && ok "e2e runs the container health check" \
    || bad "e2e no longer runs tests/e2e-assert-running.sh"
grep -q 'oneshot.txt' "${E2E_CHECK[@]}" \
    && ok "e2e derives the one-shot set from docker-compose.yml" \
    || bad "e2e is back to a hand-written list, which is what drifted"
grep -qE 'moav-certbot\|moav-bootstrap' "${E2E_CHECK[@]}" \
    && bad "the old hand-written allowlist is still in e2e" \
    || ok "the old hand-written allowlist is gone"

# A one-shot that FAILS must still fail the build; skipping by name alone would
# have hidden a broken bootstrap.
grep -q 'one-shot job that failed' "${E2E_CHECK[@]}" \
    && ok "a one-shot exiting non-zero still fails e2e" \
    || bad "one-shot jobs are skipped unconditionally, so a failing bootstrap passes"

# --- moav status must agree ---------------------------------------------------
# lib/service.sh hides some of these from `moav status` for the same reason.
# It may hide fewer (certbot is deferred, not hidden), but it must never hide a
# service that is genuinely long-lived.
HIDDEN=$(grep -oE 'local status_hide=" [^"]+"' "$ROOT/lib/service.sh" | sed -E 's/.*=" (.*)"/\1/')
drift=0
for h in $HIDDEN; do
    case " $ONESHOT " in
        *" $h "*) ;;
        *) bad "moav status hides '$h', which is a long-lived service"; drift=1 ;;
    esac
done
[ "$drift" = "0" ] && ok "moav status only hides services that legitimately exit"

echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
