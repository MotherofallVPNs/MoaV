# dns-router

A tiny UDP DNS forwarder that lets **three DNS tunnels share port 53 at once**,
with no conflict, by routing each query to a backend based on its domain suffix.

## Why parallel DNS tunnels don't conflict

A DNS tunnel works by NS-delegating a subdomain to this server. Each tunnel
gets its **own** subdomain, so the recursive resolver sends a tunnel's traffic
to us only for that subdomain. `dns-router` listens once on `:5353` (mapped to
host `:53`), reads the QNAME from each query, and forwards it to the backend
whose configured suffix matches:

```
            ┌─ *.t.example.com  ─→ dnstt      :5353
:53/udp ──► │─ *.s.example.com  ─→ slipstream :5354
 (router)   └─ *.m.example.com  ─→ masterdns  :5355
```

Routing is a **pure function of the query's domain suffix** (`findBackend` →
`matchDomainSuffix`). The three subdomains (`t.`, `s.`, `m.`) are disjoint by
construction, so a query can never be ambiguous and can never be misrouted.
There is no shared mutable state between tunnels and no port overlap — the
backends listen on distinct internal ports and only the router binds 53.
Anything that matches no route is dropped.

## The three tunnels (defaults)

| Tunnel     | Subdomain | Backend           | Enabled by default |
|------------|-----------|-------------------|--------------------|
| dnstt      | `t`       | `dnstt:5353`      | yes                |
| Slipstream | `s`       | `slipstream:5354` | yes                |
| MasterDNS  | `m`       | `masterdns:5355`  | yes                |

Each is gated by `ENABLE_DNSTT` / `ENABLE_SLIPSTREAM` / `ENABLE_MASTERDNS`
(all default `true`) and needs its own NS record (`*_SUBDOMAIN`). XDNS is the
exception: it needs sole ownership of port 53 and is enabled *instead* via
`moav switch-dns xdns`.

## Tests

```
cd dns-router && go test ./... -v
```

`main_test.go` proves the no-conflict property: subdomain isolation across all
three backends, packet-name parsing, suffix matching, and `buildRoutes()`
wiring. Pure stdlib, no external dependencies.
