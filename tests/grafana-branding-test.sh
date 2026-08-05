#!/bin/bash
# Regression test: grafana branding writes must never crash-loop the container.
#
# The grafana entrypoint patches cosmetic branding into the image's public dir.
# On some images/hosts that dir is not writable even as root (observed live on a
# DigitalOcean droplet with grafana/grafana:latest), so the writes fail with
# "Permission denied". Every such write MUST be non-fatal under `set -e` — one
# unguarded `cat >` used to kill the entrypoint and restart-loop grafana.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
f="$ROOT/scripts/grafana-entrypoint.sh"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "grafana branding non-fatal tests"

# No bare `cat > "$GRAFANA_*"` — must be guarded (if cat / || true).
if grep -nE '^\s*cat > "\$GRAFANA' "$f" >/dev/null; then
    bad "unguarded 'cat > \$GRAFANA...' — a read-only image dir crash-loops grafana"
else
    ok "no unguarded cat-redirect into the grafana image dir"
fi

# The specific logo write is inside an `if cat ... then ... else` (non-fatal).
if grep -q 'if cat > "\$GRAFANA_IMG/grafana_icon.svg"' "$f"; then
    ok "grafana_icon.svg write is guarded (if cat)"
else
    bad "grafana_icon.svg write is not guarded with 'if cat'"
fi

# Functional: the exact guard pattern is non-fatal under set -e on a failed write.
if sh -c 'set -eu
if cat > /nonexistent-ro/x 2>/dev/null <<E
<svg/>
E
then :; else :; fi
exit 0'; then
    ok "if-cat guard is non-fatal under set -e (reaches exec)"
else
    bad "guard still aborts under set -e"
fi

echo ""
echo "  $pass passed, $fail failed"
[[ $fail -eq 0 ]]
