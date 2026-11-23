#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\UT99Monitor.psm1') -Force
    $script:T0 = [DateTimeOffset]::new(2026, 11, 1, 0, 0, 0, [TimeSpan]::Zero)
    function Hrs([double]$hours) { $T0.AddHours($hours) }
    # Builds an in-memory row as Read-StateChanges returns it. Time given in hours after T0.
    function Row([double]$hours, [string]$state, [string]$notes = '') {
        [pscustomobject]@{ TimestampLocal = (Hrs $hours); TimestampUtc = (Hrs $hours); NewState = $state; PreviousState = ''
            PreviousDurationSeconds = $null; Map = 'DM-Codex'; NumPlayers = 1; MaxPlayers = 14; Notes = $notes }
    }
}

Describe 'Format-Duration' {
    It '<Secs>s formats as <Text>' -ForEach @(
        @{ Secs = 45; Text = '45s' }
        @{ Secs = 720; Text = '12m' }
        @{ Secs = 4320; Text = '1h 12m' }
        @{ Secs = 7200; Text = '2h' }
        @{ Secs = 183600; Text = '2d 3h' }
        @{ Secs = 0; Text = '0s' }
    ) {
        Format-Duration -Span ([TimeSpan]::FromSeconds($Secs)) | Should -Be $Text
    }
}

Describe 'Get-StateIntervals' {
    It 'intervals are clipped to the period' {
        $rows = @((Row -5 'UP'), (Row 2 'GAME_DOWN'), (Row 3 'UP'))
        $i = @(Get-StateIntervals -Rows $rows -From (Hrs 0) -To (Hrs 10))
        ($i | ForEach-Object State) -join ',' | Should -Be 'UP,GAME_DOWN,UP'
        $i[0].Start | Should -Be (Hrs 0)
        $i[0].Seconds | Should -Be 7200
        $i[2].End | Should -Be (Hrs 10)
    }

    It 'a BLIP inside an UP interval does not split it' {
        $rows = @((Row 0 'UP'), (Row 4 'BLIP' 'blip: 1 failed cycle(s) (GAME_DOWN), 30s'))
        $i = @(Get-StateIntervals -Rows $rows -From (Hrs 0) -To (Hrs 10))
        $i.Count | Should -Be 1
        $i[0].Seconds | Should -Be 36000
        @(Get-Blips -Rows $rows -From (Hrs 0) -To (Hrs 10)).Count | Should -Be 1
    }
}

Describe 'Get-Outages' {
    It 'GAME to HOST class change is one outage with both classes and split seconds' {
        $rows = @((Row 0 'UP'), (Row 1 'GAME_DOWN'), (Row 1.5 'HOST_DOWN'), (Row 2 'UP'))
        $o = @(Get-Outages -Intervals (Get-StateIntervals -Rows $rows -From (Hrs 0) -To (Hrs 5)))
        $o.Count | Should -Be 1
        $o[0].Classes -join ',' | Should -Be 'GAME_DOWN,HOST_DOWN'
        $o[0].GameSeconds | Should -Be 1800
        $o[0].HostSeconds | Should -Be 1800
        $o[0].Seconds | Should -Be 3600
        $o[0].End | Should -Be (Hrs 2)
    }

    It 'GAME_DOWN, UNKNOWN, GAME_DOWN merges into one interrupted outage excluding blind time' {
        $rows = @((Row 0 'UP'), (Row 1 'GAME_DOWN'), (Row 2 'UNKNOWN'), (Row 3 'GAME_DOWN'), (Row 4 'UP'))
        $o = @(Get-Outages -Intervals (Get-StateIntervals -Rows $rows -From (Hrs 0) -To (Hrs 5)))
        $o.Count | Should -Be 1
        $o[0].Interrupted | Should -BeTrue
        $o[0].Seconds | Should -Be 7200
        $o[0].Start | Should -Be (Hrs 1)
        $o[0].End | Should -Be (Hrs 4)
    }

    It 'GAME_DOWN, UNKNOWN, UP is a single uninterrupted outage ending at the blind start' {
        $rows = @((Row 0 'UP'), (Row 1 'GAME_DOWN'), (Row 2 'UNKNOWN'), (Row 3 'UP'))
        $o = @(Get-Outages -Intervals (Get-StateIntervals -Rows $rows -From (Hrs 0) -To (Hrs 5)))
        $o.Count | Should -Be 1
        $o[0].End | Should -Be (Hrs 2)
        $o[0].Interrupted | Should -BeTrue
    }

    It 'ongoing outage has End null and runs to To' {
        $rows = @((Row 0 'UP'), (Row 4 'HOST_DOWN'))
        $o = @(Get-Outages -Intervals (Get-StateIntervals -Rows $rows -From (Hrs 0) -To (Hrs 5)))
        $o[0].End | Should -BeNullOrEmpty
        $o[0].Seconds | Should -Be 3600
    }
}

