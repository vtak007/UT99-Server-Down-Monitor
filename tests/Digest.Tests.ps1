#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\UT99Monitor.psm1') -Force
    function L([int]$h, [int]$m, [int]$day = 23) { [DateTimeOffset][DateTime]::new(2026, 11, $day, $h, $m, 0, [DateTimeKind]::Local) }
    function Row([DateTimeOffset]$at, [string]$state, [string]$notes = '') {
        [pscustomobject]@{ TimestampLocal = $at; TimestampUtc = $at; NewState = $state; PreviousState = ''
            PreviousDurationSeconds = $null; Map = 'DM-Codex'; NumPlayers = 1; MaxPlayers = 14; Notes = $notes }
    }
    $script:Window = Get-QuietWindow -LocalDate ([DateTime]'2026-11-23') -Start '01:00' -End '09:00'
}

Describe 'New-DigestMessage' {
    It "quiet night yields 'all quiet' at priority 0" {
        $rows = @((Row (L 18 0 22) 'UP'))
        $m = New-DigestMessage -Rows $rows -Window $Window -CurrentState 'UP' -CurrentSince (L 18 0 22) -Now (L 9 0)
        $m.Title | Should -Be 'UT99 overnight: all quiet'
        $m.Priority | Should -Be 0
        $m.Message | Should -Match 'No outages'
    }

    It 'still down at 09:00 yields priority 2 and STILL DOWN title' {
        $rows = @((Row (L 18 0 22) 'UP'), (Row (L 7 0) 'HOST_DOWN'))
        $m = New-DigestMessage -Rows $rows -Window $Window -CurrentState 'HOST_DOWN' -CurrentSince (L 7 0) -Now (L 9 0)
        $m.Title | Should -Be 'UT99 STILL DOWN (HOST_DOWN)'
        $m.Priority | Should -Be 2
        $m.Message | Should -Match 'ongoing'
    }

    It "outage at 03:10 lasting 25m appears in the body as '03:10' and '25m'" {
        $rows = @((Row (L 18 0 22) 'UP'), (Row (L 3 10) 'GAME_DOWN'), (Row (L 3 35) 'UP'))
        $m = New-DigestMessage -Rows $rows -Window $Window -CurrentState 'UP' -CurrentSince (L 3 35) -Now (L 9 0)
        $m.Title | Should -Be 'UT99 overnight: 1 outage(s)'
        $m.Priority | Should -Be 0
        $m.Message | Should -Match '03:10'
        $m.Message | Should -Match '25m'
        $m.Message | Should -Match 'GAME_DOWN'
    }

    It "monitor started at 04:00 inside the window says 'only watching since 04:00'" {
        $rows = @((Row (L 4 0) 'MONITOR_STARTED'), (Row (L 4 0) 'UP'))
        $m = New-DigestMessage -Rows $rows -Window $Window -CurrentState 'UP' -CurrentSince (L 4 0) -Now (L 9 0)
        $m.Message | Should -Match 'only watching since 04:00'
    }

    It 'lists blips without changing the all-quiet title' {
        $rows = @((Row (L 18 0 22) 'UP'), (Row (L 3 12) 'BLIP' 'blip: 1 failed cycle(s) (GAME_DOWN), 30s'), (Row (L 5 40) 'BLIP' 'x'))
        $m = New-DigestMessage -Rows $rows -Window $Window -CurrentState 'UP' -CurrentSince (L 18 0 22) -Now (L 9 0)
        $m.Title | Should -Be 'UT99 overnight: all quiet'
        $m.Message | Should -Match 'Brief interruptions: 03:12, 05:40'
    }

    It 'reports unobserved home-internet time' {
        $rows = @((Row (L 18 0 22) 'UP'), (Row (L 2 0) 'UNKNOWN'), (Row (L 2 20) 'UP'))
        $m = New-DigestMessage -Rows $rows -Window $Window -CurrentState 'UP' -CurrentSince (L 2 20) -Now (L 9 0)
        $m.Message | Should -Match '20m'
        $m.Message | Should -Match 'internet'
    }
}

Describe 'Test-DigestDue' {
    BeforeEach { $script:StatePath = Join-Path $TestDrive "digest-$([guid]::NewGuid()).json" }

    It 'due at 09:00 when never sent' {
        Test-DigestDue -Now (L 9 0) -QuietEnd '09:00' -GraceHours 3 -StatePath $StatePath | Should -BeTrue
    }

    It 'not due before 09:00' {
        Test-DigestDue -Now (L 8 59) -QuietEnd '09:00' -GraceHours 3 -StatePath $StatePath | Should -BeFalse
    }

    It 'not due twice on the same day across a restart' {
        Set-DigestSent -StatePath $StatePath -Now (L 9 0)
        Test-DigestDue -Now (L 9 1) -QuietEnd '09:00' -GraceHours 3 -StatePath $StatePath | Should -BeFalse
    }

    It 'due again the next day' {
        Set-DigestSent -StatePath $StatePath -Now (L 9 0)
        Test-DigestDue -Now (L 9 0 24) -QuietEnd '09:00' -GraceHours 3 -StatePath $StatePath | Should -BeTrue
    }

    It 'due at 10:30 if not yet sent (PC was off)' {
        Test-DigestDue -Now (L 10 30) -QuietEnd '09:00' -GraceHours 3 -StatePath $StatePath | Should -BeTrue
    }

    It 'not due at 12:30 (past grace)' {
        Test-DigestDue -Now (L 12 30) -QuietEnd '09:00' -GraceHours 3 -StatePath $StatePath | Should -BeFalse
    }

    It 'missing or corrupt digest-state.json counts as not sent' {
        Set-Content $StatePath '{ not json'
        Test-DigestDue -Now (L 9 0) -QuietEnd '09:00' -GraceHours 3 -StatePath $StatePath | Should -BeTrue
    }
}
