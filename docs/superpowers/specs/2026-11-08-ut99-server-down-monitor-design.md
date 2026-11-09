# UT99 Server Down Monitor — Design

**Date:** 2026-11-08
**Status:** Awaiting admin approval. Builder review complete; its questions are resolved in
§9 (admin's answers) and §10 (assistant's calls).
**Branch:** `feature/initial-monitor`

---

## 1. Intent and why

The FullMetalJacket UT99 Deathmatch server (NFOservers VPS, `74.91.119.21:7777`) has
recently been going down for unknown reasons. Two concrete problems follow from that:

1. **Discovery is too slow.** Outages have been found hours after they began, by chance.
   The admin wants to know within a couple of minutes so he can either restart the server
   himself (he has remote restart capability) or raise an NFOservers help-desk ticket
   while the evidence is fresh.
2. **There is no record.** The outages have no documented pattern, so there is nothing to
   put in front of the hosting provider. The admin wants durable, defensible downtime data
   he can hand to NFO.

The existing FMJ Live Scores app can show the server state, but it only works with the
phone awake and the app in the foreground, so it cannot be the alerting mechanism.

The record is not a by-product of the alerting here — it is a first-class deliverable of
equal weight. Design choices resolve in favour of data integrity.

## 2. Goals

- Push a notification to the admin's phone, phone idle and screen off, within ~2 minutes
  of the server ceasing to respond.
- Distinguish **UT99 stopped answering** from **the whole VPS/network is gone**, because
  these are different remedies (restart vs ticket) and different conversations with NFO.
- Notify on recovery, with the outage duration.
- Record every state change durably, in a form that can be summarised into a ticket.
- Never silently lose data — including overnight, when alerts are suppressed.
- Run unattended on hardware the admin already has on 24/7.

## 3. Non-goals (v1)

Not in scope for the first version. Listed so the builder does not drift into them, and so
the admin can pull one forward deliberately:

- Automatically restarting UT99.
- A status page, badge, or widget on the live-scores site.
- Player-count history or graphing (though player count *is* captured at state changes).
- Notifying other administrators (explicitly decided: the admin is the sole recipient).
- SMS or email fallback.
- Monitoring anything other than this one server.

## 4. Anti-goals

Outcomes that would make this a failure even if it technically runs:

