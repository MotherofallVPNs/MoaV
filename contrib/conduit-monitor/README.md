# conduit-monitor

A periodic health-check-and-repair script for a Conduit CLI station, for
macOS and Linux. Runs every 15-30 minutes via a scheduled job, notices if
Conduit has stopped running or gotten stuck, and fixes the specific
failure modes it knows how to fix — anything else, it logs and notifies
about rather than guessing.

## Why this exists

A Conduit CLI station is usually unattended for long stretches. Two
failure modes are common enough to be worth automating around:

- The service stops running (a crash, a `launchctl bootout`/`systemctl
  stop`, anything that leaves it down) and doesn't come back on its own.
- Conduit is technically running but stuck — connected to nothing, or
  cycling through failed connection attempts without ever landing one.
  `conduit_idle_seconds` alone doesn't catch every shape of this (a proxy
  that's actively failing, not idle, can show near-zero idle time while
  still being fully broken), so this script checks both.

Two design choices come directly from a real incident, not speculation:

**An inconclusive check must default to "assume fine," not "assume the
worst."** This script optionally supports stopping Conduit if it detects
you've roamed onto a network that isn't your own (a privacy feature for
laptop-based stations — donating a stranger's bandwidth isn't the point).
The check that decides this depends on an external network lookup. If that
lookup ever fails — a DNS hiccup, a routing blip, the lookup service being
briefly down — treating the failure as "confirmed away from home" and
stopping Conduit is exactly backwards: it turns a transient, unrelated
network problem into an extended outage, because the same failing lookup
then also blocks the script from ever starting it back up. This script
treats a failed lookup as inconclusive and takes no action, while still
logging the failure so it's visible.

**A repair path shouldn't depend on the thing it's repairing.** An earlier
version of the interface-repair logic here (macOS only, see below) was
only reachable through a check that itself required a working IP address
to run — meaning the one scenario that most needed the repair (no IP at
all) could never actually trigger it. The no-usable-IPv4 check in this
version has no prerequisites beyond the interface being powered on.

**A safety check should fail closed, not guess.** `networksetup
-setairportpower` doesn't validate that the interface name it's given is
actually a WiFi device — given an unrecognized name, it silently falls
back to controlling whatever WiFi interface *does* exist on the system,
rather than erroring. Found live while testing a sibling script's
identical code path: a misconfigured interface name toggled the real WiFi
connection instead of failing loudly. This script now confirms
`NETWORK_INTERFACE` actually matches the system's real Wi-Fi hardware port
(via `networksetup -listallhardwareports`) before ever touching airport
power, and refuses to act — logging it as an anomaly instead — if it
doesn't match.

## What it does

Every run:
1. **macOS only**: if configured, bounces a network interface that has no
   usable IPv4 address at all (not even a self-assigned link-local) and
   restarts Conduit. Not available on Linux — see "Platform differences"
   below for why.
2. If configured, checks whether this machine's public IP matches a
   configured "home" prefix; stops Conduit if not, starts it if so. Both
   sides of this are opt-in — skipped entirely unless you set
   `HOME_PUBLIC_IP_PREFIX`. Works on both platforms.
3. Starts Conduit if it isn't running.
4. Detects a stuck/stale proxy (idle too long, or connected=0 with recent
   errors) and restarts it, with a cooldown to avoid restart loops.
5. Optionally calls out to a log-rotation helper you provide.
6. Logs every check, and sends one consolidated notification per run if
   anything happened — not one per finding.

Everything it can't fix (not connected to the broker at all, a stale
public-IP lookup, a stuck proxy that was already restarted too recently to
restart again) gets logged and pushed as a notification instead of
silently ignored.

## How to run

conduit-monitor is for a machine running a **native Conduit CLI station** (the
service is managed by `launchctl` on macOS or `systemctl` on Linux). Run it
every 15-30 minutes from a scheduled job so it survives closed terminals and
sleep. Configure it with the environment variables documented at the top of
`conduit-monitor.sh`; set only what differs from the defaults.

> **Running the dockerized MoaV server?** You don't need this. `psiphon-conduit`
> is a container with `restart: unless-stopped`, so Docker already restarts it on
> crash. This tool restarts a *host* Conduit service and (on macOS) repairs host
> network interfaces, neither of which applies to the container.

### Linux — systemd timer (recommended)

