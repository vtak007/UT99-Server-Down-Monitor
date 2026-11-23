#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\UT99Monitor.psm1') -Force
    $script:Config = Read-MonitorConfig -Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'config.template')
    function L([int]$h, [int]$m, [int]$s = 0, [int]$day = 23) { [DateTimeOffset][DateTime]::new(2026, 11, $day, $h, $m, $s, [DateTimeKind]::Local) }

    # Fake transport: records every call; Send results come from SendQueue (default: Ok, receipt for priority 2).
    function New-FakeTransport {
        $t = [pscustomobject]@{
            Sends = [Collections.Generic.List[object]]::new()
            Polls = [Collections.Generic.List[string]]::new()
            Cancels = [Collections.Generic.List[string]]::new()
            SendQueue = [Collections.Generic.Queue[object]]::new()
            ReceiptStatus = @{ Ok = $true; Acknowledged = $false; Expired = $false; Error = $null }
            N = 0
        }
        $t | Add-Member ScriptMethod Send {
            param($Msg)
            $this.Sends.Add($Msg)
            if ($this.SendQueue.Count) { return $this.SendQueue.Dequeue() }
            $this.N++
            @{ Ok = $true; Receipt = $(if ($Msg.Priority -eq 2) { "r$($this.N)" } else { $null }); Retryable = $false; Error = $null }
        }
        $t | Add-Member ScriptMethod GetReceipt { param($R) $this.Polls.Add($R); $this.ReceiptStatus }
        $t | Add-Member ScriptMethod CancelReceipt { param($R) $this.Cancels.Add($R); @{ Ok = $true; Error = $null } }
        $t
    }

    function New-Tr([DateTimeOffset]$At, [string]$State, [string]$Prev, $RecoveredFrom = $null, $OutageStart = $null, [bool]$Interrupted = $false) {
        [pscustomobject]@{ Timestamp = $At; NewState = $State; PreviousState = $Prev; PreviousDurationSeconds = 0
            Snapshot = @{ Map = 'DM-Codex'; NumPlayers = 5; MaxPlayers = 14 }; Notes = ''
            RecoveredFrom = $RecoveredFrom; OutageStart = $OutageStart; Interrupted = $Interrupted }
    }

    # Runs Update-Notifier every $StepSeconds from $From to $To (inclusive) with no transitions.
    function Invoke-Ticks($N, $Ms, [DateTimeOffset]$From, [DateTimeOffset]$To, [int]$StepSeconds = 30, [scriptblock]$Before) {
        for ($t = $From; $t -le $To; $t = $t.AddSeconds($StepSeconds)) {
            if ($Before) { & $Before $t }
            Update-Notifier -Notifier $N -Transitions @() -MonitorState $Ms -Now $t -CsvPath $Csv
        }
    }
}

