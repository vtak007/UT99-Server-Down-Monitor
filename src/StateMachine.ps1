# StateMachine.ps1 — debounce, blind (UNKNOWN) intervals and BLIP events (spec §6.3–6.4; plan Task 4).

$script:DownStates = @('GAME_DOWN', 'HOST_DOWN')

function New-MonitorState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][DateTimeOffset]$StartedAt,
        [int]$DownThreshold = 3,
        [int]$UpThreshold = 3
    )
    @{
        DownThreshold     = $DownThreshold
        UpThreshold       = $UpThreshold
        Current           = 'MONITOR_STARTED'
        CurrentSince      = $StartedAt
        FailCount         = 0
        FirstFailAt       = $null
        FailClasses       = [Collections.Generic.List[string]]::new()
        SuccessCount      = 0
        FirstSuccessAt    = $null
        AltClass          = $null      # class-change candidate while down
        AltCount          = 0
        AltFirstAt        = $null
        PreBlindState     = $null
        OutageStart       = $null      # start of the current outage; carried across class changes and blind windows
        OutageInterrupted = $false
        LastGoodSnapshot  = $null
    }
}

function New-Transition {
    param($State, [DateTimeOffset]$Timestamp, [string]$NewState, $Snapshot, [string]$Notes = '',
        [switch]$NoDuration, $RecoveredFrom = $null, $OutageStart = $null, [bool]$Interrupted = $false)
    $duration = $null
    if (-not $NoDuration) {
        $duration = [int][Math]::Max(0, [Math]::Floor(($Timestamp - $State.CurrentSince).TotalSeconds))
    }
    [pscustomobject]@{
        Timestamp               = $Timestamp
        NewState                = $NewState
        PreviousState           = $State.Current
        PreviousDurationSeconds = $duration
        Snapshot                = $Snapshot
        Notes                   = $Notes
        RecoveredFrom           = $RecoveredFrom
        OutageStart             = $OutageStart
        Interrupted             = $Interrupted
    }
}

function Reset-AltCandidate($State) {
    $State.AltClass = $null; $State.AltCount = 0; $State.AltFirstAt = $null
}

function Step-MonitorState {
    # Feeds one cycle's classification into the state; returns 0..n transitions and mutates State.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)]$Cycle,
        [Parameter(Mandatory)][DateTimeOffset]$Now
    )
    $out = [Collections.Generic.List[object]]::new()
    $class = $Cycle.Classification

    if ($class -eq 'LINK_DOWN') {
        if ($State.Current -ne 'UNKNOWN') {
            $out.Add((New-Transition -State $State -Timestamp $Now -NewState 'UNKNOWN' -Snapshot $State.LastGoodSnapshot -Notes 'cause=LINK_DOWN'))
            $State.PreBlindState = $State.Current
            $State.Current = 'UNKNOWN'
            $State.CurrentSince = $Now
        }
        # Suspend counters; clear run start times so no later declaration predates the UNKNOWN row.
        $State.FirstFailAt = $null
        $State.FirstSuccessAt = $null
        $State.FailClasses.Clear()
        Reset-AltCandidate $State
        return $out.ToArray()
    }

    if ($class -eq 'UP') {
        $State.LastGoodSnapshot = $Cycle.Snapshot
        $State.SuccessCount++
        if ($null -eq $State.FirstSuccessAt) { $State.FirstSuccessAt = $Now }

        if ($State.Current -eq 'UP' -and $State.FailCount -gt 0 -and $null -ne $State.FirstFailAt) {
            $secs = [int][Math]::Floor(($Now - $State.FirstFailAt).TotalSeconds)
            $classes = ($State.FailClasses | Select-Object -Unique) -join ','
            $notes = "blip: $($State.FailCount) failed cycle(s) ($classes), ${secs}s"
            $out.Add((New-Transition -State $State -Timestamp $State.FirstFailAt -NewState 'BLIP' -Snapshot $State.LastGoodSnapshot -Notes $notes -NoDuration))
        }
        $State.FailCount = 0
        $State.FirstFailAt = $null
        $State.FailClasses.Clear()
        Reset-AltCandidate $State

        if ($State.Current -ne 'UP' -and $State.SuccessCount -ge $State.UpThreshold) {
            $recoveredFrom = $null
            if ($State.Current -in $script:DownStates) { $recoveredFrom = $State.Current }
            elseif ($State.Current -eq 'UNKNOWN' -and $State.PreBlindState -in $script:DownStates) { $recoveredFrom = $State.PreBlindState }
            $interrupted = $false
            $outageStart = $null
            if ($recoveredFrom) {
                $outageStart = $State.OutageStart
                $interrupted = $State.OutageInterrupted -or ($State.Current -eq 'UNKNOWN')
            }
            $out.Add((New-Transition -State $State -Timestamp $State.FirstSuccessAt -NewState 'UP' -Snapshot $Cycle.Snapshot `
                        -RecoveredFrom $recoveredFrom -OutageStart $outageStart -Interrupted $interrupted))
            $State.Current = 'UP'
            $State.CurrentSince = $State.FirstSuccessAt
            $State.PreBlindState = $null
            $State.OutageStart = $null
            $State.OutageInterrupted = $false
        }
        return $out.ToArray()
    }

    # Observing failure: GAME_DOWN or HOST_DOWN.
    $State.SuccessCount = 0
    $State.FirstSuccessAt = $null
    $State.FailCount++
    if ($null -eq $State.FirstFailAt) { $State.FirstFailAt = $Now }
    $State.FailClasses.Add($class)

    if ($State.Current -in $script:DownStates) {
        if ($class -eq $State.Current) {
            Reset-AltCandidate $State
        } else {
            if ($State.AltClass -ne $class) { $State.AltClass = $class; $State.AltCount = 0; $State.AltFirstAt = $Now }
            $State.AltCount++
            if ($State.AltCount -ge $State.DownThreshold) {
                $out.Add((New-Transition -State $State -Timestamp $State.AltFirstAt -NewState $class -Snapshot $State.LastGoodSnapshot -Notes 'class change'))
                $State.Current = $class
                $State.CurrentSince = $State.AltFirstAt
                Reset-AltCandidate $State
            }
        }
        return $out.ToArray()
    }

    if ($State.FailCount -ge $State.DownThreshold) {
        $interrupted = ($State.Current -eq 'UNKNOWN' -and $State.PreBlindState -in $script:DownStates)
        $notes = if ($interrupted) { 'resumed after blind window' } else { '' }
        $out.Add((New-Transition -State $State -Timestamp $State.FirstFailAt -NewState $class -Snapshot $State.LastGoodSnapshot -Notes $notes -Interrupted $interrupted))
        if ($interrupted) { $State.OutageInterrupted = $true } else { $State.OutageStart = $State.FirstFailAt; $State.OutageInterrupted = $false }
        $State.Current = $class
        $State.CurrentSince = $State.FirstFailAt
        $State.PreBlindState = $null
        Reset-AltCandidate $State
    }
    $out.ToArray()
}
