# UT99 Server Down Monitor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A PowerShell watchdog on the home PC that probes the FMJ UT99 server every 30 s, pushes
Pushover alerts on outages (never 01:00–09:00), and keeps a defensible downtime record for NFOservers.

**Architecture:** One module `src\UT99Monitor.psm1` dot-sources small single-purpose files. Every
decision (classification, debounce, escalation, quiet hours, digest, report) is a pure function
taking an injected `-Now` and injected probes/transport, so it is testable without a live server or
Pushover. Three thin entry scripts (`UT99-Monitor.ps1`, `Get-DowntimeReport.ps1`, `Setup.ps1`) wire
the module to real sockets, HTTP and Task Scheduler.

**Tech Stack:** PowerShell 7.6 (`pwsh`), Pester 6.2 (installed CurrentUser 2026-11-23; tests use
v5-compatible syntax), .NET `UdpClient` and `Ping`, Pushover REST API, Windows Task Scheduler.

**Spec:** `docs/superpowers/specs/2026-11-08-ut99-server-down-monitor-design.md` — read it alongside
this plan; section refs (§) below point into it.

## Global Constraints

- Target `74.91.119.21`, query port `7778` (UDP `\status\`), game port `7777`.
- Cycle 30 s; game timeout 3000 ms; link targets `1.1.1.1`, `8.8.8.8`.
- Debounce 3 failures down / 3 successes up.
- Pushover emergency: priority 2, `retry` 300, `expire` 10800 (API limits: retry ≥ 30, expire ≤ 10800).
  Reminders priority 1 every 15 min from acknowledgement (or expiry). Receipt poll every 60 s.
- Quiet hours 01:00–09:00 local: suppress sends only — never probing or logging. Digest every day.
- Timestamps: local as `yyyy-MM-ddTHH:mm:sszzz`, UTC as `yyyy-MM-ddTHH:mm:ssZ`. All logic uses
  `[DateTimeOffset]`.
- CSV header exactly: `timestamp_local,timestamp_utc,new_state,previous_state,previous_duration_seconds,map,numplayers,maxplayers,notes`
- CSV `new_state` values: `UP`, `GAME_DOWN`, `HOST_DOWN`, `UNKNOWN`, `MONITOR_STARTED`,
  `MONITOR_STOPPED`, `MONITOR_GAP`, `BLIP`. A `LINK_DOWN` cycle is written as an `UNKNOWN` row with
  `notes` = `cause=LINK_DOWN`.
- `BLIP` (added 2026-11-23 at the user's request, to make sub-debounce restarts visible) is an **event row,
  not a state**: 1 to `DownThreshold-1` observing failures while `UP`, then a success. It never alerts,
  never counts as downtime, and does not end the `UP` interval.
- CSV is append-only; never rewritten. Files under `data\` are git-ignored.
- `*.ini` stays untracked; only `config.example.ini` is tracked. Code never prints key values.
- Runs as `<PC>\<admin>` at logon, never SYSTEM.
- Every test file starts `#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0' }` and
  imports `src\UT99Monitor.psm1` in `BeforeAll`. Run all: `Invoke-Pester -Path tests -Output Detailed`.
- Every commit also adds a one-line `- 2026-MM-DD — …` entry to the `MEMORY.md` CHANGE LOG.
  `Readme.md` / `CLAUDE.md` are **not** written until the user has tested (Task 12).

## Review Focus

1. **An emergency alert sent at 00:55 keeps retrying on the phone into quiet hours.** Pushover retries
   on its own schedule, so the monitor must cancel any outstanding receipt at quiet start. Test goes in Task 10.
2. **Dropbox briefly locks `state-changes.csv` during sync.** The row must still land, through retries,
   and never be dropped silently. Test goes in Task 5.
3. **The UT99 process is gone but the VPS is up.** Windows surfaces the ICMP port-unreachable as a
   `SocketException` (ConnectionReset) on receive. That must read as a probe failure, not an
   exception that kills the loop. Test goes in Task 2.
4. **The monitor restarts after the 09:00 digest, or inside the window.** There must be no second digest
   and no skipped one: sent-state is persisted. Test goes in Task 8.
5. **A power cut leaves a truncated last CSV line.** The reader skips malformed lines with a warning,
   and startup still infers `MONITOR_GAP`. Test goes in Task 5.

---

## File Structure

| Path | Responsibility |
|---|---|
| `.gitignore` | `data/` ignored; `!config.example.ini` negation |
| `config.example.ini` | Documented template, empty keys |
| `src\UT99Monitor.psm1` | Dot-sources `src\*.ps1`, exports all functions |
| `src\Config.ps1` | INI parsing + defaults + validation |
| `src\GameSpy.ps1` | `\status\` UDP query and multi-packet parser |
| `src\Probes.ps1` | ICMP echo; one probe cycle → classification |
| `src\StateMachine.ps1` | Debounce, UNKNOWN intervals, transitions |
| `src\Evidence.ps1` | CSV + raw poll log I/O, gap inference, pruning |
| `src\QuietHours.ps1` | Window maths across midnight/DST |
| `src\Intervals.ps1` | CSV rows → intervals/outages; duration formatting |
| `src\Digest.ps1` | 09:00 digest due-check, persisted sent-state, text |
| `src\Pushover.ps1` | HTTP transport (send / receipt / cancel) |
| `src\Notifier.ps1` | Which message when; escalation; suppression; retry |
| `UT99-Monitor.ps1` | Main loop, mutex, shutdown row, health hook |
| `Get-DowntimeReport.ps1` | Ticket-ready text report |
| `Setup.ps1` | Prompt keys → `config.ini`, test push, register task |
| `tests\*.Tests.ps1` | One per `src` file |

Runtime files (ignored): `config.ini`, `data\state-changes.csv`, `data\raw\poll-YYYY-MM.log`,
`data\monitor.log` (operational events and errors), `data\digest-state.json`.

---

### Task 1: Scaffolding and config

**Files:** Create `.gitignore`, `config.example.ini`, `src\UT99Monitor.psm1`, `src\Config.ps1`,
`tests\Config.Tests.ps1`. Commit the already-present untracked `open-items.md` here too.

**Interfaces:**
- Produces: `Read-MonitorConfig -Path <string> -> [pscustomobject]` with properties
  `ServerAddress, QueryPort, GamePort, IntervalSeconds, GameTimeoutMs, PingTimeoutMs, PingCount,
  LinkTargets [string[]], DownThreshold, UpThreshold, QuietStart [TimeSpan], QuietEnd [TimeSpan],
  EmergencyRetrySeconds, EmergencyExpireSeconds, ReminderMinutes, ReceiptPollSeconds, SoundDown,
  SoundUp, SoundInfo, DigestGraceHours, PushoverUserKey, PushoverAppToken, DataDir (absolute),
  RawRetentionMonths, HealthcheckUrl`.

`config.example.ini` sections/keys and defaults (the loader uses the same defaults for any missing key):

```ini
[Server]   Address=74.91.119.21  QueryPort=7778  GamePort=7777
[Probe]    IntervalSeconds=30  GameTimeoutMs=3000  PingTimeoutMs=1000  PingCount=2  LinkTargets=1.1.1.1,8.8.8.8
[Debounce] DownThreshold=3  UpThreshold=3
[Notify]   QuietStart=01:00  QuietEnd=09:00  EmergencyRetrySeconds=300  EmergencyExpireSeconds=10800
           ReminderMinutes=15  ReceiptPollSeconds=60  SoundDown=siren  SoundUp=magic  SoundInfo=pushover  DigestGraceHours=3
[Pushover] UserKey=  AppToken=
[Data]     DataDir=data  RawRetentionMonths=12
[Health]   PingUrl=
```
(One `key=value` per line in the real file, each with a `;` comment.)

- [ ] **Step 1: Write failing tests** in `tests\Config.Tests.ps1`:
  - `reads config.example.ini with spec defaults`: `ServerAddress -eq '74.91.119.21'`, `QueryPort -eq 7778`,
    `LinkTargets -join ',' -eq '1.1.1.1,8.8.8.8'`, `QuietStart -eq [TimeSpan]'01:00'`, `EmergencyExpireSeconds -eq 10800`.
  - `fills missing keys from defaults` (INI with only `[Server]`) → `UpThreshold -eq 3`.
  - `resolves DataDir relative to the ini's folder` → `[IO.Path]::IsPathRooted($c.DataDir)` and it ends in `\data`.
  - `rejects EmergencyRetrySeconds below 30` and `rejects EmergencyExpireSeconds above 10800` → `Should -Throw`.
  - `missing file throws mentioning Setup.ps1` → `Should -Throw '*Setup.ps1*'`.
  - `ignores ; comments and blank lines`.
- [ ] **Step 2:** `Invoke-Pester tests\Config.Tests.ps1` → FAIL (function not found).
- [ ] **Step 3:** Implement `Read-MonitorConfig` in `src\Config.ps1`. Write `src\UT99Monitor.psm1` (dot-source
  `$PSScriptRoot\*.ps1`, `Export-ModuleMember -Function *`). Write `.gitignore` (`data/`, `!config.example.ini`) and `config.example.ini`.
- [ ] **Step 4:** Tests PASS. Then `git check-ignore -v config.example.ini` → exit 1 (not ignored);
  `New-Item config.ini; git check-ignore -v config.ini` → matches `.gitignore_global`; delete the temp `config.ini`.
- [ ] **Step 5: Commit** `.gitignore config.example.ini src tests open-items.md MEMORY.md` — "Add scaffolding and config loader".

---

### Task 2: GameSpy `\status\` probe

**Files:** Create `src\GameSpy.ps1`, `tests\GameSpy.Tests.ps1`.

**Interfaces:**
- Produces: `ConvertFrom-GameSpyPackets -Packets <string[]> -> [hashtable] | $null` — merged key/values, or
  `$null` if incomplete. `Invoke-GameSpyStatus -Address <string> -Port <int> -TimeoutMs <int> ->
  [pscustomobject]@{ Ok [bool]; LatencyMs [int]; Map; NumPlayers [int]; MaxPlayers [int]; QueryId [int]; Error [string] }`.
  Never throws. `QueryId` is the integer part of `queryid` (`92.1` → `92`). The server's per-query counter is logged so
  that a future `RESTART_DETECTED` can be built from it (open item); nothing interprets it yet.
  `ConvertFrom-GameSpyPackets` returns `queryid` under the key `_queryid` for this purpose.

Completeness rule (§6.1): every packet carries `\queryid\<id>.<n>`; exactly one carries `\final\`. Complete when
the `\final\` packet has been seen **and** fragments `1..n_final` are all present, in any arrival order. Pairs
are split on `\`; key `final` and `queryid` are not returned as data.

- [ ] **Step 1: Write failing tests:**
  - `parses a single-packet reply`: `\hostname\FMJ\mapname\DM-Deck16][\numplayers\3\maxplayers\16\queryid\92.1\final\` →
    `mapname -eq 'DM-Deck16]['`, `numplayers -eq '3'`, `_queryid -eq '92'`.
  - `merges three fragments received out of order` (order 3,1,2; `\final\` on fragment 3) → all keys present.
  - `returns null when the final fragment has not arrived` (fragments 1,2).
  - `returns null when a middle fragment is missing` (1,3 with final on 3).
  - `queries a loopback fake server` — test starts a `UdpClient` on `127.0.0.1:<free port>` in a background
    runspace that replies with three fragments in order 2,3,1 → `Ok -eq $true`, `Map` set, `LatencyMs -ge 0`.
  - `times out cleanly when nothing replies` (fake server receives but never answers; `-TimeoutMs 500`) →
    `Ok -eq $false`, elapsed < 1500 ms.
  - **Review Focus 3** — `treats port-unreachable as failure, not exception`: query a loopback port with no listener →
    `{ Invoke-GameSpyStatus ... } | Should -Not -Throw` and `Ok -eq $false`.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement. Send ASCII `\status\`; loop `ReceiveAsync().Wait(remaining)` until complete or deadline;
  discard datagrams whose source is not the target; catch `SocketException` into `Error`. LatencyMs is measured to
  the completing packet.
- [ ] **Step 4:** Run → PASS. Then one live smoke check:
  `Invoke-GameSpyStatus 74.91.119.21 7778 3000` → `Ok True`.
- [ ] **Step 5: Commit** — "Add GameSpy status probe with multi-packet reassembly".

---

### Task 3: Ping probe and cycle classification

**Files:** Create `src\Probes.ps1`, `tests\Probes.Tests.ps1`.

**Interfaces:**
- Consumes: `Invoke-GameSpyStatus` (Task 2), config object (Task 1).
- Produces: `Test-IcmpEcho -Target <string> -TimeoutMs <int> -Count <int> -> @{ Ok; LatencyMs }` (Ok if any
  echo replies; never throws). `Invoke-ProbeCycle -Config <obj> [-GameProbe <scriptblock>] [-PingProbe <scriptblock>] ->
  [pscustomobject]@{ Classification; Game; HostPing; LinkPings [array]; Snapshot }`. `Classification` is one of
  `UP|GAME_DOWN|HOST_DOWN|LINK_DOWN`. `Snapshot` = `@{Map;NumPlayers;MaxPlayers}` only when UP, else `$null`.
  `HostPing` / `LinkPings` are `$null` when not run. The default scriptblocks call the real functions; tests inject fakes.

Rule (§6.2–6.3): game ok → UP. Else host ping ok → GAME_DOWN. Else if **either** link target is ok → HOST_DOWN,
else LINK_DOWN. The two link targets are pinged in sequence and the second is skipped if the first succeeds.

- [ ] **Step 1: Write failing tests** (fakes only):
  - `UP and no pings when game answers` — the ping fake records calls, so expect `0` calls.
  - `GAME_DOWN when game silent and host pings` — `LinkPings -eq $null`.
  - `HOST_DOWN when host silent and only 8.8.8.8 answers`.
  - `LINK_DOWN when host and both link targets are silent`.
  - `Test-IcmpEcho against 127.0.0.1 succeeds`; `against 192.0.2.1 (TEST-NET) fails without throwing` (`-TimeoutMs 300`).
- [ ] **Step 2:** FAIL. **Step 3:** Implement, using `System.Net.NetworkInformation.Ping.Send(target, timeoutMs)`.
- [ ] **Step 4:** PASS. **Step 5: Commit** — "Add ping probe and cycle classification".

---

### Task 4: State machine (debounce, UNKNOWN intervals)

**Files:** Create `src\StateMachine.ps1`, `tests\StateMachine.Tests.ps1`.

**Interfaces:**
- Consumes: the cycle result shape from Task 3 (only `.Classification` and `.Snapshot`).
- Produces: `New-MonitorState -StartedAt <DateTimeOffset> -DownThreshold <int> -UpThreshold <int> -> [hashtable]`
  (initial `Current='MONITOR_STARTED'`, `CurrentSince=StartedAt`). `Step-MonitorState -State <hashtable> -Cycle <obj>
  -Now <DateTimeOffset> -> [pscustomobject[]]` of transitions, 0 or more, mutating `State`. Each transition is
  `@{ Timestamp; NewState; PreviousState; PreviousDurationSeconds [int]; Snapshot; Notes; RecoveredFrom [string|null];
  OutageStart [DateTimeOffset|null]; Interrupted [bool] }`. `State.LastGoodSnapshot` holds the last UP snapshot.

Rules. These are exact, and extend §6.3–6.4:
- **Observing failure** = `GAME_DOWN` or `HOST_DOWN`. It increments `FailCount` and zeroes `SuccessCount`. `UP` does the reverse.
  `FirstFailAt` / `FirstSuccessAt` are set by the first cycle of each run.
- **Declare down** when `FailCount` reaches `DownThreshold` and `Current` is not a down state. The class is that of
  the confirming cycle, and `Timestamp = FirstFailAt`.
- **Declare UP** when `SuccessCount` reaches `UpThreshold` and `Current -ne 'UP'`. `Timestamp = FirstSuccessAt`.
- **Class change while down** (`GAME_DOWN`↔`HOST_DOWN`) needs `DownThreshold` *consecutive* cycles of the other class.
  The transition is timestamped at the first of them.
- **`LINK_DOWN`**: if `Current -ne 'UNKNOWN'`, emit `UNKNOWN` immediately at `Now`, with `Notes='cause=LINK_DOWN'`, and
  remember `PreBlindState` plus any open outage start. The counters keep their values (suspended), but `FirstFailAt` and
  `FirstSuccessAt` are cleared, so a post-blind declaration is never timestamped before the `UNKNOWN` row. This is what
  keeps the CSV monotonic. Repeated `LINK_DOWN` cycles emit nothing.
- **Leaving `UNKNOWN`** uses the same thresholds. A down declaration whose `PreBlindState` was a down state gets
  `Interrupted=$true`. An `UP` declaration whose `PreBlindState` was down gets `RecoveredFrom=<that state>` and
  `OutageStart` set. A plain `UP`→`UNKNOWN`→`UP` gets neither.
- `RecoveredFrom` / `OutageStart` are also set on every ordinary down→UP transition. `OutageStart` is the start of the
  first down row of that outage, carried across any class changes.
- `PreviousDurationSeconds = (Timestamp - CurrentSince)`, rounded down.
- **`BLIP`**: when `Current -eq 'UP'` and a success arrives after 1 to `DownThreshold-1` observing failures, emit
  `BLIP` at `Timestamp = FirstFailAt` with `PreviousState='UP'` and `PreviousDurationSeconds=$null`. Its `Notes` are
  `blip: <n> failed cycle(s) (<classes>), <seconds>s` (seconds = first success − first failure), and its `Snapshot` is
  the last good one. `Current`/`CurrentSince` are unchanged. If a `LINK_DOWN` intervenes, no blip is emitted (the
  counters are suspended and the timestamps cleared, as above).

- [ ] **Step 1: Write failing tests**, with a helper `Invoke-Cycles $state $t0 @('UP','GAME_DOWN',…)` that steps at 30 s intervals:
  - `declares UP from MONITOR_STARTED after 3 successes at the first success time`.
  - `declares GAME_DOWN after 3 failures timestamped at the first failure` (UP×3, GD×3 → GD row `Timestamp -eq t0+90s`).
  - `two failures then a success declares nothing`.
  - `GAME, HOST, GAME resolves to GAME_DOWN` and `HOST, GAME, HOST resolves to HOST_DOWN`.
  - `recovery carries RecoveredFrom, OutageStart and PreviousDurationSeconds`.
  - `a single LINK_DOWN emits UNKNOWN at that cycle with cause=LINK_DOWN`; `repeated LINK_DOWN emits one row`.
  - `LINK_DOWN suspends the failure count`: UP×3, GD, LINK, GD, GD → rows `UNKNOWN` then `GAME_DOWN`, and the
    `GAME_DOWN` timestamp equals the first post-blind failure, which is ≥ the `UNKNOWN` timestamp.
  - `outage across a blind window`: …GD×3, LINK, GD×3 → `GAME_DOWN, UNKNOWN, GAME_DOWN(Interrupted=$true)`.
  - `UP observed after a blind outage reports RecoveredFrom`: GD×3, LINK, UP×3 → last row `UP`, `RecoveredFrom -eq 'GAME_DOWN'`.
  - `GAME_DOWN to HOST_DOWN needs 3 consecutive HOST cycles` (GD×3, HD, GD, HD×3 → exactly one `HOST_DOWN` row).
  - `LastGoodSnapshot survives into the down transition's Snapshot`.
  - `UP×3, GD, GD, UP emits one BLIP at the first failure with notes 'blip: 2 failed cycle(s) (GAME_DOWN), 60s'` and the
    state stays `UP` with `CurrentSince` unchanged.
  - `UP×3, GD, LINK, UP emits UNKNOWN but no BLIP`; `two failures from MONITOR_STARTED then UP emits no BLIP`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS.
- [ ] **Step 5: Commit** — "Add debounce state machine with blind-window handling".

---

### Task 5: Evidence files

**Files:** Create `src\Evidence.ps1`, `tests\Evidence.Tests.ps1` (all tests use `$TestDrive`).

**Interfaces:**
- Consumes: transition shape (Task 4), cycle shape (Task 3).
- Produces:
  - `Add-StateChangeRow -CsvPath <string> -Transition <obj>`: writes the header if the file is new. It retries an
    `IOException` up to 10× at 250 ms. After that it writes the row to `data\monitor.log` as `CSV_WRITE_FAILED <row>`
    and rethrows.
  - `Read-StateChanges -CsvPath <string> -> [pscustomobject[]]`: each row has `TimestampLocal`/`TimestampUtc` as
    `[DateTimeOffset]`, `NewState`, `PreviousState`, `Map`, `NumPlayers`, `MaxPlayers`, `Notes`. Malformed lines are
    skipped with `Write-Warning`.
  - `Add-PollLogLine -DataDir <string> -Now <DateTimeOffset> -Cycle <obj>`: appends to
    `raw\poll-yyyy-MM.log`, one tab-separated line:
    `<ts_local>\t<Classification>\tgame=ok:61ms|fail:<err>\thost=ok:40ms|fail|skip\tlink=1.1.1.1:ok:12ms,8.8.8.8:skip|skip\tmap=<m>\tplayers=<n>/<max>\tqid=<QueryId>`
    (`map`/`players`/`qid` are empty when the game probe failed).
  - `Get-LastPollTime -DataDir <string> -> [DateTimeOffset] | $null`: parses the newest poll log's last valid line.
  - `Start-MonitorSession -CsvPath -DataDir -Now -> [pscustomobject]@{ GapStart [DateTimeOffset|null]; GapSeconds }`.
    If the CSV's last valid row is not `MONITOR_STOPPED`, it first writes a `MONITOR_GAP` row. That row's timestamp is
    the later of `Get-LastPollTime` and the last row's timestamp; `Notes='inferred: monitor ended without MONITOR_STOPPED'`.
    Then it always writes `MONITOR_STARTED` at `Now`.
  - `Add-MonitorStoppedRow -CsvPath -Now -CurrentState -CurrentSince`.
  - `Write-MonitorLog -DataDir -Now -Message`: appends to `data\monitor.log`.
  - `Remove-ExpiredPollLogs -DataDir -Now -RetentionMonths <int>`: deletes `poll-yyyy-MM.log` files whose month is older
    than `Now`'s month minus `RetentionMonths`. Any other file is never touched.

- [ ] **Step 1: Write failing tests:**
  - `creates the CSV with the exact header then appends` — compare line 1 to the Global Constraints header.
  - `round-trips a transition`: write then read; `TimestampUtc` equals the input; local text matches `yyyy-MM-ddTHH:mm:sszzz`.
  - **Review Focus 2** — `retries while the CSV is locked`: the test opens the file with `FileShare.None` and releases it
    after 600 ms from a background job; the row is present afterwards, and the call takes ≥ 500 ms.
  - **Review Focus 5** — `skips a truncated final line`: append `2026-11-23T03:1` without a newline → `Read-StateChanges`
    returns the earlier rows only, with a warning.
  - `infers MONITOR_GAP from the last poll time when the last row is not MONITOR_STOPPED`: the gap row's timestamp
    equals the last poll line's timestamp, and `MONITOR_STARTED` follows.
  - `no gap row after a clean MONITOR_STOPPED`; `no gap row on an empty/new CSV`.
  - `poll line format` → it matches `^\S+\tUP\tgame=ok:\d+ms\thost=skip\tlink=skip\tmap=.*\tplayers=\d+/\d+\tqid=\d+$`.
  - `BLIP row has an empty previous_duration_seconds field`.
  - `prunes logs older than 12 months only` — with Now 2026-11, files `poll-2025-10.log` (deleted), `poll-2025-11.log`
    (kept) and `notes.txt` (kept).
- [ ] **Step 2:** FAIL. **Step 3:** Implement. Use `[IO.File]::AppendAllText` for appends, and write CSV fields with
  RFC 4180 quoting (quote any field containing `,` `"` or a newline).
- [ ] **Step 4:** PASS. **Step 5: Commit** — "Add evidence CSV, raw poll log, gap inference and pruning".

---

### Task 6: Quiet hours

**Files:** Create `src\QuietHours.ps1`, `tests\QuietHours.Tests.ps1`.

**Interfaces:**
- Produces: `Test-InQuietHours -Now <DateTimeOffset> -Start <TimeSpan> -End <TimeSpan> -> [bool]` (local wall-clock,
  start inclusive, end exclusive, handles `Start > End`). `Get-QuietWindow -LocalDate <DateTime> -Start -End ->
  @{ From [DateTimeOffset]; To [DateTimeOffset] }`: the window that **ends** on `LocalDate`. Each bound is converted
  through `TimeZoneInfo.Local` separately, so a DST night just yields a 7 h or 9 h window.

- [ ] **Step 1: Write failing tests:** `00:59 not quiet`, `01:00 quiet`, `08:59 quiet`, `09:00 not quiet`;
  `22:00–06:00 window crossing midnight: 23:30 quiet, 12:00 not`; `same-day window 01:00–09:00 for date D spans
  D 01:00 → D 09:00`; `22:00–06:00 for date D spans D-1 22:00 → D 06:00`; `window length is 8h on a normal day`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS. **Step 5: Commit** — "Add quiet-hours window logic".

---

### Task 7: Intervals and the downtime report

**Files:** Create `src\Intervals.ps1`, `Get-DowntimeReport.ps1`, `tests\Intervals.Tests.ps1`.

**Interfaces:**
- Consumes: `Read-StateChanges` (Task 5).
- Produces:
  - `Format-Duration -Span <TimeSpan> -> [string]`: `45s`, `12m`, `1h 12m`, `2d 3h`. Seconds appear only under 1 minute;
    otherwise it uses the two largest units, and drops a zero second unit (`2h`).
  - `Get-StateIntervals -Rows <obj[]> -From <DateTimeOffset> -To <DateTimeOffset> -> [pscustomobject[]]`
    `@{ State; Start; End; Seconds }`. Each row's state runs until the next row, and the last one runs until `To`.
    Intervals are clipped to `[From, To)`. `BLIP` rows are skipped (they are events, not states).
  - `Get-Blips -Rows -From -To -> [pscustomobject[]]` `@{ Timestamp; Notes; Map }`.
  - `Get-Outages -Intervals <obj[]> -> [pscustomobject[]]` `@{ Start; End [null if ongoing]; Seconds; Classes [string[]];
    GameSeconds; HostSeconds; Interrupted [bool] }`. An outage is a maximal run of `GAME_DOWN`/`HOST_DOWN` intervals.
    Runs separated only by `UNKNOWN` merge into one outage with `Interrupted=$true`, and the blind seconds are not
    counted in `Seconds`.
  - `Get-DowntimeSummary -Rows -From -To -> @{ ObservedSeconds; UpSeconds; GameSeconds; HostSeconds;
    UnknownSeconds; UnmonitoredSeconds; UptimePercent; Outages; Longest }`. Observed = UP + GAME_DOWN + HOST_DOWN.
    Unknown = UNKNOWN. Unmonitored = MONITOR_STARTED, MONITOR_STOPPED and MONITOR_GAP intervals.
    `UptimePercent = Up / Observed * 100`, or `$null` if nothing was observed.
  - `Get-DowntimeReport.ps1 [-From <datetime>] [-To <datetime>] [-ConfigPath] [-OutFile]`: the default period is the
    1st of the current month 00:00 local → now. It prints plain text, in this order: period; observed `X of Y`, with
    unobserved broken out by UNKNOWN and unmonitored; uptime %; outage count and total; the GAME_DOWN vs HOST_DOWN
    split; one line per outage (`start → end (duration) classes`, plus `[interrupted by blind window]`); the longest
    outage; outage starts by 4-hour bucket (only when there are ≥ 3 outages); then a **Brief interruptions** section listing
    each `BLIP` (time, notes), headed with the note "under 90 s; not counted as downtime — possibly quick restarts".
    It finishes with a
    **Method** paragraph that states, verbatim in substance:
    1. Outage start = first failing 30 s cycle; recovery = first successful cycle; so durations may run up to ~90 s
       longer at each end than the moment of detection.
    2. Periods when the monitoring PC's own internet was down (UNKNOWN) and periods when the monitor was not
       running are excluded from the uptime denominator and listed above.

- [ ] **Step 1: Write failing tests** (rows built in memory):
  - `Format-Duration` table: 45s→`45s`, 720s→`12m`, 4320s→`1h 12m`, 7200s→`2h`, 183600s→`2d 3h`.
  - `intervals are clipped to the period`.
  - `GAME→HOST class change is one outage with both classes and split seconds`.
  - `GAME_DOWN, UNKNOWN, GAME_DOWN merges into one interrupted outage excluding blind time`.
  - `uptime excludes UNKNOWN and MONITOR_GAP from the denominator`: UP 9h, GAME 1h, UNKNOWN 5h, GAP 9h → `UptimePercent -eq 90`.
  - `ongoing outage has End null and runs to To`.
  - `a BLIP inside an UP interval does not split it` (UP 10h with one BLIP → one UP interval of 10h; `Get-Blips` returns 1).
  - `report script output contains 'Method' and 'first failing'` — run the script against a fixture CSV in `$TestDrive` via `-ConfigPath`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS. **Step 5: Commit** — "Add interval maths and downtime report".

---

### Task 8: 09:00 digest

**Files:** Create `src\Digest.ps1`, `tests\Digest.Tests.ps1`.

**Interfaces:**
- Consumes: `Get-QuietWindow` (Task 6), `Get-StateIntervals`, `Get-Outages`, `Format-Duration` (Task 7), `Read-StateChanges` (Task 5).
- Produces:
  - `Test-DigestDue -Now -QuietEnd <TimeSpan> -GraceHours <int> -StatePath <string> -> [bool]`: true when local time
    is in `[QuietEnd, QuietEnd+Grace)` and `digest-state.json`'s `lastSentLocalDate` ≠ today.
  - `Set-DigestSent -StatePath -Now`: atomic write via a temp file plus `Move-Item -Force`.
  - `New-DigestMessage -Rows -Window <@{From;To}> -CurrentState <string> -CurrentSince -Now -> @{ Title; Message; Priority }`.
    Title is `UT99 overnight: all quiet` when there were no outages and the state is UP; otherwise `UT99 overnight: <n> outage(s)`,
    or `UT99 STILL DOWN (<state>)` when the current state is down. Priority is 2 if the current state is GAME_DOWN/HOST_DOWN, else 0.
    The body lists each outage (start time, duration or "ongoing", classes), any blips (`Brief interruptions: 03:12, 05:40`),
    the UNKNOWN total and the unmonitored total. Blips alone do not stop the title from being "all quiet".
    If the first `MONITOR_STARTED` falls inside the window, it adds `Monitor only watching since HH:mm.`

- [ ] **Step 1: Write failing tests:**
  - `quiet night yields 'all quiet' at priority 0`.
  - `still down at 09:00 yields priority 2 and STILL DOWN title`.
  - `outage at 03:10 lasting 25m appears in the body as '03:10' and '25m'`.
  - `monitor started at 04:00 inside the window says 'only watching since 04:00'`.
  - **Review Focus 4** — `not due twice on the same day across a restart` (Set-DigestSent, then a new
    `Test-DigestDue` call reading the same file → `$false`); `due at 10:30 if not yet sent (PC was off)`;
    `not due at 12:30 (past grace)`; `missing or corrupt digest-state.json counts as not sent`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS. **Step 5: Commit** — "Add 09:00 digest built from the CSV".

---

### Task 9: Pushover transport

**Files:** Create `src\Pushover.ps1`, `tests\Pushover.Tests.ps1`.

**Interfaces:**
- Produces: `New-PushoverTransport -UserKey <string> -AppToken <string> -> [hashtable]` with scriptblocks:
  - `Send.Invoke(@{Title;Message;Priority;Sound;Retry;Expire;Timestamp})` → `@{ Ok; Receipt; Retryable; Error }`.
    It POSTs to `https://api.pushover.net/1/messages.json`; `retry`/`expire` are sent only for priority 2.
  - `GetReceipt.Invoke($receipt)` → `@{ Ok; Acknowledged [bool]; Expired [bool]; Error }`, via GET
    `https://api.pushover.net/1/receipts/<r>.json?token=<t>`.
  - `CancelReceipt.Invoke($receipt)` → `@{ Ok; Error }`, via POST `https://api.pushover.net/1/receipts/<r>/cancel.json`.
  - Error policy: a network failure, a 429 or a 5xx gives `Retryable=$true`; any other 4xx gives `Retryable=$false`.
    `Error` text never contains the token or user key; the test checks this.

- [ ] **Step 1: Write failing tests** (`Mock Invoke-RestMethod -ModuleName UT99Monitor`):
  - `priority 2 sends retry 300 and expire 10800 and returns the receipt`.
  - `priority 0 omits retry/expire`.
  - `429 is retryable; 400 is not`.
  - `error text does not contain the key or token` (the mock throws using the token string in its message).
  - `GetReceipt maps acknowledged=1 and expired=1`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement with `Invoke-RestMethod -TimeoutSec 15`. **Step 4:** PASS.
- [ ] **Step 5: Commit** — "Add Pushover transport".

---

### Task 10: Notifier (what to send, when)

**Files:** Create `src\Notifier.ps1`, `tests\Notifier.Tests.ps1`.

**Interfaces:**
- Consumes: transport shape (Task 9), transitions (Task 4), `Test-InQuietHours` (Task 6), `Test-DigestDue` /
  `Set-DigestSent` / `New-DigestMessage` (Task 8), `Format-Duration` (Task 7), `Write-MonitorLog` (Task 5).
- Produces: `New-Notifier -Config -Transport -DataDir -> [hashtable]`;
  `Update-Notifier -Notifier -Transitions <obj[]> -MonitorState <hashtable> -Now <DateTimeOffset> -CsvPath <string>`,
  called once per cycle; `Send-StartupNotice -Notifier -Now -Gap <Start-MonitorSession result>`.

Messages (exact titles; sounds from config):

| Trigger | Title | Pri | Sound |
|---|---|---|---|
| Declared GAME_DOWN | `UT99 CRASHED (VPS up)` | 2 | Down |
| Declared HOST_DOWN | `VPS/NETWORK DOWN` | 2 | Down |
| Class change while down | the new class's title, prefixed `NOW: ` | see rule | Down |
| Reminder | `UT99 still down — <Format-Duration since OutageStart>` | 1 | Down |
| Recovery | `Server UP — was down <duration>` | 0 | Up |
| Startup | `UT99 monitor started` (body adds `Previous gap: <duration> unobserved` if there was a gap) | 0 | Info |
| Digest | from `New-DigestMessage` | 0/2 | Info / Down |

The down body carries the start time (`HH:mm`), last map and `players n/max` from the transition `Snapshot`.
The recovery body carries the class(es) it recovered from, plus `(outage interrupted by a blind window)` when that applies.
`UNKNOWN` and `BLIP` transitions, and the declared-`UP` that ends a startup, send nothing.

Escalation rules (§6.5):
- An emergency send stores `Receipt`, `SentAt`. The receipt is polled when `Now - LastPoll ≥ ReceiptPollSeconds`.
- Acknowledged → `ReminderDue = AckSeenAt + ReminderMinutes`; polling stops. Expired, or `Now ≥ SentAt + Expire` even if
  polls keep failing → `ReminderDue = Now` (implicit hand-off). A failed poll changes nothing.
- A reminder is sent at `ReminderDue`, which then moves on by `ReminderMinutes`. Reminders only run while the current state is down.
- Class change while down: if a receipt is outstanding and unacknowledged, cancel it and send the new class at
  priority 2 (escalation restarts). Otherwise send it at priority 1 and leave `ReminderDue` alone.
- Recovery: cancel any outstanding receipt, clear escalation, send the recovery message.
- **Quiet hours:** no `Send` at all. On the first cycle inside the window, cancel any outstanding receipt and remember
  that the outage is still unacknowledged. Reminders and polls pause. The digest at window end takes over. If it goes out
  at priority 2, its receipt becomes the escalation receipt; if the state is UP, escalation is cleared.
- **Send failure:** there is one pending slot per kind (`Down`, `Recovery`, `Startup`), retried every cycle while
  `Retryable`. A newer down or recovery message replaces the older pending one. A pending `Down` is dropped as soon as
  the state is no longer down. Any other pending message is dropped after 30 minutes. Every send, failure and drop goes
  to `monitor.log`.

- [ ] **Step 1: Write failing tests.** The fake transport records calls and returns scripted results; `-Now` is stepped manually:
  - `GAME_DOWN at 14:00 sends priority 2 'UT99 CRASHED (VPS up)' with map and players in the body`.
  - `ack seen at 14:07 → first reminder 14:22 priority 1, next 14:37`.
  - `no reminder before ack while unacknowledged`.
  - `expiry without ack starts reminders at expiry even when every poll failed`.
  - `receipt polled at most once per 60 s`.
  - `recovery cancels the outstanding receipt and sends 'Server UP — was down 1h 12m' at priority 0`.
  - `class change unacknowledged → cancel + new priority 2 'NOW: VPS/NETWORK DOWN'`; `class change acknowledged → priority 1`.
  - `down declared at 02:00 sends nothing`; `recovery at 03:00 sends nothing`; `a BLIP at 14:00 sends nothing`.
  - **Review Focus 1** — `outage alerted at 00:55, still unacknowledged at 01:00 → receipt cancelled at first quiet cycle, no further sends until 09:00`.
  - `09:00 digest while still down is priority 2 and its receipt drives reminders after ack`.
  - `failed down send (Retryable) is retried next cycle and sent once`; `pending down dropped once state is UP`;
    `non-retryable failure is not retried`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS.
- [ ] **Step 5: Commit** — "Add notifier with escalation, quiet hours and send retry".

---

### Task 11: Main loop `UT99-Monitor.ps1`

**Files:** Create `UT99-Monitor.ps1`, `tests\Monitor.Tests.ps1`.

**Interfaces:**
- Consumes: everything above.
- Produces: `UT99-Monitor.ps1 [-ConfigPath <string>] [-MaxCycles <int>] [-Probe <scriptblock>] [-Transport <hashtable>]`.
  The last three parameters exist for tests only. `-Probe` replaces `Invoke-ProbeCycle`, and `-MaxCycles` exits cleanly
  after N cycles with a 0 s interval.

Behaviour:
- Single instance via the named mutex `Local\UT99ServerDownMonitor`. If it is already held: write `monitor.log`
  `ALREADY_RUNNING` and `exit 0` (a non-zero exit would trigger Task Scheduler's restart-on-failure loop).
- It validates that the Pushover keys are non-empty, else exits 1 with a message pointing to `Setup.ps1`. It never prints them.
- Startup: `Start-MonitorSession` → `Send-StartupNotice` → `Remove-ExpiredPollLogs` (and again on each local-date change).
- Each cycle: probe → `Add-PollLogLine` → `Step-MonitorState` → `Add-StateChangeRow` for each transition →
  `Update-Notifier` → `Invoke-CycleHook` (a no-op unless `HealthcheckUrl` is set; if set, fire-and-forget GET with a
  5 s timeout — the hook point for the deferred Healthchecks.io ping, §6.10).
- Cadence: ticks at `start + n × IntervalSeconds`. If a tick is missed (e.g. the PC stalled), go to the next future
  tick without bursting.
- A cycle exception is caught, written to `monitor.log`, and the loop continues. An exception outside the loop
  propagates and exits non-zero, so Task Scheduler restarts it.
- Shutdown: a `finally` block plus `Register-EngineEvent PowerShell.Exiting` write `MONITOR_STOPPED` once (guarded
  by a flag). If the process is killed, no row is written and the next start infers the gap, which is the intended behaviour.

- [ ] **Step 1: Write failing tests** (run the script with `-ConfigPath` pointing at a `$TestDrive` ini, a fake probe
  and a fake transport):
  - `writes MONITOR_STARTED, UP, GAME_DOWN, MONITOR_STOPPED for scripted UP×3 GD×3` (CSV states in order).
  - `one poll log line per cycle`.
  - `second instance exits 0 while the mutex is held` — hold the mutex in the test runspace, run the script in a child `pwsh`.
  - `a probe that throws once does not stop the loop` (the log has the error; the cycle count completes).
  - `exits 1 with Setup.ps1 hint when keys are empty`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS, and the full suite `Invoke-Pester -Path tests` is all green.
- [ ] **Step 5: Commit** — "Add monitor main loop".

---

### Task 12: Setup, deploy and live verification

**Files:** Create `Setup.ps1`, `tests\Setup.Tests.ps1`.

**Interfaces:**
- Produces: `Setup.ps1 [-ConfigPath] [-SkipTask] [-SkipTest]`.
  1. Prompts with `Read-Host -AsSecureString` for the Pushover User Key and App Token, and converts them only in memory.
     If `config.ini` exists, it asks before overwriting; blank input keeps the existing values.
  2. Writes `config.ini` from `config.example.ini`, replacing only `UserKey=`/`AppToken=`.
  3. Unless `-SkipTest`, sends a priority-0 `UT99 monitor: test notification` and reports Ok or Error (never the keys).
  4. Unless `-SkipTask`, registers the scheduled task `UT99 Server Down Monitor` (`-Force` replaces an existing one):
     - Action: `pwsh.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "<repo>\UT99-Monitor.ps1"`
       with WorkingDirectory `<repo>`.
     - Trigger: AtLogOn for `<PC>\<admin>`. Principal: `<PC>\<admin>`, LogonType Interactive, RunLevel Limited —
       no stored password, never SYSTEM.
     - Settings: `-RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
       -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries`.
     - Then it offers to start the task now.

- [ ] **Step 1: Write failing tests:** `writes keys into a config.ini copied from the example, other lines unchanged`
  (a helper `Write-ConfigWithKeys -TemplatePath -OutPath -UserKey -AppToken` in `Setup.ps1`, dot-sourced under a test
  guard); `builds the task definition with the admin principal and the restart settings` (a helper `New-MonitorTaskDefinition`
  returns the objects without registering them; assert `Principal.UserId -eq 'EXAMPLEPC\admin'` and `LogonType -eq 'Interactive'`).
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS, and the full suite is green.
- [ ] **Step 5: Commit** — "Add Setup script". This is the committed state that gets deployed (deploy-discipline).
- [ ] **Step 6: User runs `.\Setup.ps1`** (the assistant does not see the keys). Expected: the test push arrives, the task
  is registered, and the "monitor started" push arrives after it starts.
- [ ] **Step 7: Live checks**, each checkable:
  - Within ~2 min: the CSV has `MONITOR_STARTED` then `UP`; `data\raw\poll-2026-11.log` gains a line every 30 s with `game=ok`.
  - `Get-ScheduledTask 'UT99 Server Down Monitor' | Select -Expand Principal` → `UserId <admin>`, not SYSTEM.
  - Kill the `pwsh` process → the task restarts it within ~1 min → the CSV shows `MONITOR_GAP` then `MONITOR_STARTED`,
    and a startup push arrives that mentions the gap.
  - Run `Get-DowntimeReport.ps1` → the report prints with the Method paragraph.
  - Optional real-outage test: the user stops UT99 via the NFO panel for ~3 min → `UT99 CRASHED (VPS up)` emergency
    arrives → acknowledge it → restart UT99 → `Server UP — was down …`.
  - The next morning: the 09:00 digest arrives.
- [ ] **Step 8:** After the user approves: propose `Readme.md` and `CLAUDE.md` (with a Key Files table), and update
  `MEMORY.md` and `open-items.md`. Wait for approval, then merge to `main` and push.
