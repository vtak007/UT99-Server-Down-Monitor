# UT99 Server Down Monitor — Open Items

## Status

| #    | Item                                          | Status                                                |
| ---- | --------------------------------------------- | ----------------------------------------------------- |
| 1    | Real outage test (alert → ack → recovery)     | Ready — waiting on you; best after #3                 |
| 2    | First 09:00 digest                            | Open — due 2026-11-24 09:00                           |
| 3    | Second admin via Pushover Delivery Group      | Open — waiting on his User Key and your group setup   |
| 4    | Digest priority while an outage is unobserved | Accepted — normal priority (your decision 2026-11-23) |
| 5    | Cause of the server's unexplained outages     | Open — needs monitor data                             |
| 6    | `RESTART_DETECTED` from GameSpy `queryid`     | Blocked — needs poll-log data on `queryid` resets     |
| 7–12 | Deferred minor review findings                | Accepted for now                                      |

## VERIFY

1. Stop UT99 from the NFO panel for about 3 min. Expect `UT99 CRASHED (VPS up)` about 90 s after the stop,
   repeating until acknowledged, then `Server UP — was down Xm` after the restart, and `GAME_DOWN` then `UP` in
   the CSV. With a delivery group set up, check both phones, and check that one acknowledgement stops both.
2. Tomorrow at 09:00: the digest arrives ("UT99 overnight: all quiet" unless something happened).

## WATCH

None.

## DECIDE

None.

## BLOCKED

3. Second admin: he installs Pushover and sends you his User Key. You create a Delivery Group with both keys,
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
