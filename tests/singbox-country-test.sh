#!/bin/bash
# Regression test: the two country metrics in exporters/singbox/main.py.
#
# All three of these shipped broken at once and looked plausible on the
# dashboard, which is why they went unnoticed:
#   1. every open connection was recounted on every poll, so "connections"
#      was really "connection-polls" -- 42,428 against a true count in the
#      low hundreds
#   2. user -> country was only ever set from metadata.inboundUser, which
#      sing-box does not emit, so every user was "XX"
#   3. the "Users by Country" panel queried the connections metric
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "sing-box country metrics"

# --- the log lines must actually parse -----------------------------------------
# sing-box splits the client IP and the username across two lines joined by the
# connection id. Neither line alone can attribute a user to a country.
out=$(python3 - "$ROOT/exporters/singbox/main.py" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
def pat(name):
    return re.compile(re.search(name + r" = re\.compile\(r'(.+?)'\)", s).group(1))
CF, CI, UP = pat("CONN_FROM_PATTERN"), pat("CONN_ID_PATTERN"), pat("USER_PATTERN")

# Verbatim from a live server, after the entrypoint strips colour.
FROM = "INFO [3883633974 0ms] inbound/vless[vless-reality-in]: inbound connection from 89.196.4.82:20159"
USER = "INFO [3883633974 1.18s] inbound/vless[vless-reality-in]: [aug8_ykr15] inbound connection to a.example.com:443"
ERR  = "ERROR [3883633974 1.37s] inbound/vless[vless-reality-in]: process connection from 89.196.4.82:20159: EOF"

m = CF.search(FROM)
print("FROM_ID=%s FROM_IP=%s" % (m.group(1), m.group(2)) if m else "FROM_NOMATCH")
print("USER_NAME=%s" % UP.search(USER).group(1))
print("USER_ID=%s" % CI.search(USER).group(1))
print("ERR_MATCHED=%s" % bool(CF.search(ERR)))
PY
)
grep -q 'FROM_ID=3883633974 FROM_IP=89.196.4.82' <<<"$out" \
    && ok "the client IP is read off the line that carries no username" \
    || bad "the 'inbound connection from' line no longer parses: $out"
grep -q 'USER_NAME=aug8_ykr15' <<<"$out" && grep -q 'USER_ID=3883633974' <<<"$out" \
    && ok "the username line carries the same connection id, so the two join" \
    || bad "user and connection id cannot be paired: $out"
grep -q 'ERR_MATCHED=False' <<<"$out" \
    && ok "a teardown line is not mistaken for a new connection" \
    || bad "'process connection from' was counted as an inbound connection"

# --- one connection must count once, not once per poll ------------------------
grep -A3 'counted_connection_ids.add(conn_id)' "$ROOT/exporters/singbox/main.py" \
    | grep -q 'seen_countries\[conn_country\]' \
    && ok "countries are counted inside the new-connection guard" \
    || bad "country counting is outside the dedup guard: every poll recounts every open connection"

# --- user country must have a working source ----------------------------------
# metadata.inboundUser is not emitted by sing-box; if it is the only writer,
# every user reports XX for ever.
if grep -q 'user_country\[username\] = country' "$ROOT/exporters/singbox/main.py"; then
    ok "user country is set from the log correlation"
else
    bad "user_country has no writer that sing-box actually feeds"
fi

# --- the panels must query their own metric -----------------------------------
out=$(python3 - "$ROOT/configs/monitoring/grafana/provisioning/dashboards/singbox.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
want = {"Users by Country": "singbox_active_users_by_country",
        "Connections by Country": "singbox_connections_by_country"}
wrong = []
for p in d["panels"]:
    if p.get("title") in want:
        got = p["targets"][0].get("expr", "")
        if want[p["title"]] not in got:
            wrong.append("%s queries %s" % (p["title"], got))
print("PANELS=%s" % (wrong or "OK"))
PY
)
grep -q 'PANELS=OK' <<<"$out" \
    && ok "each country panel queries the metric its title claims" \
    || bad "a country panel queries a different metric than its title says: $out"

echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
