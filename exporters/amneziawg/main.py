#!/usr/bin/env python3
"""
AmneziaWG Prometheus Exporter (per-peer metrics)

Reads the awg state file published by the tunnel container and exposes per-peer metrics.
Complements the official amneziawg-exporter (which provides DAU/MAU/online).
"""

import re
import os
import threading
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from collections import defaultdict
from geoip import GeoIPLookup

# Metrics storage
metrics = {
    'peers': {},  # public_key -> {endpoint, latest_handshake, transfer_rx, transfer_tx, allowed_ips}
    'interface': {},  # interface stats
    'last_update': 0,
}

metrics_lock = threading.Lock()

# Peer name mapping (from config file)
peer_names = {}  # public_key -> name

# GeoIP lookup
geoip = GeoIPLookup()


def load_peer_names():
    """Load peer names from amneziawg config."""
    global peer_names
    try:
        with open('/etc/amneziawg/awg0.conf', 'r') as f:
            content = f.read()

        current_name = None
        for line in content.split('\n'):
            line = line.strip()
            if line.startswith('# ') and not line.startswith('# ='):
                current_name = line[2:].strip()
            elif line == '[Peer]':
                pass
            elif line.startswith('PublicKey') and current_name:
                pubkey = line.split('=', 1)[1].strip()
                peer_names[pubkey] = current_name
                current_name = None
    except Exception as e:
        print(f"Could not load peer names: {e}")


def parse_awg_show(output: str):
    """Parse awg show output into metrics."""
    peers = {}
    interface = {}
    current_peer = None

    for line in output.split('\n'):
        line = line.strip()
        if not line:
            continue

        if line.startswith('interface:'):
            interface['name'] = line.split(':', 1)[1].strip()
        elif line.startswith('public key:'):
            if current_peer is None:
                interface['public_key'] = line.split(':', 1)[1].strip()
        elif line.startswith('listening port:'):
            interface['listening_port'] = int(line.split(':', 1)[1].strip())
        elif line.startswith('peer:'):
            current_peer = line.split(':', 1)[1].strip()
            peers[current_peer] = {
                'endpoint': '',
                'latest_handshake': 0,
                'transfer_rx': 0,
                'transfer_tx': 0,
                'allowed_ips': '',
            }
        elif current_peer:
            if line.startswith('endpoint:'):
                peers[current_peer]['endpoint'] = line.split(':', 1)[1].strip()
            elif line.startswith('allowed ips:'):
                peers[current_peer]['allowed_ips'] = line.split(':', 1)[1].strip()
            elif line.startswith('latest handshake:'):
                hs_str = line.split(':', 1)[1].strip()
                peers[current_peer]['latest_handshake'] = parse_handshake_time(hs_str)
            elif line.startswith('transfer:'):
                transfer_str = line.split(':', 1)[1].strip()
                rx, tx = parse_transfer(transfer_str)
                peers[current_peer]['transfer_rx'] = rx
                peers[current_peer]['transfer_tx'] = tx

    return interface, peers


def parse_handshake_time(hs_str: str) -> int:
    """Parse handshake time string to seconds ago."""
    if not hs_str or hs_str == '(none)':
        return 0

    total_seconds = 0
    parts = re.findall(r'(\d+)\s*(second|minute|hour|day)s?', hs_str)
    for value, unit in parts:
        value = int(value)
        if 'second' in unit:
            total_seconds += value
        elif 'minute' in unit:
            total_seconds += value * 60
        elif 'hour' in unit:
            total_seconds += value * 3600
        elif 'day' in unit:
            total_seconds += value * 86400

    return int(time.time()) - total_seconds if total_seconds else 0


def parse_transfer(transfer_str: str) -> tuple:
    """Parse transfer string to bytes (rx, tx)."""
    rx_bytes = 0
    tx_bytes = 0

    rx_match = re.search(r'([\d.]+)\s*(B|KiB|MiB|GiB|TiB)\s*received', transfer_str)
    tx_match = re.search(r'([\d.]+)\s*(B|KiB|MiB|GiB|TiB)\s*sent', transfer_str)

    multipliers = {'B': 1, 'KiB': 1024, 'MiB': 1024**2, 'GiB': 1024**3, 'TiB': 1024**4}

    if rx_match:
        rx_bytes = int(float(rx_match.group(1)) * multipliers.get(rx_match.group(2), 1))
    if tx_match:
        tx_bytes = int(float(tx_match.group(1)) * multipliers.get(tx_match.group(2), 1))

    return rx_bytes, tx_bytes


def extract_ip_from_endpoint(endpoint: str) -> str:
    """Extract IP from endpoint string (IP:port format)."""
    if not endpoint:
        return ""
    parts = endpoint.rsplit(':', 1)
    return parts[0] if parts else ""


