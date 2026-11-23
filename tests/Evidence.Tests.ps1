#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\UT99Monitor.psm1') -Force
    $script:Header = 'timestamp_local,timestamp_utc,new_state,previous_state,previous_duration_seconds,map,numplayers,maxplayers,notes'
    $script:T0 = [DateTimeOffset]::new(2026, 11, 23, 14, 0, 0, [TimeSpan]::FromHours(-5))

    function New-T([DateTimeOffset]$At, [string]$State, [string]$Prev = 'UP', $Dur = 90, [string]$Notes = '') {
        [pscustomobject]@{
            Timestamp = $At; NewState = $State; PreviousState = $Prev; PreviousDurationSeconds = $Dur
            Snapshot = @{ Map = 'DM-Codex'; NumPlayers = 3; MaxPlayers = 14 }; Notes = $Notes
        }
    }

    $script:UpCycle = [pscustomobject]@{
        Classification = 'UP'
        Game = [pscustomobject]@{ Ok = $true; LatencyMs = 61; Map = 'DM-Codex'; NumPlayers = 3; MaxPlayers = 14; QueryId = 15; Error = $null }
        HostPing = $null; LinkPings = $null
        Snapshot = @{ Map = 'DM-Codex'; NumPlayers = 3; MaxPlayers = 14 }
    }
}

Describe 'state-changes.csv' {
    BeforeEach {
        $script:Dir = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory $Dir | Out-Null
        $script:Csv = Join-Path $Dir 'state-changes.csv'
    }

    It 'creates the CSV with the exact header then appends' {
        Add-StateChangeRow -CsvPath $Csv -Transition (New-T $T0 'GAME_DOWN')
        Add-StateChangeRow -CsvPath $Csv -Transition (New-T $T0.AddMinutes(5) 'UP' 'GAME_DOWN' 300)
        $lines = Get-Content $Csv
        $lines[0] | Should -Be $Header
        $lines.Count | Should -Be 3
    }

    It 'round-trips a transition' {
        Add-StateChangeRow -CsvPath $Csv -Transition (New-T $T0 'GAME_DOWN' -Notes 'a, "quoted" note')
        $r = @(Read-StateChanges -CsvPath $Csv)
        $r.Count | Should -Be 1
        $r[0].TimestampUtc | Should -Be $T0
        $r[0].NewState | Should -Be 'GAME_DOWN'
        $r[0].PreviousState | Should -Be 'UP'
        $r[0].PreviousDurationSeconds | Should -Be 90
        $r[0].Map | Should -Be 'DM-Codex'
        $r[0].NumPlayers | Should -Be 3
        $r[0].Notes | Should -Be 'a, "quoted" note'
        (Get-Content $Csv)[1] | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2},\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z,'
    }

    It 'BLIP row has an empty previous_duration_seconds field' {
        Add-StateChangeRow -CsvPath $Csv -Transition (New-T $T0 'BLIP' 'UP' $null 'blip: 1 failed cycle(s) (GAME_DOWN), 30s')
        (Get-Content $Csv)[1] | Should -Match ',BLIP,UP,,DM-Codex,'
        (Read-StateChanges -CsvPath $Csv)[0].PreviousDurationSeconds | Should -BeNullOrEmpty
    }

    It 'retries while the CSV is locked' {
        Add-StateChangeRow -CsvPath $Csv -Transition (New-T $T0 'UP')
        $locked = [Threading.ManualResetEventSlim]::new($false)
        $job = Start-ThreadJob -ArgumentList $Csv, $locked -ScriptBlock {
            param($path, $signal)
            $fs = [IO.File]::Open($path, 'Open', 'ReadWrite', 'None')
            $signal.Set()
            Start-Sleep -Milliseconds 600
            $fs.Dispose()
        }
        $locked.Wait(5000) | Should -BeTrue
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Add-StateChangeRow -CsvPath $Csv -Transition (New-T $T0.AddMinutes(1) 'GAME_DOWN')
        $sw.Stop()
        $job | Wait-Job | Remove-Job
        $sw.ElapsedMilliseconds | Should -BeGreaterOrEqual 500
        @(Read-StateChanges -CsvPath $Csv).Count | Should -Be 2
    }

    It 'skips a truncated final line with a warning' {
        Add-StateChangeRow -CsvPath $Csv -Transition (New-T $T0 'UP')
        [IO.File]::AppendAllText($Csv, '2026-11-23T03:1')
        $r = @(Read-StateChanges -CsvPath $Csv -WarningVariable w -WarningAction SilentlyContinue)
        $r.Count | Should -Be 1
        $w.Count | Should -Be 1
    }

    It 'reads a missing CSV as no rows' {
        @(Read-StateChanges -CsvPath (Join-Path $Dir 'none.csv')).Count | Should -Be 0
    }
}

