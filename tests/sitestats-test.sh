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

# --- totals must stay complete ------------------------------------------------
# Measured on a live server: sing-box's Clash API sets destinationIP OR host,
# never both. Roughly a fifth of connections are dialed by IP literal, and those
# have no site name. Dropping them would silently under-count every total.
out=$(run_py ENABLE_SITE_ANALYTICS=true <<'PY'
import sitestats
s = sitestats.SiteStats(now=0)
s.record("10.0.0.1", "8.222.185.93", 700, 300, dest_country="CN")   # IP literal
s.record("10.0.0.2", "", 100, 100)                                   # neither
s.maybe_roll(now=99999)
body = "\n".join(s.render())
import re
up = re.search(r'site="other",direction="up"\} (\d+)', body)
print("OTHER_UP=%s" % (up.group(1) if up else "missing"))
print("HAS_IP_LABEL=%s" % ("8.222" in body))
print("UNKNOWN=%s" % ('country="unknown"' in body))
print("CN=%s" % ('country="CN"' in body))
PY
)
grep -q 'OTHER_UP=800' <<<"$out" \
    && ok "IP-literal and hostless traffic still counts, under 'other' (700+100)" \
    || bad "bytes with no site name were dropped, so totals under-count: $out"
grep -q 'HAS_IP_LABEL=False' <<<"$out" \
    && ok "a destination IP is never used as a site label" \
    || bad "a raw destination IP reached a label"
grep -q 'UNKNOWN=True' <<<"$out" && grep -q 'CN=True' <<<"$out" \
    && ok "traffic with no known country is counted as 'unknown', not omitted" \
    || bad "the country chart silently covers only part of the traffic: $out"

# --- country resolution -------------------------------------------------------
# Only named sites are resolved, so the set of names looked up has already
# cleared the k threshold and points at no one.
out=$(run_py ENABLE_SITE_ANALYTICS=true SITE_ANALYTICS_MIN_CLIENTS=5 <<'PY'
import sitestats
asked = []
def fake_resolver(name):
    asked.append(name)
    return {"cdn.popular-site.net": "NL"}.get(name, "")
s = sitestats.SiteStats(now=0, resolver=fake_resolver)
for i in range(9):
    s.record("10.0.0.%d" % i, "cdn.popular-site.net", 500, 500)   # named
for i in range(2):
    s.record("10.0.9.%d" % i, "rare-site.org", 50, 50)            # below k
s.maybe_roll(now=99999)
body = "\n".join(s.render())
print("ASKED=%s" % sorted(asked))
print("NL=%s" % ('country="NL"} 9000' in body))
print("UNKNOWN=%s" % ('country="unknown"} 200' in body))
for i in range(9):
    s.record("10.0.0.%d" % i, "cdn.popular-site.net", 1, 1)
s.maybe_roll(now=199999)
print("ASKED_AGAIN=%s" % sorted(asked))
PY
)
grep -q "ASKED=\['cdn.popular-site.net'\]" <<<"$out" \
    && ok "a real hostname is resolved, not the folded name" \
    || bad "resolved something other than a hostname seen in traffic: $out"
grep -q 'NL=True' <<<"$out" \
    && ok "a named site's bytes are attributed to its resolved country" \
    || bad "resolution did not reach the country counter: $out"
grep -q 'UNKNOWN=True' <<<"$out" \
    && ok "unresolved and sub-threshold bytes stay 'unknown'" \
    || bad "unattributable bytes went missing or were mislabelled: $out"
grep -q "ASKED_AGAIN=\['cdn.popular-site.net'\]" <<<"$out" \
    && ok "answers are cached; the second bucket resolves nothing new" \
    || bad "the resolver is called again every bucket: $out"

