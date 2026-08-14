#!/bin/bash
# Regression test: exporters/lib/sitestats.py. Issue #297.
#
# The guarantee is that no output can be traced to a client. That is not a
# property of the dashboard or of the scrape config -- it has to hold in the
# object that produces the numbers, so it is tested there.
#
# The threshold is the load-bearing part: on a real server the MEDIAN domain has
# exactly one client, and a one-client domain is that person's browsing history.
# Measured, k>=5 discards 94% of domains while still attributing ~89% of traffic.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "site analytics: aggregation that cannot be linked to a client (#297)"

run_py() {  # <env assignments...> -- reads the python body on stdin
    env "$@" PYTHONPATH="$ROOT/exporters/lib" python3 -
}

# --- off unless asked ---------------------------------------------------------
out=$(run_py ENABLE_SITE_ANALYTICS=false <<'PY'
import sitestats
s = sitestats.SiteStats(now=0)
for i in range(50):
    s.record("10.0.0.%d" % i, "news.example.com", 1000, 2000)
s.maybe_roll(now=99999)
print("LINES=%d" % len(s.render()))
PY
)
[ "$out" = "LINES=0" ] \
    && ok "produces nothing when ENABLE_SITE_ANALYTICS is unset" \
    || bad "emitted output while disabled: $out"

# --- the k threshold ----------------------------------------------------------
out=$(run_py ENABLE_SITE_ANALYTICS=true SITE_ANALYTICS_MIN_CLIENTS=5 <<'PY'
import sitestats
s = sitestats.SiteStats(now=0)
for i in range(4):                       # below the threshold
    s.record("10.0.0.%d" % i, "host.rare-site.org", 100, 100)
for i in range(9):                       # above it
    s.record("10.0.1.%d" % i, "cdn.popular-site.net", 500, 500)
s.maybe_roll(now=99999)
body = "\n".join(s.render())
print("RARE_NAMED=%s" % ("rare-site.org" in body))
print("POPULAR_NAMED=%s" % ("popular-site.net" in body))
print("OTHER_PRESENT=%s" % ('site="other"' in body))
import re
m = re.search(r'site="other",direction="up"\} (\d+)', body)
print("OTHER_UP=%s" % (m.group(1) if m else "missing"))
PY
)
grep -q 'RARE_NAMED=False'    <<<"$out" && ok "a 4-client domain is never named" \
                                        || bad "named a domain reached by fewer than k clients"
grep -q 'POPULAR_NAMED=True'  <<<"$out" && ok "a 9-client domain is named" \
                                        || bad "suppressed a domain that cleared the threshold"
grep -q 'OTHER_UP=400'        <<<"$out" && ok "sub-threshold bytes are kept under 'other' (4x100)" \
                                        || bad "traffic below the threshold was lost, not bucketed: $out"

# --- no client identifier may appear anywhere ---------------------------------
out=$(run_py ENABLE_SITE_ANALYTICS=true ENABLE_SITE_ANALYTICS_RESEARCH=true <<'PY'
import sitestats
s = sitestats.SiteStats(now=0)
for i in range(9):
    s.record("203.0.113.%d" % i, "a.example.net", 10, 10,
             dest_country="US", port="443", network="tcp")
s.maybe_roll(now=99999)
print("\n".join(s.render()))
PY
)
if grep -qE '203\.0\.113\.|source|client' <<<"$out"; then
    bad "a client identifier reached the output: $(grep -m1 -E '203\.0\.113\.|source|client' <<<"$out")"
else
    ok "no client IP or client-shaped label in the output"
fi
grep -q 'moav_site_destination_country_bytes_total{country="US"}' <<<"$out" \
    && ok "destination country is reported" \
    || bad "destination country missing"
grep -q 'moav_site_port_bytes_total' <<<"$out" \
    && ok "research mode adds destination port" \
    || bad "research mode did not add the port metric"

# --- research mode must stay opt-in ------------------------------------------
out=$(run_py ENABLE_SITE_ANALYTICS=true <<'PY'
import sitestats
s = sitestats.SiteStats(now=0)
for i in range(9):
    s.record("10.0.0.%d" % i, "a.example.net", 10, 10, port="443", network="tcp")
s.maybe_roll(now=99999)
print("\n".join(s.render()))
PY
)
grep -q 'moav_site_port_bytes_total' <<<"$out" \
    && bad "port metric emitted without ENABLE_SITE_ANALYTICS_RESEARCH" \
    || ok "port metric requires its own flag"

