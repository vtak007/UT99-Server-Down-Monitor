#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\UT99Monitor.psm1') -Force
    $script:Monitor = Join-Path (Split-Path $PSScriptRoot -Parent) 'UT99-Monitor.ps1'

    function New-TestIni([string]$Dir, [switch]$NoKeys) {
        $keys = if ($NoKeys) { "UserKey=`nAppToken=" } else { "UserKey=uTEST`nAppToken=aTEST" }
        $p = Join-Path $Dir 'config.ini'
        Set-Content $p "[Probe]`nIntervalSeconds=0`n[Pushover]`n$keys`n[Data]`nDataDir=data"
        $p
    }

    # A probe that returns scripted classifications in order; 'X' throws.
    function New-ScriptedProbe([string[]]$Classes) {
        $queue = [Collections.Generic.Queue[string]]::new([string[]]$Classes)
        {
            $c = $queue.Dequeue()
            if ($c -eq 'X') { throw 'probe exploded' }
            $ok = $c -eq 'UP'
            [pscustomobject]@{
                Classification = $c
                Game = [pscustomobject]@{ Ok = $ok; LatencyMs = 5; Map = $(if ($ok) { 'DM-Codex' }); NumPlayers = 1; MaxPlayers = 14; QueryId = 3; Error = $(if (-not $ok) { 'no reply' }) }
                HostPing = $(if (-not $ok) { @{ Ok = $true; LatencyMs = 10 } }); LinkPings = $null
                Snapshot = $(if ($ok) { @{ Map = 'DM-Codex'; NumPlayers = 1; MaxPlayers = 14 } })
            }
        }.GetNewClosure()
    }

    function New-FakeTransport {
        $t = [pscustomobject]@{ Sends = [Collections.Generic.List[object]]::new() }
        $t | Add-Member ScriptMethod Send { param($Msg) $this.Sends.Add($Msg); @{ Ok = $true; Receipt = 'r1'; Retryable = $false; Error = $null } }
        $t | Add-Member ScriptMethod GetReceipt { param($R) @{ Ok = $true; Acknowledged = $false; Expired = $false } }
        $t | Add-Member ScriptMethod CancelReceipt { param($R) @{ Ok = $true } }
        $t
    }
}

Describe 'UT99-Monitor.ps1' {
    BeforeEach {
        $script:Dir = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory $Dir | Out-Null
        $script:Mutex = "Local\UT99MonitorTest-$([guid]::NewGuid().ToString('N'))"
    }

    It 'writes MONITOR_STARTED, UP, GAME_DOWN, MONITOR_STOPPED for scripted UP x3 GD x3' {
        $ini = New-TestIni $Dir
        $tx = New-FakeTransport
        & $Monitor -ConfigPath $ini -MaxCycles 6 -Probe (New-ScriptedProbe @('UP', 'UP', 'UP', 'GAME_DOWN', 'GAME_DOWN', 'GAME_DOWN')) -Transport $tx -MutexName $Mutex
        $rows = @(Read-StateChanges -CsvPath (Join-Path $Dir 'data\state-changes.csv'))
        ($rows | ForEach-Object NewState) -join ',' | Should -Be 'MONITOR_STARTED,UP,GAME_DOWN,MONITOR_STOPPED'
        @($tx.Sends | Where-Object Title -eq 'UT99 CRASHED (VPS up)').Count | Should -BeLessOrEqual 1
    }

    It 'one poll log line per cycle' {
        $ini = New-TestIni $Dir
        & $Monitor -ConfigPath $ini -MaxCycles 4 -Probe (New-ScriptedProbe @('UP', 'UP', 'UP', 'UP')) -Transport (New-FakeTransport) -MutexName $Mutex
        $lines = Get-Content (Get-ChildItem (Join-Path $Dir 'data\raw') -Filter 'poll-*.log').FullName
        $lines.Count | Should -Be 4
    }

    It 'a probe that throws once does not stop the loop' {
        $ini = New-TestIni $Dir
        & $Monitor -ConfigPath $ini -MaxCycles 4 -Probe (New-ScriptedProbe @('UP', 'X', 'UP', 'UP')) -Transport (New-FakeTransport) -MutexName $Mutex
        (Get-Content (Get-ChildItem (Join-Path $Dir 'data\raw') -Filter 'poll-*.log').FullName).Count | Should -Be 3
        (Get-Content (Join-Path $Dir 'data\monitor.log') -Raw) | Should -Match 'CYCLE_ERROR.*probe exploded'
    }

    It 'a restart after a kill infers MONITOR_GAP' {
        $ini = New-TestIni $Dir
        $csv = Join-Path $Dir 'data\state-changes.csv'
        Add-StateChangeRow -CsvPath $csv -Transition ([pscustomobject]@{ Timestamp = [DateTimeOffset]::Now.AddHours(-1); NewState = 'UP'
                PreviousState = 'MONITOR_STARTED'; PreviousDurationSeconds = 1; Snapshot = $null; Notes = '' })
        & $Monitor -ConfigPath $ini -MaxCycles 1 -Probe (New-ScriptedProbe @('UP')) -Transport (New-FakeTransport) -MutexName $Mutex
        (@(Read-StateChanges -CsvPath $csv) | ForEach-Object NewState) -join ',' | Should -Be 'UP,MONITOR_GAP,MONITOR_STARTED,MONITOR_STOPPED'
    }

    It 'second instance exits 0 while the mutex is held' {
        $ini = New-TestIni $Dir -NoKeys
        $m = [Threading.Mutex]::new($false, $Mutex)
        try {
            $m.WaitOne(0) | Should -BeTrue
            $out = & pwsh -NoProfile -NonInteractive -File $Monitor -ConfigPath $ini -MaxCycles 1 -MutexName $Mutex 2>&1
            $LASTEXITCODE | Should -Be 0
        } finally { $m.ReleaseMutex(); $m.Dispose() }
        (Get-Content (Join-Path $Dir 'data\monitor.log') -Raw) | Should -Match 'ALREADY_RUNNING'
        Test-Path (Join-Path $Dir 'data\state-changes.csv') | Should -BeFalse
    }

    It 'exits 1 with Setup.ps1 hint when keys are empty' {
        $ini = New-TestIni $Dir -NoKeys
        $out = & pwsh -NoProfile -NonInteractive -File $Monitor -ConfigPath $ini -MaxCycles 1 -MutexName $Mutex 2>&1
        $LASTEXITCODE | Should -Be 1
        ($out -join "`n") | Should -Match 'Setup\.ps1'
    }
}
