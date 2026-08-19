# session-high-exporter

A tiny Prometheus exporter that maintains a *true* running maximum of a
Conduit station's connected/connecting client counts since the current
process started ("session high").

## Why this exists

The obvious way to show "highest value this session" in Grafana is a
PromQL query like `max_over_time(conduit_connected_clients[72h])`. That
works, but has two real costs:

1. **Accuracy at wide time ranges.** Prometheus caps any single query at
   11,000 samples per series. Over many days, that forces a coarser
   sampling interval than the metric's actual scrape rate, which can
   silently under-count a brief spike between samples.
2. **Repeated cost.** Every dashboard refresh re-runs the *entire*
   historical scan from scratch — even on a 5-second refresh, where 99%+
   of a 7-day window is identical to 5 seconds ago. Neither Prometheus
   nor Grafana caches or incrementally extends this by default.

This exporter sidesteps both: it polls Conduit's own `/metrics` on the
same cadence Prometheus already scrapes at, updates an in-memory running
maximum only when a new value beats the record, and serves that single
number. A running max updated on every real sample is mathematically
identical to the true max — no sampling loss, and querying it costs
nothing (one gauge, no historical scan) regardless of refresh rate or how
long the session has run.

**Trade-off**: it can't backfill. It only starts tracking from whenever
it's first started, not retroactively from earlier history.

## What it needs

Nothing beyond Python 3's standard library — no dependencies to install.
Reads Conduit's own `/metrics` endpoint (must expose
`conduit_connected_clients`, `conduit_connecting_clients`, and the
standard Go `process_start_time_seconds`, all present by default), writes
a small JSON state file so its own restarts don't lose the record, and
serves the two derived gauges on its own `/metrics` endpoint for
Prometheus to scrape.

Configuration is via environment variables (all optional):

| Variable | Default |
|---|---|
| `CONDUIT_METRICS_URL` | `http://127.0.0.1:9090/metrics` |
| `SESSION_HIGH_STATE_FILE` | `~/.session-high-state.json` |
| `SESSION_HIGH_LISTEN_HOST` | `127.0.0.1` |
| `SESSION_HIGH_LISTEN_PORT` | `9201` |
| `SESSION_HIGH_POLL_INTERVAL` | `15` (seconds) |

## Running it persistently

- **Linux**: `session-high-exporter.service` (systemd unit, included) —
  verified under a real systemd container (Debian + Docker/Colima):
  starts correctly, persists state across its own restarts via a
  `DynamicUser`-sandboxed `StateDirectory`, correctly tracks a rising
  max, and correctly resets when Conduit's own `process_start_time`
  changes (i.e. when Conduit itself restarts).
- **macOS**: `com.conduit.session-high-exporter.plist.template` (LaunchAgent
  template, included) — fill in the real paths, `launchctl bootstrap
  gui/$(id -u) <path>`.
- **Windows**: see `windows-service-setup.md` (NSSM-based, included) —
  written from NSSM's documented behavior, not yet verified against a
  real Windows machine.

## Wiring it into Prometheus + Grafana

Add a scrape target for wherever it's listening (default `127.0.0.1:9201`):

```yaml
  - job_name: 'session_high'
    static_configs:
      - targets: ['127.0.0.1:9201']
```

Then point a Stat panel's query at `conduit_session_high_connected_clients`
/ `conduit_session_high_connecting_clients` directly — no PromQL
aggregation needed, it's already the final number.

If this exporter isn't deployed, a panel querying these metrics will show
"No data" rather than erroring — deploying it is optional, the rest of
the dashboard doesn't depend on it.
