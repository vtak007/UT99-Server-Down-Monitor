# UT99 Server Down Monitor — Open Items

## Status

| #   | Item                                         | Status                                           |
| --- | -------------------------------------------- | ------------------------------------------------ |
| 1   | Build the watchdog                           | In progress — plan approved 2026-11-23, native   |
| 2   | Cause of the server's unexplained outages    | Open — needs monitor data                        |
| 3   | `RESTART_DETECTED` from GameSpy `queryid`    | Blocked — needs poll-log data on `queryid` reset |
| 4   | Branch `feature/initial-monitor`             | Open — implementation commits pending            |

## VERIFY

None.

## WATCH

None.

## DECIDE

None.

## BLOCKED

1. Build the watchdog per `docs/superpowers/plans/2026-11-23-ut99-server-down-monitor.md` (12 tasks; BLIP rows and
   `qid` in the poll log added at your request).
2. Root cause of the recent unexplained outages — unknown until the monitor has gathered evidence.
3. `RESTART_DETECTED` row: the server's `queryid` counter rose by one per query on 2026-11-23 (29→30→31; was 92 on
   2026-11-08). Once the poll log shows whether it also resets on a map change, a reset with no map change can mark a
   restart too fast for any probe to fail.

## ACCEPTED

None.

## Git Actions Outstanding

4. Commit each task on `feature/initial-monitor`; after your live test and docs approval, merge to `main` and push.
