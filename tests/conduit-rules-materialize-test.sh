#!/bin/bash
# Regression test: the Prometheus rules file must be materialized before compose
# bind-mounts it, and a Docker directory stand-in must be repaired.
#
# conduit_lifetime.rules.yml is gitignored and copied from its template by
# ensure_conduit_lifetime_rules (lib/service.sh). On the e2e runner the copy
# failed silently (configs/monitoring/ was root-owned), Docker created a
# root-owned DIRECTORY at the mount source, and Prometheus crash-looped on
# "read ...: is a directory" for weeks. The e2e RUNNING check missed it because
# `docker ps --format` has no .ExitCode field: the template errored, the loop
# read zero rows, and the step passed. Both halves are pinned here.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# shellcheck source=/dev/null
source "$ROOT/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/cert.sh"
# _root_prefix lives in moav.sh. "env" is a no-op wrapper: the retry runs with
# the same privileges, which is what makes the unwritable-parent case fail.
_root_prefix() { echo "env"; }
# shellcheck source=/dev/null
source "$ROOT/lib/service.sh"
: "${RED:=}" "${GREEN:=}" "${YELLOW:=}" "${BLUE:=}" "${CYAN:=}" "${WHITE:=}" "${NC:=}"

WORK="$(mktemp -d)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
SCRIPT_DIR="$WORK"
MON="$WORK/configs/monitoring"
RULES="$MON/conduit_lifetime.rules.yml"
mkdir -p "$MON"
cp "$ROOT/configs/monitoring/conduit_lifetime.rules.yml.template" "$RULES.template"

echo "ensure_conduit_lifetime_rules: Docker directory stand-in, missing file, existing file"

# 1. Missing file: copied from the template.
out=$(ensure_conduit_lifetime_rules 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ -f "$RULES" ] && cmp -s "$RULES" "$RULES.template"; then
    ok "missing rules file is copied from the template"
else
    bad "missing file: rc=$rc out=$out"
fi

# 2. Existing file is never clobbered (it holds the operator's banked offsets).
printf 'groups: []  # operator offsets\n' > "$RULES"
out=$(ensure_conduit_lifetime_rules 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grep -q 'operator offsets' "$RULES"; then
    ok "existing rules file is left untouched"
else
    bad "existing file clobbered or rc=$rc: $(cat "$RULES")"
fi

# 3. A directory stand-in (what Docker leaves when the file was missing at
#    `compose up`) is replaced by the real file, with a warning.
rm -f "$RULES"; mkdir "$RULES"
out=$(ensure_conduit_lifetime_rules 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ -f "$RULES" ] && cmp -s "$RULES" "$RULES.template" \
   && printf '%s' "$out" | grep -q "is a directory"; then
    ok "directory stand-in is replaced by the template file (and warned about)"
else
    bad "directory stand-in: rc=$rc exists_as_file=$([ -f "$RULES" ] && echo y || echo n) out=$out"
fi

# 4. Unwritable parent and no real privilege escalation: must FAIL LOUDLY
#    (non-zero + error text), not return 0 with nothing written. Root can write
#    anywhere, so this case only means something as a regular user.
if [ "$EUID" -ne 0 ]; then
    rm -f "$RULES"; chmod 555 "$MON"
    out=$(ensure_conduit_lifetime_rules 2>&1); rc=$?
    chmod 755 "$MON"
    if [ "$rc" -ne 0 ] && [ ! -e "$RULES" ] && printf '%s' "$out" | grep -qi "cannot write"; then
        ok "unwritable parent: non-zero exit and an error line, not silence"
    else
        bad "unwritable parent: rc=$rc out=$out"
    fi
else
    ok "unwritable-parent case skipped (running as root)"
fi

# 5. The start path must call it so a failure is reported but does not abort
#    the rest of the stack (|| true), and the textfile dir must be made
#    world-searchable for node-exporter's nobody user.
grep -qE '^\s*ensure_conduit_lifetime_rules \|\| true' "$ROOT/lib/service.sh" \
    && ok "start path reports a rules failure without aborting the stack" \
    || bad "ensure_clash_api_secret no longer calls ensure_conduit_lifetime_rules || true"
cert_metric_dir_ensure
mode=$(stat -f '%Lp' "$WORK/configs/monitoring/textfile" 2>/dev/null || stat -c '%a' "$WORK/configs/monitoring/textfile")
[ "$mode" = "755" ] \
    && ok "cert textfile dir is 755 (readable by node-exporter's nobody)" \
    || bad "cert textfile dir mode is $mode, expected 755"

# 6. e2e RUNNING check: no .ExitCode template (docker has none; the step then
#    inspects nothing), and it must refuse to pass with zero rows.
E2E="$ROOT/.github/workflows/e2e.yml"
grep -q '{{.ExitCode}}' "$E2E" \
    && bad "e2e uses {{.ExitCode}}, which docker ps rejects: the RUNNING check inspects nothing" \
    || ok "e2e RUNNING check does not use the nonexistent .ExitCode field"
grep -q 'listed no moav-\* containers' "$E2E" \
    && ok "e2e RUNNING check fails when it inspected no containers" \
    || bad "e2e RUNNING check can pass having inspected zero containers"
# The exit-code parser must read both Exited and Restarting statuses.
parse() { printf '%s' "$1" | sed -nE 's/^(Exited|Restarting) \(([0-9]+)\).*/\2/p'; }
[ "$(parse 'Exited (0) 54 seconds ago')" = "0" ] && [ "$(parse 'Restarting (2) 2 seconds ago')" = "2" ] \
   && [ "$(parse 'Exited (137) 1 minute ago')" = "137" ] && [ -z "$(parse 'Up 2 minutes (healthy)')" ] \
    && ok "exit code is parsed from .Status for Exited and Restarting" \
    || bad "exit-code parser: $(parse 'Exited (0) x')/$(parse 'Restarting (2) x')/$(parse 'Up 2m')"
grep -qF "sed -nE 's/^(Exited|Restarting) \\(([0-9]+)\\).*/\\2/p'" "$E2E" \
    && ok "e2e uses that parser" \
    || bad "e2e parser drifted from the one tested here"

echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
