# log-metrics-exporter

A tiny Prometheus exporter that turns notable text patterns in
`conduit.log` into real, graphable metrics — no dependencies beyond
Python 3's standard library.

## Why this exists

Conduit logs things like a broker "limited" backoff response, an
ICE-negotiation timeout, or a "no match" result as plain text lines. On
their own, that's only visible by grepping the log after the fact. This
exporter tails `conduit.log` incrementally (a byte-offset cursor, same
approach used elsewhere for log rotation handling) and counts a small,
fixed set of patterns, so they can be graphed on the same timeline as
Connected/Connecting/Announcing:

| Metric label | Matches |
|---|---|
| `limited` | Broker rate/entry-limit backoff response |
| `ice_timeout` | `context deadline exceeded` (ICE negotiation timing out) |
| `no_match` | Broker "no match" response |
| `broker_reset` | `connection reset by peer` on the broker connection |

All four are exposed as a single counter, `conduit_log_events_total`,
labeled by `type`.

**Trade-off**: like any log-tailing approach, it only sees what's in
`conduit.log` from whenever it starts — no backfill from before that.

## What it needs

Nothing to install. Reads `conduit.log` from wherever Conduit is
writing it, and serves the derived counter on its own `/metrics`
endpoint for Prometheus to scrape.

Configuration is via environment variables (all optional):

| Variable | Default |
|---|---|
| `CONDUIT_LOG_PATH` | `~/conduit.log` |
| `LOG_METRICS_OFFSET_FILE` | `~/.log-metrics-offset` |
| `LOG_METRICS_LISTEN_HOST` | `127.0.0.1` |
| `LOG_METRICS_LISTEN_PORT` | `9200` |
| `LOG_METRICS_POLL_INTERVAL` | `10` (seconds) |

## Wiring it into Prometheus + Grafana

Add a scrape target for wherever it's listening (default `127.0.0.1:9200`):

```yaml
  - job_name: 'log_events'
    static_configs:
      - targets: ['127.0.0.1:9200']
```

The dashboard's Log Event Rate panel queries
`increase(conduit_log_events_total[1h])` by `type` directly.

If this exporter isn't deployed, that panel will show "No data" rather
than erroring — deploying it is optional, the rest of the dashboard
doesn't depend on it.

## Note on router-side log metrics

An earlier version of this exporter also parsed a home router's own
event log for DoS/filter events (`router_log_events_total` in some
dashboard revisions). That part is tied to one specific router's log
format and isn't something that generalizes to other operators' setups,
so it's deliberately left out of this contribution. If your dashboard
still references `router_log_events_total`, that panel will simply show
"No data" unless you build an equivalent exporter for your own router.
