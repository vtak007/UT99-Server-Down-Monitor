<#
.SYNOPSIS
    UT99 Server Down Monitor — the long-running watchdog loop (spec §6.9).
.DESCRIPTION
    Probes the server every IntervalSeconds, records state changes to data\state-changes.csv and every
    cycle to data\raw\poll-YYYY-MM.log, and sends Pushover notifications. Started at logon by the
    scheduled task that Setup.ps1 registers. Only one instance runs at a time.
.PARAMETER ConfigPath
    Default: config.ini next to this script.
.PARAMETER MaxCycles
    Test use: stop cleanly after N cycles (0 = run forever).
.PARAMETER Probe
    Test use: replaces Invoke-ProbeCycle.
.PARAMETER Transport
    Test use: replaces the Pushover transport.
.PARAMETER MutexName
    Test use: single-instance mutex name.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.ini'),
    [int]$MaxCycles = 0,
    [scriptblock]$Probe,
    $Transport,
    [string]$MutexName = 'Local\UT99ServerDownMonitor'
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src\UT99Monitor.psm1') -Force

$config = Read-MonitorConfig -Path $ConfigPath
$dataDir = $config.DataDir
$csvPath = Join-Path $dataDir 'state-changes.csv'

# Single instance. A second copy exits 0 so Task Scheduler's restart-on-failure does not loop.
$mutex = [Threading.Mutex]::new($false, $MutexName)
$haveMutex = $false
try { $haveMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $haveMutex = $true }
if (-not $haveMutex) {
    Write-MonitorLog -DataDir $dataDir -Now ([DateTimeOffset]::Now) -Message 'ALREADY_RUNNING: another monitor instance holds the mutex; exiting'
    $mutex.Dispose()
    exit 0
}

$exitCode = 0
$state = $null
$stopped = $false
try {
    if (-not $Transport) {
        if (-not $config.PushoverUserKey -or -not $config.PushoverAppToken) {
            Write-Error -ErrorAction Continue "Pushover keys are missing from $ConfigPath. Run Setup.ps1 to enter them."
            exit 1
        }
        $Transport = New-PushoverTransport -UserKey $config.PushoverUserKey -AppToken $config.PushoverAppToken
    }
    if (-not $Probe) { $Probe = { Invoke-ProbeCycle -Config $config } }

    $now = [DateTimeOffset]::Now
    $gap = Start-MonitorSession -CsvPath $csvPath -DataDir $dataDir -Now $now
    Write-MonitorLog -DataDir $dataDir -Now $now -Message "MONITOR_STARTED pid=$PID"
    $state = New-MonitorState -StartedAt $now -DownThreshold $config.DownThreshold -UpThreshold $config.UpThreshold
    $notifier = New-Notifier -Config $config -Transport $Transport -DataDir $dataDir
    Send-StartupNotice -Notifier $notifier -Now $now -Gap $gap
    Remove-ExpiredPollLogs -DataDir $dataDir -Now $now -RetentionMonths $config.RawRetentionMonths
    $pruneDate = $now.ToLocalTime().Date

    # Best effort on host shutdown paths that skip finally.
    $null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -SupportEvent -Action {
        if ($global:UT99MonitorStopAction) { & $global:UT99MonitorStopAction }
    }
    $global:UT99MonitorStopAction = {
        if (-not $stopped -and $state) {
            $script:stopped = $true
            try { Add-MonitorStoppedRow -CsvPath $csvPath -Now ([DateTimeOffset]::Now) -CurrentState $state.Current -CurrentSince $state.CurrentSince } catch { }
        }
    }.GetNewClosure()

    $start = [DateTimeOffset]::Now
    $interval = [Math]::Max(0, $config.IntervalSeconds)
    $n = 0
    $cycles = 0
    while ($MaxCycles -le 0 -or $cycles -lt $MaxCycles) {
        $tick = $start.AddSeconds($interval * $n)
        $wait = ($tick - [DateTimeOffset]::Now).TotalMilliseconds
        if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]$wait) }
        $now = [DateTimeOffset]::Now
        try {
            $cycle = & $Probe
            Add-PollLogLine -DataDir $dataDir -Now $now -Cycle $cycle
            $transitions = @(Step-MonitorState -State $state -Cycle $cycle -Now $now)
            foreach ($t in $transitions) { Add-StateChangeRow -CsvPath $csvPath -Transition $t }
            Update-Notifier -Notifier $notifier -Transitions $transitions -MonitorState $state -Now $now -CsvPath $csvPath
            Invoke-CycleHook -Url $config.HealthcheckUrl
            if ($now.ToLocalTime().Date -ne $pruneDate) {
                Remove-ExpiredPollLogs -DataDir $dataDir -Now $now -RetentionMonths $config.RawRetentionMonths
                $pruneDate = $now.ToLocalTime().Date
            }
        } catch {
            Write-MonitorLog -DataDir $dataDir -Now $now -Message "CYCLE_ERROR $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage -replace '\s+', ' ')"
        }
        $cycles++
        # Next future tick; missed ticks are skipped, never burst.
        $n++
        if ($interval -gt 0) {
            $due = [Math]::Floor(([DateTimeOffset]::Now - $start).TotalSeconds / $interval) + 1
            if ($due -gt $n) { $n = [int]$due }
        }
    }
} catch {
    try { Write-MonitorLog -DataDir $dataDir -Now ([DateTimeOffset]::Now) -Message "FATAL $($_.Exception.Message)" } catch { }
    Write-Error -ErrorAction Continue $_
    $exitCode = 2
} finally {
    if (-not $stopped -and $state) {
        $stopped = $true
        try { Add-MonitorStoppedRow -CsvPath $csvPath -Now ([DateTimeOffset]::Now) -CurrentState $state.Current -CurrentSince $state.CurrentSince } catch { }
    }
    $global:UT99MonitorStopAction = $null
    Unregister-Event -SourceIdentifier PowerShell.Exiting -ErrorAction SilentlyContinue
    if ($haveMutex) { try { $mutex.ReleaseMutex() } catch { } }
    $mutex.Dispose()
}
exit $exitCode
