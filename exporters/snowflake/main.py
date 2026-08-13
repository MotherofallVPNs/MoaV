#!/usr/bin/env python3
"""
Snowflake Prometheus Exporter (Optimized)

Efficiently parses snowflake proxy logs for metrics.
Uses file watching and incremental parsing to minimize CPU usage.

Log format examples:
  snowflake-proxy 2026/02/11 14:47:43 In the last 1h0m0s, this proxy served 42 connections
  snowflake-proxy 2026/02/11 14:47:43 Total bytes transferred: 123.4 MB down, 456.7 MB up
"""

import re
import os
import time
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler

# Metrics storage (cumulative - we add to these, never replace)
metrics = {
    'served_people': 0,      # Total connections served (cumulative)
    'down_bytes': 0,         # Total bytes relayed toward the client (cumulative)
    'up_bytes': 0,           # Total bytes relayed from the client (cumulative)
    'last_update_timestamp': 0,
}

# Lock for thread safety
metrics_lock = threading.Lock()

# Regex patterns for snowflake log parsing
# "there were 33 completed successful connections"
CONNECTIONS_PATTERN = re.compile(r'there were (\d+) completed')
# "Traffic Relayed ↓ 4006 KB (1.11 KB/s), ↑ 1705 KB (0.47 KB/s)"
# Note: ↓ is download (what users downloaded), ↑ is upload (what users uploaded)
BYTES_PATTERN = re.compile(r'Traffic Relayed\s*↓\s*(\d+\.?\d*)\s*(B|KB|MB|GB|TB).*?↑\s*(\d+\.?\d*)\s*(B|KB|MB|GB|TB)', re.IGNORECASE)
# Alternative: "123 MB down, 456 MB up"
ALT_BYTES_PATTERN = re.compile(r'(\d+\.?\d*)\s*(B|KB|MB|GB|TB)\s*down.*?(\d+\.?\d*)\s*(B|KB|MB|GB|TB)\s*up', re.IGNORECASE)


def convert_to_bytes(value: float, unit: str) -> int:
    """Convert a logged value with its unit to bytes."""
    unit = unit.upper()
    multipliers = {
        'B': 1,
        'KB': 1024,
        'MB': 1024 ** 2,
        'GB': 1024 ** 3,
        'TB': 1024 ** 4,
    }
    return int(value * multipliers.get(unit, 0))


def parse_log_line(line: str) -> bool:
    """Parse a log line and ACCUMULATE metrics. Returns True if metrics updated."""
    updated = False

    # Check for connections count - ACCUMULATE (add to total)
    conn_match = CONNECTIONS_PATTERN.search(line)
    if conn_match:
        connections = int(conn_match.group(1))
        with metrics_lock:
            metrics['served_people'] += connections  # Add, don't replace
            metrics['last_update_timestamp'] = time.time()
        updated = True

    # Check for bytes transferred
    bytes_match = BYTES_PATTERN.search(line)
    if not bytes_match:
        bytes_match = ALT_BYTES_PATTERN.search(line)

    if bytes_match:
        down_value = float(bytes_match.group(1))
        down_unit = bytes_match.group(2)
        up_value = float(bytes_match.group(3))
        up_unit = bytes_match.group(4)

        with metrics_lock:
            # ACCUMULATE - add to running totals
            metrics['down_bytes'] += convert_to_bytes(down_value, down_unit)
            metrics['up_bytes'] += convert_to_bytes(up_value, up_unit)
            metrics['last_update_timestamp'] = time.time()
        updated = True

    return updated


