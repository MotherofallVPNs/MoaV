# Running session-high-exporter.py as a Windows service

Untested against a real Windows machine as of writing this — written from
NSSM's well-established, standard documentation, same confidence level the
systemd unit had *before* it got verified under real Linux. Test this for
real the first time it's actually needed, the same way the Linux version
was verified before being trusted.

`session-high-exporter.py` itself needs no changes — it's plain Python
standard library, already cross-platform. Only the "run this persistently
as a background service" part is OS-specific.

## Option A: NSSM (recommended — closest match to launchd/systemd behavior)

NSSM ("the Non-Sucking Service Manager") wraps an arbitrary executable as
a real Windows Service: proper start/stop via `services.msc` or
`sc`/`net`, automatic restart on crash, stdout/stderr redirected to a log
file. This is the same kind of persistent-background-service behavior
`KeepAlive`/`Restart=always` give on Mac/Linux.

1. Download NSSM from https://nssm.cc/download (a small, standalone
   `.exe`, no installer) and place `nssm.exe` somewhere on PATH, e.g.
   `C:\Tools\nssm.exe`.
2. Confirm Python 3 is installed and on PATH (`python --version`).
3. Run `install-windows-service.ps1` (below) as Administrator — it wraps
   the `nssm install`/`nssm set` calls needed to register and configure
   the service.
4. Verify: `Get-Service session-high-exporter` should show `Running`.
   `curl http://127.0.0.1:9201/metrics` should return the two gauges.

To uninstall later: `nssm remove session-high-exporter confirm`.

### install-windows-service.ps1

```powershell
# Run as Administrator. Adjust $PythonExe/$ScriptPath if needed.
$ServiceName = "session-high-exporter"
$PythonExe   = (Get-Command python).Source
$ScriptPath  = "$PSScriptRoot\session-high-exporter.py"
$StateFile   = "$env:ProgramData\ConduitCLI\session-high-state.json"
$LogDir      = "$env:ProgramData\ConduitCLI\logs"

New-Item -ItemType Directory -Force -Path (Split-Path $StateFile) | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

nssm install $ServiceName $PythonExe $ScriptPath
nssm set $ServiceName AppDirectory (Split-Path $ScriptPath)
nssm set $ServiceName AppStdout "$LogDir\session-high-exporter.log"
nssm set $ServiceName AppStderr "$LogDir\session-high-exporter.log"
nssm set $ServiceName AppRotateFiles 1
nssm set $ServiceName AppRotateBytes 10485760   # 10 MB, matches conduit.log rotation elsewhere in this project
nssm set $ServiceName AppEnvironmentExtra "SESSION_HIGH_STATE_FILE=$StateFile"
nssm set $ServiceName Start SERVICE_AUTO_START
# Matches Restart=always / KeepAlive=true on the other two platforms:
nssm set $ServiceName AppExit Default Restart
nssm set $ServiceName AppRestartDelay 5000      # 5s, matches RestartSec=5 in the systemd unit

nssm start $ServiceName
Write-Host "Installed and started '$ServiceName'. Check with: Get-Service $ServiceName"
```

If Conduit's own metrics endpoint isn't on the default `127.0.0.1:9090`,
add before `nssm start`:
```powershell
nssm set $ServiceName AppEnvironmentExtra "SESSION_HIGH_STATE_FILE=$StateFile`nCONDUIT_METRICS_URL=http://127.0.0.1:9090/metrics"
```
(NSSM's `AppEnvironmentExtra` takes one `KEY=VALUE` pair per line,
separated by `` `n `` in PowerShell string literals.)

## Option B: Task Scheduler (no third-party tool, weaker restart semantics)

If avoiding a third-party binary matters more than clean service
semantics: a Scheduled Task triggered "At log on" or "At startup",
running `pythonw.exe session-high-exporter.py`, with "Restart if the
task fails" configured (Task Scheduler supports up to a fixed retry
count/interval, not true indefinite `Restart=always`). Simpler to set
up via the Task Scheduler GUI, but less robust than a real service if
the machine is meant to run unattended for long stretches — for a
station meant to stay up continuously (the same reason Conduit itself
runs via a real service, not a login script), NSSM is the better fit.

## Not yet done

- Real verification on an actual Windows machine (this doc is written
  from NSSM's documented behavior, not tested the way the systemd path
  was tested under Colima).
- Confirming Python's `http.server`/`urllib` behave identically on
  Windows (expected to, since neither uses anything POSIX-specific, but
  "expected to" isn't "verified" — same caveat as above).
