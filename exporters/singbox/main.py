#!/usr/bin/env python3
"""
Sing-box User Prometheus Exporter

Parses sing-box container logs to extract user connection metrics.
Polls Clash API for source IPs to provide GeoIP country metrics.
"""

import re
import os
import time
import threading
import json
from http.server import HTTPServer, BaseHTTPRequestHandler
from collections import defaultdict
from geoip import GeoIPLookup

try:
    from urllib.request import urlopen, Request
    from urllib.error import URLError
except ImportError:
    urlopen = None

# Metrics storage
user_connections = defaultdict(int)  # user -> total connections
counted_connection_ids = set()  # Clash connection ids already counted (see poll_clash_connections)
user_last_seen = {}  # user -> timestamp
active_users = set()  # users seen in last 5 minutes
protocol_connections = defaultdict(int)  # protocol -> total connections
country_connections = defaultdict(int)  # country -> total connections
user_country = {}  # user -> last seen country code

# Lock for thread safety
metrics_lock = threading.Lock()

# GeoIP lookup
geoip = GeoIPLookup()

# Clash API config
CLASH_API = os.environ.get("CLASH_API", "http://moav-sing-box:9090")
CLASH_SECRET = ""

# Regex to parse connection lines with usernames
# Example: [newaidin] inbound connection to vas.samsungapps.com:443
USER_PATTERN = re.compile(r'\[([^\]]+)\]\s*inbound connection')

# Regex to extract protocol from inbound name
# Example: inbound/hysteria2[hysteria2-in]: [user]
PROTOCOL_PATTERN = re.compile(r'inbound/(\w+)\[')

# Active window in seconds (5 minutes)
ACTIVE_WINDOW = 300

# GeoIP poll interval (seconds)
# Poll interval for the Clash API. This drives BOTH the GeoIP country stats and
# (since the docker-logs tailer was removed) per-user connection counting.
#
# FIDELITY TRADEOFF, stated plainly: the old log tailer saw every "inbound
# connection" event. A poller only sees connections that are still open when it
# looks, so a connection that opens and closes entirely within one interval is
# not counted. Long-lived sessions -- which is what the user-activity panels are
# actually for -- are unaffected, and `user_last_seen` / active-user counts still
# work. Short bursty connections will read low.
#
# 15s halves the window versus the previous 30s at modest extra API cost. Tune
# with SINGBOX_POLL_INTERVAL if a deployment wants tighter or cheaper sampling.
GEOIP_POLL_INTERVAL = int(os.environ.get("SINGBOX_POLL_INTERVAL", "15"))


def load_clash_secret():
    """Try to load the Clash API secret from state volume or environment."""
    global CLASH_SECRET

    # Try state volume (source of truth from bootstrap)
    for path in ["/state/keys/clash-api.env", "/state/clash_api_secret"]:
        try:
            with open(path) as f:
                for line in f:
                    line = line.strip()
                    if line.startswith("CLASH_API_SECRET="):
                        CLASH_SECRET = line.split("=", 1)[1].strip()
                        print(f"Loaded Clash API secret from {path}")
                        return
                    elif not line.startswith("#") and not "=" in line and line:
                        # Plain text file (just the secret)
                        CLASH_SECRET = line
                        print(f"Loaded Clash API secret from {path}")
                        return
        except FileNotFoundError:
            continue

    # Fall back to environment
    CLASH_SECRET = os.environ.get("CLASH_TOKEN", "").strip().strip('"').strip("'")
    if CLASH_SECRET:
        print(f"Loaded Clash API secret from environment ({len(CLASH_SECRET)} chars)")
    else:
        print("WARNING: No Clash API secret found — GeoIP country tracking will not work")


def parse_log_line(line: str) -> bool:
    """Parse a log line and update metrics. Returns True if parsed."""
    user_match = USER_PATTERN.search(line)
    if not user_match:
        return False

    username = user_match.group(1)
    now = time.time()

    # Extract protocol if present
    protocol_match = PROTOCOL_PATTERN.search(line)
    protocol = protocol_match.group(1) if protocol_match else "unknown"

    with metrics_lock:
        user_connections[username] += 1
        user_last_seen[username] = now
        protocol_connections[protocol] += 1

    return True


def update_active_users():
    """Update the set of active users based on last seen time."""
    global active_users
    now = time.time()
    cutoff = now - ACTIVE_WINDOW

    with metrics_lock:
        active_users = {
            user for user, last_seen in user_last_seen.items()
            if last_seen > cutoff
        }


