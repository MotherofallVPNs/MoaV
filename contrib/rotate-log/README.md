# rotate-log.sh

A small, generic weekly log rotation script for any append-mode log file
that never rotates on its own — for macOS and Linux.

## Why this exists

If you run Conduit CLI with `-v` (verbose logging), you probably need to —
error-level messages are gated behind that same flag, not just debug
noise, so verbose logging is closer to required than optional for
meaningful diagnostics. But verbose logging on a busy station means the
log file grows fast: gigabytes within days is normal, not a sign anything
is wrong. Conduit doesn't rotate its own log, so left alone it grows
without bound.

## What it does

```
rotate-log.sh <log_path> <archive_prefix>
```

Checks whether the newest existing archive for that prefix is at least 7
days old (or doesn't exist yet). If so: copies the log to
`<same_dir>/log_archive/<prefix>_<timestamp>.log`, truncates the live file
in place (not a rename — a rename would break whatever process still has
the original file open in append mode, requiring a restart; truncating in
place is transparent to an already-running writer), then **synchronously**
gzips the copy and verifies the resulting archive with `gzip -t` before
declaring success. If gzip fails or produces a corrupt archive, the raw
copy is left in place rather than silently lost.

Meant to be called periodically from your own health-check loop or cron
job — it manages its own weekly cadence internally, so calling it more
often than that is a harmless no-op.

## How to run

Run it on a schedule, or let another script call it (conduit-monitor invokes it
via `ROTATE_LOG_SCRIPT`). It self-limits to one rotation per 7 days, so running
it daily is fine.

### Linux / macOS — cron (simplest)

```bash
# crontab -e  (daily; the script self-limits to a weekly rotation)
0 4 * * * /opt/moav/contrib/rotate-log/rotate-log.sh /var/log/conduit/conduit.log conduit
```

### Linux — systemd timer

A `Type=oneshot` service running `rotate-log.sh <log> <prefix>`, on a timer with
`OnUnitActiveSec=1d` (same shape as conduit-monitor's timer).

### As a container (when the log lives in a Docker volume)

To rotate a log a MoaV container writes to a named volume, run it from the host
on a schedule against that volume (bash + gzip, so use a `debian` base):

```bash
# e.g. rotate the snowflake proxy log volume
docker run --rm \
  -v moav_snowflake_logs:/logs \
  -v /opt/moav/contrib/rotate-log/rotate-log.sh:/rotate-log.sh:ro \
  debian:stable-slim bash /rotate-log.sh /logs/snowflake.log snowflake
```

## A real bug this script's history is worth knowing about

An earlier version ran gzip in the background (`nohup gzip ... &`) so a
large one-time archive wouldn't block the caller. In production, this
failed silently on the largest archives — the background process got cut
off before finishing (most likely because the calling script was itself a
short-lived scheduled job, and the process manager reaped the whole job's
process group once the main script exited, taking the still-running gzip
with it) — leaving a truncated, corrupt `.gz` file sitting next to an
un-deleted multi-gigabyte raw copy. This happened twice, silently, over
several weeks, before being noticed. A real timed test showed synchronous
gzip only takes 16-17 seconds even on a ~5GB file — nowhere near enough to
justify the background/detach complexity that caused the silent failure.
Current version gzips synchronously and verifies the result; if you're
reviewing or adapting this script, the backgrounded version is a trap
worth knowing not to reintroduce.

## How this was tested

Both platforms were tested for real, end-to-end, immediately before this
README was written — not assumed from reading the code:

- **macOS**: ran directly against a real test log file, confirmed the
  archive was created, gzip-verified as valid, the live file correctly
  truncated to zero, and a second immediate run correctly no-op'd (archive
  too fresh to rotate again).
- **Linux**: same test, run inside a Debian container via
  [Colima](https://github.com/abiosoft/colima) (a real Linux VM on macOS,
  not just a container-in-name-only). This actually caught a real bug in
  the process: the archive-age check used `stat -f%m`, which is BSD/macOS-
  only syntax — Linux's `stat` needs `-c%Y` for the same value. As
  originally written, this would have silently misbehaved on Linux. Fixed
  (branches on `uname` now) and re-verified with the same end-to-end test
  described above, which passed cleanly afterward.

Nothing else in this script is platform-specific — it's plain file
operations (`cp`, truncate-in-place, `gzip`) throughout, so once that one
`stat` call was fixed, both platforms behave identically.
