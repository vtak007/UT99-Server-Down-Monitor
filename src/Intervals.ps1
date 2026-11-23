# Intervals.ps1 — turns state-change rows into intervals, outages and the downtime report (spec §6.8).

$script:ObservedStates = @('UP', 'GAME_DOWN', 'HOST_DOWN')
$script:OutageStates = @('GAME_DOWN', 'HOST_DOWN')

function Format-Duration {
    # 45s / 12m / 1h 12m / 2h / 2d 3h: seconds only under a minute, else the two largest units.
    [CmdletBinding()]
    param([Parameter(Mandatory)][TimeSpan]$Span)
    $total = [long][Math]::Floor($Span.TotalSeconds)
    if ($total -lt 60) { return "$([Math]::Max(0, $total))s" }
    $units = @(
        @{ N = [long][Math]::Floor($total / 86400); S = 'd' }
        @{ N = [long][Math]::Floor(($total % 86400) / 3600); S = 'h' }
        @{ N = [long][Math]::Floor(($total % 3600) / 60); S = 'm' }
    )
    $first = 0
    while ($units[$first].N -eq 0) { $first++ }
    $parts = @("$($units[$first].N)$($units[$first].S)")
    if ($first + 1 -lt $units.Count -and $units[$first + 1].N -gt 0) { $parts += "$($units[$first + 1].N)$($units[$first + 1].S)" }
    $parts -join ' '
}

function Get-StateIntervals {
    # Each row's state runs until the next row (the last until To), clipped to [From, To). BLIP rows are events, skipped.
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Rows = @(), [Parameter(Mandatory)][DateTimeOffset]$From, [Parameter(Mandatory)][DateTimeOffset]$To)
    $states = @($Rows | Where-Object { $_.NewState -ne 'BLIP' } | Sort-Object { $_.TimestampUtc })
    for ($i = 0; $i -lt $states.Count; $i++) {
        $start = $states[$i].TimestampUtc
        $end = if ($i + 1 -lt $states.Count) { $states[$i + 1].TimestampUtc } else { $To }
        $s = if ($start -gt $From) { $start } else { $From }
        $e = if ($end -lt $To) { $end } else { $To }
        if ($e -gt $s) {
            [pscustomobject]@{ State = $states[$i].NewState; Start = $s; End = $e; Seconds = [long]($e - $s).TotalSeconds }
        }
    }
}

function Get-Blips {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Rows = @(), [Parameter(Mandatory)][DateTimeOffset]$From, [Parameter(Mandatory)][DateTimeOffset]$To)
    $Rows | Where-Object { $_.NewState -eq 'BLIP' -and $_.TimestampUtc -ge $From -and $_.TimestampUtc -lt $To } |
        ForEach-Object { [pscustomobject]@{ Timestamp = $_.TimestampUtc; Notes = $_.Notes; Map = $_.Map } }
}

function Get-Outages {
    # Maximal runs of GAME_DOWN/HOST_DOWN. Runs separated only by unobserved time (UNKNOWN or MONITOR_*)
    # merge into one outage flagged Interrupted; unobserved seconds are not counted.
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Intervals = @())
    $outages = [Collections.Generic.List[object]]::new()
    $cur = $null
    $blindPending = $false
    $all = @($Intervals)
    for ($i = 0; $i -lt $all.Count; $i++) {
        $iv = $all[$i]
        if ($iv.State -in $script:OutageStates) {
            if ($null -eq $cur) {
                $cur = [pscustomobject]@{ Start = $iv.Start; End = $iv.End; Seconds = 0L; Classes = [Collections.Generic.List[string]]::new()
                    GameSeconds = 0L; HostSeconds = 0L; Interrupted = $false }
            } elseif ($blindPending) { $cur.Interrupted = $true }
            $blindPending = $false
            $cur.End = $iv.End
            $cur.Seconds += $iv.Seconds
            if ($iv.State -eq 'GAME_DOWN') { $cur.GameSeconds += $iv.Seconds } else { $cur.HostSeconds += $iv.Seconds }
            if (-not $cur.Classes.Contains($iv.State)) { $cur.Classes.Add($iv.State) }
            if ($i -eq $all.Count - 1) { $cur.End = $null }   # still down at the end of the period
        } elseif ($iv.State -eq 'UP') {
            if ($null -ne $cur) { $outages.Add($cur); $cur = $null }
            $blindPending = $false
        } else {
            # Unobserved: the outage may or may not have continued.
            if ($null -ne $cur) { $blindPending = $true; $cur.Interrupted = $true }
        }
    }
    if ($null -ne $cur) { $outages.Add($cur) }
    foreach ($o in $outages) { $o.Classes = [string[]]$o.Classes.ToArray(); $o }
}

