#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\UT99Monitor.psm1') -Force
    function L([int]$h, [int]$m, [int]$day = 23) { [DateTimeOffset][DateTime]::new(2026, 11, $day, $h, $m, 0, [DateTimeKind]::Local) }
    $script:S = [TimeSpan]'01:00'
    $script:E = [TimeSpan]'09:00'
}

Describe 'Test-InQuietHours' {
    It '<Label>' -ForEach @(
        @{ Label = '00:59 not quiet'; H = 0; M = 59; Expected = $false }
        @{ Label = '01:00 quiet'; H = 1; M = 0; Expected = $true }
        @{ Label = '08:59 quiet'; H = 8; M = 59; Expected = $true }
        @{ Label = '09:00 not quiet'; H = 9; M = 0; Expected = $false }
    ) {
        Test-InQuietHours -Now (L $H $M) -Start $S -End $E | Should -Be $Expected
    }

    It '22:00-06:00 window crossing midnight: 23:30 quiet, 12:00 not' {
        Test-InQuietHours -Now (L 23 30) -Start '22:00' -End '06:00' | Should -BeTrue
        Test-InQuietHours -Now (L 3 0) -Start '22:00' -End '06:00' | Should -BeTrue
        Test-InQuietHours -Now (L 12 0) -Start '22:00' -End '06:00' | Should -BeFalse
    }

    It 'uses local wall-clock time whatever offset Now carries' {
        $utc = (L 1 30).ToUniversalTime()
        Test-InQuietHours -Now $utc -Start $S -End $E | Should -BeTrue
    }
}

Describe 'Get-QuietWindow' {
    It 'same-day window 01:00-09:00 for date D spans D 01:00 to D 09:00' {
        $w = Get-QuietWindow -LocalDate ([DateTime]'2026-11-23') -Start $S -End $E
        $w.From | Should -Be (L 1 0)
        $w.To | Should -Be (L 9 0)
    }

    It '22:00-06:00 for date D spans D-1 22:00 to D 06:00' {
        $w = Get-QuietWindow -LocalDate ([DateTime]'2026-11-23') -Start '22:00' -End '06:00'
        $w.From | Should -Be (L 22 0 22)
        $w.To | Should -Be (L 6 0)
    }

    It 'window length is 8h on a normal day' {
        $w = Get-QuietWindow -LocalDate ([DateTime]'2026-11-23') -Start $S -End $E
        ($w.To - $w.From).TotalHours | Should -Be 8
    }
}
