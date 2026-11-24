# UT99 Server Down Monitor — Open Items

## Status

| #    | Item                                          | Status                                                |
| ---- | --------------------------------------------- | ----------------------------------------------------- |
| 1    | Both-phones check after the group is set up   | Blocked — waiting on #3                               |
| 2    | First 09:00 digest                            | Open — due 2026-11-24 09:00                           |
| 3    | Second admin via Pushover Delivery Group      | Blocked — waiting on the other admin's Pushover setup |
| 4    | Digest priority while an outage is unobserved | Accepted — normal priority (your decision 2026-11-23) |
| 5    | Cause of the server's unexplained outages     | Open — needs monitor data                             |
| 6    | `RESTART_DETECTED` from GameSpy `queryid`     | Blocked — needs poll-log data on `queryid` resets     |
| 7–12 | Deferred minor review findings                | Accepted for now                                      |
| 13   | No spurious "monitor started" notices         | Open — watching since 2026-11-23 22:25                |

## VERIFY

2. Tomorrow at 09:00: the digest arrives ("UT99 overnight: all quiet" unless something happened).

## WATCH

13. Headless launch: no "UT99 monitor started" push except after a reboot, a logon or a deliberate restart, and
    no new `MONITOR_GAP` rows in the CSV.

## DECIDE

None.

## BLOCKED

1. Once the group is live (#3), repeat the outage test: both phones get `UT99 CRASHED (VPS up)`, and one
   acknowledgement stops the alert on both. (The single-phone test passed 2026-11-23: alert 60 s after the first
   failed check, recovery 60 s after the first good one.)
3. Second admin: waiting for him to confirm he has the Pushover app and an account, and to send you his User Key. You create a Delivery Group with both keys,
   re-run `.\Setup.ps1` with the group key as the User Key, then restart the monitor.
5. Root cause of the recent unexplained outages — unknown until the monitor has gathered evidence.
6. `RESTART_DETECTED` row: `qid` counts every query from anyone and reset at least once on 2026-11-23. Once the
   poll log shows whether it resets on a map change, a reset with no map change can mark a restart too fast for
   any probe to fail.

## ACCEPTED

4. If the home internet is down at 09:00 while an outage was in progress, the digest goes at normal priority:
   the server is unobserved, not observed-down.
7. An outage followed by a home-internet gap at the end of a report period shows its end as the gap start.
8. The digest can read "Now: MONITOR_STARTED" just after a restart.
9. A locked poll log at startup makes the monitor exit; the 5-minute trigger relaunches it.
10. A failed down alert still pending when the outage changes class is retried with the old title.
11. Stop/gap rows absorb up to 2 unconfirmed failing cycles (not yet stated in the report's Method section).
12. A report period that spans a DST change shows a single UTC offset.

## Git Actions Outstanding

None.
