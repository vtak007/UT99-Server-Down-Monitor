#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\UT99Monitor.psm1') -Force
    $script:T0 = [DateTimeOffset]::new(2026, 11, 23, 14, 0, 0, [TimeSpan]::FromHours(-5))

    # Steps the state through the given classifications at 30 s intervals starting at $Start.
    # Returns all transitions emitted. Abbreviations: U=UP, G=GAME_DOWN, H=HOST_DOWN, L=LINK_DOWN.
    function Invoke-Cycles($State, [DateTimeOffset]$Start, [string[]]$Classes) {
        $map = @{ U = 'UP'; G = 'GAME_DOWN'; H = 'HOST_DOWN'; L = 'LINK_DOWN' }
        $out = @()
        for ($i = 0; $i -lt $Classes.Count; $i++) {
            $c = $map[$Classes[$i]]
            $snap = if ($c -eq 'UP') { @{ Map = "DM-Map$i"; NumPlayers = $i; MaxPlayers = 14 } } else { $null }
            $cycle = [pscustomobject]@{ Classification = $c; Snapshot = $snap }
            $out += @(Step-MonitorState -State $State -Cycle $cycle -Now $Start.AddSeconds(30 * $i))
        }
        , $out
    }

    function New-TestState { New-MonitorState -StartedAt $T0.AddSeconds(-1) -DownThreshold 3 -UpThreshold 3 }
    function At([int]$cycle) { $T0.AddSeconds(30 * $cycle) }
}

