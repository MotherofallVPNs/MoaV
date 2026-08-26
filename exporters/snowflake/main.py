#!/usr/bin/env python3
"""
Snowflake cumulative + windowed Prometheus exporter.

The proxy's own /internal/metrics endpoint (scraped directly by Prometheus) is
authoritative for per-country connections and connection failures, but its
byte/connection counters are in-memory and RESET to zero every time the proxy
restarts. A dashboard that sums them therefore shows only the traffic since the
last restart -- which is why a proxy that relayed tens of GB reads near-zero
after a routine `docker compose up -d`.

This exporter closes that gap by reading the proxy's persistent summary log
(tee'd to a named volume that survives container recreation). It exposes two
kinds of metric, both derived from the log so both survive proxy AND exporter
restarts:

  * Cumulative counters -- lifetime bytes relayed / connections served. Seeded
    from a state file so they only ever go up. Backfilled in one pass, so they
    are FLAT afterwards: read them raw for a lifetime total, NEVER with
    increase()/rate() over a range (there is no per-scrape history to diff).

  * Trailing-window gauges -- bytes/connections within the last 1h/24h/7d/14d,
    summed from the log's OWN timestamps. This is what the "last N days" panels
    need: Prometheus stamps samples at scrape time, so a backfilled counter can
    never answer "how much in the last 14 days" via increase(); computing it
    from the log timestamps can, and it is correct immediately and after any
    restart.

Split of responsibility (see tests/snowflake-metrics-test.sh):
  native /internal/metrics  -> per-country, failures, live throughput (rate)
  this exporter             -> cumulative + windowed bytes/connections

Summary line format (snowflake proxy, -summary-interval):
  2026/08/26 16:37:41 In the last 1m30s, there were 3 completed successful
  connections. Traffic Relayed ↓ 8667 KB (0.00 KB/s), ↑ 512 KB (0.00 KB/s).
"""

import datetime
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
# Recompute the trailing-window gauges every Nth poll (they need minutes, not
# seconds, of freshness, and each rebuild re-parses a log tail).
WINDOW_EVERY = max(1, int(os.environ.get("SNOWFLAKE_WINDOW_EVERY", "4")))
# How much of the log tail to re-parse for the windows. 8 MB of ~150-byte
# summary lines at one per 90s covers well over 14 days.
WINDOW_TAIL_BYTES = int(os.environ.get("SNOWFLAKE_WINDOW_TAIL_BYTES", str(8_000_000)))

# Trailing windows to expose, label -> seconds.
WINDOWS = {"1h": 3600, "24h": 86400, "7d": 604800, "14d": 1209600}

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

# Leading log timestamp, e.g. "2026/08/26 16:37:41". Parsed naive: the snowflake
# and exporter containers share one TZ env, so naive-vs-naive age is correct
# without assuming which zone it is.
TS_RE = re.compile(r"^(\d{4})/(\d{2})/(\d{2}) (\d{2}):(\d{2}):(\d{2})")
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

# Trailing-window rollups, recomputed from the log tail. Served under its own
# lock so a slow rebuild never blocks the cumulative poll.
window_state = {"bytes": {}, "conns": {}, "computed_at": 0}
window_lock = threading.Lock()
exporter_ready = False


def _to_bytes(value: str, unit: str) -> int:
    return int(float(value) * UNIT_BYTES.get(unit.upper(), 0))


def parse_dt(line: str):
    """Datetime from a summary line's leading timestamp, or None."""
    m = TS_RE.match(line)
    if not m:
        return None
    try:
        return datetime.datetime(*(int(x) for x in m.groups()))
    except ValueError:
        return None


def parse_counts(line: str):
    """(connections, inbound_bytes, outbound_bytes) for a summary line, or None."""
    cm = CONN_RE.search(line)
    if not cm:
        return None
    tm = TRAFFIC_RE.search(line)
    inb = _to_bytes(tm.group(1), tm.group(2)) if tm else 0
    outb = _to_bytes(tm.group(3), tm.group(4)) if tm else 0
    return int(cm.group(1)), inb, outb


