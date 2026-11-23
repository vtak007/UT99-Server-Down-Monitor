# Digest.ps1 — the daily quiet-hours digest, rebuilt from the CSV (spec §6.6). Sent-state is persisted so a
# restart neither repeats nor skips it.

function Get-DigestLastSentDate([string]$StatePath) {
    if (-not (Test-Path -LiteralPath $StatePath)) { return $null }
    try {
        $raw = Invoke-WithFileRetry -Action { [IO.File]::ReadAllText($StatePath) }
        $j = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($j.PSObject.Properties['lastSentLocalDate']) { return [string]$j.lastSentLocalDate }
    } catch { }
    $null
}

function Test-DigestDue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][DateTimeOffset]$Now, [Parameter(Mandatory)][TimeSpan]$QuietEnd,
        [int]$GraceHours = 3, [Parameter(Mandatory)][string]$StatePath)
    $local = $Now.ToLocalTime()
    $t = $local.TimeOfDay
    if ($t -lt $QuietEnd -or $t -ge $QuietEnd.Add([TimeSpan]::FromHours($GraceHours))) { return $false }
    (Get-DigestLastSentDate $StatePath) -ne $local.ToString('yyyy-MM-dd')
}

function Set-DigestSent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StatePath, [Parameter(Mandatory)][DateTimeOffset]$Now)
    $dir = Split-Path $StatePath -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$StatePath.tmp"
    @{ lastSentLocalDate = $Now.ToLocalTime().ToString('yyyy-MM-dd'); sentAt = $Now.ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath $tmp -Encoding utf8
    Invoke-WithFileRetry -Action { Move-Item -LiteralPath $tmp -Destination $StatePath -Force -ErrorAction Stop }
}

function New-DigestMessage {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Rows = @(), [Parameter(Mandatory)]$Window,
        [Parameter(Mandatory)][string]$CurrentState, $CurrentSince, [Parameter(Mandatory)][DateTimeOffset]$Now)
    $hm = { param($ts) $ts.ToLocalTime().ToString('HH:mm') }
    $d = { param($secs) Format-Duration -Span ([TimeSpan]::FromSeconds($secs)) }
    $s = Get-DowntimeSummary -Rows $Rows -From $Window.From -To $Window.To
    $intervals = @(Get-StateIntervals -Rows $Rows -From $Window.From -To $Window.To)
    $isDown = $CurrentState -in @('GAME_DOWN', 'HOST_DOWN')

    $title = if ($isDown) { "UT99 STILL DOWN ($CurrentState)" }
    elseif ($s.Outages.Count -eq 0) { 'UT99 overnight: all quiet' }
    else { "UT99 overnight: $($s.Outages.Count) outage(s)" }

    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("Quiet hours $(& $hm $Window.From)-$(& $hm $Window.To).")
    if ($s.Outages.Count -eq 0) { $lines.Add('No outages.') }
    foreach ($o in $s.Outages) {
        $dur = if ($null -eq $o.End) { "ongoing, $(& $d $o.Seconds) so far" } else { & $d $o.Seconds }
        $flag = if ($o.Interrupted) { ' (interrupted by blind window)' } else { '' }
        $lines.Add("Outage $(& $hm $o.Start): $dur, $($o.Classes -join '+')$flag")
    }
    if ($s.Blips.Count) { $lines.Add('Brief interruptions: ' + (($s.Blips | ForEach-Object { & $hm $_.Timestamp }) -join ', ')) }
    if ($s.UnknownSeconds -gt 0) { $lines.Add("Unobserved (home internet down): $(& $d $s.UnknownSeconds)") }

    $firstObserved = $intervals | Where-Object { $_.State -in @('UP', 'GAME_DOWN', 'HOST_DOWN', 'UNKNOWN') } | Select-Object -First 1
    $startCovered = $intervals.Count -gt 0 -and $intervals[0].Start -le $Window.From -and $intervals[0].State -notlike 'MONITOR_*'
    if (-not $startCovered -and $firstObserved) {
        $lines.Add("Monitor only watching since $(& $hm $firstObserved.Start).")
    } elseif (-not $firstObserved) {
        $lines.Add('Monitor was not watching during quiet hours.')
    } elseif ($s.UnmonitoredSeconds -gt 0) {
        $lines.Add("Monitor not running for $(& $d $s.UnmonitoredSeconds) overnight.")
    }

    $since = if ($CurrentSince) { " since $(& $hm ([DateTimeOffset]$CurrentSince))" } else { '' }
    $lines.Add("Now: $CurrentState$since.")

    @{ Title = $title; Message = ($lines -join "`n"); Priority = $(if ($isDown) { 2 } else { 0 }) }
}