Describe 'Step-MonitorState' {
    It 'declares UP from MONITOR_STARTED after 3 successes at the first success time' {
        $s = New-TestState
        $t = Invoke-Cycles $s $T0 @('U', 'U', 'U')
        $t.Count | Should -Be 1
        $t[0].NewState | Should -Be 'UP'
        $t[0].PreviousState | Should -Be 'MONITOR_STARTED'
        $t[0].Timestamp | Should -Be (At 0)
        $t[0].PreviousDurationSeconds | Should -Be 1
        $t[0].RecoveredFrom | Should -BeNullOrEmpty
        $s.Current | Should -Be 'UP'
    }

    It 'declares GAME_DOWN after 3 failures timestamped at the first failure' {
        $s = New-TestState
        $t = Invoke-Cycles $s $T0 @('U', 'U', 'U', 'G', 'G', 'G')
        $t.Count | Should -Be 2
        $t[1].NewState | Should -Be 'GAME_DOWN'
        $t[1].Timestamp | Should -Be (At 3)
        $t[1].PreviousState | Should -Be 'UP'
        $t[1].PreviousDurationSeconds | Should -Be 90
        $s.OutageStart | Should -Be (At 3)
    }

    It 'two failures then a success while starting declares nothing' {
        $s = New-TestState
        $t = Invoke-Cycles $s $T0 @('G', 'G', 'U')
        $t.Count | Should -Be 0
    }

    It 'GAME, HOST, GAME resolves to GAME_DOWN' {
        $s = New-TestState
        $t = Invoke-Cycles $s $T0 @('U', 'U', 'U', 'G', 'H', 'G')
        $t[-1].NewState | Should -Be 'GAME_DOWN'
    }

    It 'HOST, GAME, HOST resolves to HOST_DOWN' {
        $s = New-TestState
        $t = Invoke-Cycles $s $T0 @('U', 'U', 'U', 'H', 'G', 'H')
        $t[-1].NewState | Should -Be 'HOST_DOWN'
        $t[-1].Timestamp | Should -Be (At 3)
    }

    It 'recovery carries RecoveredFrom, OutageStart and PreviousDurationSeconds' {
        $s = New-TestState
        $t = Invoke-Cycles $s $T0 @('U', 'U', 'U', 'G', 'G', 'G', 'G', 'U', 'U', 'U')
        $up = $t[-1]
        $up.NewState | Should -Be 'UP'
        $up.Timestamp | Should -Be (At 7)
        $up.RecoveredFrom | Should -Be 'GAME_DOWN'
        $up.OutageStart | Should -Be (At 3)
        $up.PreviousDurationSeconds | Should -Be 120
        $up.Snapshot.Map | Should -Be 'DM-Map9'
        $s.OutageStart | Should -BeNullOrEmpty
    }

    It 'a single LINK_DOWN emits UNKNOWN at that cycle with cause=LINK_DOWN' {
        $s = New-TestState
        $t = Invoke-Cycles $s $T0 @('U', 'U', 'U', 'L')
        $t[-1].NewState | Should -Be 'UNKNOWN'
        $t[-1].Timestamp | Should -Be (At 3)
        $t[-1].Notes | Should -Be 'cause=LINK_DOWN'
        $t[-1].PreviousState | Should -Be 'UP'
    }

    It 'repeated LINK_DOWN emits one row' {
        $s = New-TestState
        $t = Invoke-Cycles $s $T0 @('U', 'U', 'U', 'L', 'L', 'L', 'L')
        @($t | Where-Object NewState -eq 'UNKNOWN').Count | Should -Be 1
    }

    It 'LINK_DOWN suspends the failure count' {
        $s = New-TestState
        $t = Invoke-Cycles $s $T0 @('U', 'U', 'U', 'G', 'L', 'G', 'G')
        ($t | ForEach-Object NewState) -join ',' | Should -Be 'UP,UNKNOWN,GAME_DOWN'
        $t[2].Timestamp | Should -Be (At 5)
        $t[2].Timestamp | Should -BeGreaterOrEqual $t[1].Timestamp
        $t[2].Interrupted | Should -BeFalse
    }

    It 'outage across a blind window is GAME_DOWN, UNKNOWN, GAME_DOWN(Interrupted)' {
        $s = New-TestState
        $t = Invoke-Cycles $s $T0 @('U', 'U', 'U', 'G', 'G', 'G', 'L', 'G', 'G', 'G')
        ($t | ForEach-Object NewState) -join ',' | Should -Be 'UP,GAME_DOWN,UNKNOWN,GAME_DOWN'
        $t[3].Interrupted | Should -BeTrue
        $t[3].PreviousState | Should -Be 'UNKNOWN'
        $s.OutageStart | Should -Be (At 3)
    }

    It 'UP observed after a blind outage reports RecoveredFrom' {
        $s = New-TestState
        $t = Invoke-Cycles $s $T0 @('U', 'U', 'U', 'G', 'G', 'G', 'L', 'U', 'U', 'U')
        $t[-1].NewState | Should -Be 'UP'
        $t[-1].PreviousState | Should -Be 'UNKNOWN'
        $t[-1].RecoveredFrom | Should -Be 'GAME_DOWN'
        $t[-1].OutageStart | Should -Be (At 3)
        $t[-1].Interrupted | Should -BeTrue
    }

    It 'UP, UNKNOWN, UP is not a recovery' {
        $s = New-TestState
        $t = Invoke-Cycles $s $T0 @('U', 'U', 'U', 'L', 'U', 'U', 'U')
        $t[-1].NewState | Should -Be 'UP'
        $t[-1].RecoveredFrom | Should -BeNullOrEmpty
    }

    It 'GAME_DOWN to HOST_DOWN needs 3 consecutive HOST cycles' {
        $s = New-TestState
        $t = Invoke-Cycles $s $T0 @('U', 'U', 'U', 'G', 'G', 'G', 'H', 'G', 'H', 'H', 'H')
        @($t | Where-Object NewState -eq 'HOST_DOWN').Count | Should -Be 1
        $hd = $t | Where-Object NewState -eq 'HOST_DOWN'
        $hd.Timestamp | Should -Be (At 8)
        $hd.PreviousState | Should -Be 'GAME_DOWN'
        $s.OutageStart | Should -Be (At 3)
    }

    It "LastGoodSnapshot survives into the down transition's Snapshot" {
        $s = New-TestState
        $t = Invoke-Cycles $s $T0 @('U', 'U', 'U', 'G', 'G', 'G')
        $t[-1].Snapshot.Map | Should -Be 'DM-Map2'
        $t[-1].Snapshot.NumPlayers | Should -Be 2
    }

    It "UP x3, GD, GD, UP emits one BLIP at the first failure" {
        $s = New-TestState
        $t = Invoke-Cycles $s $T0 @('U', 'U', 'U', 'G', 'G', 'U')
        $t.Count | Should -Be 2
        $b = $t[1]
        $b.NewState | Should -Be 'BLIP'
        $b.Timestamp | Should -Be (At 3)
        $b.PreviousState | Should -Be 'UP'
        $b.PreviousDurationSeconds | Should -BeNullOrEmpty
        $b.Notes | Should -Be 'blip: 2 failed cycle(s) (GAME_DOWN), 60s'
        $s.Current | Should -Be 'UP'
        $s.CurrentSince | Should -Be (At 0)
    }

    It 'BLIP notes list mixed classes once each' {
        $s = New-TestState
        $t = Invoke-Cycles $s $T0 @('U', 'U', 'U', 'G', 'H', 'U')
        $t[-1].Notes | Should -Be 'blip: 2 failed cycle(s) (GAME_DOWN,HOST_DOWN), 60s'
    }

    It 'UP x3, GD, LINK, UP emits UNKNOWN but no BLIP' {
        $s = New-TestState
        $t = Invoke-Cycles $s $T0 @('U', 'U', 'U', 'G', 'L', 'U')
        @($t | Where-Object NewState -eq 'BLIP').Count | Should -Be 0
        @($t | Where-Object NewState -eq 'UNKNOWN').Count | Should -Be 1
    }

    It 'two failures from MONITOR_STARTED then UP emits no BLIP' {
        $s = New-TestState
        $t = Invoke-Cycles $s $T0 @('G', 'G', 'U', 'U', 'U')
        ($t | ForEach-Object NewState) -join ',' | Should -Be 'UP'
    }
}