# --- counters only advance on a bucket boundary ------------------------------
out=$(run_py ENABLE_SITE_ANALYTICS=true SITE_ANALYTICS_BUCKET_SECONDS=3600 <<'PY'
import sitestats
s = sitestats.SiteStats(now=0)
for i in range(9):
    s.record("10.0.0.%d" % i, "a.example.net", 100, 100)
print("BEFORE_ROLL=%d" % len(s.render()))     # same bucket: nothing exposed yet
s.maybe_roll(now=100)                          # still inside the bucket
print("SAME_BUCKET=%d" % len(s.render()))
s.maybe_roll(now=3601)                         # next bucket
print("AFTER_ROLL=%d" % len(s.render()))
PY
)
grep -q 'BEFORE_ROLL=0' <<<"$out" && grep -q 'SAME_BUCKET=0' <<<"$out" && ! grep -q 'AFTER_ROLL=0' <<<"$out" \
    && ok "nothing is exposed until the bucket closes (coarse timeline)" \
    || bad "counters moved inside a bucket, which restores per-poll timing: $out"

# --- registrable-name folding -------------------------------------------------
out=$(run_py ENABLE_SITE_ANALYTICS=true <<'PY'
import sitestats as s
for host, want in (("edge-42.a.example-cdn.net", "example-cdn.net"),
                   ("example.co.uk", "example.co.uk"),
                   ("x.y.example.co.uk", "example.co.uk"),
                   ("192.0.2.7", ""),
                   ("localhost", "")):
    got = s.registrable(host)
    print("%s -> %s %s" % (host, got, "OK" if got == want else "WANT:" + want))
PY
)
grep -q 'WANT:' <<<"$out" && bad "registrable-name folding wrong: $(grep -m1 'WANT:' <<<"$out")" \
                          || ok "hostnames fold to the registrable name; bare IPs are dropped"

# --- top-N ranks by clients, not bytes ---------------------------------------
out=$(run_py ENABLE_SITE_ANALYTICS=true SITE_ANALYTICS_TOP_N=1 SITE_ANALYTICS_MIN_CLIENTS=5 <<'PY'
import sitestats
s = sitestats.SiteStats(now=0)
for i in range(6):                       # fewer clients, huge traffic
    s.record("10.0.0.%d" % i, "cdn.video-site.net", 10**9, 10**9)
for i in range(30):                      # many clients, little traffic
    s.record("10.0.1.%d" % i, "api.chat-site.org", 10, 10)
s.maybe_roll(now=99999)
body = "\n".join(s.render())
print("CHAT=%s VIDEO=%s" % ("chat-site.org" in body, "video-site.net" in body))
PY
)
grep -q 'CHAT=True VIDEO=False' <<<"$out" \
    && ok "top-N keeps the most-used site, not the heaviest" \
    || bad "ranked by bytes: a CDN crowded out the site more people used ($out)"

# --- the exporter must actually drive the object ------------------------------
# record() without maybe_roll() collects and never exposes: the failure is
# silent, and only visible on a live server an hour later.
EXP="$ROOT/exporters/singbox/main.py"
for call in "site_stats.record(" "site_stats.maybe_roll()" "site_stats.render()"; do
    grep -qF "$call" "$EXP" \
        && ok "singbox exporter calls ${call%(*}" \
        || bad "singbox exporter never calls $call — stats would be collected but never exposed"
done
grep -qF "COPY lib/sitestats.py" "$ROOT/exporters/singbox/Dockerfile" \
    && ok "the module is shipped in the image" \
    || bad "sitestats.py is not COPYed into the image; the import degrades to None"

# --- the metric names the dashboard queries must be the ones emitted ---------
# A renamed metric on either side shows as an empty panel, never as an error.
DASH="$ROOT/configs/monitoring/grafana/provisioning/dashboards/singbox.json"
for m in moav_site_traffic_bytes_total moav_site_destination_country_bytes_total; do
    if grep -qF "$m" "$DASH" && grep -qF "$m" "$ROOT/exporters/lib/sitestats.py"; then
        ok "$m is emitted and charted"
    else
        bad "$m is not on both sides (exporter emits / dashboard queries)"
    fi
done
python3 - "$DASH" <<'PY' && ok "the site panels sit in a collapsed row (they are empty when the flag is off)" \
                          || bad "site panels are always expanded; with the flag off that is three empty panels"
import json, sys
d = json.load(open(sys.argv[1]))
row = next((p for p in d["panels"]
            if p["type"] == "row" and "moav_site" in json.dumps(p.get("panels", []))), None)
sys.exit(0 if row and row.get("collapsed") else 1)
PY

echo ""
echo "  passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
