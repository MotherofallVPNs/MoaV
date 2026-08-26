#!/usr/bin/env python3
"""
Snowflake cumulative Prometheus exporter.

The proxy's own /internal/metrics endpoint (scraped directly by Prometheus) is
authoritative for per-country connections and connection failures, but its
byte/connection counters are in-memory and RESET to zero every time the proxy
restarts. A dashboard that sums them therefore shows only the traffic since the
last restart -- which is why a proxy that relayed tens of GB reads near-zero
after a routine `docker compose up -d`.

This exporter closes that gap. It reads the proxy's persistent summary log
(tee'd to a named volume that survives container recreation) and accumulates the
per-window totals into monotonic counters that persist across BOTH proxy
restarts (the log volume) AND its own restarts (a small state file). The result
is a lifetime "bytes relayed / connections served" that only ever goes up.

Split of responsibility (see tests/snowflake-metrics-test.sh):
  native /internal/metrics  -> per-country, failures, live throughput (rate)
  this exporter             -> cumulative bytes relayed + connections served

Summary line format (snowflake proxy, -summary-interval):
  2026/08/26 16:37:41 In the last 1m30s, there were 3 completed successful
  connections. Traffic Relayed ↓ 8667 KB (0.00 KB/s), ↑ 512 KB (0.00 KB/s).
"""

import json
import os
import re
import threading
import time
from http.server import HTTPServer, BaseHTTPRequestHandler

LOG_FILE = os.environ.get("SNOWFLAKE_LOG_FILE", "/var/log/snowflake/snowflake.log")
STATE_FILE = os.environ.get("SNOWFLAKE_STATE_FILE", "/var/lib/snowflake-exporter/state.json")
PORT = int(os.environ.get("SNOWFLAKE_EXPORTER_PORT", "9105"))
POLL_INTERVAL = int(os.environ.get("SNOWFLAKE_POLL_INTERVAL", "15"))

# KB=1024 to match the native traffic counters, which the dashboard already
# scales by 1024 (tests/snowflake-metrics-test.sh trap #2). Snowflake's own log
# uses decimal KB; the ~2.4% delta is accepted so the cumulative panels and the
# live-throughput panels on the same dashboard agree with each other.
UNIT_BYTES = {
    "B": 1,
    "KB": 1024, "KIB": 1024,
    "MB": 1024 ** 2, "MIB": 1024 ** 2,
    "GB": 1024 ** 3, "GIB": 1024 ** 3,
    "TB": 1024 ** 4, "TIB": 1024 ** 4,
}

# "there were N completed successful connections"
CONN_RE = re.compile(r"there were (\d+) completed successful connection")
# "Traffic Relayed ↓ X UNIT (...), ↑ Y UNIT (...)". Down (↓) is inbound to
# match the native tor_snowflake_proxy_traffic_inbound_bytes_total naming.
TRAFFIC_RE = re.compile(
    r"Relayed\s+↓\s*([\d.]+)\s*([KMGT]?i?B)\b.*?↑\s*([\d.]+)\s*([KMGT]?i?B)\b"
)

# Cumulative state. Seeded from disk, advanced by the poll loop, served as-is.
state = {
    "offset": 0,          # byte offset read so far in the current log file
    "inode": 0,           # inode of the log file (rotation detection)
    "connections": 0,     # cumulative completed connections
    "inbound_bytes": 0,   # cumulative down / relayed-to-client bytes
    "outbound_bytes": 0,  # cumulative up bytes
    "windows": 0,         # number of summary windows parsed (debug/freshness)
    "last_summary": 0,    # epoch of the newest parsed summary line
}
state_lock = threading.Lock()
exporter_ready = False


def _to_bytes(value: str, unit: str) -> int:
    return int(float(value) * UNIT_BYTES.get(unit.upper(), 0))


def load_state():
    """Seed cumulative totals from the persisted state file, if present."""
    try:
        with open(STATE_FILE) as fh:
            saved = json.load(fh)
        with state_lock:
            for k in state:
                if k in saved:
                    state[k] = saved[k]
        print(f"snowflake-exporter: resumed state from {STATE_FILE} "
              f"(offset={state['offset']}, windows={state['windows']})")
    except FileNotFoundError:
        print(f"snowflake-exporter: no state file yet at {STATE_FILE}; "
              f"backfilling from the start of {LOG_FILE}")
    except (OSError, ValueError) as exc:
        # Corrupt state must not zero a lifetime counter: keep whatever we have
        # (fresh zeros on first boot) and re-read the whole log from offset 0.
        print(f"snowflake-exporter: ignoring unreadable state file {STATE_FILE}: {exc}")


