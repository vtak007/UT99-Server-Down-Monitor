# CLAUDE.md — UT99 Server Down Monitor

Project rules on top of the global `~/.claude/CLAUDE.md` and the shared `UT99\CLAUDE.md`. Orientation (module
map, wiring, data stores) is in `Workspace Map.md`; usage is in `Readme.md`; history and conventions are in `MEMORY.md`.

## Key Files

| File | Purpose |
|---|---|
| `UT99-Monitor.ps1` | The watchdog loop run by the scheduled task |
| `Get-DowntimeReport.ps1` | Ticket-ready downtime summary from the CSV |
| `Setup.ps1` | Prompts for Pushover keys → `config.ini`, test push, registers the scheduled task |
| `src\UT99Monitor.psm1` | Module loader; dot-sources every `src\*.ps1` |
| `src\StateMachine.ps1` | Debounce, UNKNOWN blind windows, BLIP events — the core logic |
| `src\Notifier.ps1` | What to send and when: escalation, reminders, quiet hours, digest, retries |
| `src\Evidence.ps1` | CSV, raw poll log, `monitor.log`, gap inference, pruning |
| `config.template` | Tracked settings template (no secrets) |
| `config.ini` | Live settings + Pushover keys — untracked, never read or print the key values |
| `data\` | Evidence and runtime state — untracked, append-only |
| `tests\*.Tests.ps1` | Pester suite, one file per `src` file plus the three scripts |
| `docs\superpowers\specs\2026-11-08-ut99-server-down-monitor-design.md` | Design (binding requirements) |
| `docs\superpowers\plans\2026-11-23-ut99-server-down-monitor.md` | Implementation plan |
| `open-items.md` | Open items and outstanding git actions |

## Working rules

- **The scheduled task runs the scripts straight from this working tree.** Switching branches or saving an edit
  changes the live monitor's code at its next start. Commit first, then restart the monitor deliberately
  (`Stop-ScheduledTask` / `Start-ScheduledTask 'UT99 Server Down Monitor'`). Never leave the tree on an
  untested branch.
- **A running monitor does not reload `config.ini`.** Restart it after any config change or Setup run.
- **The secrets hook blocks the assistant from writing any `.ini` file.** That's why the template is
  `config.template`. Tests create their `.ini` files at run time in Pester's `TestDrive`.
- **Never edit `data\state-changes.csv` by hand.** It is the evidence file and is append-only.
- **Run the tests** before every commit: `Invoke-Pester -Path tests -CI`. Several tests start a child
  `pwsh` and use a private mutex name, so they are safe to run while the live monitor is running.
- The probe logic and the state machine must stay injectable (`-Probe`, `-Transport`, `-Now`). Real outages
  can't be manufactured for testing.
