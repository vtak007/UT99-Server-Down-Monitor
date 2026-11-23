# Evidence.ps1 — the append-only state-change CSV, raw poll logs, monitor.log, gap inference, pruning (spec §6.7).

$script:CsvHeader = 'timestamp_local,timestamp_utc,new_state,previous_state,previous_duration_seconds,map,numplayers,maxplayers,notes'
$script:LocalFormat = 'yyyy-MM-ddTHH:mm:sszzz'
$script:UtcFormat = 'yyyy-MM-ddTHH:mm:ssZ'

function Format-LocalTimestamp([DateTimeOffset]$Ts) { $Ts.ToLocalTime().ToString($script:LocalFormat, [Globalization.CultureInfo]::InvariantCulture) }
function Format-UtcTimestamp([DateTimeOffset]$Ts) { $Ts.ToUniversalTime().ToString($script:UtcFormat, [Globalization.CultureInfo]::InvariantCulture) }

function ConvertTo-CsvField($Value) {
    $s = if ($null -eq $Value) { '' } else { ([string]$Value) -replace '[\r\n]+', ' ' }
    if ($s -match '[,"]') { '"' + $s.Replace('"', '""') + '"' } else { $s }
}

function Split-CsvLine([string]$Line) {
    # RFC 4180 single-line split. Returns $null on an unterminated quote.
    $fields = [Collections.Generic.List[string]]::new()
    $sb = [Text.StringBuilder]::new()
    $inQuotes = $false
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $ch = $Line[$i]
        if ($inQuotes) {
            if ($ch -eq '"') {
                if ($i + 1 -lt $Line.Length -and $Line[$i + 1] -eq '"') { [void]$sb.Append('"'); $i++ } else { $inQuotes = $false }
            } else { [void]$sb.Append($ch) }
        } elseif ($ch -eq '"') { $inQuotes = $true }
        elseif ($ch -eq ',') { $fields.Add($sb.ToString()); [void]$sb.Clear() }
        else { [void]$sb.Append($ch) }
    }
    if ($inQuotes) { return $null }
    $fields.Add($sb.ToString())
    , $fields.ToArray()
}

function Invoke-WithFileRetry([scriptblock]$Action, [int]$Attempts = 10, [int]$DelayMs = 250) {
    for ($i = 1; ; $i++) {
        try { return (& $Action) }
        catch [IO.IOException] {
            if ($i -ge $Attempts) { throw }
            Start-Sleep -Milliseconds $DelayMs
        }
    }
}

function Write-MonitorLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataDir, [Parameter(Mandatory)][DateTimeOffset]$Now, [Parameter(Mandatory)][string]$Message)
    if (-not (Test-Path -LiteralPath $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
    $path = Join-Path $DataDir 'monitor.log'
    $line = (Format-LocalTimestamp $Now) + "`t" + ($Message -replace '[\r\n]+', ' ') + "`r`n"
    try { Invoke-WithFileRetry { [IO.File]::AppendAllText($path, $line) } } catch { Write-Warning "monitor.log write failed: $($_.Exception.Message)" }
}

function Add-StateChangeRow {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CsvPath, [Parameter(Mandatory)]$Transition)
    $snap = $Transition.Snapshot
    $fields = @(
        (Format-LocalTimestamp $Transition.Timestamp)
        (Format-UtcTimestamp $Transition.Timestamp)
        $Transition.NewState
        $Transition.PreviousState
        $Transition.PreviousDurationSeconds
        $(if ($snap) { $snap.Map } else { '' })
        $(if ($snap) { $snap.NumPlayers } else { '' })
        $(if ($snap) { $snap.MaxPlayers } else { '' })
        $Transition.Notes
    )
    $row = (($fields | ForEach-Object { ConvertTo-CsvField $_ }) -join ',') + "`r`n"
    $dir = Split-Path $CsvPath -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    try {
        Invoke-WithFileRetry {
            $text = if (Test-Path -LiteralPath $CsvPath) { $row } else { $script:CsvHeader + "`r`n" + $row }
            [IO.File]::AppendAllText($CsvPath, $text)
        }
    } catch {
        Write-MonitorLog -DataDir $dir -Now ([DateTimeOffset]::Now) -Message ('CSV_WRITE_FAILED ' + $row.Trim())
        throw
    }
}