def save_state():
    """Atomically persist cumulative totals so an exporter restart resumes."""
    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        tmp = STATE_FILE + ".tmp"
        with state_lock:
            snapshot = dict(state)
        with open(tmp, "w") as fh:
            json.dump(snapshot, fh)
        os.replace(tmp, STATE_FILE)
    except OSError as exc:
        print(f"snowflake-exporter: could not persist state: {exc}")


def parse_line(line: str):
    """Add one summary line's counts to the cumulative state (caller holds lock)."""
    m = CONN_RE.search(line)
    if not m:
        return  # not a summary line
    state["connections"] += int(m.group(1))
    t = TRAFFIC_RE.search(line)
    if t:
        state["inbound_bytes"] += _to_bytes(t.group(1), t.group(2))
        state["outbound_bytes"] += _to_bytes(t.group(3), t.group(4))
    state["windows"] += 1
    state["last_summary"] = int(time.time())


def poll_once():
    """Read new log bytes since last offset, handling rotation/truncation."""
    try:
        st = os.stat(LOG_FILE)
    except FileNotFoundError:
        return
    except OSError as exc:
        print(f"snowflake-exporter: cannot stat {LOG_FILE}: {exc}")
        return

    with state_lock:
        offset = state["offset"]
        known_inode = state["inode"]

    # Rotation/truncation: a new inode or a file shorter than where we stopped
    # means the log we were tailing is gone. Keep the accumulated totals and
    # re-read the replacement from the top -- the counters must never regress.
    if known_inode and (st.st_ino != known_inode or st.st_size < offset):
        print(f"snowflake-exporter: log rotation detected "
              f"(inode {known_inode}->{st.st_ino}, size {st.st_size} < offset {offset}); "
              f"re-reading from start, totals preserved")
        offset = 0

    try:
        with open(LOG_FILE, "r", encoding="utf-8", errors="replace") as fh:
            fh.seek(offset)
            with state_lock:
                for line in fh:
                    parse_line(line)
                new_offset = fh.tell()
                state["offset"] = new_offset
                state["inode"] = st.st_ino
    except OSError as exc:
        print(f"snowflake-exporter: cannot read {LOG_FILE}: {exc}")
        return

    save_state()


def poll_loop():
    global exporter_ready
    while True:
        poll_once()
        exporter_ready = True
        time.sleep(POLL_INTERVAL)


class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return

        with state_lock:
            snap = dict(state)

        out = [
            "# HELP moav_snowflake_relayed_bytes_total Cumulative bytes relayed to Snowflake clients, across proxy and exporter restarts.",
            "# TYPE moav_snowflake_relayed_bytes_total counter",
            f'moav_snowflake_relayed_bytes_total{{direction="inbound"}} {snap["inbound_bytes"]}',
            f'moav_snowflake_relayed_bytes_total{{direction="outbound"}} {snap["outbound_bytes"]}',
            "# HELP moav_snowflake_completed_connections_total Cumulative completed successful connections, across restarts.",
            "# TYPE moav_snowflake_completed_connections_total counter",
            f'moav_snowflake_completed_connections_total {snap["connections"]}',
            "# HELP moav_snowflake_summary_windows_total Number of proxy summary windows parsed from the log.",
            "# TYPE moav_snowflake_summary_windows_total counter",
            f'moav_snowflake_summary_windows_total {snap["windows"]}',
            "# HELP moav_snowflake_last_summary_timestamp_seconds Unix time the newest summary line was parsed (freshness).",
            "# TYPE moav_snowflake_last_summary_timestamp_seconds gauge",
            f'moav_snowflake_last_summary_timestamp_seconds {snap["last_summary"]}',
            "# HELP moav_snowflake_exporter_up 1 once the exporter has completed a poll of the log.",
            "# TYPE moav_snowflake_exporter_up gauge",
            f'moav_snowflake_exporter_up {1 if exporter_ready else 0}',
        ]
        body = ("\n".join(out) + "\n").encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass  # Prometheus scrapes every few seconds; stay quiet.


def main():
    load_state()
    threading.Thread(target=poll_loop, daemon=True).start()
    print(f"snowflake-exporter: serving /metrics on :{PORT}, log={LOG_FILE}")
    HTTPServer(("0.0.0.0", PORT), MetricsHandler).serve_forever()


if __name__ == "__main__":
    main()
