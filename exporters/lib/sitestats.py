"""Aggregate destination stats that cannot be linked back to a client.

Off unless ENABLE_SITE_ANALYTICS=true. See MotherofallVPNs/MoaV#297.

Guarantees, all enforced here rather than downstream:
  * no client identifier is ever returned, in any label
  * a site is named only after MIN_CLIENTS distinct clients have reached it
  * everything below that threshold accumulates under "other"
  * exposed counters advance on a bucket boundary, not per poll
"""
import hashlib
import os
import threading
import time

ENABLED = os.environ.get("ENABLE_SITE_ANALYTICS", "false").lower() == "true"
RESEARCH = os.environ.get("ENABLE_SITE_ANALYTICS_RESEARCH", "false").lower() == "true"
MIN_CLIENTS = int(os.environ.get("SITE_ANALYTICS_MIN_CLIENTS", "5"))
TOP_N = int(os.environ.get("SITE_ANALYTICS_TOP_N", "50"))
BUCKET_SECONDS = int(os.environ.get("SITE_ANALYTICS_BUCKET_SECONDS", "3600"))

OTHER = "other"

# Suffixes needing three labels to reach the registrable name. Not the full
# public suffix list: this only has to be right for common hosts, and a wrong
# guess folds too much together rather than too little.
_TWO_PART = {
    "co.uk", "org.uk", "ac.uk", "gov.uk", "co.jp", "ne.jp", "or.jp",
    "com.br", "com.au", "net.au", "org.au", "com.cn", "com.tr", "com.mx",
    "co.in", "co.kr", "co.za", "com.ar", "com.sg", "com.hk", "com.tw",
}

# Per-process, never persisted: makes the in-memory client set unusable even to
# something that reads this process's memory.
_SALT = os.urandom(16)


def registrable(host):
    """foo.bar.example-cdn.net -> example-cdn.net"""
    host = (host or "").strip().strip(".").lower()
    if not host or host.replace(".", "").isdigit() or ":" in host:
        return ""                      # bare IP or malformed: no site to report
    parts = host.split(".")
    if len(parts) < 2:
        return ""
    if len(parts) >= 3 and ".".join(parts[-2:]) in _TWO_PART:
        return ".".join(parts[-3:])
    return ".".join(parts[-2:])


def _client_key(client):
    return hashlib.blake2b(_SALT + client.encode(), digest_size=16).digest()


class SiteStats:
    def __init__(self, now=None):
        self.lock = threading.Lock()
        self._bucket = int((time.time() if now is None else now) // BUCKET_SECONDS)
        self._clients = {}        # site -> set of salted client digests
        self._pending = {}        # site -> {"up": n, "down": n}
        self._countries = {}      # destination country -> pending bytes
        self._ports = {}          # (site, port, network) -> pending bytes, research only
        self.sites = {}           # exposed cumulative counters
        self.countries = {}
        self.ports = {}

    def record(self, client, host, up, down, dest_country="", port="", network=""):
        """One connection's delta. `client` never leaves this object."""
        if not ENABLED or (up <= 0 and down <= 0):
            return
        # A bare IP has no site to name, but its bytes still belong in the
        # total, so it lands in "other" rather than being dropped.
        site = registrable(host) or OTHER
        with self.lock:
            self._clients.setdefault(site, set()).add(_client_key(client))
            p = self._pending.setdefault(site, {"up": 0, "down": 0})
            p["up"] += max(0, up)
            p["down"] += max(0, down)
            # sing-box records destinationIP or host, not both, so a country is
            # only known for IP-dialed connections. The rest is counted as
            # "unknown" so the chart sums to the real total.
            c = dest_country or "unknown"
            self._countries[c] = self._countries.get(c, 0) + up + down
            if RESEARCH and port:
                k = (site, str(port), network or "tcp")
                self._ports[k] = self._ports.get(k, 0) + up + down

    def maybe_roll(self, now=None):
        """Fold the finished bucket into the exposed counters. Idempotent."""
        bucket = int((time.time() if now is None else now) // BUCKET_SECONDS)
        with self.lock:
            if bucket == self._bucket:
                return False
            qualifying = [(len(self._clients.get(s, ())), s) for s in self._pending
                          if s != OTHER]
            qualifying = [(n, s) for n, s in qualifying if n >= MIN_CLIENTS]
            qualifying.sort(reverse=True)
            named = {s for _, s in qualifying[:TOP_N]}

            for site, p in self._pending.items():
                key = site if site in named else OTHER
                cur = self.sites.setdefault(key, {"up": 0, "down": 0})
                cur["up"] += p["up"]
                cur["down"] += p["down"]
            for c, n in self._countries.items():
                self.countries[c] = self.countries.get(c, 0) + n
            for k, n in self._ports.items():
                if k[0] in named:
                    self.ports[k] = self.ports.get(k, 0) + n

            self._clients.clear()
            self._pending.clear()
            self._countries.clear()
            self._ports.clear()
            self._bucket = bucket
            return True

    def render(self):
        if not ENABLED:
            return []
        out = []
        with self.lock:
            sites, countries, ports = dict(self.sites), dict(self.countries), dict(self.ports)
        if sites:
            out.append("# HELP moav_site_traffic_bytes_total Bytes relayed per destination site")
            out.append("# TYPE moav_site_traffic_bytes_total counter")
            for site, v in sorted(sites.items()):
                for direction in ("up", "down"):
                    out.append('moav_site_traffic_bytes_total{site="%s",direction="%s"} %d'
                               % (site, direction, v[direction]))
        if countries:
            out.append("# HELP moav_site_destination_country_bytes_total Bytes relayed per destination country")
            out.append("# TYPE moav_site_destination_country_bytes_total counter")
            for c, n in sorted(countries.items()):
                out.append('moav_site_destination_country_bytes_total{country="%s"} %d' % (c, n))
        if ports:
            out.append("# HELP moav_site_port_bytes_total Bytes relayed per destination port")
            out.append("# TYPE moav_site_port_bytes_total counter")
            for (site, port, network), n in sorted(ports.items()):
                out.append('moav_site_port_bytes_total{site="%s",port="%s",network="%s"} %d'
                           % (site, port, network, n))
        return out
