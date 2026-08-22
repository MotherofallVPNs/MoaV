#!/usr/bin/env python3
"""Prometheus exporter that turns notable conduit.log text patterns into
real, graphable metrics. Things like the broker's "limited" backoff
response, ICE-negotiation timeouts, and "no match" results only ever
existed as text a human had to grep for after the fact — this tails
conduit.log incrementally (byte-offset cursor, so a restart doesn't
re-count already-seen content) and serves counts at /metrics for
Prometheus to scrape, so they can be graphed on the same timeline as
Connected/Connecting/Announcing.

Counters reset to 0 on exporter restart — this is normal, expected
Prometheus counter behavior, and rate()/increase() in Grafana handle a
counter reset correctly on their own. What must never happen is
re-counting already-seen log content after a restart, which is why the
byte offset (not the counts) is the thing persisted across restarts.
"""

import os
import re
import time
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from collections import defaultdict

CONDUIT_LOG = os.environ.get('CONDUIT_LOG_PATH', os.path.expanduser('~/conduit.log'))
OFFSET_FILE = os.environ.get('LOG_METRICS_OFFSET_FILE', os.path.expanduser('~/.log-metrics-offset'))
LISTEN_HOST = os.environ.get('LOG_METRICS_LISTEN_HOST', '127.0.0.1')
LISTEN_PORT = int(os.environ.get('LOG_METRICS_LISTEN_PORT', '9200'))
POLL_INTERVAL = float(os.environ.get('LOG_METRICS_POLL_INTERVAL', '10'))

PATTERNS = {
    'limited': re.compile(r'\blimited\b'),
    'ice_timeout': re.compile(r'context deadline exceeded'),
    'no_match': re.compile(r'\bno match\b', re.IGNORECASE),
    'broker_reset': re.compile(r'connection reset by peer'),
}

lock = threading.Lock()
counts = defaultdict(int)


def read_offset():
    try:
        with open(OFFSET_FILE) as f:
            return int(f.read().strip())
    except (FileNotFoundError, ValueError):
        return 0


def write_offset(offset):
    with open(OFFSET_FILE, 'w') as f:
        f.write(str(offset))


def read_new_content():
    try:
        size = os.path.getsize(CONDUIT_LOG)
    except FileNotFoundError:
        return ''
    offset = read_offset()
    if offset > size:
        offset = 0  # log rotated/truncated
    with open(CONDUIT_LOG, 'rb') as f:
        f.seek(offset)
        data = f.read()
    write_offset(size)
    return data.decode('utf-8', errors='replace')


def scan():
    content = read_new_content()
    if not content:
        return
    # Do the (potentially slow, for a large first-scan backlog) regex work
    # OUTSIDE the lock, so a long scan can't block /metrics from being
    # served in the meantime. Only the final dict update needs the lock.
    deltas = {}
    for name, pattern in PATTERNS.items():
        n = len(pattern.findall(content))
        if n:
            deltas[name] = n
    if deltas:
        with lock:
            for name, n in deltas.items():
                counts[name] += n


def poll_loop():
    while True:
        try:
            scan()
        except Exception as e:
            print(f'{time.strftime("%Y-%m-%d %H:%M:%S")} ERROR in poll_loop: {e}', flush=True)
        time.sleep(POLL_INTERVAL)


def render_metrics():
    lines = []
    lines.append('# HELP conduit_log_events_total Counts of notable patterns seen in conduit.log since exporter start')
    lines.append('# TYPE conduit_log_events_total counter')
    with lock:
        for name, count in sorted(counts.items()):
            lines.append(f'conduit_log_events_total{{type="{name}"}} {count}')
    return '\n'.join(lines) + '\n'


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != '/metrics':
            self.send_response(404)
            self.end_headers()
            return
        body = render_metrics().encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain; version=0.0.4')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass  # quiet — Prometheus scrapes every 10-15s, no need to log each one


if __name__ == '__main__':
    t = threading.Thread(target=poll_loop, daemon=True)
    t.start()
    print(f'{time.strftime("%Y-%m-%d %H:%M:%S")} log-metrics-exporter listening on {LISTEN_HOST}:{LISTEN_PORT}, tailing {CONDUIT_LOG}', flush=True)
    server = HTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    server.serve_forever()
