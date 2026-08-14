#!/bin/bash
# Regression test: sing-box must not write a user's destinations to disk. #297
#
# sing-box logs "[username] inbound connection to <host>:443" at INFO, and every
# line carries a connection id that ties that username to the client IP logged
# on a different line. Scrubbing only the obvious line would leave the pairing
# reconstructable through the id, so the destination has to come off every shape
# the log produces.
#
# The awk program under test is extracted from the shipped entrypoint, not
# copied here -- a test with its own copy would keep passing after the real one
# drifted.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRY="$ROOT/scripts/sing-box-entrypoint.sh"
EXPORTER="$ROOT/exporters/singbox/main.py"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "sing-box log scrubbing (#297)"

# Verbatim shapes from a live server, covering every line that carried a
# destination in a 3000-line sample.
FIXTURE=$(cat <<'LOG'
INFO [3883633974 0ms] inbound/vless[vless-reality-in]: inbound connection from 89.196.4.82:20159
INFO [3883633974 1.18s] inbound/vless[vless-reality-in]: [aug8_ykr15] inbound connection to scontent.cdninstagram.com:443
INFO [1264076553 1.2s] inbound/vless[vless-reality-in]: [aug8_ykr15] inbound packet connection to 8.8.8.8:53
INFO [453647460 1.1s] outbound/direct[direct]: outbound connection to graph.facebook.com:443
INFO [497090584 0.9s] outbound/direct[direct]: outbound connection to 157.240.196.40:443
INFO [2543373071 0.4s] dns: exchanged A scontent.cdninstagram.com. 55 IN A 157.240.196.40
INFO [1023548901 0.3s] dns: exchanged AAAA mtalk.google.com. 228 IN AAAA 2a00:1450::200e
INFO [3937803010 0.2s] dns: lookup succeed for z-m-gateway.facebook.com: 157.240.196.40
ERROR [3213091123 0.1s] dns: lookup failed for badhost.example.org: connection refused
INFO [4001 1.40s] dns: cached CNAME test-gateway.instagram.com. 0 IN CNAME dgw-ig.c10r.facebook.com.
INFO [4002 1.60s] dns: cached A scontent.cdninstagram.com. 2 IN A 157.240.196.63
INFO [4003 0.5s] dns: some-future-verb whatever.example.net. 30 IN A 1.2.3.4
ERROR [3406667087 1.37s] inbound/vless[vless-reality-in]: process connection from 178.176.84.148:25746: EOF
LOG
)

# Pull the scrubber out of the entrypoint so this tests what actually ships.
PROG=$(python3 - "$ENTRY" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r"awk '(\{.*?\})'\s*<", s, re.S)
sys.stdout.write(m.group(1) if m else "")
PY
)
if [ -z "$PROG" ]; then
    bad "could not find the scrubber awk program in the entrypoint"
    echo "  passed: $pass   failed: $fail"; exit 1
fi
ok "the scrubber is defined in the shipped entrypoint"

SCRUBBED=$(printf '%s\n' "$FIXTURE" | awk "$PROG")

# --- no destination may survive ------------------------------------------------
leaked=$(grep -oE '[a-z0-9-]+\.[a-z0-9.-]+\.[a-z]{2,}' <<<"$SCRUBBED" | sort -u | tr '\n' ' ')
[ -z "$leaked" ] \
    && ok "no domain-shaped token survives, in any line shape" \
    || bad "destination still on disk: $leaked"

# Destination IPs too. Client IPs are allowed, so check the known ones by value.
leaked=""
for dest in 157.240.196.40 157.240.196.63 2a00:1450::200e 8.8.8.8 1.2.3.4; do
    grep -qF "$dest" <<<"$SCRUBBED" && leaked="$leaked $dest"
done
[ -z "$leaked" ] \
    && ok "no destination IP survives either" \
    || bad "destination IP still on disk:$leaked"

# --- what the exporter needs must survive --------------------------------------
# Scrubbing too hard is the other failure: it silently empties the dashboards.
grep -q '89.196.4.82' <<<"$SCRUBBED" \
    && ok "the client IP is kept (per-user country needs it)" \
    || bad "the client IP was scrubbed too; user country would go back to XX"
grep -q 'aug8_ykr15' <<<"$SCRUBBED" \
    && ok "the username is kept (per-user counting needs it)" \
    || bad "the username was scrubbed; per-user metrics would go empty"
grep -q 'connection refused' <<<"$SCRUBBED" \
    && ok "a DNS failure reason is kept (it names no host)" \
    || bad "the failure reason went with the hostname, making DNS undebuggable"

# --- the exporter's own regexes must still match -------------------------------
SCRUB_FILE=$(mktemp); printf '%s\n' "$SCRUBBED" > "$SCRUB_FILE"
trap 'rm -f "$SCRUB_FILE"' EXIT
out=$(python3 - "$EXPORTER" "$SCRUB_FILE" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
def pat(n): return re.compile(re.search(n + r" = re\.compile\(r'(.+?)'\)", s).group(1))
UP, CF, CI = pat("USER_PATTERN"), pat("CONN_FROM_PATTERN"), pat("CONN_ID_PATTERN")
scrub = open(sys.argv[2]).read().splitlines()
print("USER=%s"     % any(UP.search(l) for l in scrub))
print("CONNFROM=%s" % any(CF.search(l) for l in scrub))
print("PAIRED=%s"   % any(CI.search(l) and UP.search(l) for l in scrub))
PY
)
grep -q 'USER=True' <<<"$out" && grep -q 'CONNFROM=True' <<<"$out" && grep -q 'PAIRED=True' <<<"$out" \
    && ok "the exporter's user, source-IP and id patterns all still match" \
    || bad "scrubbing broke a pattern the exporter depends on: $out"

# --- the raw stream must never touch the log volume ----------------------------
grep -q 'RAW_LOG="/tmp/' "$ENTRY" \
    && ok "the unscrubbed stream is a FIFO on tmpfs, never the log volume" \
    || bad "the raw log path is not under /tmp; unscrubbed lines could persist"
grep -q 'sleep 3600; done ) <> "$RAW_LOG"' "$ENTRY" \
    && ok "the FIFO is held open, so sing-box never blocks on open()" \
    || bad "nothing pins the FIFO open; sing-box could block or see EOF"
grep -q 'Cleared the pre-scrub log' "$ENTRY" \
    && ok "an upgrade clears the log written before scrubbing existed" \
    || bad "the pre-scrub log survives the upgrade that fixed it"
grep -A2 'awk .{$' "$ENTRY" >/dev/null; grep -q 'sleep 1' "$ENTRY" \
    && ok "the scrubber is restarted if it dies (a full pipe blocks sing-box)" \
    || bad "no restart loop around the scrubber"

echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
