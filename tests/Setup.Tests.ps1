#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0' }

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $Root 'Setup.ps1')    # dot-sourcing loads the helpers without running setup
}

Describe 'Write-ConfigWithKeys' {
    It 'writes keys into a config.ini copied from the template, other lines unchanged' {
        $out = Join-Path $TestDrive 'config.ini'
        Write-ConfigWithKeys -TemplatePath (Join-Path $Root 'config.template') -OutPath $out -UserKey 'uKEY123' -AppToken 'aTOK456'
        $tpl = Get-Content (Join-Path $Root 'config.template')
        $new = Get-Content $out
        $new.Count | Should -Be $tpl.Count
        ($new | Where-Object { $_ -match '^UserKey=' }) | Should -Be 'UserKey=uKEY123'
        ($new | Where-Object { $_ -match '^AppToken=' }) | Should -Be 'AppToken=aTOK456'
        $diff = 0
        for ($i = 0; $i -lt $tpl.Count; $i++) { if ($tpl[$i] -ne $new[$i]) { $diff++ } }
        $diff | Should -Be 2
        Import-Module (Join-Path $Root 'src\UT99Monitor.psm1') -Force
        (Read-MonitorConfig -Path $out).PushoverAppToken | Should -Be 'aTOK456'
    }

    It 'updates the keys of an existing customised config.ini in place' {
        $out = Join-Path $TestDrive 'existing.ini'
        Set-Content $out "[Probe]`nIntervalSeconds=45`n[Pushover]`nUserKey=uOLD`nAppToken=aOLD"
        Write-ConfigWithKeys -TemplatePath $out -OutPath $out -UserKey 'uNEW' -AppToken 'aNEW'
        (Get-Content $out) -join '|' | Should -Be '[Probe]|IntervalSeconds=45|[Pushover]|UserKey=uNEW|AppToken=aNEW'
    }
}

Describe 'New-MonitorTaskDefinition' {
    It 'builds the task definition with the admin principal and the restart settings' {
        $d = New-MonitorTaskDefinition -RepoRoot $Root -UserId 'EXAMPLEPC\admin'
        $d.Principal.UserId | Should -Be 'EXAMPLEPC\admin'
        [string]$d.Principal.LogonType | Should -Be 'Interactive'
        [string]$d.Principal.RunLevel | Should -Be 'Limited'
        $d.Trigger.UserId | Should -Be 'EXAMPLEPC\admin'
        $d.Action.Execute | Should -Match 'pwsh(\.exe)?$'
        $d.Action.Arguments | Should -Match '-WindowStyle Hidden'
        $d.Action.Arguments | Should -Match ([regex]::Escape("-File `"$(Join-Path $Root 'UT99-Monitor.ps1')`""))
        $d.Action.WorkingDirectory | Should -Be $Root
        $d.Settings.RestartCount | Should -Be 999
        $d.Settings.RestartInterval | Should -Be 'PT1M'
        $d.Settings.ExecutionTimeLimit | Should -Be 'PT0S'
        [string]$d.Settings.MultipleInstances | Should -Be 'IgnoreNew'
        $d.Settings.StartWhenAvailable | Should -BeTrue
        $d.Settings.DisallowStartIfOnBatteries | Should -BeFalse
        $d.Settings.StopIfGoingOnBatteries | Should -BeFalse
    }
}
