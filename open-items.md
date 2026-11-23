# UT99 Server Down Monitor — Open Items

## Status

| #    | Item                                          | Status                                           |
| ---- | --------------------------------------------- | ------------------------------------------------ |
| 1    | Run `Setup.ps1` and the live checks           | Ready — waiting on you to run `.\Setup.ps1`      |
| 2    | Task restarts a killed/crashed monitor        | Ready — verify during the live checks            |
| 3    | Digest priority while an outage is unobserved | Waiting on your approval                         |
| 4    | Cause of the server's unexplained outages     | Open — needs monitor data                        |
| 5    | `RESTART_DETECTED` from GameSpy `queryid`     | Blocked — needs poll-log data on `queryid` reset |
| 6–11 | Deferred minor review findings                | Accepted for now                                 |
| 12   | Docs, merge and push                          | Waiting on your test sign-off                    |

## VERIFY

1. Run `.\Setup.ps1` (enter the Pushover keys; test push arrives; task registered; "monitor started" push). Then
   the plan's Task 12 Step 7 checks: CSV gets `MONITOR_STARTED`/`UP`, poll log grows every 30 s, task principal is
   admin, `Get-DowntimeReport.ps1` prints, the 09:00 digest arrives next morning.
2. Kill the monitor's `pwsh` process: it should be relaunched within ~5 min (the repeating trigger), the CSV shows
   `MONITOR_GAP` then `MONITOR_STARTED`, and a startup push mentions the gap.

## WATCH

None.

## DECIDE

3. If your home internet is down at 09:00 while an outage was in progress, the digest currently goes at normal
   priority (the server is unobserved, not observed-down). Keep that, or send it at emergency priority?

## BLOCKED

4. Root cause of the recent unexplained outages — unknown until the monitor has gathered evidence.
5. `RESTART_DETECTED` row: `queryid` rose by one per query (29→30→31 at ~14:00 on 2026-11-23) and had reset to 15
   by ~14:30. Once the poll log (`qid=`) shows whether it resets on map change, a reset with no map change can mark a
   restart too fast for any probe to fail.

## ACCEPTED

6. An outage followed by a home-internet gap at the end of a report period shows its end as the gap start.
7. The digest can read "Now: MONITOR_STARTED" just after a restart.
8. A locked poll log at startup makes the monitor exit; the 5-minute trigger relaunches it.
9. A failed down alert still pending when the outage changes class is retried with the old title.
10. Stop/gap rows absorb up to 2 unconfirmed failing cycles (not yet stated in the report's Method section).
11. A report period that spans a DST change shows a single UTC offset.

## Git Actions Outstanding

12. After your live test: approve `Readme.md` + `CLAUDE.md` (with a Key Files table) and the design-doc status line,
    then merge `feature/initial-monitor` to `main` (no `main` branch exists yet; it will be created) and push.
