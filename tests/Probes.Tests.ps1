#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\UT99Monitor.psm1') -Force
    $script:Config = Read-MonitorConfig -Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'config.template')

    $script:GameOk = { [pscustomobject]@{ Ok = $true; LatencyMs = 50; Map = 'DM-Codex'; NumPlayers = 2; MaxPlayers = 14; QueryId = 7; Error = $null } }
    $script:GameFail = { [pscustomobject]@{ Ok = $false; LatencyMs = 0; Map = $null; NumPlayers = 0; MaxPlayers = 0; QueryId = 0; Error = 'no reply' } }

    # Ping fake: answers per-target from a table, and records every target it was asked about.
    function New-PingFake([hashtable]$Answers) {
        $calls = [Collections.Generic.List[string]]::new()
        $probe = {
            param($Target)
            $calls.Add($Target)
            @{ Ok = [bool]$Answers[$Target]; LatencyMs = if ($Answers[$Target]) { 10 } else { 0 } }
        }.GetNewClosure()
        @{ Probe = $probe; Calls = $calls }
    }
}

Describe 'Invoke-ProbeCycle' {
    It 'UP and no pings when game answers' {
        $p = New-PingFake @{}
        $r = Invoke-ProbeCycle -Config $Config -GameProbe $GameOk -PingProbe $p.Probe
        $r.Classification | Should -Be 'UP'
        $p.Calls.Count | Should -Be 0
        $r.HostPing | Should -BeNullOrEmpty
        $r.Snapshot.Map | Should -Be 'DM-Codex'
        $r.Snapshot.NumPlayers | Should -Be 2
        $r.Snapshot.MaxPlayers | Should -Be 14
    }

    It 'GAME_DOWN when game silent and host pings' {
        $p = New-PingFake @{ '74.91.119.21' = $true }
        $r = Invoke-ProbeCycle -Config $Config -GameProbe $GameFail -PingProbe $p.Probe
        $r.Classification | Should -Be 'GAME_DOWN'
        $r.HostPing.Ok | Should -BeTrue
        $r.LinkPings | Should -BeNullOrEmpty
        $r.Snapshot | Should -BeNullOrEmpty
        @($p.Calls) | Should -Be @('74.91.119.21')
    }

    It 'HOST_DOWN when host silent and only 8.8.8.8 answers' {
        $p = New-PingFake @{ '8.8.8.8' = $true }
        $r = Invoke-ProbeCycle -Config $Config -GameProbe $GameFail -PingProbe $p.Probe
        $r.Classification | Should -Be 'HOST_DOWN'
        @($r.LinkPings).Count | Should -Be 2
        @($p.Calls) | Should -Be @('74.91.119.21', '1.1.1.1', '8.8.8.8')
    }

    It 'skips the second link target when the first answers' {
        $p = New-PingFake @{ '1.1.1.1' = $true }
        $r = Invoke-ProbeCycle -Config $Config -GameProbe $GameFail -PingProbe $p.Probe
        $r.Classification | Should -Be 'HOST_DOWN'
        @($p.Calls) | Should -Be @('74.91.119.21', '1.1.1.1')
    }

    It 'LINK_DOWN when host and both link targets are silent' {
        $p = New-PingFake @{}
        $r = Invoke-ProbeCycle -Config $Config -GameProbe $GameFail -PingProbe $p.Probe
        $r.Classification | Should -Be 'LINK_DOWN'
    }
}

Describe 'Test-IcmpEcho' {
    It 'against 127.0.0.1 succeeds' {
        (Test-IcmpEcho -Target '127.0.0.1' -TimeoutMs 1000 -Count 1).Ok | Should -BeTrue
    }

    It 'against 192.0.2.1 (TEST-NET) fails without throwing' {
        { $script:t = Test-IcmpEcho -Target '192.0.2.1' -TimeoutMs 300 -Count 1 } | Should -Not -Throw
        $script:t.Ok | Should -BeFalse
    }
}