function Read-StateChanges {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CsvPath)
    if (-not (Test-Path -LiteralPath $CsvPath)) { return }
    $text = Invoke-WithFileRetry {
        $fs = [IO.File]::Open($CsvPath, 'Open', 'Read', 'ReadWrite')
        try { [IO.StreamReader]::new($fs).ReadToEnd() } finally { $fs.Dispose() }
    }
    $lineNo = 0
    foreach ($line in ($text -split "`r?`n")) {
        $lineNo++
        if ($line -eq '' -or $line -eq $script:CsvHeader) { continue }
        $f = Split-CsvLine $line
        $local = [DateTimeOffset]::MinValue
        $utc = [DateTimeOffset]::MinValue
        $inv = [Globalization.CultureInfo]::InvariantCulture
        $ok = $null -ne $f -and $f.Count -eq 9 -and
            [DateTimeOffset]::TryParseExact($f[0], $script:LocalFormat, $inv, 'None', [ref]$local) -and
            [DateTimeOffset]::TryParseExact($f[1], $script:UtcFormat, $inv, 'AssumeUniversal', [ref]$utc)
        if (-not $ok) {
            Write-Warning "state-changes.csv line ${lineNo} is malformed and was skipped: $line"
            continue
        }
        [pscustomobject]@{
            TimestampLocal          = $local
            TimestampUtc            = $utc
            NewState                = $f[2]
            PreviousState           = $f[3]
            PreviousDurationSeconds = $(if ($f[4] -ne '') { [int]$f[4] } else { $null })
            Map                     = $f[5]
            NumPlayers              = $(if ($f[6] -ne '') { [int]$f[6] } else { $null })
            MaxPlayers              = $(if ($f[7] -ne '') { [int]$f[7] } else { $null })
            Notes                   = $f[8]
        }
    }
}

function Add-PollLogLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataDir, [Parameter(Mandatory)][DateTimeOffset]$Now, [Parameter(Mandatory)]$Cycle)
    $g = $Cycle.Game
    $game = if ($g.Ok) { "ok:$($g.LatencyMs)ms" } else { 'fail:' + ([string]$g.Error -replace '\s+', ' ') }
    $hostField = if ($null -eq $Cycle.HostPing) { 'skip' } elseif ($Cycle.HostPing.Ok) { "ok:$($Cycle.HostPing.LatencyMs)ms" } else { 'fail' }
    $link = if ($null -eq $Cycle.LinkPings) { 'skip' } else {
        (@($Cycle.LinkPings) | ForEach-Object { if ($_.Ok) { "$($_.Target):ok:$($_.LatencyMs)ms" } else { "$($_.Target):fail" } }) -join ','
    }
    $map = if ($g.Ok) { $g.Map } else { '' }
    $players = if ($g.Ok) { "$($g.NumPlayers)/$($g.MaxPlayers)" } else { '' }
    $qid = if ($g.Ok) { $g.QueryId } else { '' }
    $line = (@((Format-LocalTimestamp $Now), $Cycle.Classification, "game=$game", "host=$hostField", "link=$link",
            "map=$map", "players=$players", "qid=$qid") -join "`t") -replace '[\r\n]', ' '

    $raw = Join-Path $DataDir 'raw'
    if (-not (Test-Path -LiteralPath $raw)) { New-Item -ItemType Directory -Path $raw -Force | Out-Null }
    $path = Join-Path $raw ('poll-{0}.log' -f $Now.ToLocalTime().ToString('yyyy-MM'))
    Invoke-WithFileRetry { [IO.File]::AppendAllText($path, $line + "`r`n") }
}