# A resolver that hangs or errors must not take the exporter down with it.
out=$(run_py ENABLE_SITE_ANALYTICS=true <<'PY'
import sitestats
def broken(site):
    raise RuntimeError("DNS is down")
s = sitestats.SiteStats(now=0, resolver=broken)
for i in range(9):
    s.record("10.0.0.%d" % i, "a.example.net", 10, 10)
s.maybe_roll(now=99999)
print("SURVIVED=%s" % ('example.net' in "\n".join(s.render())))
PY
)
grep -q 'SURVIVED=True' <<<"$out" \
    && ok "a failing resolver degrades to 'unknown' instead of losing the bucket" \
    || bad "a resolver error killed the roll: $out"

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
samples=$(grep -v '^#' <<<"$out")
if grep -qE '203\.0\.113\.|(^|[{,])(source|client|client_ip|src|ip|user)=' <<<"$samples"; then
    bad "a client identifier reached the output: $(grep -m1 -E '203\.0\.113\.|(^|[{,])(source|client|client_ip|src|ip|user)=' <<<"$samples")"
else
    ok "no client IP, and no client-shaped label key, on any sample"
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
out=$(run_py ENABLE_SITE_ANALYTICS=true SITE_ANALYTICS_BUCKET_SECONDS=3600 \
             SITE_ANALYTICS_STATE=/nonexistent/state.json <<'PY'
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
                   ("mail.example.co.ir", "example.co.ir"),
                   ("a.b.example.com.ru", "example.com.ru"),
                   ("cdn.example.com.cn", "example.com.cn"),
                   ("x.example.co.il", "example.co.il"),
                   ("www.example.ca.us", "example.ca.us"),
                   ("school.example.k12.il", "example.k12.il"),
                   # Hosting suffixes stay folded: naming the tenant is the
                   # thing this whole module exists to avoid.
                   ("someone.github.io", "github.io"),
                   ("d111.cloudfront.net", "cloudfront.net"),
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

# --- connection and client counts ---------------------------------------------
# record() is called once per byte-delta poll, so counting calls would report
# connections that never happened.
out=$(run_py ENABLE_SITE_ANALYTICS=true SITE_ANALYTICS_MIN_CLIENTS=3 <<'PY'
import sitestats
s = sitestats.SiteStats(now=0)
for i in range(5):
    s.record("10.0.0.%d" % i, "a.popular.net", 100, 200, new_conn=True)
    s.record("10.0.0.%d" % i, "a.popular.net", 50, 50)      # same connection again
s.record("10.0.9.1", "lonely.example.org", 10, 10, new_conn=True)
s.maybe_roll(now=99999)
body = "\n".join(s.render())
print(body)
PY
)
grep -q 'moav_site_connections_total{site="popular.net"} 5' <<<"$out" \
    && ok "a connection counts once, not once per poll" \
    || bad "connection count follows poll frequency: $(grep -m1 connections_total <<<"$out")"
grep -q 'moav_site_clients{site="popular.net"} 5' <<<"$out" \
    && ok "distinct clients per site are exposed" \
    || bad "no client count for a named site: $out"
grep -q 'moav_site_clients{site="other"}' <<<"$out" \
    && bad "'other' got a client count; only threshold-clearing sites may have one" \
    || ok "'other' has bytes and connections but no client count"
grep -q 'moav_site_connections_total{site="other"} 1' <<<"$out" \
    && ok "sub-threshold connections are still counted, under 'other'" \
    || bad "connections below the threshold were dropped: $out"

# --- aggregates survive a restart ---------------------------------------------
# Everything lived in memory, so a restart emptied every instant-query panel for
# up to a full bucket and reset the counters Prometheus had been tracking.
STATE_DIR=$(mktemp -d)
out=$(run_py ENABLE_SITE_ANALYTICS=true SITE_ANALYTICS_MIN_CLIENTS=2 \
             SITE_ANALYTICS_STATE="$STATE_DIR/state.json" <<'PY'
import sitestats
s = sitestats.SiteStats(now=0)
for i in range(4):
    s.record("10.0.0.%d" % i, "a.popular.net", 100, 200, new_conn=True)
s.maybe_roll(now=99999)
print("BEFORE=%d" % len(s.render()))

s2 = sitestats.SiteStats(now=99999)          # a fresh process, same state file
body = "\n".join(s2.render())
print("AFTER_BYTES=%s" % ('site="popular.net",direction="up"} 400' in body))
print("AFTER_CONNS=%s" % ('moav_site_connections_total{site="popular.net"} 4' in body))
print("AFTER_FOLDED=%s" % ("moav_site_folded_sites" in body))
PY
)
grep -q 'AFTER_BYTES=True' <<<"$out" && grep -q 'AFTER_CONNS=True' <<<"$out" \
    && ok "totals survive a restart instead of resetting to nothing" \
    || bad "a restart lost every aggregate: $out"
grep -q 'AFTER_FOLDED=True' <<<"$out" \
    && ok "the threshold-cost figures survive too, rather than reading zero" \
    || bad "folded counts reset on restart, so the panel would claim nothing was folded: $out"

# The salted client digests must never be among what is written.
if grep -qE '"_clients"|"clients": *\[' "$STATE_DIR/state.json" 2>/dev/null; then
    bad "client digests were persisted to disk"
else
    ok "only aggregates are written; the client digests stay in memory"
fi
python3 -c "
import json,sys
d=json.load(open('$STATE_DIR/state.json'))
c=d.get('clients') or {}
sys.exit(0 if all(isinstance(v,int) for v in c.values()) else 1)" \
    && ok "the persisted client field is a count, not a set of identifiers" \
    || bad "the persisted client field holds something other than counts"
rm -rf "$STATE_DIR"

# --- the threshold must show what it costs ------------------------------------
# "other" swamping the chart looks like a bug. These say how many sites were
# folded and how close the biggest came, so k can be tuned on evidence.
out=$(run_py ENABLE_SITE_ANALYTICS=true SITE_ANALYTICS_MIN_CLIENTS=5 \
             SITE_ANALYTICS_STATE=/nonexistent/state.json <<'PY'
import sitestats
s = sitestats.SiteStats(now=0)
for i in range(4):
    s.record("10.0.0.%d" % i, "a.nearmiss.net", 10, 10, new_conn=True)
for i in range(2):
    s.record("10.0.1.%d" % i, "b.faroff.org", 10, 10, new_conn=True)
s.maybe_roll(now=99999)
print("\n".join(l for l in s.render() if "folded" in l and not l.startswith("#")))
PY
)
grep -q 'moav_site_folded_sites 2' <<<"$out" \
    && ok "the number of folded sites is reported" \
    || bad "no way to see how much the threshold is folding away: $out"
grep -q 'moav_site_folded_clients_max 4' <<<"$out" \
    && ok "the closest miss is reported, so k can be tuned on evidence" \
    || bad "cannot tell whether lowering k by one would help: $out"
grep -qE 'nearmiss|faroff' <<<"$out" \
    && bad "a folded site was named; that is the whole point of folding it" \
    || ok "folded sites are counted, never named"

# --- a failed lookup must stay retryable --------------------------------------
# Caching the miss meant one bad answer marked a site unknown for ever. On a
# live server that left cdninstagram.com -- the single biggest destination --
# permanently uncounted, and 65% of bytes in "unknown".
out=$(run_py ENABLE_SITE_ANALYTICS=true SITE_ANALYTICS_MIN_CLIENTS=2 \
             SITE_ANALYTICS_STATE=/nonexistent/state.json <<'PY'
import sitestats
calls = {"n": 0}
def flaky(name):
    calls["n"] += 1
    return "" if calls["n"] == 1 else "DE"     # first attempt fails
s = sitestats.SiteStats(now=0, resolver=flaky)
for i in range(3):
    s.record("10.0.0.%d" % i, "edge.flaky-site.net", 10, 10)
s.maybe_roll(now=7200)
print("AFTER_FAIL=%s" % ('country="DE"' in "\n".join(s.render())))
for i in range(3):
    s.record("10.0.0.%d" % i, "edge.flaky-site.net", 10, 10)
s.maybe_roll(now=14400)
print("RETRIED=%s" % ('country="DE"' in "\n".join(s.render())))
print("CALLS=%d" % calls["n"])
PY
)
grep -q 'AFTER_FAIL=False' <<<"$out" \
    && ok "a failed lookup leaves the traffic in 'unknown' for that bucket" \
    || bad "a failed lookup invented a country: $out"
grep -q 'RETRIED=True' <<<"$out" \
    && ok "and is retried on the next bucket rather than cached as unknown" \
    || bad "one bad answer marks the site unknown for ever: $out"

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