`/etc/systemd/system/conduit-monitor.service`:
```ini
[Unit]
Description=Conduit health check + known-fix autopilot
After=network-online.target

[Service]
Type=oneshot
Environment=CONDUIT_SERVICE_LABEL=conduit
Environment=NTFY_TOPIC_FILE=%h/.conduit-ntfy-topic
ExecStart=/opt/moav/contrib/conduit-monitor/conduit-monitor.sh
```

`/etc/systemd/system/conduit-monitor.timer`:
```ini
[Unit]
Description=Run conduit-monitor every 15 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now conduit-monitor.timer
systemctl list-timers conduit-monitor.timer   # confirm it is scheduled
```

### Linux / macOS — cron

```bash
# crontab -e  (every 15 minutes)
*/15 * * * * CONDUIT_SERVICE_LABEL=conduit /opt/moav/contrib/conduit-monitor/conduit-monitor.sh >> "$HOME/conduit-monitor.log" 2>&1
```

### macOS — LaunchAgent

`~/Library/LaunchAgents/sh.moav.conduit-monitor.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>sh.moav.conduit-monitor</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>/opt/moav/contrib/conduit-monitor/conduit-monitor.sh</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>NETWORK_INTERFACE</key><string>en0</string>
  </dict>
  <key>StartInterval</key><integer>900</integer>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
```
```bash
launchctl load ~/Library/LaunchAgents/sh.moav.conduit-monitor.plist
```

See the top of `conduit-monitor.sh` for the full list of environment variables
and their defaults.

## Platform differences

The core logic — checking Conduit's own metrics, deciding whether it's
down or stuck — is identical on both platforms. Only the actual
start/stop/restart/notify commands differ (macOS: `launchctl`; Linux:
`systemctl`), branched once via `uname` near the top of the script.

**The network-interface repair feature is macOS-only, on purpose, not
because it wasn't gotten to.** It was tested for real against a genuine
Linux environment (see "How this was tested" below) and found to be
genuinely fragmented across distros in a way the macOS version isn't:
which mechanism actually re-acquires a DHCP lease after a link is brought
back up — NetworkManager, `dhclient`, `dhcpcd`, `systemd-networkd`, or
sometimes nothing at all — varies by distro and by how that particular
machine is configured, and there's no single command that reliably works
everywhere the way `networksetup` does on macOS. Shipping something that
silently does the wrong thing (or nothing) on someone's specific setup
seemed worse than not including it. It's also arguably more of a
laptop/roaming-station concern than a typical fixed-location Linux
deployment (a server, a Raspberry Pi on a stable wired connection) would
actually need.

## How this was tested

The macOS path has been running in production on a real station for an
extended period, including through a real multi-hour outage that led
directly to two of the fixes described above.

The Linux path was tested for real, not just written from documentation —
against a genuine `systemd`-based environment running in Docker via
[Colima](https://github.com/abiosoft/colima) on macOS (a real Linux VM,
not just a container-in-name-only): a custom Debian image with `systemd`,
`systemd-sysv`, and `network-manager` actually installed, run with
`--privileged --cgroupns=host` so `systemd` genuinely manages services
inside it. Both restart paths were verified against a real dummy
`systemd` service: stopping it and confirming the script detects the
failure and runs `systemctl start`, and separately simulating a stuck
proxy (via a fake metrics endpoint reporting elevated `conduit_idle_seconds`)
against an already-running service and confirming the script correctly
runs `systemctl restart` instead.

This is a real `systemd` environment, not a mock, so the `systemctl`
commands behave as expected — but a privileged `systemd`-in-Docker VM can
still differ from a bare-metal or VM Linux install in edge cases. If you
deploy this on Linux, keep an eye on the log the first few runs rather than
assuming it's flawless from a container test alone.

## What it needs

Nothing beyond what the OS already ships with, plus optionally:
- macOS: [terminal-notifier](https://github.com/julienXX/terminal-notifier)
  (falls back to `osascript` if not present).
- Linux: `notify-send`, if you want a local desktop notification — most
  headless servers won't have this, which is fine, it's skipped silently
  if absent.
- Either platform: an [ntfy.sh](https://ntfy.sh) topic if you want push
  notifications to a phone — this is the more reliable channel on a
  headless Linux server specifically, since there's often no local
  notification system to fall back on there at all.

Configuration is entirely via environment variables — see the comment
block at the top of the script for the full list and defaults. Nothing is
hardcoded to any particular machine, router, or network.

## What this isn't

This isn't a full station-management suite — it doesn't touch router
configuration and doesn't manage anything beyond Conduit itself. It's
deliberately narrow: notice Conduit is down or stuck, and get it running
again, correctly, without guessing at problems it doesn't actually
understand.
