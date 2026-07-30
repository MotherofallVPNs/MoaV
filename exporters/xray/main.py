#!/usr/bin/env python3
"""
Xray User Prometheus Exporter

Parses Xray container logs for connection metrics and queries the
Xray Stats API (gRPC via dokodemo-door) for per-user traffic data.
"""

import json
import re
import os
import time
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler
from collections import defaultdict
from geoip import GeoIPLookup

# Metrics storage
user_connections = defaultdict(int)  # user -> total connections
user_last_seen = {}  # user -> timestamp
active_users = set()  # users seen in last 5 minutes
user_upload = defaultdict(int)  # user -> upload bytes (cumulative)
user_download = defaultdict(int)  # user -> download bytes (cumulative)
inbound_upload = defaultdict(int)  # inbound_tag -> upload bytes (cumulative)
inbound_download = defaultdict(int)  # inbound_tag -> download bytes (cumulative)
country_connections = defaultdict(int)  # country -> total connections
user_country = {}  # user -> last seen country code

# Lock for thread safety
metrics_lock = threading.Lock()

# GeoIP lookup
geoip = GeoIPLookup()

# Regex to parse Xray access log lines with source IP
# Format: IP:port accepted tcp:destination:port email:user@moav
IP_EMAIL_PATTERN = re.compile(
    r'(\d+\.\d+\.\d+\.\d+):\d+\s+accepted\s+.*?email:\s*(\S+?)@moav'
)
# Fallback patterns (without IP)
EMAIL_PATTERN = re.compile(r'email:\s*(\S+?)@moav')
BRACKET_PATTERN = re.compile(r'\[([^\]]+?)@moav\]')

# Active window in seconds (5 minutes)
ACTIVE_WINDOW = 300

# Stats query interval (seconds)
STATS_INTERVAL = 15

# Track first successful stats query for diagnostics
stats_query_count = 0


def parse_log_line(line: str) -> bool:
    """Parse a log line and update metrics. Returns True if parsed."""
    if 'accepted' not in line:
        return False

    source_ip = None
    username = None

    # Try to extract both IP and email
    ip_match = IP_EMAIL_PATTERN.search(line)
    if ip_match:
        source_ip = ip_match.group(1)
        username = ip_match.group(2)
    else:
        # Fallback: extract email only
        match = EMAIL_PATTERN.search(line)
        if not match:
            match = BRACKET_PATTERN.search(line)
        if not match:
            return False
        username = match.group(1)

    now = time.time()
    country = geoip.lookup(source_ip) if source_ip else "XX"

    with metrics_lock:
        user_connections[username] += 1
        user_last_seen[username] = now
        country_connections[country] += 1
        if source_ip:
            user_country[username] = country

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


def _run_statsquery(pattern):
    """Read a stats snapshot published by the xray container.

    Previously this ran `docker exec moav-xray xray api statsquery`, which needed
    the raw Docker socket mounted -- unrestricted Docker API access, i.e. a path
    to host root, for a read-only scrape. The stats API listens on 127.0.0.1
    inside the xray container, so rather than exposing it on the container
    network the container publishes snapshots to a shared volume (same mechanism
    as the wireguard/amneziawg exporters). Returns the raw output, or None.
    """
    state_dir = os.environ.get("XRAY_STATE_DIR", "/var/lib/moav-metrics")
    path = os.path.join(state_dir, f"xray-stats-{pattern}.json")
    try:
        with open(path) as fh:
            data = fh.read()
    except FileNotFoundError:
        print(f"xray stats snapshot not found yet: {path} "
              f"(the xray container publishes it every 15s)")
        return None
    except OSError as exc:
        print(f"cannot read {path}: {exc}")
        return None
    if not data.strip():
        print(f"xray stats snapshot is empty: {path}")
        return None
    return data

def query_xray_stats():
    """Query Xray Stats API for per-user and per-inbound traffic data."""
    # User stats
    try:
        user_output = _run_statsquery("user")
        if user_output is None:
            return

        if stats_query_count == 0:
            print(f"Stats API raw: stdout={len(user_output)} bytes, stderr={len(result.stderr)} bytes")
            if user_output:
                print(f"Stats stdout preview: {user_output[:200]}")
            if result.stderr and not user_output:
                print(f"Stats stderr preview: {result.stderr[:200]}")

        # xray may output to stdout or stderr depending on version
        output = user_output.strip()
        if not output:
            output = result.stderr.strip()
        if not output:
            return

        parse_stats_output(output)
    except Exception as e:
        print(f"Stats API error: {e}")

    # Inbound stats (separate query)
    inbound_output = _run_statsquery("inbound")
    if inbound_output:
        parse_inbound_stats(inbound_output)


