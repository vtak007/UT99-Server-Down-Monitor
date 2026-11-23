#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\UT99Monitor.psm1') -Force
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
}

Describe 'Read-MonitorConfig' {
    It 'reads config.template with spec defaults' {
        $c = Read-MonitorConfig -Path (Join-Path $RepoRoot 'config.template')
        $c.ServerAddress | Should -Be '74.91.119.21'
        $c.QueryPort | Should -Be 7778
        $c.GamePort | Should -Be 7777
        $c.IntervalSeconds | Should -Be 30
        $c.GameTimeoutMs | Should -Be 3000
        ($c.LinkTargets -join ',') | Should -Be '1.1.1.1,8.8.8.8'
        $c.QuietStart | Should -Be ([TimeSpan]'01:00')
        $c.QuietEnd | Should -Be ([TimeSpan]'09:00')
        $c.EmergencyRetrySeconds | Should -Be 300
        $c.EmergencyExpireSeconds | Should -Be 10800
        $c.ReminderMinutes | Should -Be 15
        $c.ReceiptPollSeconds | Should -Be 60
        $c.RawRetentionMonths | Should -Be 12
        $c.PushoverUserKey | Should -Be ''
    }

    It 'fills missing keys from defaults' {
        $p = Join-Path $TestDrive 'min.ini'
        Set-Content $p "[Server]`nAddress=10.0.0.1"
        $c = Read-MonitorConfig -Path $p
        $c.ServerAddress | Should -Be '10.0.0.1'
        $c.UpThreshold | Should -Be 3
        $c.DownThreshold | Should -Be 3
    }

    It "resolves DataDir relative to the ini's folder" {
        $p = Join-Path $TestDrive 'rel.ini'
        Set-Content $p "[Data]`nDataDir=data"
        $c = Read-MonitorConfig -Path $p
        [IO.Path]::IsPathRooted($c.DataDir) | Should -BeTrue
        $c.DataDir | Should -Be (Join-Path $TestDrive 'data')
    }

    It 'rejects EmergencyRetrySeconds below 30' {
        $p = Join-Path $TestDrive 'r.ini'
        Set-Content $p "[Notify]`nEmergencyRetrySeconds=29"
        { Read-MonitorConfig -Path $p } | Should -Throw '*EmergencyRetrySeconds*'
    }

    It 'rejects EmergencyExpireSeconds above 10800' {
        $p = Join-Path $TestDrive 'e.ini'
        Set-Content $p "[Notify]`nEmergencyExpireSeconds=10801"
        { Read-MonitorConfig -Path $p } | Should -Throw '*EmergencyExpireSeconds*'
    }

    It 'missing file throws mentioning Setup.ps1' {
        { Read-MonitorConfig -Path (Join-Path $TestDrive 'nope.ini') } | Should -Throw '*Setup.ps1*'
    }

    It 'ignores ; comments and blank lines' {
        $p = Join-Path $TestDrive 'c.ini'
        Set-Content $p "; top comment`n`n[Probe]`n; IntervalSeconds=99`nIntervalSeconds=45  ; trailing`n"
        (Read-MonitorConfig -Path $p).IntervalSeconds | Should -Be 45
    }
}