def tail_log_file(log_path: str):
    """Efficiently tail the log file using seek."""
    print(f"Starting log tailer for {log_path}...")

    last_position = 0
    last_inode = None

    while True:
        try:
            # Check if file exists
            if not os.path.exists(log_path):
                print(f"Waiting for log file: {log_path}")
                time.sleep(10)
                continue

            # Check if file was rotated (inode changed)
            current_inode = os.stat(log_path).st_ino
            if last_inode is not None and current_inode != last_inode:
                print("Log file rotated, resetting position")
                last_position = 0
            last_inode = current_inode

            # Open file and seek to last position
            with open(log_path, 'r') as f:
                # Check if file was truncated
                f.seek(0, 2)  # Seek to end
                file_size = f.tell()
                if file_size < last_position:
                    print("Log file truncated, resetting position")
                    last_position = 0

                f.seek(last_position)

                # Read new lines
                new_lines = False
                for line in f:
                    new_lines = True
                    if parse_log_line(line):
                        print(f"Total: served={metrics['served_people']}, "
                              f"down={metrics['down_bytes'] / 1024**3:.2f}GiB, "
                              f"up={metrics['up_bytes'] / 1024**3:.2f}GiB")

                last_position = f.tell()

            # Sleep longer if no new lines (file hasn't been updated)
            if new_lines:
                time.sleep(1)  # Short sleep when actively receiving data
            else:
                time.sleep(5)  # Longer sleep when idle

        except Exception as e:
            print(f"Error reading log: {e}")
            time.sleep(10)


class MetricsHandler(BaseHTTPRequestHandler):
    """HTTP handler for Prometheus metrics endpoint."""

    def do_GET(self):
        if self.path == '/metrics':
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.end_headers()

            output = []

            with metrics_lock:
                served = metrics["served_people"]
                down = metrics["down_bytes"]
                up = metrics["up_bytes"]
                stamp = metrics["last_update_timestamp"]

            # COUNTERS. These are monotonically increasing totals, and typing them
            # as gauges is what made every "over time" panel useless: Grafana was
            # plotting the lifetime total, so the line looked flat and the axis
            # auto-scaled to the noise band (150.07845..150.07848 GB). As counters,
            # rate()/increase() work and a restart -- which replays the log from
            # zero -- reads as a counter reset instead of a cliff.
            output.append('# HELP snowflake_connections_total Connections served by this proxy')
            output.append('# TYPE snowflake_connections_total counter')
            output.append(f'snowflake_connections_total {served}')

            # Bytes, not GB floats: the unit belongs in the dashboard, and GB
            # floats drift as they accumulate.
            output.append('# HELP snowflake_relayed_bytes_total Bytes relayed, by direction')
            output.append('# TYPE snowflake_relayed_bytes_total counter')
            output.append(f'snowflake_relayed_bytes_total{{direction="down"}} {down}')
            output.append(f'snowflake_relayed_bytes_total{{direction="up"}} {up}')

            output.append('# HELP snowflake_last_update_timestamp_seconds When a log line last moved a counter')
            output.append('# TYPE snowflake_last_update_timestamp_seconds gauge')
            output.append(f'snowflake_last_update_timestamp_seconds {stamp}')

            # DEPRECATED, kept so an operator's own panels do not break on upgrade.
            # Same numbers, old names and units. Remove once 2.1.x is well past.
            output.append('# HELP served_people DEPRECATED, use snowflake_connections_total')
            output.append('# TYPE served_people gauge')
            output.append(f'served_people {served}')
            output.append('# HELP download_gb DEPRECATED, use snowflake_relayed_bytes_total{direction="down"}')
            output.append('# TYPE download_gb gauge')
            output.append(f'download_gb {down / 1024 ** 3:.6f}')
            output.append('# HELP upload_gb DEPRECATED, use snowflake_relayed_bytes_total{direction="up"}')
            output.append('# TYPE upload_gb gauge')
            output.append(f'upload_gb {up / 1024 ** 3:.6f}')
            output.append('# HELP snowflake_last_update DEPRECATED, use snowflake_last_update_timestamp_seconds')
            output.append('# TYPE snowflake_last_update gauge')
            output.append(f'snowflake_last_update {stamp}')

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
        # Suppress access logs
        pass


def main():
    import sys

    # Get log path from argument or use default
    log_path = sys.argv[1] if len(sys.argv) > 1 else '/var/log/snowflake/snowflake.log'
    # Overridable so the exporter can be run and scraped outside the container,
    # which is the only way to test the metric output.
    port = int(os.environ.get('SNOWFLAKE_EXPORTER_PORT', '8080'))

    # Start log tailer in background thread
    tailer_thread = threading.Thread(target=tail_log_file, args=(log_path,), daemon=True)
    tailer_thread.start()

    # Start HTTP server
    server = HTTPServer(('0.0.0.0', port), MetricsHandler)
    print(f"Snowflake exporter listening on port {port}")
    print(f"Metrics available at http://localhost:{port}/metrics")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()


if __name__ == '__main__':
    main()