def compute_windows(text, now):
    """Sum bytes/connections per trailing window from timestamped summary lines.

    Pure: given the log text and a `now` datetime, return (bytes, conns) where
    bytes maps (direction, window) -> int and conns maps window -> int. Lines
    without a parseable timestamp or count are skipped.
    """
    b = {(d, w): 0 for d in ("inbound", "outbound") for w in WINDOWS}
    c = {w: 0 for w in WINDOWS}
    for line in text.splitlines():
        dt = parse_dt(line)
        if dt is None:
            continue
        counts = parse_counts(line)
        if counts is None:
            continue
        conns, inb, outb = counts
        age = (now - dt).total_seconds()
        if age < 0:
            age = 0.0
        for w, secs in WINDOWS.items():
            if age <= secs:
                b[("inbound", w)] += inb
                b[("outbound", w)] += outb
                c[w] += conns
    return b, c


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
    counts = parse_counts(line)
    if counts is None:
        return  # not a summary line
    conns, inb, outb = counts
    state["connections"] += conns
    state["inbound_bytes"] += inb
    state["outbound_bytes"] += outb
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


def rebuild_windows():
    """Recompute the trailing-window gauges from a bounded tail of the log."""
    try:
        st = os.stat(LOG_FILE)
    except OSError:
        return
    try:
        with open(LOG_FILE, "rb") as fh:
            if st.st_size > WINDOW_TAIL_BYTES:
                fh.seek(st.st_size - WINDOW_TAIL_BYTES)
                fh.readline()  # drop the partial line the seek landed inside
            text = fh.read().decode("utf-8", "replace")
    except OSError as exc:
        print(f"snowflake-exporter: cannot read log tail for windows: {exc}")
        return
    b, c = compute_windows(text, datetime.datetime.now())
    with window_lock:
        window_state["bytes"] = b
        window_state["conns"] = c
        window_state["computed_at"] = int(time.time())


def poll_loop():
    global exporter_ready
    n = 0
    while True:
        poll_once()
        if n % WINDOW_EVERY == 0:
            rebuild_windows()
        n += 1
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
        with window_lock:
            wb = dict(window_state["bytes"])
            wc = dict(window_state["conns"])

        out = [
            "# HELP moav_snowflake_relayed_bytes_total Cumulative bytes relayed to Snowflake clients, across proxy and exporter restarts. Read raw for a lifetime total; the counter is backfilled flat, so increase()/rate() over a range reads 0.",
            "# TYPE moav_snowflake_relayed_bytes_total counter",
            f'moav_snowflake_relayed_bytes_total{{direction="inbound"}} {snap["inbound_bytes"]}',
            f'moav_snowflake_relayed_bytes_total{{direction="outbound"}} {snap["outbound_bytes"]}',
            "# HELP moav_snowflake_completed_connections_total Cumulative completed successful connections, across restarts. Read raw (backfilled flat).",
            "# TYPE moav_snowflake_completed_connections_total counter",
            f'moav_snowflake_completed_connections_total {snap["connections"]}',
            "# HELP moav_snowflake_relayed_bytes_window Bytes relayed within a trailing window, summed from the log's own timestamps (restart-independent).",
            "# TYPE moav_snowflake_relayed_bytes_window gauge",
        ]
        for (d, w) in sorted(wb):
            out.append(f'moav_snowflake_relayed_bytes_window{{direction="{d}",window="{w}"}} {wb[(d, w)]}')
        out += [
            "# HELP moav_snowflake_completed_connections_window Completed connections within a trailing window, from the log timestamps.",
            "# TYPE moav_snowflake_completed_connections_window gauge",
        ]
        for w in sorted(wc):
            out.append(f'moav_snowflake_completed_connections_window{{window="{w}"}} {wc[w]}')
        out += [
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