function Get-DowntimeSummary {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Rows = @(), [Parameter(Mandatory)][DateTimeOffset]$From, [Parameter(Mandatory)][DateTimeOffset]$To)
    $intervals = @(Get-StateIntervals -Rows $Rows -From $From -To $To)
    $sum = { param($states) $t = 0L; foreach ($iv in $intervals) { if ($iv.State -in $states) { $t += $iv.Seconds } }; $t }
    $up = & $sum @('UP')
    $game = & $sum @('GAME_DOWN')
    $hostSecs = & $sum @('HOST_DOWN')
    $unknown = & $sum @('UNKNOWN')
    $observed = $up + $game + $hostSecs
    $period = [long]($To - $From).TotalSeconds
    $outages = @(Get-Outages -Intervals $intervals)
    [pscustomobject]@{
        PeriodSeconds      = $period
        ObservedSeconds    = $observed
        UpSeconds          = $up
        GameSeconds        = $game
        HostSeconds        = $hostSecs
        UnknownSeconds     = $unknown
        UnmonitoredSeconds = $period - $observed - $unknown
        UptimePercent      = $(if ($observed -gt 0) { [double]$up / $observed * 100 } else { $null })
        Outages            = $outages
        Longest            = ($outages | Sort-Object Seconds -Descending | Select-Object -First 1)
        Blips              = @(Get-Blips -Rows $Rows -From $From -To $To)
    }
}

function Format-LocalShort([DateTimeOffset]$Ts) { $Ts.ToLocalTime().ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture) }

function Format-DowntimeReport {
    # Ticket-ready plain text for [From, To).
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Rows = @(), [Parameter(Mandatory)][DateTimeOffset]$From, [Parameter(Mandatory)][DateTimeOffset]$To,
        [string]$Server = '')
    $s = Get-DowntimeSummary -Rows $Rows -From $From -To $To
    $d = { param($secs) Format-Duration -Span ([TimeSpan]::FromSeconds($secs)) }
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('UT99 Server Downtime Report')
    if ($Server) { $lines.Add("Server: $Server") }
    $lines.Add("Period: $(Format-LocalShort $From) to $(Format-LocalShort $To) (local, UTC$($From.ToLocalTime().ToString('zzz'))) - $(& $d $s.PeriodSeconds)")
    $lines.Add("Observed: $(& $d $s.ObservedSeconds) of $(& $d $s.PeriodSeconds); unobserved: $(& $d $s.UnknownSeconds) monitoring PC's internet down (UNKNOWN), $(& $d $s.UnmonitoredSeconds) monitor not running")
    $lines.Add($(if ($null -ne $s.UptimePercent) { 'Uptime (observed time only): {0:N2}%' -f $s.UptimePercent } else { 'Uptime: n/a (nothing observed in this period)' }))
    $total = $s.GameSeconds + $s.HostSeconds
    $lines.Add("Outages: $($s.Outages.Count), total downtime $(& $d $total)")
    $lines.Add("  GAME_DOWN (UT99 not answering, VPS reachable): $(& $d $s.GameSeconds)")
    $lines.Add("  HOST_DOWN (VPS/network unreachable):           $(& $d $s.HostSeconds)")
    if ($s.Outages.Count) {
        $lines.Add('')
        $lines.Add('Outage list (local time):')
        foreach ($o in $s.Outages) {
            $end = if ($null -ne $o.End) { Format-LocalShort $o.End } else { 'ongoing' }
            $flag = if ($o.Interrupted) { ' [interrupted by blind window]' } else { '' }
            $lines.Add("  $(Format-LocalShort $o.Start) -> $end ($(& $d $o.Seconds)) $($o.Classes -join '+')$flag")
        }
        $lines.Add("Longest outage: $(& $d $s.Longest.Seconds), starting $(Format-LocalShort $s.Longest.Start)")
        if ($s.Outages.Count -ge 3) {
            $lines.Add('Outage starts by time of day (local):')
            foreach ($b in 0..5) {
                $n = @($s.Outages | Where-Object { [Math]::Floor($_.Start.ToLocalTime().Hour / 4) -eq $b }).Count
                $lines.Add(('  {0:00}:00-{1:00}:00  {2}' -f ($b * 4), ($b * 4 + 4), $n))
            }
        }
    }
    $lines.Add('')
    $lines.Add("Brief interruptions (under 90 s; not counted as downtime - possibly quick restarts): $($s.Blips.Count)")
    foreach ($b in $s.Blips) { $lines.Add("  $(Format-LocalShort $b.Timestamp)  $($b.Notes)") }
    $lines.Add('')
    $lines.Add('Method:')
    $lines.Add('  - The server is probed every 30 s (GameSpy status query; ping of the VPS; ping of 1.1.1.1/8.8.8.8).')
    $lines.Add('  - An outage is declared after 3 consecutive failed cycles; recovery after 3 consecutive successes.')
    $lines.Add('  - Outage start = the first failing 30 s cycle; recovery = the first successful cycle. Durations may')
    $lines.Add('    therefore run up to ~90 s longer at each end than the moment the outage was detected.')
    $lines.Add("  - Periods when the monitoring PC's own internet was down (UNKNOWN) and periods when the monitor was")
    $lines.Add('    not running are excluded from the uptime denominator and listed above.')
    $lines.Add('  - An outage marked [interrupted by blind window] spans such a period; only observed downtime is counted.')
    $lines -join [Environment]::NewLine
}
