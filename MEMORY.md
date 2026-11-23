# MEMORY.md — UT99 Server Down Monitor

Persistent project memory. Read at the start of every session.

## CONFIRMED ROOT CAUSES

- *(The cause of the server's recent unexplained outages is unknown — gathering the data
  to establish it is the purpose of this project. Nothing confirmed yet.)*

## RULED-OUT THEORIES

- *(none yet about the outages.)*
- Implementation: Task Scheduler's restart-on-failure is not relied on — it is widely reported not to relaunch on a
  non-zero exit code (not tested here). The 5-minute repeating trigger (`IgnoreNew`) is the relaunch mechanism;
  verified live 2026-11-23: task stopped 15:26:59, relaunched by the trigger 15:30:01.

## PROJECT CONVENTIONS

- **Target server:** `74.91.119.21`, game port `7777`, GameSpy query port `7778`.
  Hostname reported by the server: `FullMetalJacket Deathmatch (Ping Compensation - IG+)`.
  Running UT99 v469 (gamever `469`, revision `f - Sep 24 2026 Preview`).
- **Verified 2026-11-08:** UDP `\status\` to 7778 replies (738 bytes / 61 ms, terminated by
  `\final\`); ICMP echo to the IP succeeds (~40 ms). Both probe types are viable.
- **Multi-packet responses:** with players connected, a `\status\` reply spans several UDP
  datagrams and only the last carries `\final\`. Any reader must accumulate until `\final\`
  or timeout, else it reports false failures under load.
- **`queryid` counter (2026-11-23):** counts every query from anyone (master servers, browsers),
  not just ours — 57→68→72 between our 30 s polls. Our consecutive queries gave 29→30→31 at ~14:00;
  it had reset to 15 by ~14:30 on map DM-Codex. Reset cause (map change vs restart) not yet known.
- **Secrets:** Pushover user key and app token live in `config.ini`, untracked. The global
  `core.excludesFile` (`~/.gitignore_global`) excludes `*.ini` — verified in
  effect 2026-11-08. The key-free template is `config.template` (not `config.example.ini`: the
  secrets hook blocks the assistant from writing any `.ini`, so the tracked template avoids the
  extension — decided 2026-11-23). Never handle the key values directly; the user enters them via `Setup.ps1`.
- **Data files** (`data\state-changes.csv`, `data\raw\*.log`) are git-ignored. Dropbox
  provides off-PC durability; committing per-30-second-growth files would ruin the repo.
- **Quiet hours 01:00–09:00 are a hard user constraint** — suppress notifications, never
  suppress probing or logging.
- **Run as `<PC>\<admin>`, never SYSTEM.** Dropbox's sync client is per-user, so files
  written by SYSTEM to the Dropbox folder may never replicate off the PC, silently voiding
  the off-site backup of the evidence. A logon trigger is safe here because autologon is
  enabled (verified 2026-11-08), so the PC signs itself in unattended after a reboot.
- **Digest priority when blind (user decision 2026-11-23):** if the home link is down at 09:00 during an
  outage, the digest stays at normal priority — the server is unobserved, not observed-down.
- **Unobservable time is never counted as uptime.** `LINK_DOWN`, `UNKNOWN` (monitor blind)
  and `MONITOR_GAP` (monitor not running) are all excluded from the uptime denominator and
  reported separately. The evidence file's value is that NFO cannot wave it away.
- **Pre-commit:** verify the doc-update gate in the global `CLAUDE.md` (Readme/CLAUDE.md
  updates come only after the user has tested and approved, as the last step before merge)
  and update this file with new findings.
- **Repo is public:** `vtak007/UT99-Server-Down-Monitor` (published 2026-11-23). Before publishing, history was
  rewritten with `git filter-repo` to remove the PC/account names and autologon registry details; keep them out
  of every committed file. Work on feature branches, never directly on `main`.
- **The scheduled task runs straight from the working tree**, so a branch switch or an edit changes the live
  monitor at its next start. Commit, then restart deliberately.
- **A running monitor never reloads `config.ini`.** Found 2026-11-23: Setup was run twice (15:09, 15:15); the
  5-minute trigger had already started the monitor at 15:10 with the first run's keys, so its "monitor started"
  push went to a destination that wasn't the admin's phone. Fixed by restarting the task. After any Setup run or
  config edit, restart the task.
- **Second admin (decided 2026-11-23, reversing the design's sole-recipient non-goal):** via a Pushover
  Delivery Group — the group key replaces the User Key in `config.ini`; no code change. Any member's
  acknowledgement stops an emergency for everyone; quiet hours are shared.

## CHANGE LOG

- 2026-11-23 — Live outage test passed (UT99 stopped via NFO): GAME_DOWN 16:09:02, emergency sent 16:10:02,
  UP 16:11:32, receipt cancelled + recovery sent 16:12:32 ("was down 2m").
- 2026-11-23 — History scrubbed of PC/account names and autologon details (all hashes changed); published as
  public repo `vtak007/UT99-Server-Down-Monitor`; `feature/initial-monitor` merged as `main` and deleted.
- 2026-11-23 — Live: monitor running as a scheduled task (admin account, Interactive); startup push received on the phone;
  kill/relaunch and MONITOR_GAP inference verified. Docs written: `Readme.md`, `CLAUDE.md`, `Workspace Map.md`.
- 2026-11-23 — Final-review fixes committed (blind-window escalation, CSV tail repair, cancel retry, receipt persistence, row queue, 5-min watchdog trigger).
- 2026-11-23 — Setup.ps1 committed (hidden key prompts → config.ini, test push, logon task as current user).
- 2026-11-23 — UT99-Monitor.ps1 main loop committed (mutex, drift-free cadence, cycle error isolation, MONITOR_STOPPED on exit).
- 2026-11-23 — Notifier committed: emergency→ack→15-min reminders, expiry hand-off, cancel at quiet start, digest, pending retry.
- 2026-11-23 — Pushover transport committed (send/receipt/cancel, retryable mapping, secrets redacted from errors).
- 2026-11-23 — 09:00 digest committed: built from CSV, persisted sent-state, 3 h grace, priority 2 if still down.
- 2026-11-23 — Interval/outage maths and Get-DowntimeReport.ps1 committed (BLIPs listed, Method paragraph, exclusions stated).
- 2026-11-23 — Quiet-hours window logic committed (crosses midnight; per-bound local conversion for DST).
- 2026-11-23 — Evidence files committed: append-only CSV with lock retry, raw poll log (with qid), MONITOR_GAP inference, 12-month pruning.
- 2026-11-23 — State machine committed: 3-cycle debounce, UNKNOWN blind intervals, class changes, BLIP events.
- 2026-11-23 — Ping probe and per-cycle classification (UP/GAME_DOWN/HOST_DOWN/LINK_DOWN) committed.
- 2026-11-23 — GameSpy `\status\` probe with out-of-order multi-packet reassembly committed.
- 2026-11-23 — Implementation plan written (BLIP rows + `qid` logging added); scaffolding,
  `config.template` and config loader (`Read-MonitorConfig`) committed.
- 2026-11-08 — Project created. Design document approved route chosen: PowerShell watchdog
  on the always-on home PC + Pushover push notifications, with four-state classification
  (UP / GAME_DOWN / HOST_DOWN / LINK_DOWN) and a downtime CSV as evidence for NFOservers.
  Git repo initialised, branch `feature/initial-monitor`.
