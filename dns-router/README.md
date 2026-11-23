# dns-router

A tiny UDP DNS forwarder that lets **all the DNS tunnels share port 53 at
once**, with no conflict, by routing each query to a backend based on its
domain suffix.

## Why parallel DNS tunnels don't conflict

A DNS tunnel works by NS-delegating a subdomain to this server. Each tunnel
gets its **own** subdomain, so the recursive resolver sends a tunnel's traffic
to us only for that subdomain. `dns-router` listens once on `:5353` (mapped to
host `:53`), reads the QNAME from each query, and forwards it to the backend
whose configured suffix matches:

```
            ┌─ *.t.example.com  ─→ dnstt        :5353
:53/udp ──► │─ *.m.example.com  ─→ masterdns    :5355
 (router)   └─ *.x.example.com  ─→ xray (XDNS)   :5355
```

(MasterDNS and XDNS both listen on internal port `5355`, but in **separate
containers** — `masterdns` vs `xray` — so there's no collision.)

Routing is a **pure function of the query's domain suffix** (`findBackend` →
`matchDomainSuffix`). The subdomains (`t.`, `m.`, `x.`) are disjoint
by construction, so a query can never be ambiguous and can never be misrouted.
There is no shared mutable state between tunnels and no port overlap — the
backends listen on distinct container endpoints and only the router binds 53.
Anything that matches no route is dropped.

## The tunnels (defaults)

| Tunnel     | Subdomain | Backend           | Enabled by default |
|------------|-----------|-------------------|--------------------|
| dnstt      | `t`       | `dnstt:5353`      | yes                |
| MasterDNS  | `m`       | `masterdns:5355`  | yes                |
| XDNS       | `x`       | `xray:5355`       | yes                |

Each is gated by its own flag (`ENABLE_DNSTT` / `ENABLE_MASTERDNS` /
`ENABLE_XDNS`, all default `true`) and needs its own NS record
(`*_SUBDOMAIN`). All of them run **simultaneously** through this router —
there is no mutual exclusion. `moav switch-dns` just toggles which tunnels are
enabled; it does not pick a single owner of port 53. (Earlier versions ran XDNS
directly on host port 53, mutually exclusive with the dns-router group — that
model is retired.)

### Slipstream (removed) and the reserved slot

Slipstream (`s.` → `slipstream:5354`) was removed from the router on
2026-11-23: its upstream (slipstream-rust) is archived, and MasterDNS plus
dnstt cover the same use case. `ENABLE_SLIPSTREAM=true` left over in an old
`.env` is ignored here (the router logs a warning) and queries for the `s.`
subdomain are dropped. `buildRoutes()` keeps a commented placeholder where a
future DNS-tunnel backend can plug in with the same shape as the others: an
`ENABLE_*` gate, a `*_DOMAIN`, an overridable `*_BACKEND`, and a subdomain
that does not overlap any existing route.

## Tests

```
cd dns-router && go test ./... -v
```

`main_test.go` proves the no-conflict property: subdomain isolation across all
backends, packet-name parsing, suffix matching, and `buildRoutes()` wiring
(all-on → 3 routes, XDNS-off → 2 routes, and a leftover
`ENABLE_SLIPSTREAM=true` adding no route and causing no error). Pure
stdlib, no external dependencies.