def collect_metrics():
    """Run awg show and collect metrics."""
    try:
        # Read the state file published by the moav-amneziawg entrypoint instead of
        # `docker exec … awg show`. That exec required mounting the raw Docker
        # socket -- unrestricted Docker API access, a path to host root, for a
        # read-only scrape. `awg show` needs that container's netns, so there is no
        # API to call: the container publishes its state and we read it.
        state_file = os.environ.get(
            "AWG_STATE_FILE", "/var/lib/moav-metrics/awg-show.txt")
        try:
            with open(state_file) as fh:
                show_output = fh.read()
        except FileNotFoundError:
            print(f"awg state file not found yet: {state_file} "
                  f"(the moav-amneziawg container publishes it every 15s)")
            return
        except OSError as exc:
            print(f"cannot read {state_file}: {exc}")
            return

        if not show_output.strip():
            print(f"awg state file is empty: {state_file}")
            return

        interface, peers = parse_awg_show(show_output)

        # Add country to each peer
        for pubkey, peer in peers.items():
            ip = extract_ip_from_endpoint(peer['endpoint'])
            peer['country'] = geoip.lookup(ip) if ip else "XX"

        with metrics_lock:
            metrics['interface'] = interface
            metrics['peers'] = peers
            metrics['last_update'] = time.time()

        print(f"Updated: {len(peers)} peers")

    except Exception as e:
        print(f"Error collecting metrics: {e}")


def metrics_collector():
    """Background thread to collect metrics periodically."""
    while True:
        collect_metrics()
        time.sleep(15)


class MetricsHandler(BaseHTTPRequestHandler):
    """HTTP handler for Prometheus metrics endpoint."""

    def do_GET(self):
        if self.path == '/metrics':
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.end_headers()

            output = []

            with metrics_lock:
                # Interface info
                if metrics['interface'].get('name'):
                    output.append('# HELP amneziawg_interface_info AmneziaWG interface information')
                    output.append('# TYPE amneziawg_interface_info gauge')
                    output.append(f'amneziawg_interface_info{{interface="{metrics["interface"].get("name", "")}"}} 1')

                # Peer count
                output.append('# HELP amneziawg_peers_total Total number of configured peers')
                output.append('# TYPE amneziawg_peers_total gauge')
                output.append(f'amneziawg_peers_total {len(metrics["peers"])}')

                # Per-peer metrics
                output.append('# HELP amneziawg_peer_transfer_rx_bytes Bytes received from peer')
                output.append('# TYPE amneziawg_peer_transfer_rx_bytes counter')

                output.append('# HELP amneziawg_peer_transfer_tx_bytes Bytes sent to peer')
                output.append('# TYPE amneziawg_peer_transfer_tx_bytes counter')

                output.append('# HELP amneziawg_peer_latest_handshake_seconds UNIX timestamp of last handshake')
                output.append('# TYPE amneziawg_peer_latest_handshake_seconds gauge')

                output.append('# HELP amneziawg_peer_active Whether peer has recent handshake (1=active)')
                output.append('# TYPE amneziawg_peer_active gauge')

                country_counts = defaultdict(int)

                for pubkey, peer in metrics['peers'].items():
                    name = peer_names.get(pubkey, pubkey[:8] + '...')
                    country = peer.get('country', 'XX')
                    labels = f'public_key="{pubkey}",name="{name}",country="{country}"'

                    output.append(f'amneziawg_peer_transfer_rx_bytes{{{labels}}} {peer["transfer_rx"]}')
                    output.append(f'amneziawg_peer_transfer_tx_bytes{{{labels}}} {peer["transfer_tx"]}')

                    if peer['latest_handshake'] > 0:
                        output.append(f'amneziawg_peer_latest_handshake_seconds{{{labels}}} {peer["latest_handshake"]}')
                        is_active = 1 if (time.time() - peer['latest_handshake']) < 180 else 0
                        output.append(f'amneziawg_peer_active{{{labels}}} {is_active}')
                        if is_active:
                            country_counts[country] += 1
                    else:
                        output.append(f'amneziawg_peer_latest_handshake_seconds{{{labels}}} 0')
                        output.append(f'amneziawg_peer_active{{{labels}}} 0')

                # Active peers by country
                output.append('# HELP amneziawg_active_peers_by_country Active peers by source country')
                output.append('# TYPE amneziawg_active_peers_by_country gauge')
                for country, count in sorted(country_counts.items()):
                    output.append(f'amneziawg_active_peers_by_country{{country="{country}"}} {count}')

                # Last update timestamp
                output.append('# HELP amneziawg_last_update_timestamp Unix timestamp of last successful update')
                output.append('# TYPE amneziawg_last_update_timestamp gauge')
                output.append(f'amneziawg_last_update_timestamp {metrics["last_update"]}')

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
    port = 9587

    # Load peer names from config
    load_peer_names()
    print(f"Loaded {len(peer_names)} peer names from config")

    # Initial collection
    collect_metrics()

    # Start background collector
    collector_thread = threading.Thread(target=metrics_collector, daemon=True)
    collector_thread.start()

    # Start HTTP server
    server = HTTPServer(('0.0.0.0', port), MetricsHandler)
    print(f"AmneziaWG exporter listening on port {port}")
    print(f"Metrics available at http://localhost:{port}/metrics")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()


if __name__ == '__main__':
    main()