- **A log full of false outages.** Evidence that NFO can wave away ("that was your own
  internet") is worse than no evidence, because it costs credibility. Every recorded
  outage must be defensible.
- **Alert fatigue.** If the admin starts ignoring the notifications, the monitor has
  failed regardless of its accuracy.
- **Being woken between 01:00 and 09:00.** A hard constraint, not a preference.
- **Silent death of the monitor.** A monitor that stopped three weeks ago, leaving a
  reassuringly quiet phone, is the worst possible outcome — it converts a known unknown
  into an unknown unknown.

## 5. Constraints

- Windows 11 Pro, PowerShell primary shell. Runs on the admin's home PC, on 24/7, never
  sleeps.
- The home PC's internet is a shared failure mode with the thing being measured, and must
  be accounted for (see §6.3).
- Pushover is the notification channel, already chosen. One-off licence, already understood.
- Secrets live in a local untracked `.ini` per the house rule; the global
  `core.excludesFile` (`~/.gitignore_global`) already excludes `*.ini`,
  verified on 2026-11-08. The assistant never handles the key values.
- Repo is private, git, feature-branch workflow.

## 6. How it works

### 6.1 Verified facts about the target

Confirmed live against `74.91.119.21` on 2026-11-08, not assumed:

- A UDP `\status\` query to port **7778** returns a GameSpy key/value response terminated
  by `\final\`. Observed: 738 bytes in 61 ms, with `hostname`, `maptitle`, `mapname`,
  `gametype`, `numplayers`, `maxplayers`, `gamever\469`, `queryid\92.1`.
- ICMP echo to `74.91.119.21` succeeds (~40 ms RTT), so an ICMP probe is a valid
  VPS-liveness signal.

**Builder note:** with players connected, a `\status\` response exceeds one datagram and
arrives as several packets, of which only the last carries `\final\`. The reader must
receive in a loop, accumulating until `\final\` is seen or a timeout expires, and must
tolerate out-of-order arrival. A single-`Receive` implementation will report spurious
failures precisely when the server is busy — the worst time for a false alarm. This is the
single most likely source of bogus data in the whole system.

### 6.2 Probe cycle

Every **30 seconds**:

1. **Game probe** — UDP `\status\` to `74.91.119.21:7778`, ~3 s timeout. Success means a
   well-formed response terminated by `\final\`. On success, nothing else is probed, and
   `mapname` / `numplayers` / `maxplayers` are retained as the last-known-good snapshot.
2. If the game probe fails, **host probe** — ICMP echo to `74.91.119.21`.
3. If the host probe also fails, **link probe** — ICMP echo to two independent public
   targets (`1.1.1.1` and `8.8.8.8`). Two targets, so one provider's bad day is not
   mistaken for the admin's line being down.

Probes 2 and 3 run only when needed. The raw log records which probes actually ran.

### 6.3 Classification

The cycle resolves to exactly one state:

| State | Meaning | Remedy | Counts as server downtime? |
|---|---|---|---|
| `UP` | Game probe answered | — | No |
| `GAME_DOWN` | Game silent, VPS pings, internet fine | Restart UT99 | **Yes** |
| `HOST_DOWN` | Game silent, VPS silent, internet fine | NFO ticket | **Yes** |
| `LINK_DOWN` | The admin's own internet is unreachable | None | **No — excluded** |
| `UNKNOWN` | The monitor could not observe the server | None | **No — excluded, reported separately** |

`LINK_DOWN` is the load-bearing state. Without it, every home-internet blip becomes a
fabricated server outage, and the resulting log cannot survive contact with NFO. It is
recorded in full but excluded from downtime statistics and raises no alert — if the
admin's link is down he already knows.

`GAME_DOWN` does not distinguish a crashed process from a hung one; that cannot be
determined from outside and the remedy is the same.

**`UNKNOWN` — blind intervals.** *(Assistant's call, resolved from the §4 anti-goals.)*
When the admin's link drops, the monitor goes blind: it cannot know what the server did
during that window. If an outage was already in progress, continuing to assert downtime
through the gap would claim observations that were never made — precisely the kind of
figure NFO can dismiss, and the §4 anti-goal. Equally, ending the outage at the link
failure and starting a fresh one on return would fabricate two short outages where there
may have been one long one.

So a blind window is its own interval, neither up nor down:

- Entering `LINK_DOWN` closes whatever interval was open and opens an `UNKNOWN` interval.
- On the link's return, the next observed classification opens a new interval. If the
  server is still down, the CSV shows `GAME_DOWN` → `UNKNOWN` → `GAME_DOWN`.
- `UNKNOWN` time is excluded from both the numerator and the denominator of uptime, and
  reported as a separate "unobserved" total so the gap is visible rather than papered over.
- No recovery notification fires on leaving `UNKNOWN` unless the server is actually
  observed `UP`.

The report must state plainly that an outage was interrupted by a blind window, because a
2-hour outage recorded as two 50-minute outages either side of a 20-minute gap is a
materially different claim and the admin should not be surprised by it in front of NFO.

### 6.4 Debounce

- **3 consecutive** failing cycles before declaring a down state (~90 s).
- **3 consecutive** successful cycles before declaring recovery.

This absorbs isolated dropped UDP packets and the brief query gap around a map change. It
sets the floor on detection latency at roughly 90–120 seconds, which is within the stated
goal.

If the classification changes *while* down (e.g. `GAME_DOWN` → `HOST_DOWN`), that is a new
state change: logged, and worth a notification, because the remedy changed.

**When the three failing cycles disagree** *(assistant's call)*. A VPS reboot realistically
produces `GAME_DOWN`, `HOST_DOWN`, `GAME_DOWN` across three cycles. The rule:

- Any *observing* failure (`GAME_DOWN` or `HOST_DOWN`) increments the counter. Three
  consecutive increments declare a down state, whose classification is that of the **third,
  confirming** cycle — the most recent evidence is the most relevant to what the admin
  should do right now.
- A `LINK_DOWN` cycle is not an observation. It neither increments nor resets the counter:
  it suspends it and opens an `UNKNOWN` interval per §6.3. If observation resumes with
  further failures, the counter continues from where it paused.
- A single successful cycle resets the failure counter to zero, and vice versa.

**Timestamp convention** *(assistant's call, must be stated in the report output)*. An
outage's start is the timestamp of the **first failing cycle**, not the confirming third;
recovery is the timestamp of the **first successful cycle**. The first failure is when the
server actually stopped answering, so this is the truthful reading, but it means every
duration is up to ~90 s longer at each end than the moment the monitor *decided*. Because
this inflates durations relative to a decision-time convention, the report states the
convention explicitly rather than leaving it implicit in the code — the same treatment the
`LINK_DOWN` exclusion gets.

### 6.5 Notifications (Pushover)

| Event | Priority | Detail |
|---|---|---|
| Down detected | **2 (emergency)**, retry 300 s | Title states classification: `UT99 CRASHED (VPS up)` or `VPS/NETWORK DOWN`. Body carries time, last map, last player count. |
| Still down | 1 (high) | At 15 minutes, then every 15 minutes. |
| Recovery | 0 (normal) | `Server UP — was down 1h 12m`, with the classification it recovered from. |
| Monitor started | 0 (normal) | So a silent PC reboot is not mistaken for a quiet night. |
| 09:00 digest | 0, or 2 if still down | See §6.6. |

Distinct Pushover sounds for down vs up, so the two are tellable apart without reading.

**Escalation hand-off — confirmed by the admin 2026-11-08.** Pushover priority 2 already
retries until acknowledged, which would overlap the 15-minute still-down reminders. The
reconciliation: the priority-2 alert retries every 5 minutes until acknowledged; *once
acknowledged*, the 15-minute reminders take over at priority 1. Nagged hard until he has
seen it, reminded gently while it stays broken, never both at once.

This requires detecting the acknowledgement, which the admin has approved: the priority-2
push returns a **receipt id**, and the monitor polls Pushover's receipts endpoint (once per
minute while an unacknowledged emergency alert is outstanding, not on every 30 s cycle) to
learn when it was acknowledged. Constraints and failure handling:

- Pushover requires `retry` ≥ 30 s and `expire` ≤ 10800 s. Use `retry` 300, `expire` 10800.
- The 15-minute reminder clock starts **at acknowledgement**, not at outage start.
- If the alert is never acknowledged, Pushover stops retrying at `expire` (3 h). Treat
  expiry as an implicit hand-off: reminders begin at that point, so an unacknowledged
  outage does not decay into silence.
- If receipt polling itself fails (network, API error), fall back to treating the alert as
  unacknowledged and let the expiry hand-off cover it. A broken poll must never be able to
  cancel the escalation.
- Receipt polling stops as soon as the alert is acknowledged, expires, or the server
  recovers (recovery cancels an outstanding emergency alert via the receipt-cancel
  endpoint, so the phone stops nagging about a problem that has gone away).

### 6.6 Quiet hours — 01:00 to 09:00 local

A suppression of the *buzz*, never of the data. This is the admin's hard constraint.

- Probing, classification and logging continue entirely unchanged.
- Notifications that would fire in the window are suppressed, not sent.
- At **09:00** one digest is sent summarising the window: number of outages, their start
  times and durations, any `UNKNOWN` gaps, and the current state.
- If the server is **still down** at 09:00, the digest goes at priority 2 — it is the
  first moment the admin can usefully be shouted at.
- An outage beginning before 01:00 alerts normally; only the part of its notification
  traffic that falls inside the window is suppressed.

**The digest is derived from the CSV, not from a queue** *(assistant's call)*. The obvious
implementation holds suppressed notifications in an in-memory queue and drains it at 09:00,
but §6.9 restarts the process on failure, so a 03:00 crash would silently empty the queue
and under-report the night — the one moment this design most depends on. Instead, at 09:00
the monitor *reads back* `state-changes.csv` for the window and builds the digest from it.
The durable record is the single source of truth, the queue holds nothing that matters, and
a restart mid-window costs nothing. A monitor started *inside* the window reports only what
the CSV covers and says so, rather than implying it watched the whole night.

**The digest fires every day, including quiet nights** — confirmed by the admin
2026-11-08. An "all quiet, server up" message each morning is also a daily proof-of-life
for the monitor itself; see §6.10.

Quiet hours are configurable in the `.ini`, including crossing midnight as this one does.
DST transitions are the builder's to handle, but the window is defined in local wall-clock
time: on the two ambiguous days a window that is 7 or 9 hours long is acceptable, silently
skipping or doubling a digest is not.

### 6.7 The record

Two files, serving two different purposes.

**`data\state-changes.csv`** — the evidence. One row per state change, append-only:

`timestamp_local, timestamp_utc, new_state, previous_state, previous_duration_seconds, map, numplayers, maxplayers, notes`

UTC alongside local because the ticket may cross timezones and because local time is
ambiguous across a DST change. Append-only and never rewritten, so its integrity is not
contingent on the report generator being correct.

**The monitor's own coverage is recorded in this file too** *(assistant's call, resolved
from the §4 anti-goals).* `new_state` therefore admits three further values beyond the five
in §6.3:

| Value | Written when |
|---|---|
| `MONITOR_STARTED` | On every launch |
| `MONITOR_STOPPED` | On clean shutdown (Ctrl-C, task end, OS shutdown — best effort) |
| `MONITOR_GAP` | Inferred at startup: the previous row was not a `MONITOR_STOPPED`, so the monitor died without saying so. The gap between the last row and this launch was unobserved. |

Without these rows, a monitor that died three weeks ago leaves a CSV with no rows at all,
and the report would read that silence as a continuous `UP` and print 100% uptime for a
period nothing was watching. That is a fabricated number in the file whose entire purpose
is to be defensible. Unmonitored time is therefore first-class, visible data, excluded from
the uptime denominator exactly as `LINK_DOWN` and `UNKNOWN` are.

**`data\raw\poll-YYYY-MM.log`** — the backing detail. One line per poll cycle: timestamp,
which probes ran, their results and latencies. This is what answers "prove it" if NFO
disputes a specific outage.

Monthly files, **retained 12 months** by default and configurable *(assistant's call: the
original ~30 days contradicted the file's own purpose, since help-desk disputes routinely
run longer than a month and a 30-day prune would delete the proof for a six-week-old
argument)*. Cost is modest: roughly 2,880 lines/day at ~120 bytes is ~350 KB/day, about
125 MB/year, inside a Dropbox folder. If that footprint is unwelcome, compressing completed
months is the builder's option.

Both live in the project folder, which is inside Dropbox, so the evidence is continuously
replicated off the PC. Both are git-ignored: Dropbox already covers durability, and
committing a file that grows every 30 seconds would make the repo useless.

### 6.8 Report generator

`Get-DowntimeReport.ps1`, run on demand, reads `state-changes.csv` and emits a summary
suitable for pasting into a help-desk ticket:

- Outage count and total downtime for a period (default: current month).
- Each outage: start, end, duration, classification.
- Split of `GAME_DOWN` vs `HOST_DOWN`, since NFO is answerable for the latter.
- Uptime percentage over **observed** time, with `LINK_DOWN`, `UNKNOWN` and unmonitored
  (`MONITOR_GAP`) time excluded from the denominator, and every exclusion stated
  explicitly in the output with its total — never silently dropped. A reader must be able
  to see "observed 29d 4h of 30d; 18h unobserved" and judge the figure for themselves.
- Any outage that was interrupted by a blind window, flagged as such (§6.3).
- Longest outage, and time-of-day distribution if a pattern exists.
- The timestamp convention from §6.4, stated in the output.

The point of this script is that the summary exists at the moment it is needed, rather
than requiring spreadsheet arithmetic during an outage.

### 6.9 Operation

- A single long-running PowerShell loop, `UT99-Monitor.ps1`. State lives in memory;
  the 30-second cadence does not fit a scheduled task well.
- Runs as the admin's own account **`<PC>\<admin>`**, triggered **at logon**, configured
  to restart on failure, window hidden.

  Confirmed with the admin 2026-11-08, replacing an earlier SYSTEM-based plan that was
  wrong. Dropbox's sync client runs as the logged-on user, so files written by SYSTEM can
  land on disk **without ever being replicated** — silently removing the off-PC durability
  the evidence story depends on (§6.7). Running as the admin's account keeps sync working, and also
  inherits his proxy/network configuration for the Pushover HTTPS calls.

  A logon trigger would normally be weaker than a startup trigger, but it is not here:
  the PC is set to sign in automatically (verified 2026-11-08), so it signs itself in unattended after any reboot and the trigger fires
  without anyone present. No password is stored in Task Scheduler.

  **Residual risk, accepted:** if autologon is ever disabled, the monitor stops starting at
  boot. The daily 09:00 digest (§6.6) surfaces that within one day.
- `Setup.ps1` handles first-run: prompts the admin for his Pushover user key and app token
  and writes `config.ini`, sends a test notification, and registers the scheduled task.
  The assistant never sees or handles the key values.
- Only one instance may run at a time (mutex or pid file). Two instances would double
  every alert and interleave writes into the CSV.

### 6.10 Monitoring the monitor

Three layers, two of them in v1:

1. A **"monitor started"** notification on launch, so a silent PC reboot is not mistaken
   for a quiet night.
2. The **daily 09:00 digest, sent even on quiet nights** (§6.6). This is the substantive
   mitigation: if the monitor dies, the digest stops arriving, and the admin notices within
   a day instead of finding out weeks later. It also catches autologon being disabled
   (§6.9) and the PC being off.
3. `MONITOR_GAP` rows in the CSV (§6.7), so unobserved time is visible in the record after
   the fact rather than being quietly counted as uptime.

What remains uncovered is the narrow case of the monitor dying *and* the admin not noticing
a missing 09:00 message. Closing that needs an outside observer — a free Healthchecks.io
dead-man's-switch pinged each cycle, alerting if the pings stop. Deliberately deferred, not
forgotten; the digest reduces it from a serious hole to a refinement. The builder should
leave the per-cycle hook where that ping will go.

## 7. Files

| Path | Purpose | Tracked |
|---|---|---|
| `UT99-Monitor.ps1` | The watchdog loop | Yes |
| `Get-DowntimeReport.ps1` | Ticket-ready summary from the CSV | Yes |
| `Setup.ps1` | First-run config + scheduled-task registration | Yes |
| `config.ini` | Server, thresholds, quiet hours, Pushover keys | **No** (secrets) |
| `config.example.ini` | Documented template, no secrets | Yes (needs `!` negation in repo `.gitignore`) |
| `data\state-changes.csv` | The evidence | No |
| `data\raw\poll-YYYY-MM.log` | Backing detail | No |
| `MEMORY.md`, `CLAUDE.md`, `Readme.md` | Per house rules | Yes |

## 8. Left to the builder

- PowerShell module layout and internal function boundaries.
- The GameSpy response parser, subject to the multi-packet requirement in §6.1.
- Pushover HTTP error and rate-limit handling, and what happens to an alert that fails to
  send because the admin's own link is down. Note that §6.6's queue is gone, so there is no
  existing mechanism to borrow: a send failure must either retry with backoff or be
  reconciled from the CSV the way the digest is. The latter is probably simpler and is
  consistent with treating the CSV as the single source of truth.
- Exact digest wording and notification sounds.
- Log pruning mechanism.
- Test strategy. Note that the probe layer must be injectable/fakeable: the classification
  and debounce logic is the part most likely to be wrong and cannot be tested against a
  live server, since the interesting cases are outages that cannot be manufactured on
  demand.

## 9. Decisions recorded as the admin's

Confirmed explicitly on 2026-11-08: server `74.91.119.21`, game 7777, query 7778; real
GameSpy `\status\` probe; 30 s interval; 3 failures down / 3 successes up; priority 2 with
5-minute retry; still-down reminders at 15 minutes then every 15 minutes; normal-priority
recovery; link-failure exclusion; state-change CSV plus raw log; storage in the Dropbox
project folder; report generator; long-running loop via Task Scheduler; monitor-started
notification; secrets in untracked `.ini`; private git repo; sole recipient; quiet hours
01:00–09:00.

Confirmed in a second round on 2026-11-08, after a builder review of this document:
run as `<PC>\<admin>` triggered at logon (not SYSTEM); poll Pushover receipts to detect
acknowledgement before handing off to 15-minute reminders; send the 09:00 digest every day
including quiet nights.

## 10. Assistant's calls

Settled by the assistant, not the admin, and open to correction. Each is marked in place
above:

| § | Call |
|---|---|
| 6.3 | A link failure opens an `UNKNOWN` interval rather than continuing or splitting an in-progress outage; unobserved time is excluded and reported separately. |
| 6.4 | Mixed classifications across the three confirming cycles resolve to the third cycle's; `LINK_DOWN` suspends the counter rather than resetting it. |
| 6.4 | Outage start/end timestamps are the first failing / first successful cycle, and the convention is printed in the report. |
| 6.6 | The 09:00 digest is reconstructed from the CSV, not drained from an in-memory queue, so a restart cannot lose it. |
| 6.7 | `MONITOR_STARTED` / `MONITOR_STOPPED` / `MONITOR_GAP` rows go in the evidence CSV, and unmonitored time is excluded from the uptime denominator. |
| 6.7 | Raw-log retention raised from ~30 days to 12 months, configurable. |

Six of these answer questions raised by the builder review; the remaining three went back
to the admin and are recorded in §9.