Describe 'Update-Notifier' {
    BeforeEach {
        $script:Dir = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory $Dir | Out-Null
        $script:Csv = Join-Path $Dir 'state-changes.csv'
        $script:Tx = New-FakeTransport
        $script:N = New-Notifier -Config $Config -Transport $Tx -DataDir $Dir
        $script:Ms = @{ Current = 'GAME_DOWN'; CurrentSince = (L 14 0); OutageStart = (L 14 0) }
        # Mark today's digest as sent so it does not interfere unless a test wants it.
        Set-DigestSent -StatePath (Join-Path $Dir 'digest-state.json') -Now (L 9 0)
    }

    It "GAME_DOWN at 14:00 sends priority 2 'UT99 CRASHED (VPS up)' with map and players in the body" {
        Update-Notifier -Notifier $N -Transitions @(New-Tr (L 14 0) 'GAME_DOWN' 'UP') -MonitorState $Ms -Now (L 14 1 30) -CsvPath $Csv
        $Tx.Sends.Count | Should -Be 1
        $m = $Tx.Sends[0]
        $m.Title | Should -Be 'UT99 CRASHED (VPS up)'
        $m.Priority | Should -Be 2
        $m.Retry | Should -Be 300
        $m.Expire | Should -Be 10800
        $m.Sound | Should -Be 'siren'
        $m.Message | Should -Match '14:00'
        $m.Message | Should -Match 'DM-Codex'
        $m.Message | Should -Match '5/14'
    }

    It "HOST_DOWN sends 'VPS/NETWORK DOWN'" {
        $Ms.Current = 'HOST_DOWN'
        Update-Notifier -Notifier $N -Transitions @(New-Tr (L 14 0) 'HOST_DOWN' 'UP') -MonitorState $Ms -Now (L 14 1 30) -CsvPath $Csv
        $Tx.Sends[0].Title | Should -Be 'VPS/NETWORK DOWN'
    }

    It 'ack seen at 14:07 gives first reminder 14:22 priority 1, next 14:37' {
        Update-Notifier -Notifier $N -Transitions @(New-Tr (L 14 0) 'GAME_DOWN' 'UP') -MonitorState $Ms -Now (L 14 1 30) -CsvPath $Csv
        Invoke-Ticks $N $Ms (L 14 2) (L 14 40) -Before { param($t) if ($t -ge (L 14 7)) { $Tx.ReceiptStatus = @{ Ok = $true; Acknowledged = $true; Expired = $false } } }
        $rem = @($Tx.Sends | Where-Object Priority -eq 1)
        $rem.Count | Should -Be 2
        $rem[0].Title | Should -Match '^UT99 still down — '
        $rem[0].Timestamp | Should -BeGreaterOrEqual (L 14 22)
        $rem[0].Timestamp | Should -BeLessThan (L 14 23)
        $rem[1].Timestamp | Should -BeGreaterOrEqual (L 14 37)
    }

    It 'no reminder before ack while unacknowledged' {
        Update-Notifier -Notifier $N -Transitions @(New-Tr (L 14 0) 'GAME_DOWN' 'UP') -MonitorState $Ms -Now (L 14 1 30) -CsvPath $Csv
        Invoke-Ticks $N $Ms (L 14 2) (L 15 0)
        @($Tx.Sends | Where-Object Priority -eq 1).Count | Should -Be 0
    }

    It 'receipt polled at most once per 60 s' {
        Update-Notifier -Notifier $N -Transitions @(New-Tr (L 14 0) 'GAME_DOWN' 'UP') -MonitorState $Ms -Now (L 14 1 30) -CsvPath $Csv
        Invoke-Ticks $N $Ms (L 14 2) (L 14 6 30)
        $Tx.Polls.Count | Should -BeLessOrEqual 5
        $Tx.Polls.Count | Should -BeGreaterOrEqual 4
    }

    It 'expiry without ack starts reminders at expiry even when every poll failed' {
        $Tx.ReceiptStatus = @{ Ok = $false; Acknowledged = $false; Expired = $false; Error = 'network' }
        Update-Notifier -Notifier $N -Transitions @(New-Tr (L 14 0) 'GAME_DOWN' 'UP') -MonitorState $Ms -Now (L 14 1 30) -CsvPath $Csv
        Invoke-Ticks $N $Ms (L 14 5) (L 17 0) -StepSeconds 300
        @($Tx.Sends | Where-Object Priority -eq 1).Count | Should -Be 0
        Invoke-Ticks $N $Ms (L 17 1 30) (L 17 3)
        $rem = @($Tx.Sends | Where-Object Priority -eq 1)
        $rem.Count | Should -Be 1
    }

    It "recovery cancels the outstanding receipt and sends 'Server UP — was down 1h 12m' at priority 0" {
        Update-Notifier -Notifier $N -Transitions @(New-Tr (L 14 0) 'GAME_DOWN' 'UP') -MonitorState $Ms -Now (L 14 1 30) -CsvPath $Csv
        $Ms.Current = 'UP'; $Ms.OutageStart = $null
        Update-Notifier -Notifier $N -Transitions @(New-Tr (L 15 12) 'UP' 'GAME_DOWN' 'GAME_DOWN' (L 14 0)) -MonitorState $Ms -Now (L 15 13 30) -CsvPath $Csv
        @($Tx.Cancels) | Should -Be @('r1')
        $m = $Tx.Sends[-1]
        $m.Title | Should -Be 'Server UP — was down 1h 12m'
        $m.Priority | Should -Be 0
        $m.Sound | Should -Be 'magic'
        $m.Message | Should -Match 'GAME_DOWN'
    }

    It 'recovery after a blind window says so' {
        $Ms.Current = 'UP'
        Update-Notifier -Notifier $N -Transitions @(New-Tr (L 15 12) 'UP' 'UNKNOWN' 'GAME_DOWN' (L 14 0) $true) -MonitorState $Ms -Now (L 15 13 30) -CsvPath $Csv
        $Tx.Sends[-1].Message | Should -Match 'interrupted by a blind window'
    }

    It "class change unacknowledged cancels and sends a new priority 2 'NOW: VPS/NETWORK DOWN'" {
        Update-Notifier -Notifier $N -Transitions @(New-Tr (L 14 0) 'GAME_DOWN' 'UP') -MonitorState $Ms -Now (L 14 1 30) -CsvPath $Csv
        $Ms.Current = 'HOST_DOWN'
        Update-Notifier -Notifier $N -Transitions @(New-Tr (L 14 5) 'HOST_DOWN' 'GAME_DOWN') -MonitorState $Ms -Now (L 14 6 30) -CsvPath $Csv
        @($Tx.Cancels) | Should -Be @('r1')
        $Tx.Sends[-1].Title | Should -Be 'NOW: VPS/NETWORK DOWN'
        $Tx.Sends[-1].Priority | Should -Be 2
    }

    It 'class change after acknowledgement sends priority 1 and keeps the reminder schedule' {
        $Tx.ReceiptStatus = @{ Ok = $true; Acknowledged = $true; Expired = $false }
        Update-Notifier -Notifier $N -Transitions @(New-Tr (L 14 0) 'GAME_DOWN' 'UP') -MonitorState $Ms -Now (L 14 1 30) -CsvPath $Csv
        Invoke-Ticks $N $Ms (L 14 2) (L 14 3)
        $Ms.Current = 'HOST_DOWN'
        Update-Notifier -Notifier $N -Transitions @(New-Tr (L 14 5) 'HOST_DOWN' 'GAME_DOWN') -MonitorState $Ms -Now (L 14 6 30) -CsvPath $Csv
        $Tx.Cancels.Count | Should -Be 0
        $Tx.Sends[-1].Title | Should -Be 'NOW: VPS/NETWORK DOWN'
        $Tx.Sends[-1].Priority | Should -Be 1
        Invoke-Ticks $N $Ms (L 14 7) (L 14 18)
        @($Tx.Sends | Where-Object { $_.Title -clike 'UT99 still down*' }).Count | Should -Be 1
    }

    It 'down declared at 02:00 sends nothing; recovery at 03:00 sends nothing; a BLIP at 14:00 sends nothing' {
        Update-Notifier -Notifier $N -Transitions @(New-Tr (L 2 0) 'GAME_DOWN' 'UP') -MonitorState $Ms -Now (L 2 1 30) -CsvPath $Csv
        $Ms.Current = 'UP'
        Update-Notifier -Notifier $N -Transitions @(New-Tr (L 3 0) 'UP' 'GAME_DOWN' 'GAME_DOWN' (L 2 0)) -MonitorState $Ms -Now (L 3 1 30) -CsvPath $Csv
        Update-Notifier -Notifier $N -Transitions @(New-Tr (L 14 0) 'BLIP' 'UP') -MonitorState $Ms -Now (L 14 1) -CsvPath $Csv
        $Tx.Sends.Count | Should -Be 0
    }

    It 'UNKNOWN and an ordinary startup UP send nothing' {
        $Ms.Current = 'UP'
        Update-Notifier -Notifier $N -Transitions @((New-Tr (L 14 0) 'UP' 'MONITOR_STARTED'), (New-Tr (L 14 5) 'UNKNOWN' 'UP')) -MonitorState $Ms -Now (L 14 5) -CsvPath $Csv
        $Tx.Sends.Count | Should -Be 0
    }

    It 'outage alerted at 00:55, still unacknowledged at 01:00: receipt cancelled at first quiet cycle, no further sends until 09:00' {
        $Ms.CurrentSince = (L 0 55); $Ms.OutageStart = (L 0 55)
        Update-Notifier -Notifier $N -Transitions @(New-Tr (L 0 55) 'GAME_DOWN' 'UP') -MonitorState $Ms -Now (L 0 56 30) -CsvPath $Csv
        Invoke-Ticks $N $Ms (L 0 57) (L 1 0 30)
        @($Tx.Cancels) | Should -Be @('r1')
        Invoke-Ticks $N $Ms (L 1 5) (L 8 55) -StepSeconds 300
        $Tx.Sends.Count | Should -Be 1
        $Tx.Cancels.Count | Should -Be 1
    }

    It '09:00 digest while still down is priority 2 and its receipt drives reminders after ack' {
        Remove-Item (Join-Path $Dir 'digest-state.json')
        Add-StateChangeRow -CsvPath $Csv -Transition ([pscustomobject]@{ Timestamp = (L 0 55); NewState = 'GAME_DOWN'; PreviousState = 'UP'
                PreviousDurationSeconds = 0; Snapshot = $null; Notes = '' })
        $Ms.CurrentSince = (L 0 55); $Ms.OutageStart = (L 0 55)
        Invoke-Ticks $N $Ms (L 8 59) (L 9 0)
        $d = $Tx.Sends[-1]
        $d.Title | Should -Be 'UT99 STILL DOWN (GAME_DOWN)'
        $d.Priority | Should -Be 2
        $Tx.ReceiptStatus = @{ Ok = $true; Acknowledged = $true; Expired = $false }
        Invoke-Ticks $N $Ms (L 9 0 30) (L 9 17)
        @($Tx.Sends | Where-Object { $_.Title -clike 'UT99 still down*' }).Count | Should -Be 1
        @($Tx.Sends | Where-Object { $_.Title -clike 'UT99 STILL DOWN*' }).Count | Should -Be 1
    }

    It 'failed down send (Retryable) is retried next cycle and sent once' {
        $Tx.SendQueue.Enqueue(@{ Ok = $false; Receipt = $null; Retryable = $true; Error = 'network' })
        Update-Notifier -Notifier $N -Transitions @(New-Tr (L 14 0) 'GAME_DOWN' 'UP') -MonitorState $Ms -Now (L 14 1 30) -CsvPath $Csv
        Invoke-Ticks $N $Ms (L 14 2) (L 14 4)
        @($Tx.Sends | Where-Object Title -eq 'UT99 CRASHED (VPS up)').Count | Should -Be 2
        Invoke-Ticks $N $Ms (L 14 5) (L 14 6)
        $Tx.Polls.Count | Should -BeGreaterThan 0
    }

    It 'pending down dropped once state is UP' {
        $Tx.SendQueue.Enqueue(@{ Ok = $false; Receipt = $null; Retryable = $true; Error = 'network' })
        Update-Notifier -Notifier $N -Transitions @(New-Tr (L 14 0) 'GAME_DOWN' 'UP') -MonitorState $Ms -Now (L 14 1 30) -CsvPath $Csv
        $Ms.Current = 'UP'
        Invoke-Ticks $N $Ms (L 14 2) (L 14 4)
        @($Tx.Sends | Where-Object Title -eq 'UT99 CRASHED (VPS up)').Count | Should -Be 1
    }

    It 'non-retryable failure is not retried' {
        $Tx.SendQueue.Enqueue(@{ Ok = $false; Receipt = $null; Retryable = $false; Error = 'HTTP 400' })
        Update-Notifier -Notifier $N -Transitions @(New-Tr (L 14 0) 'GAME_DOWN' 'UP') -MonitorState $Ms -Now (L 14 1 30) -CsvPath $Csv
        Invoke-Ticks $N $Ms (L 14 2) (L 14 4)
        $Tx.Sends.Count | Should -Be 1
        (Get-Content (Join-Path $Dir 'monitor.log') -Raw) | Should -Match 'HTTP 400'
    }
}

Describe 'Send-StartupNotice' {
    BeforeEach {
        $script:Dir = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory $Dir | Out-Null
        $script:Tx = New-FakeTransport
        $script:N = New-Notifier -Config $Config -Transport $Tx -DataDir $Dir
    }

    It 'sends the startup notice with the previous gap' {
        Send-StartupNotice -Notifier $N -Now (L 14 0) -Gap ([pscustomobject]@{ GapStart = (L 13 0); GapSeconds = 3600 })
        $Tx.Sends[0].Title | Should -Be 'UT99 monitor started'
        $Tx.Sends[0].Priority | Should -Be 0
        $Tx.Sends[0].Message | Should -Match 'Previous gap: 1h unobserved'
    }

    It 'is suppressed during quiet hours' {
        Send-StartupNotice -Notifier $N -Now (L 3 0) -Gap ([pscustomobject]@{ GapStart = $null; GapSeconds = 0 })
        $Tx.Sends.Count | Should -Be 0
    }
}