Describe 'raw poll log' {
    BeforeEach {
        $script:Dir = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory $Dir | Out-Null
    }

    It 'poll line format' {
        Add-PollLogLine -DataDir $Dir -Now $T0 -Cycle $UpCycle
        $f = Join-Path $Dir ('raw\poll-{0}.log' -f $T0.ToLocalTime().ToString('yyyy-MM'))
        $line = Get-Content $f
        $line | Should -Match '^\S+\tUP\tgame=ok:\d+ms\thost=skip\tlink=skip\tmap=.*\tplayers=\d+/\d+\tqid=\d+$'
        $line | Should -Match 'qid=15$'
    }

    It 'logs failed probes with host and link results' {
        $c = [pscustomobject]@{
            Classification = 'HOST_DOWN'
            Game = [pscustomobject]@{ Ok = $false; LatencyMs = 0; Map = $null; NumPlayers = 0; MaxPlayers = 0; QueryId = 0; Error = 'no reply after 3000ms' }
            HostPing = @{ Ok = $false; LatencyMs = 0 }
            LinkPings = @(@{ Target = '1.1.1.1'; Ok = $true; LatencyMs = 12 })
            Snapshot = $null
        }
        Add-PollLogLine -DataDir $Dir -Now $T0 -Cycle $c
        $line = Get-Content (Get-ChildItem (Join-Path $Dir 'raw') -Filter 'poll-*.log').FullName
        $line | Should -Match '\tHOST_DOWN\tgame=fail:no reply after 3000ms\thost=fail\tlink=1\.1\.1\.1:ok:12ms\tmap=\tplayers=\tqid=$'
    }

    It 'Get-LastPollTime returns the last line time' {
        Add-PollLogLine -DataDir $Dir -Now $T0 -Cycle $UpCycle
        Add-PollLogLine -DataDir $Dir -Now $T0.AddSeconds(30) -Cycle $UpCycle
        Get-LastPollTime -DataDir $Dir | Should -Be $T0.AddSeconds(30)
    }

    It 'Get-LastPollTime returns null with no logs' {
        Get-LastPollTime -DataDir $Dir | Should -BeNullOrEmpty
    }

    It 'prunes logs older than 12 months only' {
        $raw = Join-Path $Dir 'raw'
        New-Item -ItemType Directory $raw | Out-Null
        'x' | Set-Content (Join-Path $raw 'poll-2025-10.log')
        'x' | Set-Content (Join-Path $raw 'poll-2025-11.log')
        'x' | Set-Content (Join-Path $raw 'notes.txt')
        Remove-ExpiredPollLogs -DataDir $Dir -Now $T0 -RetentionMonths 12
        Test-Path (Join-Path $raw 'poll-2025-10.log') | Should -BeFalse
        Test-Path (Join-Path $raw 'poll-2025-11.log') | Should -BeTrue
        Test-Path (Join-Path $raw 'notes.txt') | Should -BeTrue
    }
}

Describe 'Start-MonitorSession' {
    BeforeEach {
        $script:Dir = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory $Dir | Out-Null
        $script:Csv = Join-Path $Dir 'state-changes.csv'
    }

    It 'infers MONITOR_GAP from the last poll time when the last row is not MONITOR_STOPPED' {
        Add-StateChangeRow -CsvPath $Csv -Transition (New-T $T0 'UP' 'MONITOR_STARTED' 5)
        Add-PollLogLine -DataDir $Dir -Now $T0.AddMinutes(10) -Cycle $UpCycle
        $now = $T0.AddMinutes(70)
        $g = Start-MonitorSession -CsvPath $Csv -DataDir $Dir -Now $now
        $rows = @(Read-StateChanges -CsvPath $Csv)
        ($rows | ForEach-Object NewState) -join ',' | Should -Be 'UP,MONITOR_GAP,MONITOR_STARTED'
        $rows[1].TimestampUtc | Should -Be $T0.AddMinutes(10)
        $rows[1].PreviousState | Should -Be 'UP'
        $rows[1].PreviousDurationSeconds | Should -Be 600
        $rows[1].Notes | Should -Be 'inferred: monitor ended without MONITOR_STOPPED'
        $rows[2].PreviousState | Should -Be 'MONITOR_GAP'
        $rows[2].PreviousDurationSeconds | Should -Be 3600
        $g.GapStart | Should -Be $T0.AddMinutes(10)
        $g.GapSeconds | Should -Be 3600
    }

    It 'uses the last row time when there is no poll log' {
        Add-StateChangeRow -CsvPath $Csv -Transition (New-T $T0 'UP' 'MONITOR_STARTED' 5)
        $g = Start-MonitorSession -CsvPath $Csv -DataDir $Dir -Now $T0.AddMinutes(5)
        $g.GapStart | Should -Be $T0
    }

    It 'no gap row after a clean MONITOR_STOPPED' {
        Add-StateChangeRow -CsvPath $Csv -Transition (New-T $T0 'UP' 'MONITOR_STARTED' 5)
        Add-MonitorStoppedRow -CsvPath $Csv -Now $T0.AddMinutes(1) -CurrentState 'UP' -CurrentSince $T0
        $g = Start-MonitorSession -CsvPath $Csv -DataDir $Dir -Now $T0.AddMinutes(2)
        $rows = @(Read-StateChanges -CsvPath $Csv)
        ($rows | ForEach-Object NewState) -join ',' | Should -Be 'UP,MONITOR_STOPPED,MONITOR_STARTED'
        $rows[1].PreviousDurationSeconds | Should -Be 60
        $g.GapStart | Should -BeNullOrEmpty
    }

    It 'no gap row on an empty/new CSV' {
        $g = Start-MonitorSession -CsvPath $Csv -DataDir $Dir -Now $T0
        (@(Read-StateChanges -CsvPath $Csv) | ForEach-Object NewState) -join ',' | Should -Be 'MONITOR_STARTED'
        $g.GapStart | Should -BeNullOrEmpty
    }

    It 'Write-MonitorLog appends a timestamped line' {
        Write-MonitorLog -DataDir $Dir -Now $T0 -Message 'hello'
        (Get-Content (Join-Path $Dir 'monitor.log')) | Should -Match '^\S+\thello$'
    }
}