function Get-LastPollTime {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataDir)
    $raw = Join-Path $DataDir 'raw'
    if (-not (Test-Path -LiteralPath $raw)) { return $null }
    $files = Get-ChildItem -LiteralPath $raw -Filter 'poll-*.log' | Where-Object Name -match '^poll-\d{4}-\d{2}\.log$' | Sort-Object Name -Descending
    foreach ($file in $files) {
        $lines = [IO.File]::ReadAllLines($file.FullName)
        for ($i = $lines.Length - 1; $i -ge 0; $i--) {
            $ts = [DateTimeOffset]::MinValue
            $first = ($lines[$i] -split "`t")[0]
            if ([DateTimeOffset]::TryParseExact($first, $script:LocalFormat, [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$ts)) { return $ts }
        }
    }
    $null
}

function Start-MonitorSession {
    # Writes MONITOR_GAP if the previous run ended without MONITOR_STOPPED, then MONITOR_STARTED.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CsvPath, [Parameter(Mandatory)][string]$DataDir, [Parameter(Mandatory)][DateTimeOffset]$Now)
    $rows = @(Read-StateChanges -CsvPath $CsvPath -WarningAction SilentlyContinue)
    $gapStart = $null
    $prevState = ''
    $prevAt = $null
    if ($rows.Count -gt 0) {
        $last = $rows[-1]
        $prevState = $last.NewState
        $prevAt = $last.TimestampUtc
        if ($last.NewState -ne 'MONITOR_STOPPED') {
            $gapStart = $last.TimestampUtc
            $lastPoll = Get-LastPollTime -DataDir $DataDir
            if ($null -ne $lastPoll -and $lastPoll -gt $gapStart -and $lastPoll -le $Now) { $gapStart = $lastPoll }
            Add-StateChangeRow -CsvPath $CsvPath -Transition ([pscustomobject]@{
                    Timestamp = $gapStart; NewState = 'MONITOR_GAP'; PreviousState = $last.NewState
                    PreviousDurationSeconds = [int][Math]::Max(0, [Math]::Floor(($gapStart - $last.TimestampUtc).TotalSeconds))
                    Snapshot = $null; Notes = 'inferred: monitor ended without MONITOR_STOPPED'
                })
            $prevState = 'MONITOR_GAP'
            $prevAt = $gapStart
        }
    }
    $dur = if ($null -ne $prevAt) { [int][Math]::Max(0, [Math]::Floor(($Now - $prevAt).TotalSeconds)) } else { $null }
    Add-StateChangeRow -CsvPath $CsvPath -Transition ([pscustomobject]@{
            Timestamp = $Now; NewState = 'MONITOR_STARTED'; PreviousState = $prevState
            PreviousDurationSeconds = $dur; Snapshot = $null; Notes = ''
        })
    [pscustomobject]@{
        GapStart   = $gapStart
        GapSeconds = $(if ($null -ne $gapStart) { [int][Math]::Floor(($Now - $gapStart).TotalSeconds) } else { 0 })
    }
}

function Add-MonitorStoppedRow {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CsvPath, [Parameter(Mandatory)][DateTimeOffset]$Now,
        [Parameter(Mandatory)][string]$CurrentState, [Parameter(Mandatory)][DateTimeOffset]$CurrentSince)
    Add-StateChangeRow -CsvPath $CsvPath -Transition ([pscustomobject]@{
            Timestamp = $Now; NewState = 'MONITOR_STOPPED'; PreviousState = $CurrentState
            PreviousDurationSeconds = [int][Math]::Max(0, [Math]::Floor(($Now - $CurrentSince).TotalSeconds))
            Snapshot = $null; Notes = ''
        })
}

function Remove-ExpiredPollLogs {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataDir, [Parameter(Mandatory)][DateTimeOffset]$Now, [int]$RetentionMonths = 12)
    $raw = Join-Path $DataDir 'raw'
    if (-not (Test-Path -LiteralPath $raw)) { return }
    $local = $Now.ToLocalTime()
    $cutoff = $local.Year * 12 + $local.Month - $RetentionMonths
    foreach ($f in Get-ChildItem -LiteralPath $raw -File) {
        if ($f.Name -match '^poll-(\d{4})-(\d{2})\.log$') {
            if (([int]$Matches[1] * 12 + [int]$Matches[2]) -lt $cutoff) { Remove-Item -LiteralPath $f.FullName -Force }
        }
    }
}
