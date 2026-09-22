# MoaV contrib

Optional, self-contained tools contributed by operators. **Nothing here is part
of the core MoaV stack:** these are not started by `moav`, not built by `moav
build`, and not wired into `docker-compose.yml`. They are opt-in, and you set up
the ones you want yourself.

## What's here

| Tool | What it does | How to run |
|---|---|---|
| [conduit-monitor](conduit-monitor/) | Health-checks a native Conduit CLI station and restarts it if it is down or stuck | host schedule (systemd timer / cron / LaunchAgent) |
| [rotate-log](rotate-log/) | Weekly rotation for an append-only log that never rotates itself | host cron (or a scheduled container) |

Each tool has its own README covering what it does, its configuration (all via
environment variables, documented at the top of the script), and a **How to
run** section with copy-pasteable setup.

## How to run: the two common shapes

Optional tools tend to be one of two shapes. Pick the one that fits and document
it in the tool's own README.

### A) Long-running daemon or metrics exporter → run it as a container

A tool that scrapes a MoaV service and re-exposes something (a Prometheus
exporter, a sidecar) drops cleanly onto the monitoring network. Mount the script
read-only into a stock base image (match the image to the script's language) and
point it at the service by its compose name on `moav_moav_net`:

```bash
docker run -d --name <tool> --restart unless-stopped \
  --network moav_moav_net \
  -e SOME_METRICS_URL=http://psiphon-conduit:9090/metrics \
  -v /opt/moav/contrib/<tool>/<script>:/app/<script>:ro \
  python:3-alpine python /app/<script>
```

If it exposes metrics for Prometheus, add a scrape job (a single-file mount
needs a `docker restart moav-prometheus` to pick up the change, not just a HUP):

```yaml
# configs/monitoring/prometheus.yml
  - job_name: '<tool>'
    static_configs:
      - targets: ['<tool>:9201']
```

### B) Periodic host task → run it on a schedule

A tool that acts on the host (rotate a file, manage a native service, bounce an
interface) runs as a scheduled host job, not a container: a **systemd timer** or
**cron** on Linux, a **LaunchAgent** or **cron** on macOS. Each such tool's
README gives a ready-to-paste example.

## Adding a tool

Contributions welcome. To keep `contrib/` consistent:

- One directory per tool, `contrib/<tool>/`, containing the script(s) and a `README.md`.
- Configure via **environment variables** with sane defaults, documented in a comment block at the top of the script. Don't hardcode paths, hosts, or machine-specific values.
- The README covers: why it exists, what it does, its configuration, and a **How to run** section (shape A or B above).
- Shell scripts must pass CI: `bash -n` and `shellcheck --severity=error` clean.
- Add a row to the table at the top of this file.