Describe 'Get-DowntimeSummary' {
    It 'uptime excludes UNKNOWN and MONITOR_GAP from the denominator' {
        $rows = @((Row 0 'UP'), (Row 9 'GAME_DOWN'), (Row 10 'UNKNOWN'), (Row 15 'MONITOR_GAP'))
        $s = Get-DowntimeSummary -Rows $rows -From (Hrs 0) -To (Hrs 24)
        $s.ObservedSeconds | Should -Be (10 * 3600)
        $s.UnknownSeconds | Should -Be (5 * 3600)
        $s.UnmonitoredSeconds | Should -Be (9 * 3600)
        $s.UptimePercent | Should -Be 90
        $s.GameSeconds | Should -Be 3600
        @($s.Outages).Count | Should -Be 1
        $s.Longest.Seconds | Should -Be 3600
    }

    It 'counts time before the first row as unmonitored' {
        $rows = @((Row 6 'UP'))
        $s = Get-DowntimeSummary -Rows $rows -From (Hrs 0) -To (Hrs 10)
        $s.UnmonitoredSeconds | Should -Be (6 * 3600)
        $s.UptimePercent | Should -Be 100
    }

    It 'uptime is null when nothing was observed' {
        (Get-DowntimeSummary -Rows @() -From (Hrs 0) -To (Hrs 1)).UptimePercent | Should -BeNullOrEmpty
    }
}

Describe 'Get-DowntimeReport.ps1' {
    It "report script output contains 'Method' and 'first failing'" {
        $ini = Join-Path $TestDrive 'config.ini'
        Set-Content $ini "[Data]`nDataDir=data"
        $csv = Join-Path $TestDrive 'data\state-changes.csv'
        $mk = { param($t, $s, $n = '') [pscustomobject]@{ Timestamp = $t; NewState = $s; PreviousState = ''; PreviousDurationSeconds = 0; Snapshot = $null; Notes = $n } }
        Add-StateChangeRow -CsvPath $csv -Transition (& $mk (Hrs 0) 'UP')
        Add-StateChangeRow -CsvPath $csv -Transition (& $mk (Hrs 2) 'BLIP' 'blip: 1 failed cycle(s) (GAME_DOWN), 30s')
        Add-StateChangeRow -CsvPath $csv -Transition (& $mk (Hrs 5) 'GAME_DOWN')
        Add-StateChangeRow -CsvPath $csv -Transition (& $mk (Hrs 6) 'UP')
        $script_ = Join-Path (Split-Path $PSScriptRoot -Parent) 'Get-DowntimeReport.ps1'
        $text = (& $script_ -ConfigPath $ini -From (Hrs 0).LocalDateTime -To (Hrs 10).LocalDateTime) -join "`n"
        $text | Should -Match 'Method'
        $text | Should -Match 'first failing'
        $text | Should -Match 'Outages: 1'
        $text | Should -Match 'Brief interruptions'
        $text | Should -Match '90\.00%'
    }
}
