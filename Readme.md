# UT99 Server Down Monitor

A watchdog for the FullMetalJacket UT99 Deathmatch server (`74.91.119.21:7777`, NFOservers VPS). It runs on
the always-on home PC, sends a Pushover push to the admins' phones within about two minutes of an outage, and
keeps a downtime record that can be handed to NFOservers as evidence.

## How it works

Every 30 seconds the monitor:

1. Sends a GameSpy `\status\` query to UDP port 7778. A complete reply (all packets, up to `\final\`) means **UP**.
2. If that fails, pings the VPS. A reply means UT99 is not answering but the machine is: **GAME_DOWN**.
3. If the VPS doesn't answer either, pings `1.1.1.1` and `8.8.8.8`. If either answers, the home internet is
   fine and the VPS/network is unreachable: **HOST_DOWN**. If neither answers, the home internet is down:
   **LINK_DOWN**. The server can't be observed, so that period is recorded as **UNKNOWN** and never counted as
   up or down.

An outage is declared after **3 failing cycles in a row** (about 90 s) and recovery after **3 successes in a
row**. One or two failed cycles followed by a success are recorded as a **BLIP** (possibly a quick restart). A
blip is not counted as downtime and sends no alert.

## Notifications

| Event | Priority | Notes |
|---|---|---|
| `UT99 CRASHED (VPS up)` / `VPS/NETWORK DOWN` | Emergency | Repeats every 5 min until someone taps **Acknowledge** |
| `UT99 still down — 30m` | High | Every 15 min after acknowledgement (or after 3 h unacknowledged) |
| `NOW: …` | Emergency or high | The outage changed type (e.g. crashed → VPS down) |
| `Server UP — was down 1h 12m` | Normal | Cancels any emergency alert still repeating |
| `UT99 monitor started` | Normal | Every start, with any unobserved gap since the last run |
| 09:00 digest | Normal (emergency if still down) | Every day, even quiet nights: outages, blips and unobserved time overnight |

**Quiet hours, 01:00–09:00:** nothing is sent, and any emergency alert still repeating is cancelled at 01:00.
Probing and logging carry on unchanged, and the 09:00 digest reports the night. If the daily digest stops
arriving, the monitor (or the PC) has stopped.

## Setup

1. Run `.\Setup.ps1` in PowerShell 7 from the project folder. It asks for the Pushover **User Key** and
   **App Token** (input hidden; press Enter to keep an existing value), writes `config.ini`, sends a test
   notification, and registers the scheduled task **UT99 Server Down Monitor**. The task runs as you at logon,
   with a hidden window, and every 5 minutes as a watchdog that relaunches a dead monitor.
2. Answer **Y** to start it now.

**After changing `config.ini` or re-running Setup, restart the monitor.** The running copy keeps its old
settings until then:

```powershell
Stop-ScheduledTask 'UT99 Server Down Monitor'; Start-ScheduledTask 'UT99 Server Down Monitor'
```

Other settings (interval, thresholds, quiet hours, sounds, retention) are documented in `config.template`.

### Notifying more than one admin

1. Each admin installs the Pushover app and creates an account. Collect their **User Keys**.
2. On pushover.net, create a **Delivery Group** containing everyone's user key.
3. Re-run `.\Setup.ps1`. Paste the **group key** as the User Key and press Enter to keep the App Token.
4. Restart the monitor (above).

Everyone in the group gets every message. The first person to acknowledge an emergency alert stops it for all.
Quiet hours apply to everyone.

## Evidence and reports

| File | Contents |
|---|---|
| `data\state-changes.csv` | One row per state change, append-only, with local and UTC timestamps: the evidence |
| `data\raw\poll-YYYY-MM.log` | One line per 30 s cycle: which probes ran, results, latency, map, players, query counter. Kept 12 months |
| `data\monitor.log` | The monitor's own events: starts, sends, send failures, errors |

The monitor's own downtime is recorded too: `MONITOR_STARTED`, `MONITOR_STOPPED`, and `MONITOR_GAP` when it
died without a clean stop. Unobserved time is never counted as uptime.

For a ticket-ready summary:

```powershell
.\Get-DowntimeReport.ps1                                   # current month to now
.\Get-DowntimeReport.ps1 -From 2026-11-01 -To 2026-12-01 -OutFile report.txt
```

The report gives uptime over **observed** time, states every excluded period (home internet down, monitor not
running), lists each outage with its type, and lists brief interruptions. It ends with a Method section that
explains how start and end times are measured.

## Tests

```powershell
Invoke-Pester -Path tests -Output Detailed
```

Requires Pester 5 or later (`Install-Module Pester -Scope CurrentUser -MinimumVersion 5`).
