#!/usr/bin/env python3
"""
Sing-box User Prometheus Exporter

Two sources, because neither alone is enough:
  * Clash API /connections -- protocol, byte counters, source IPs. No user field.
  * sing-box's log -- the only place the username appears. Published to a file by
    the entrypoint so this needs no Docker socket (same as the xray exporter).
"""

import re
import os
import time
import threading
import json
from http.server import HTTPServer, BaseHTTPRequestHandler
from collections import defaultdict, OrderedDict

try:
    import sitestats
except ImportError:
    sitestats = None
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
# connection id -> client IP, from the log line that carries no username.
conn_source_ip = OrderedDict()
CONN_IP_CACHE_MAX = 4096

# Clash reports byte counters per OPEN connection, so accumulate deltas per
# connection id -- summing raw values would re-count everything still open.
protocol_bytes_up = defaultdict(int)    # protocol -> cumulative upload bytes
protocol_bytes_down = defaultdict(int)  # protocol -> cumulative download bytes
conn_bytes_seen = {}  # connection id -> (upload, download) already accounted for

# Lock for thread safety
metrics_lock = threading.Lock()
active_connections = 0      # current, from the last poll
singbox_version = ""        # from the Clash API /version

# GeoIP lookup
geoip = GeoIPLookup()

# Clash API config
CLASH_API = os.environ.get("CLASH_API", "http://moav-sing-box:9090")
CLASH_SECRET = ""

site_stats = sitestats.SiteStats(
    resolver=sitestats.make_resolver(CLASH_API, lambda: CLASH_SECRET, geoip.lookup)
) if sitestats else None

# Regex to parse connection lines with usernames
# Example: [newaidin] inbound connection to vas.samsungapps.com:443
USER_PATTERN = re.compile(r'\[([^\]]+)\]\s*inbound connection')

# "[3883633974 0ms] inbound/vless[in]: inbound connection from 89.196.4.82:20159"
CONN_FROM_PATTERN = re.compile(r'\[(\d{4,})\s[^\]]*\].*inbound connection from ([0-9a-fA-F.:]+):\d+')
# The same id reappears on the line that names the user.
CONN_ID_PATTERN = re.compile(r'\[(\d{4,})\s[^\]]*\]')

# Regex to extract protocol from inbound name
# Example: inbound/hysteria2[hysteria2-in]: [user]
PROTOCOL_PATTERN = re.compile(r'inbound/(\w+)\[')

# Active window in seconds (5 minutes)
ACTIVE_WINDOW = 300

# Clash API poll interval: country stats, protocol counts and traffic. Per-user
# counting comes from the log tailer, not from here.
GEOIP_POLL_INTERVAL = int(os.environ.get("SINGBOX_POLL_INTERVAL", "15"))


def load_clash_secret():
    """Try to load the Clash API secret from environment or state volume."""
    global CLASH_SECRET

    # Environment first: compose passes CLASH_TOKEN, and the state file is 0600
    # root-only since the admin env-handoff change. This container is
    # cap_drop ALL without DAC_OVERRIDE, so even as root it can only read
    # state files it owns; a PermissionError here used to crash-loop it.
    CLASH_SECRET = os.environ.get("CLASH_TOKEN", "").strip().strip('"').strip("'")
    if CLASH_SECRET:
        print(f"Loaded Clash API secret from environment ({len(CLASH_SECRET)} chars)")
        return

    # Fall back to the state volume; any read failure must be non-fatal.
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
        except OSError:
            continue
    if CLASH_SECRET:
        print(f"Loaded Clash API secret from environment ({len(CLASH_SECRET)} chars)")
    else:
        print("WARNING: No Clash API secret found — GeoIP country tracking will not work")