def poll_clash_connections():
    """Poll Clash API /connections for source IPs and update country metrics."""
    if urlopen is None:
        print("GeoIP: urllib not available, skipping Clash API polling")
        return

    poll_count = 0

    while True:
        poll_count += 1
        try:
            url = f"{CLASH_API}/connections"
            req = Request(url)
            if CLASH_SECRET:
                req.add_header("Authorization", "Bearer " + CLASH_SECRET)
            resp = urlopen(req, timeout=5)
            data = json.loads(resp.read().decode())

            connections = data.get("connections", []) or []
            seen_countries = defaultdict(int)
            seen_user_country = {}
            current_ids = set()
            new_user_hits = defaultdict(int)
            new_proto_hits = defaultdict(int)

            for conn in connections:
                meta = conn.get("metadata", {})
                source_ip = meta.get("sourceIP", "")
                user = meta.get("inboundUser", "")
                conn_id = conn.get("id", "")

                if source_ip:
                    country = geoip.lookup(source_ip)
                    seen_countries[country] += 1
                    if user:
                        seen_user_country[user] = country

                # Count each connection ONCE, the first time we see it. The old
                # log tailer counted "inbound connection" events; a polled
                # snapshot would otherwise re-count every still-open connection
                # on every poll.
                if conn_id:
                    current_ids.add(conn_id)
                    if conn_id not in counted_connection_ids:
                        counted_connection_ids.add(conn_id)
                        if user:
                            new_user_hits[user] += 1
                        proto = (meta.get("inboundName") or meta.get("type")
                                 or meta.get("network") or "unknown")
                        new_proto_hits[proto] += 1

            # Forget IDs that are gone so the set cannot grow without bound.
            counted_connection_ids.intersection_update(current_ids)

            now = time.time()
            with metrics_lock:
                for country, count in seen_countries.items():
                    country_connections[country] += count
                user_country.update(seen_user_country)
                for user, hits in new_user_hits.items():
                    user_connections[user] += hits
                    user_last_seen[user] = now
                for proto, hits in new_proto_hits.items():
                    protocol_connections[proto] += hits
                if new_user_hits:
                    update_active_users()

            if poll_count <= 3 or poll_count % 100 == 0:
                print(f"GeoIP poll #{poll_count}: {len(connections)} connections, "
                      f"{len(seen_countries)} countries, total tracked: {sum(country_connections.values())}")

        except Exception as e:
            if poll_count <= 5 or poll_count % 100 == 0:
                print(f"GeoIP poll #{poll_count} error: {e}")

        time.sleep(GEOIP_POLL_INTERVAL)


# NOTE: this exporter previously tailed `docker logs moav-sing-box` to attribute
# connections to users, which required mounting the raw Docker socket -- an
# unauthenticated path to host root for anything that could reach it. The Clash
# API already returns `metadata.inboundUser` for every connection and this
# process was already polling it for GeoIP, so the log tailer was redundant.
# Connection counting now happens in poll_clash_connections().

def periodic_update():
    """Periodically update active users set."""
    while True:
        time.sleep(60)
        update_active_users()


class MetricsHandler(BaseHTTPRequestHandler):
    """HTTP handler for Prometheus metrics endpoint."""

    def do_GET(self):
        if self.path == '/metrics':
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.end_headers()

            output = []

            with metrics_lock:
                # Active users count
                output.append('# HELP singbox_active_users Number of users active in last 5 minutes')
                output.append('# TYPE singbox_active_users gauge')
                output.append(f'singbox_active_users {len(active_users)}')

                # Total unique users
                output.append('# HELP singbox_total_users Total number of unique users seen')
                output.append('# TYPE singbox_total_users counter')
                output.append(f'singbox_total_users {len(user_connections)}')

                # Total connections
                output.append('# HELP singbox_total_connections Total number of user connections')
                output.append('# TYPE singbox_total_connections counter')
                output.append(f'singbox_total_connections {sum(user_connections.values())}')

                # Per-user connections
                output.append('# HELP singbox_user_connections Total connections per user')
                output.append('# TYPE singbox_user_connections counter')
                for user, count in sorted(user_connections.items()):
                    output.append(f'singbox_user_connections{{user="{user}"}} {count}')

                # Per-user active status
                output.append('# HELP singbox_user_active Whether user is active (1) or inactive (0)')
                output.append('# TYPE singbox_user_active gauge')
                for user in user_connections:
                    is_active = 1 if user in active_users else 0
                    output.append(f'singbox_user_active{{user="{user}"}} {is_active}')

                # Per-protocol connections
                output.append('# HELP singbox_protocol_connections Total connections per protocol')
                output.append('# TYPE singbox_protocol_connections counter')
                for protocol, count in sorted(protocol_connections.items()):
                    output.append(f'singbox_protocol_connections{{protocol="{protocol}"}} {count}')

                # Connections by country
                output.append('# HELP singbox_connections_by_country Total connections by source country')
                output.append('# TYPE singbox_connections_by_country counter')
                for country, count in sorted(country_connections.items()):
                    output.append(f'singbox_connections_by_country{{country="{country}"}} {count}')

                # Active users by country
                output.append('# HELP singbox_active_users_by_country Active users by source country')
                output.append('# TYPE singbox_active_users_by_country gauge')
                active_country_counts = defaultdict(int)
                for user in active_users:
                    c = user_country.get(user, "XX")
                    active_country_counts[c] += 1
                for country, count in sorted(active_country_counts.items()):
                    output.append(f'singbox_active_users_by_country{{country="{country}"}} {count}')

            self.wfile.write('\n'.join(output).encode())

        elif self.path == '/health':
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'OK')
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass


def main():
    port = 9102

    # Load Clash API secret
    load_clash_secret()

    # Start periodic update thread
    update_thread = threading.Thread(target=periodic_update, daemon=True)
    update_thread.start()

    # Start GeoIP poller (uses Clash API for source IPs)
    geoip_thread = threading.Thread(target=poll_clash_connections, daemon=True)
    geoip_thread.start()
    print("GeoIP: polling Clash API for source IPs every 30s")

    # Start HTTP server
    server = HTTPServer(('0.0.0.0', port), MetricsHandler)
    print(f"Sing-box user exporter listening on port {port}")
    print(f"Metrics available at http://localhost:{port}/metrics")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()


if __name__ == '__main__':
    main()
