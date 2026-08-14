"""Aggregate destination stats that cannot be linked back to a client.

Off unless ENABLE_SITE_ANALYTICS=true. See MotherofallVPNs/MoaV#297.

Guarantees, all enforced here rather than downstream:
  * no client identifier is ever returned, in any label
  * a site is named only after MIN_CLIENTS distinct clients have reached it
  * everything below that threshold accumulates under "other"
  * exposed counters advance on a bucket boundary, not per poll
"""
import hashlib
import json
import os
import threading
import time
import urllib.parse
import urllib.request

ENABLED = os.environ.get("ENABLE_SITE_ANALYTICS", "false").lower() == "true"
RESEARCH = os.environ.get("ENABLE_SITE_ANALYTICS_RESEARCH", "false").lower() == "true"
MIN_CLIENTS = int(os.environ.get("SITE_ANALYTICS_MIN_CLIENTS", "5"))
TOP_N = int(os.environ.get("SITE_ANALYTICS_TOP_N", "50"))
BUCKET_SECONDS = int(os.environ.get("SITE_ANALYTICS_BUCKET_SECONDS", "3600"))
# Aggregates survive a restart here. Only post-threshold totals are written;
# the in-flight client digests never are.
STATE_PATH = os.environ.get("SITE_ANALYTICS_STATE", "/var/lib/moav-exporter-state/sitestats.json")

OTHER = "other"

# New DNS answers fetched per bucket roll. Answers are cached for the life of
# the process, so this only bites on the first bucket.
RESOLVE_BUDGET = 25
RESOLVE_ATTEMPTS = 3
RESOLVE_TIMEOUT = 2.0


def make_resolver(clash_api, secret_fn, geoip_lookup):
    """site -> country, via sing-box's own resolver.

    sing-box already resolved these names to carry the traffic, so /dns/query
    is answered from its cache. Nothing is sent anywhere the proxied traffic
    did not already go, and the lookup is per site, never per client.
    """
    def resolve(site):
        url = "%s/dns/query?name=%s&type=A" % (clash_api.rstrip("/"),
                                               urllib.parse.quote(site))
        req = urllib.request.Request(url,
                                     headers={"Authorization": "Bearer " + secret_fn()})
        with urllib.request.urlopen(req, timeout=RESOLVE_TIMEOUT) as r:
            answers = json.load(r).get("Answer") or []
        for a in answers:
            if a.get("type") == 1 and a.get("data"):     # 1 = A record
                return geoip_lookup(a["data"])
        return ""
    return resolve