def parse_log_line(line: str) -> bool:
    """Count one per-user connection event. True if the line named a user.

    Does not touch protocol_connections: the Clash poller owns that series with a
    richer label, and counting both would double-count the same events.
    """
    from_match = CONN_FROM_PATTERN.search(line)
    if from_match:
        conn_id, ip = from_match.group(1), from_match.group(2)
        conn_source_ip[conn_id] = ip
        while len(conn_source_ip) > CONN_IP_CACHE_MAX:
            conn_source_ip.popitem(last=False)
        return False

    user_match = USER_PATTERN.search(line)
    if not user_match:
        return False

    username = user_match.group(1)
    now = time.time()

    id_match = CONN_ID_PATTERN.search(line)
    ip = conn_source_ip.get(id_match.group(1), "") if id_match else ""
    country = geoip.lookup(ip) if ip else ""

    with metrics_lock:
        user_connections[username] += 1
        user_last_seen[username] = now
        if country:
            user_country[username] = country

    return True


def tail_singbox_log():
    """Tail the sing-box log the entrypoint publishes. Reattaches on truncation,
    since the entrypoint caps the file."""
    path = os.environ.get("SINGBOX_LOG_PATH", "/var/log/sing-box/sing-box.log")
    print(f"Starting sing-box log tailer: {path}")

    fh = None
    inode = None
    warned = False
    while True:
        try:
            if fh is None:
                if not os.path.exists(path):
                    if not warned:
                        print(f"Log tailer: {path} not present yet - per-user "
                              "metrics stay empty until sing-box publishes it")
                        warned = True
                    time.sleep(5)
                    continue
                fh = open(path, "r", errors="replace")
                st = os.fstat(fh.fileno())
                inode = st.st_ino
                fh.seek(0, os.SEEK_END)   # only new events matter
                warned = False
                print(f"Log tailer attached to {path}")

            line = fh.readline()
            if line:
                if "inbound connection" in line and parse_log_line(line):
                    update_active_users()
                continue

            # No data: detect truncation (shrank) or replacement (new inode).
            try:
                st_path = os.stat(path)
                if st_path.st_size < fh.tell() or st_path.st_ino != inode:
                    print("sing-box log rotated/truncated - reattaching")
                    fh.close()
                    fh = None
                    continue
            except FileNotFoundError:
                fh.close()
                fh = None
                continue
            time.sleep(1)

        except Exception as exc:
            print(f"Log tailer error: {exc}")
            if fh is not None:
                try:
                    fh.close()
                except Exception:
                    pass
            fh = None
            time.sleep(5)


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


def fetch_singbox_version():
    """Clash API /version. Replaces clash_info from the removed exporter."""
    global singbox_version
    if urlopen is None:
        return
    try:
        req = Request(f"{CLASH_API}/version")
        if CLASH_SECRET:
            req.add_header("Authorization", "Bearer " + CLASH_SECRET)
        singbox_version = json.loads(urlopen(req, timeout=5).read().decode()).get("version", "")
    except Exception:
        pass