def parse_stats_output(output: str):
    """Parse JSON stats output from xray api statsquery (cumulative values)."""
    global stats_query_count
    parsed_count = 0

    try:
        data = json.loads(output)
    except json.JSONDecodeError:
        stats_query_count += 1
        if stats_query_count <= 3:
            print(f"Stats query #{stats_query_count}: failed to parse JSON")
        return

    for entry in data.get("stat", []):
        name = entry.get("name", "")
        value = entry.get("value", 0)

        parts = name.split(">>>")
        if len(parts) == 4 and parts[0] == "user" and parts[2] == "traffic":
            username = parts[1].replace("@moav", "")
            direction = parts[3]

            with metrics_lock:
                if direction == "uplink":
                    user_upload[username] = value
                elif direction == "downlink":
                    user_download[username] = value
            parsed_count += 1

    stats_query_count += 1
    if stats_query_count <= 3 or stats_query_count % 100 == 0:
        total_up = sum(user_upload.values())
        total_down = sum(user_download.values())
        print(f"Stats query #{stats_query_count}: parsed {parsed_count} entries, "
              f"users with traffic: {len(user_upload)}, total: {total_up + total_down} bytes")


def parse_inbound_stats(output: str):
    """Parse inbound-level stats (traffic per inbound tag)."""
    try:
        data = json.loads(output)
    except json.JSONDecodeError:
        return

    for entry in data.get("stat", []):
        name = entry.get("name", "")
        value = entry.get("value", 0)

        # Format: inbound>>>tag>>>traffic>>>uplink/downlink
        parts = name.split(">>>")
        if len(parts) == 4 and parts[0] == "inbound" and parts[2] == "traffic":
            tag = parts[1]
            direction = parts[3]
            # Skip api-in
            if tag == "api-in":
                continue
            with metrics_lock:
                if direction == "uplink":
                    inbound_upload[tag] = value
                elif direction == "downlink":
                    inbound_download[tag] = value


def tail_access_log():
    """Tail the xray access log published to the shared metrics volume.

    Previously this ran `docker logs -f moav-xray`, which needed the raw Docker
    socket mounted. xray writes its ACCESS log to a file (its error log still goes
    to stdout, so `moav logs xray` is unchanged), so the events are read from
    there instead. Handles truncation: the xray container caps this file, and on
    shrink we reopen from the start rather than sitting at a stale offset.
    """
    state_dir = os.environ.get("XRAY_STATE_DIR", "/var/lib/moav-metrics")
    path = os.path.join(state_dir, "xray-access.log")
    print(f"Starting access-log tailer: {path}")

    fh = None
    inode = None
    while True:
        try:
            if fh is None:
                if not os.path.exists(path):
                    time.sleep(5)
                    continue
                fh = open(path, "r", errors="replace")
                st = os.fstat(fh.fileno())
                inode = st.st_ino
                fh.seek(0, os.SEEK_END)   # only new events matter
                print(f"Access-log tailer attached to {path}")

            line = fh.readline()
            if line:
                if "accepted" in line and "moav" in line:
                    if parse_log_line(line):
                        update_active_users()
                continue

            # No data: detect truncation (file shrank) or replacement (new inode).
            try:
                st_path = os.stat(path)
                pos = fh.tell()
                if st_path.st_size < pos or st_path.st_ino != inode:
                    print("Access log rotated/truncated - reattaching")
                    fh.close()
                    fh = None
                    continue
            except FileNotFoundError:
                fh.close()
                fh = None
                continue
            time.sleep(1)

        except Exception as exc:
            print(f"Access-log tailer error: {exc}")
            if fh is not None:
                try:
                    fh.close()
                except Exception:
                    pass
                fh = None
            time.sleep(5)

