#!/usr/bin/env python3
"""Prometheus exporter maintaining a true running maximum of Conduit's
connected/connecting client counts since the current process started.

Unlike querying "max_over_time(...) over the last N hours" from Grafana,
this never re-scans history — it polls Conduit's own /metrics endpoint on
the same 15s cadence Prometheus already uses, updates an in-memory running
max only when a new value beats the record, and serves that single number.
No resolution/point-limit tradeoffs, no repeated historical query cost,
exact by construction (a running max updated on every real sample is
identical to the true max, unlike windowed/sampled approximations).

Session boundary detection: process_start_time_seconds (from Conduit's own
/metrics, a standard Go process-collector gauge) only changes when Conduit
restarts. When it changes, both running maxes reset to the session's first
observed value.

State (the running max + the process_start_time it belongs to) is
persisted to a small JSON file so restarting *this* exporter doesn't lose
the record — only a genuine Conduit restart resets it.

Configuration is via environment variables (all optional, defaults shown
below) so the same script runs unmodified on any host/user/deployment
rather than needing hardcoded local paths.

REVISION HISTORY (newest first):
  260819 - Initial version.
"""

import json
import os
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

CONDUIT_METRICS_URL = os.environ.get('CONDUIT_METRICS_URL', 'http://127.0.0.1:9090/metrics')
STATE_FILE = os.environ.get('SESSION_HIGH_STATE_FILE', os.path.expanduser('~/.session-high-state.json'))
LISTEN_HOST = os.environ.get('SESSION_HIGH_LISTEN_HOST', '127.0.0.1')
LISTEN_PORT = int(os.environ.get('SESSION_HIGH_LISTEN_PORT', '9201'))
LISTEN_ADDR = (LISTEN_HOST, LISTEN_PORT)
POLL_INTERVAL_SECONDS = int(os.environ.get('SESSION_HIGH_POLL_INTERVAL', '15'))

lock = threading.Lock()
state = {
    'process_start_time': None,
    'session_high_connected': 0,
    'session_high_connecting': 0,
}


def load_state():
    try:
        with open(STATE_FILE) as f:
            loaded = json.load(f)
        state.update(loaded)
    except (FileNotFoundError, json.JSONDecodeError, ValueError):
        pass


def save_state():
    with open(STATE_FILE, 'w') as f:
        json.dump(state, f)


def parse_conduit_metrics(text):
    values = {}
    for line in text.splitlines():
        if line.startswith('#') or not line.strip():
            continue
        if line.startswith('conduit_connected_clients '):
            values['connected'] = float(line.split()[-1])
        elif line.startswith('conduit_connecting_clients '):
            values['connecting'] = float(line.split()[-1])
        elif line.startswith('process_start_time_seconds'):
            values['start_time'] = float(line.split()[-1])
    return values


def poll_once():
    with urllib.request.urlopen(CONDUIT_METRICS_URL, timeout=10) as r:
        text = r.read().decode('utf-8', errors='replace')
    values = parse_conduit_metrics(text)
    if not {'connected', 'connecting', 'start_time'} <= values.keys():
        return  # incomplete scrape (e.g. Conduit mid-restart) -- skip this cycle

    with lock:
        if state['process_start_time'] != values['start_time']:
            # New session (or first run ever) -- reset to this cycle's own values
            state['process_start_time'] = values['start_time']
            state['session_high_connected'] = values['connected']
            state['session_high_connecting'] = values['connecting']
        else:
            if values['connected'] > state['session_high_connected']:
                state['session_high_connected'] = values['connected']
            if values['connecting'] > state['session_high_connecting']:
                state['session_high_connecting'] = values['connecting']
        save_state()


def poll_loop():
    while True:
        try:
            poll_once()
        except Exception as e:
            print(f'{time.strftime("%Y-%m-%d %H:%M:%S")} ERROR in poll_loop: {e}', flush=True)
        time.sleep(POLL_INTERVAL_SECONDS)


def render_metrics():
    with lock:
        connected = state['session_high_connected']
        connecting = state['session_high_connecting']
    lines = [
        '# HELP conduit_session_high_connected_clients True running maximum of connected clients since Conduit process start',
        '# TYPE conduit_session_high_connected_clients gauge',
        f'conduit_session_high_connected_clients {connected}',
        '# HELP conduit_session_high_connecting_clients True running maximum of connecting clients since Conduit process start',
        '# TYPE conduit_session_high_connecting_clients gauge',
        f'conduit_session_high_connecting_clients {connecting}',
    ]
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
        pass  # quiet -- Prometheus scrapes every 15s, no need to log each one


if __name__ == '__main__':
    load_state()
    t = threading.Thread(target=poll_loop, daemon=True)
    t.start()
    print(f'{time.strftime("%Y-%m-%d %H:%M:%S")} session-high-exporter listening on {LISTEN_ADDR[0]}:{LISTEN_ADDR[1]}', flush=True)
    server = HTTPServer(LISTEN_ADDR, Handler)
    server.serve_forever()