def poll_clash_connections():
    """Poll Clash API /connections for source IPs and update country metrics."""
    if urlopen is None:
        print("GeoIP: urllib not available, skipping Clash API polling")
        return

    poll_count = 0

    while True:
        poll_count += 1
        try:
            if poll_count == 1 or poll_count % 720 == 0:
                fetch_singbox_version()
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

            new_bytes_up = defaultdict(int)
            new_bytes_down = defaultdict(int)

            for conn in connections:
                meta = conn.get("metadata", {})
                source_ip = meta.get("sourceIP", "")
                # Always absent today; kept in case sing-box ever emits it.
                user = meta.get("inboundUser", "")
                conn_id = conn.get("id", "")

                conn_country = geoip.lookup(source_ip) if source_ip else ""
                if conn_country and user:
                    seen_user_country[user] = conn_country

                proto_label = (meta.get("inboundName") or meta.get("type")
                               or meta.get("network") or "unknown")
                up = conn.get("upload") or 0
                down = conn.get("download") or 0
                if conn_id and isinstance(up, int) and isinstance(down, int):
                    prev_up, prev_down = conn_bytes_seen.get(conn_id, (0, 0))
                    # Counter going backwards means a reused id.
                    d_up = up - prev_up if up >= prev_up else up
                    d_down = down - prev_down if down >= prev_down else down
                    if d_up:
                        new_bytes_up[proto_label] += d_up
                    if d_down:
                        new_bytes_down[proto_label] += d_down
                    conn_bytes_seen[conn_id] = (up, down)

                    # Aggregate destination stats. site_stats never returns a
                    # client identifier; see exporters/lib/sitestats.py. #297
                    if site_stats is not None and source_ip and (d_up or d_down):
                        dest_ip = meta.get("destinationIP", "")
                        site_stats.record(
                            source_ip,
                            meta.get("host", "") or dest_ip,
                            d_up, d_down,
                            dest_country=geoip.lookup(dest_ip) if dest_ip else "",
                            port=meta.get("destinationPort", ""),
                            network=meta.get("network", ""),
                            new_conn=conn_id not in counted_connection_ids,
                        )

                # Count each connection ONCE, the first time we see it. The old
                # log tailer counted "inbound connection" events; a polled
                # snapshot would otherwise re-count every still-open connection
                # on every poll.
                if conn_id:
                    current_ids.add(conn_id)
                    if conn_id not in counted_connection_ids:
                        counted_connection_ids.add(conn_id)
                        if conn_country:
                            seen_countries[conn_country] += 1
                        if user:
                            new_user_hits[user] += 1
                        new_proto_hits[proto_label] += 1

            global active_connections
            active_connections = len(connections)

            # Forget IDs that are gone so neither map grows without bound.
            counted_connection_ids.intersection_update(current_ids)
            for gone in [cid for cid in conn_bytes_seen if cid not in current_ids]:
                del conn_bytes_seen[gone]

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
                for proto, n in new_bytes_up.items():
                    protocol_bytes_up[proto] += n
                for proto, n in new_bytes_down.items():
                    protocol_bytes_down[proto] += n
                if new_user_hits:
                    update_active_users()

            if poll_count <= 3 or poll_count % 100 == 0:
                print(f"GeoIP poll #{poll_count}: {len(connections)} connections, "
                      f"{len(seen_countries)} countries, total tracked: {sum(country_connections.values())}")

        except Exception as e:
            if poll_count <= 5 or poll_count % 100 == 0:
                print(f"GeoIP poll #{poll_count} error: {e}")

        if site_stats is not None:
            site_stats.maybe_roll()

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

                # Deltas accumulated in the poller, so these survive closes.
                output.append('# HELP singbox_protocol_bytes_up Cumulative upload bytes per protocol')
                output.append('# TYPE singbox_protocol_bytes_up counter')
                for protocol, n in sorted(protocol_bytes_up.items()):
                    output.append(f'singbox_protocol_bytes_up{{protocol="{protocol}"}} {n}')

                output.append('# HELP singbox_protocol_bytes_down Cumulative download bytes per protocol')
                output.append('# TYPE singbox_protocol_bytes_down counter')
                for protocol, n in sorted(protocol_bytes_down.items()):
                    output.append(f'singbox_protocol_bytes_down{{protocol="{protocol}"}} {n}')

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

            output.append('# HELP singbox_active_connections Connections open right now')
            output.append('# TYPE singbox_active_connections gauge')
            output.append(f'singbox_active_connections {active_connections}')

            if singbox_version:
                output.append('# HELP singbox_version_info sing-box version')
                output.append('# TYPE singbox_version_info gauge')
                output.append(f'singbox_version_info{{version="{singbox_version}"}} 1')

            if site_stats is not None:
                output.extend(site_stats.render())

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

    # Start GeoIP poller (Clash API: source IPs, protocol counts, traffic)
    geoip_thread = threading.Thread(target=poll_clash_connections, daemon=True)
    geoip_thread.start()
    print(f"Clash API: polling every {GEOIP_POLL_INTERVAL}s "
          "for source IPs, protocol counts and per-protocol traffic")

    # The only source of usernames.
    tailer_thread = threading.Thread(target=tail_singbox_log, daemon=True)
    tailer_thread.start()

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