def periodic_update():
    """Periodically update active users and query stats API."""
    while True:
        time.sleep(STATS_INTERVAL)
        update_active_users()
        query_xray_stats()


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
                output.append('# HELP xray_active_users Number of users active in last 5 minutes')
                output.append('# TYPE xray_active_users gauge')
                output.append(f'xray_active_users {len(active_users)}')

                # Total unique users
                output.append('# HELP xray_total_users Total number of unique users seen')
                output.append('# TYPE xray_total_users counter')
                output.append(f'xray_total_users {len(user_connections)}')

                # Total connections
                output.append('# HELP xray_total_connections Total number of user connections')
                output.append('# TYPE xray_total_connections counter')
                output.append(f'xray_total_connections {sum(user_connections.values())}')

                # Per-user connections
                output.append('# HELP xray_user_connections Total connections per user')
                output.append('# TYPE xray_user_connections counter')
                for user, count in sorted(user_connections.items()):
                    output.append(f'xray_user_connections{{user="{user}"}} {count}')

                # Per-user active status
                output.append('# HELP xray_user_active Whether user is active (1) or inactive (0)')
                output.append('# TYPE xray_user_active gauge')
                for user in user_connections:
                    is_active = 1 if user in active_users else 0
                    output.append(f'xray_user_active{{user="{user}"}} {is_active}')

                # Per-user upload bytes
                output.append('# HELP xray_user_upload_bytes Total upload bytes per user')
                output.append('# TYPE xray_user_upload_bytes counter')
                for user, bytes_val in sorted(user_upload.items()):
                    output.append(f'xray_user_upload_bytes{{user="{user}"}} {bytes_val}')

                # Per-user download bytes
                output.append('# HELP xray_user_download_bytes Total download bytes per user')
                output.append('# TYPE xray_user_download_bytes counter')
                for user, bytes_val in sorted(user_download.items()):
                    output.append(f'xray_user_download_bytes{{user="{user}"}} {bytes_val}')

                # Total upload/download
                total_up = sum(user_upload.values())
                total_down = sum(user_download.values())
                output.append('# HELP xray_upload_bytes_total Total upload bytes across all users')
                output.append('# TYPE xray_upload_bytes_total counter')
                output.append(f'xray_upload_bytes_total {total_up}')

                output.append('# HELP xray_download_bytes_total Total download bytes across all users')
                output.append('# TYPE xray_download_bytes_total counter')
                output.append(f'xray_download_bytes_total {total_down}')

                # Per-inbound traffic
                output.append('# HELP xray_inbound_upload_bytes Upload bytes per inbound')
                output.append('# TYPE xray_inbound_upload_bytes counter')
                for tag, bytes_val in sorted(inbound_upload.items()):
                    output.append(f'xray_inbound_upload_bytes{{inbound="{tag}"}} {bytes_val}')

                output.append('# HELP xray_inbound_download_bytes Download bytes per inbound')
                output.append('# TYPE xray_inbound_download_bytes counter')
                for tag, bytes_val in sorted(inbound_download.items()):
                    output.append(f'xray_inbound_download_bytes{{inbound="{tag}"}} {bytes_val}')

                # Connections by country
                output.append('# HELP xray_connections_by_country Total connections by source country')
                output.append('# TYPE xray_connections_by_country counter')
                for country, count in sorted(country_connections.items()):
                    output.append(f'xray_connections_by_country{{country="{country}"}} {count}')

                # Active users by country
                output.append('# HELP xray_active_users_by_country Active users by source country')
                output.append('# TYPE xray_active_users_by_country gauge')
                active_country_counts = defaultdict(int)
                for user in active_users:
                    c = user_country.get(user, "XX")
                    active_country_counts[c] += 1
                for country, count in sorted(active_country_counts.items()):
                    output.append(f'xray_active_users_by_country{{country="{country}"}} {count}')

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
    port = 9103

    # Start log tailer in background thread
    tailer_thread = threading.Thread(target=tail_access_log, daemon=True)
    tailer_thread.start()

    # Start periodic update thread (active users + stats API)
    update_thread = threading.Thread(target=periodic_update, daemon=True)
    update_thread.start()

    # Start HTTP server
    server = HTTPServer(('0.0.0.0', port), MetricsHandler)
    print(f"Xray user exporter listening on port {port}")
    print(f"Metrics available at http://localhost:{port}/metrics")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()


if __name__ == '__main__':
    main()