# Suffixes needing three labels to reach the registrable name. Not the full
# public suffix list: this only has to be right for common hosts, and a wrong
# guess folds too much together rather than too little.
#
# Hosting suffixes (github.io, cloudfront.net, workers.dev) are deliberately
# absent. The public suffix list has them because each subdomain is separately
# owned -- which is exactly why adding them here would name individual tenants.
# Folding them to the platform is both safer and the more useful answer.
_TWO_PART = {
    # Iran
    "co.ir", "ac.ir", "org.ir", "net.ir", "gov.ir", "id.ir", "sch.ir",
    # Russia, ex-USSR
    "com.ru", "net.ru", "org.ru", "pp.ru", "int.ru", "ac.ru", "edu.ru",
    "gov.ru", "msk.ru", "spb.ru", "com.su", "net.su", "org.su",
    "com.ua", "net.ua", "org.ua", "in.ua", "kiev.ua", "com.by", "gov.by",
    "com.kz", "org.kz", "net.kz", "edu.kz", "gov.kz", "com.uz", "co.uz",
    "com.kg", "com.tj", "com.tm", "com.am", "com.ge", "com.az",
    # China, Hong Kong, Taiwan
    "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "ac.cn", "mil.cn",
    "com.hk", "net.hk", "org.hk", "edu.hk", "gov.hk", "idv.hk",
    "com.tw", "net.tw", "org.tw", "edu.tw", "gov.tw", "idv.tw",
    # Israel
    "co.il", "net.il", "org.il", "ac.il", "gov.il", "k12.il", "muni.il",
    # United States. State codes matter because .us delegates by locality;
    # k12/cc/lib sit a level deeper and fold up to the state, which is fine.
    "ak.us", "al.us", "ar.us", "az.us", "ca.us", "co.us", "ct.us", "dc.us",
    "de.us", "fl.us", "ga.us", "hi.us", "ia.us", "id.us", "il.us", "in.us",
    "ks.us", "ky.us", "la.us", "ma.us", "md.us", "me.us", "mi.us", "mn.us",
    "mo.us", "ms.us", "mt.us", "nc.us", "nd.us", "ne.us", "nh.us", "nj.us",
    "nm.us", "nv.us", "ny.us", "oh.us", "ok.us", "or.us", "pa.us", "ri.us",
    "sc.us", "sd.us", "tn.us", "tx.us", "ut.us", "va.us", "vt.us", "wa.us",
    "wi.us", "wv.us", "wy.us", "fed.us", "isa.us", "nsn.us",
    # United Kingdom
    "co.uk", "org.uk", "ac.uk", "gov.uk", "net.uk", "sch.uk", "ltd.uk",
    "plc.uk", "me.uk", "nhs.uk", "police.uk", "mod.uk",
    # Europe
    "com.tr", "net.tr", "org.tr", "gov.tr", "edu.tr", "k12.tr", "bel.tr",
    "web.tr", "gen.tr", "av.tr", "com.pl", "net.pl", "org.pl", "edu.pl",
    "gov.pl", "waw.pl", "com.es", "org.es", "nom.es", "gob.es", "edu.es",
    "com.pt", "net.pt", "org.pt", "edu.pt", "gov.pt", "com.gr", "net.gr",
    "org.gr", "edu.gr", "gov.gr", "gov.it", "edu.it", "com.ro", "com.hr",
    "com.rs", "co.rs", "org.rs", "edu.rs", "ac.rs", "gov.rs", "com.cy",
    "ac.cy", "gov.cy", "net.cy", "org.cy", "com.mt", "org.mt", "net.mt",
    "com.ee", "com.lv", "com.mk", "com.ba", "co.no", "priv.no",
    # Middle East, North Africa
    "com.sa", "net.sa", "org.sa", "gov.sa", "edu.sa", "com.ae", "net.ae",
    "org.ae", "gov.ae", "ac.ae", "com.qa", "net.qa", "org.qa", "gov.qa",
    "edu.qa", "com.kw", "com.bh", "com.om", "com.jo", "com.lb", "com.ye",
    "com.iq", "net.iq", "org.iq", "gov.iq", "edu.iq", "com.sy", "gov.sy",
    "com.eg", "net.eg", "org.eg", "gov.eg", "edu.eg", "com.ly", "com.tn",
    "com.dz", "co.ma", "net.ma", "org.ma", "gov.ma", "com.af", "com.pk",
    "net.pk", "org.pk", "edu.pk", "gov.pk",
    # South and Southeast Asia
    "co.in", "net.in", "org.in", "gen.in", "firm.in", "ind.in", "ac.in",
    "edu.in", "gov.in", "nic.in", "res.in", "com.bd", "net.bd", "org.bd",
    "edu.bd", "gov.bd", "ac.bd", "com.lk", "net.lk", "org.lk", "edu.lk",
    "gov.lk", "ac.lk", "com.np", "com.mm", "com.kh", "com.sg", "net.sg",
    "org.sg", "edu.sg", "gov.sg", "per.sg", "com.my", "net.my", "org.my",
    "edu.my", "gov.my", "com.vn", "net.vn", "org.vn", "edu.vn", "gov.vn",
    "co.th", "in.th", "ac.th", "go.th", "or.th", "net.th", "co.id", "or.id",
    "ac.id", "web.id", "my.id", "sch.id", "go.id", "com.ph", "net.ph",
    "org.ph", "edu.ph", "gov.ph",
    # East Asia
    "co.jp", "ne.jp", "or.jp", "ac.jp", "ad.jp", "go.jp", "ed.jp", "gr.jp",
    "lg.jp", "co.kr", "ne.kr", "or.kr", "re.kr", "pe.kr", "go.kr", "ac.kr",
    "hs.kr", "ms.kr", "es.kr", "sc.kr", "kg.kr", "mil.kr",
    # Oceania
    "com.au", "net.au", "org.au", "edu.au", "gov.au", "asn.au", "id.au",
    "co.nz", "net.nz", "org.nz", "govt.nz", "ac.nz", "geek.nz", "school.nz",
    # Africa
    "co.za", "org.za", "net.za", "gov.za", "ac.za", "web.za", "com.ng",
    "net.ng", "org.ng", "edu.ng", "gov.ng", "com.gh", "co.ke", "or.ke",
    "ac.ke", "go.ke", "co.tz", "ac.tz", "go.tz", "co.ug", "ac.ug",
    "com.et", "com.zm", "co.mz", "com.ci", "com.sn", "com.cm",
    # Latin America
    "com.br", "net.br", "org.br", "gov.br", "edu.br", "art.br", "blog.br",
    "com.mx", "org.mx", "net.mx", "edu.mx", "gob.mx", "com.ar", "net.ar",
    "org.ar", "gob.ar", "edu.ar", "int.ar", "mil.ar", "tur.ar", "com.co",
    "net.co", "org.co", "edu.co", "gov.co", "com.pe", "net.pe", "org.pe",
    "edu.pe", "gob.pe", "com.ve", "net.ve", "org.ve", "edu.ve", "gob.ve",
    "com.ec", "net.ec", "org.ec", "edu.ec", "gob.ec", "com.uy", "net.uy",
    "org.uy", "edu.uy", "gub.uy", "com.bo", "com.py", "com.do", "com.gt",
    "com.pa", "com.sv", "com.ni", "co.cr", "ac.cr", "go.cr", "com.cu",
    "com.hn", "com.pr", "com.jm", "com.tt", "com.bz",
    # Canada uses provincial codes only rarely; the common ones are enough.
    "ab.ca", "bc.ca", "on.ca", "qc.ca", "gc.ca",
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
    def __init__(self, now=None, resolver=None):
        self.lock = threading.Lock()
        self._bucket = int((time.time() if now is None else now) // BUCKET_SECONDS)
        self._clients = {}        # site -> set of salted client digests
        self._pending = {}        # site -> {"up": n, "down": n}
        self._countries = {}      # destination country -> pending bytes
        self._unlocated = {}      # site -> pending bytes with no country yet
        self._conns = {}          # site -> connections opened this bucket
        self._ports = {}          # (site, port, network) -> pending bytes, research only
        self._resolver = resolver  # site -> country code; see resolve_country()
        # A folded name is often not a host: cdninstagram.com and gvt1.com have
        # no A record, only their subdomains do. Resolve something real instead.
        self._host_sample = {}    # site -> one hostname seen this bucket
        self._resolve_fail = {}   # site -> attempts, so a miss is retried
        self._site_country = {}   # resolved, cached for the life of the process
        self.sites = {}           # exposed cumulative counters
        self.countries = {}
        self.ports = {}
        self.conns = {}
        self.clients = {}         # distinct clients in the last closed bucket
        self._rolled = False      # nothing is exposed before the first bucket closes
        self.folded = 0           # sites that missed the threshold last bucket
        self.folded_max = 0       # and the largest client count among them
        self._load()

    def record(self, client, host, up, down, dest_country="", port="", network="",
               new_conn=False):
        """One connection's delta. `client` never leaves this object."""
        if not ENABLED or (up <= 0 and down <= 0):
            return
        # A bare IP has no site to name, but its bytes still belong in the
        # total, so it lands in "other" rather than being dropped.
        site = registrable(host) or OTHER
        with self.lock:
            self._clients.setdefault(site, set()).add(_client_key(client))
            if site != OTHER and host and host != site:
                self._host_sample.setdefault(site, host)
            if new_conn:
                self._conns[site] = self._conns.get(site, 0) + 1
            p = self._pending.setdefault(site, {"up": 0, "down": 0})
            p["up"] += max(0, up)
            p["down"] += max(0, down)
            if dest_country:
                self._countries[dest_country] = self._countries.get(dest_country, 0) + up + down
            else:
                # sing-box reports destinationIP or host, never both, so most
                # connections arrive with no country. Held per site and located
                # at roll time; see _locate().
                self._unlocated[site] = self._unlocated.get(site, 0) + up + down
            if RESEARCH and port:
                k = (site, str(port), network or "tcp")
                self._ports[k] = self._ports.get(k, 0) + up + down

    def _load(self):
        if not ENABLED:
            return
        try:
            with open(STATE_PATH) as fh:
                d = json.load(fh)
        except Exception:
            return
        self.sites = {k: v for k, v in (d.get("sites") or {}).items()}
        self.countries = d.get("countries") or {}
        self.conns = d.get("conns") or {}
        self.clients = d.get("clients") or {}
        self._site_country = {k: v for k, v in (d.get("site_country") or {}).items() if v}
        self.folded = d.get("folded") or 0
        self.folded_max = d.get("folded_max") or 0
        self._rolled = True
        self.ports = {tuple(k.split("\x1f")): v for k, v in (d.get("ports") or {}).items()}

    def _save(self):
        """Aggregates only. self._clients holds per-client digests and is excluded."""
        if not ENABLED:
            return
        d = {"sites": self.sites, "countries": self.countries, "conns": self.conns,
             "clients": self.clients, "site_country": self._site_country,
             "folded": self.folded, "folded_max": self.folded_max,
             "ports": {"\x1f".join(k): v for k, v in self.ports.items()}}
        try:
            os.makedirs(os.path.dirname(STATE_PATH), exist_ok=True)
            tmp = STATE_PATH + ".tmp"
            with open(tmp, "w") as fh:
                json.dump(d, fh)
            os.replace(tmp, STATE_PATH)
        except Exception:
            pass                   # metrics are not worth crashing the exporter

    def _locate(self, named, samples):
        """Country for each named site, resolving at most RESOLVE_BUDGET new ones.

        Only sites that cleared the k threshold are looked up, so the set of
        names resolved here is already non-identifying. Called without the lock.
        """
        if self._resolver is None:
            return
        budget = RESOLVE_BUDGET
        for site in named:
            if site in self._site_country or site == OTHER:
                continue
            if self._resolve_fail.get(site, 0) >= RESOLVE_ATTEMPTS:
                continue
            if budget <= 0:
                break
            budget -= 1
            country = ""
            try:
                country = self._resolver(samples.get(site, site)) or ""
            except Exception:
                country = ""
            # Only positives are cached. A miss stays retryable, because caching
            # it meant one bad answer marked a site unknown for ever.
            if country:
                self._site_country[site] = country
                self._resolve_fail.pop(site, None)
            else:
                self._resolve_fail[site] = self._resolve_fail.get(site, 0) + 1

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
            pending, countries = self._pending, self._countries
            unlocated, ports, conns = self._unlocated, self._ports, self._conns
            samples = dict(self._host_sample)
            # Only named sites get a client count, and they cleared the
            # threshold, so the number describes a crowd rather than a person.
            clients = {s: len(self._clients.get(s, ())) for s in named}
            # How much the threshold is costing, so k can be tuned on evidence
            # rather than guessed. Counts only -- no site is named.
            below = [len(self._clients.get(s, ())) for s in self._pending
                     if s != OTHER and s not in named]
            folded, folded_max = len(below), (max(below) if below else 0)
            self._clients = {}
            self._pending, self._countries = {}, {}
            self._unlocated, self._ports, self._conns = {}, {}, {}
            self._host_sample = {}
            self._bucket = bucket

        # Outside the lock: a cold DNS answer must not stall recording.
        self._locate(named, samples)

        with self.lock:
            for site, p in pending.items():
                key = site if site in named else OTHER
                cur = self.sites.setdefault(key, {"up": 0, "down": 0})
                cur["up"] += p["up"]
                cur["down"] += p["down"]
            for c, n in countries.items():
                self.countries[c] = self.countries.get(c, 0) + n
            for site, n in unlocated.items():
                c = self._site_country.get(site, "") if site in named else ""
                self.countries[c or "unknown"] = self.countries.get(c or "unknown", 0) + n
            for k, n in ports.items():
                if k[0] in named:
                    self.ports[k] = self.ports.get(k, 0) + n
            for site, n in conns.items():
                key = site if site in named else OTHER
                self.conns[key] = self.conns.get(key, 0) + n
            self.clients = clients
            self.folded, self.folded_max = folded, folded_max
            self._rolled = True
        self._save()
        return True

    def render(self):
        if not ENABLED:
            return []
        out = []
        with self.lock:
            sites, countries, ports = dict(self.sites), dict(self.countries), dict(self.ports)
            conns, clients = dict(self.conns), dict(self.clients)
            folded, folded_max = self.folded, self.folded_max
            rolled = self._rolled
        if sites:
            out.append("# HELP moav_site_traffic_bytes_total Bytes relayed per destination site")
            out.append("# TYPE moav_site_traffic_bytes_total counter")
            for site, v in sorted(sites.items()):
                for direction in ("up", "down"):
                    out.append('moav_site_traffic_bytes_total{site="%s",direction="%s"} %d'
                               % (site, direction, v[direction]))
        if conns:
            out.append("# HELP moav_site_connections_total Connections opened per destination site")
            out.append("# TYPE moav_site_connections_total counter")
            for site, n in sorted(conns.items()):
                out.append('moav_site_connections_total{site="%s"} %d' % (site, n))
        if clients:
            out.append("# HELP moav_site_clients Distinct clients that reached the site in the last hour")
            out.append("# TYPE moav_site_clients gauge")
            for site, n in sorted(clients.items()):
                out.append('moav_site_clients{site="%s"} %d' % (site, n))
        if rolled:
            out.append("# HELP moav_site_folded_sites Sites that missed the client threshold and went to 'other'")
            out.append("# TYPE moav_site_folded_sites gauge")
            out.append("moav_site_folded_sites %d" % folded)
            out.append("# HELP moav_site_folded_clients_max Largest client count among the folded sites")
            out.append("# TYPE moav_site_folded_clients_max gauge")
            out.append("moav_site_folded_clients_max %d" % folded_max)
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
