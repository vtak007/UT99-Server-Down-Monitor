# MEMORY.md — UT99 Server Down Monitor

Persistent project memory. Read at the start of every session.

## CONFIRMED ROOT CAUSES

- *(The cause of the server's recent unexplained outages is unknown — gathering the data
  to establish it is the purpose of this project. Nothing confirmed yet.)*

## RULED-OUT THEORIES

- *(none yet)*

## PROJECT CONVENTIONS

- **Target server:** `74.91.119.21`, game port `7777`, GameSpy query port `7778`.
  Hostname reported by the server: `FullMetalJacket Deathmatch (Ping Compensation - IG+)`.
  Running UT99 v469 (gamever `469`, revision `f - Sep 24 2026 Preview`).
- **Verified 2026-11-08:** UDP `\status\` to 7778 replies (738 bytes / 61 ms, terminated by
  `\final\`); ICMP echo to the IP succeeds (~40 ms). Both probe types are viable.
- **Multi-packet responses:** with players connected, a `\status\` reply spans several UDP
  datagrams and only the last carries `\final\`. Any reader must accumulate until `\final\`
  or timeout, else it reports false failures under load.
- **`queryid` counter (2026-11-23):** rises by 1 per query (29→30→31 at ~14:00) and had
  reset to 15 by ~14:30 on map DM-Codex. Reset cause (map change vs restart) not yet known.
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
- **Unobservable time is never counted as uptime.** `LINK_DOWN`, `UNKNOWN` (monitor blind)
  and `MONITOR_GAP` (monitor not running) are all excluded from the uptime denominator and
  reported separately. The evidence file's value is that NFO cannot wave it away.
- **Pre-commit:** verify the doc-update gate in the global `CLAUDE.md` (Readme/CLAUDE.md
  updates come only after the user has tested and approved, as the last step before merge)
  and update this file with new findings.
- Repo is private; work on feature branches, never directly on `main`.

## CHANGE LOG

- 2026-11-23 — GameSpy `\status\` probe with out-of-order multi-packet reassembly committed.
- 2026-11-23 — Implementation plan written (BLIP rows + `qid` logging added); scaffolding,
  `config.template` and config loader (`Read-MonitorConfig`) committed.
- 2026-11-08 — Project created. Design document approved route chosen: PowerShell watchdog
  on the always-on home PC + Pushover push notifications, with four-state classification
  (UP / GAME_DOWN / HOST_DOWN / LINK_DOWN) and a downtime CSV as evidence for NFOservers.
  Git repo initialised, branch `feature/initial-monitor`.
