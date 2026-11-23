# Notifier.ps1 — decides what to send and when: alerts, escalation hand-off, reminders, quiet-hours
# suppression, the daily digest and send retry (spec §6.5–6.6; plan Task 10).

$script:NotifierDownTitles = @{ GAME_DOWN = 'UT99 CRASHED (VPS up)'; HOST_DOWN = 'VPS/NETWORK DOWN' }
$script:PendingMaxAge = [TimeSpan]::FromMinutes(30)

function New-Notifier {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Transport, [Parameter(Mandatory)][string]$DataDir)
    @{
        Config          = $Config
        Transport       = $Transport
        DataDir         = $DataDir
        DigestStatePath = (Join-Path $DataDir 'digest-state.json')
        Esc             = $null        # escalation of the current outage
        Pending         = @{}          # kind -> @{ Msg; CreatedAt; Emergency }
        WasQuiet        = $false
    }
}

function Format-HM([DateTimeOffset]$Ts) { $Ts.ToLocalTime().ToString('HH:mm') }

function New-EscalationState([string]$Receipt, [DateTimeOffset]$Now) {
    @{ Receipt = $Receipt; SentAt = $Now; LastPoll = $Now; Acked = $false; HandedOff = $false; ReminderDue = $null }
}

function Send-NotifierMessage {
    # Sends one message. Emergency sends (priority 2) start a new escalation on success.
    # Retryable failures of Down/Recovery/Startup messages are parked in the pending slot for their kind.
    param($N, [string]$Kind, [hashtable]$Msg, [DateTimeOffset]$Now, [switch]$FromPending)
    $r = $N.Transport.Send($Msg)
    if ($r.Ok) {
        Write-MonitorLog -DataDir $N.DataDir -Now $Now -Message "SEND ok $Kind p$($Msg.Priority) '$($Msg.Title)'"
        if ([int]$Msg.Priority -eq 2 -and $r.Receipt) { $N.Esc = New-EscalationState -Receipt $r.Receipt -Now $Now }
        $N.Pending.Remove($Kind)
        return $true
    }
    Write-MonitorLog -DataDir $N.DataDir -Now $Now -Message "SEND FAIL $Kind p$($Msg.Priority) '$($Msg.Title)': $($r.Error)$(if ($r.Retryable) { ' (will retry)' })"
    if ($Kind -in @('Down', 'Recovery', 'Startup')) {
        if ($r.Retryable) {
            if (-not $FromPending) {
                # A newer down/recovery message supersedes the other kind's pending message.
                if ($Kind -eq 'Down') { $N.Pending.Remove('Recovery') }
                if ($Kind -eq 'Recovery') { $N.Pending.Remove('Down') }
                $N.Pending[$Kind] = @{ Msg = $Msg; CreatedAt = $Now }
            }
        } else {
            if ($N.Pending.ContainsKey($Kind)) { Write-MonitorLog -DataDir $N.DataDir -Now $Now -Message "DROP $Kind (non-retryable)" }
            $N.Pending.Remove($Kind)
        }
    }
    $false
}

function Stop-Escalation($N, [DateTimeOffset]$Now) {
    # Cancels an outstanding (unacknowledged, not yet expired) emergency receipt and clears escalation.
    if ($N.Esc -and $N.Esc.Receipt -and -not $N.Esc.Acked -and -not $N.Esc.HandedOff) {
        $c = $N.Transport.CancelReceipt($N.Esc.Receipt)
        Write-MonitorLog -DataDir $N.DataDir -Now $Now -Message "CANCEL receipt $(if ($c.Ok) { 'ok' } else { "failed: $($c.Error)" })"
    }
    $N.Esc = $null
}

function New-DownMessage($N, $Transition, [string]$TitlePrefix = '', [int]$Priority = 2) {
    $c = $N.Config
    $snap = $Transition.Snapshot
    $last = if ($snap -and $snap.Map) { "Last map: $($snap.Map), players $($snap.NumPlayers)/$($snap.MaxPlayers)." } else { 'Last map: unknown.' }
    @{
        Title     = $TitlePrefix + $script:NotifierDownTitles[$Transition.NewState]
        Message   = "Down since $(Format-HM $Transition.Timestamp) (first failed check). $last"
        Priority  = $Priority; Sound = $c.SoundDown; Retry = $c.EmergencyRetrySeconds; Expire = $c.EmergencyExpireSeconds
        Timestamp = $Transition.Timestamp
    }
}

function Update-Notifier {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Notifier,
        [AllowEmptyCollection()][object[]]$Transitions = @(),
        [Parameter(Mandatory)][hashtable]$MonitorState,
        [Parameter(Mandatory)][DateTimeOffset]$Now,
        [Parameter(Mandatory)][string]$CsvPath
    )
    $N = $Notifier
    $c = $N.Config
    $quiet = Test-InQuietHours -Now $Now -Start $c.QuietStart -End $c.QuietEnd
    $downStates = @('GAME_DOWN', 'HOST_DOWN')

    # 1. Entering quiet hours: stop Pushover's own retries and drop anything pending; the digest takes over.
    if ($quiet -and -not $N.WasQuiet) {
        Stop-Escalation $N $Now
        if ($N.Pending.Count) { Write-MonitorLog -DataDir $N.DataDir -Now $Now -Message "DROP pending ($($N.Pending.Keys -join ',')) at quiet start" }
        $N.Pending.Clear()
    }
    $N.WasQuiet = $quiet

    # 2. Transitions.
    foreach ($t in $Transitions) {
        switch ($t.NewState) {
            { $_ -in $downStates } {
                if ($quiet) { break }
                if ($t.PreviousState -in $downStates) {
                    if ($N.Esc -and $N.Esc.Receipt -and -not $N.Esc.Acked -and -not $N.Esc.HandedOff) {
                        Stop-Escalation $N $Now
                        [void](Send-NotifierMessage $N 'Down' (New-DownMessage $N $t 'NOW: ' 2) $Now)
                    } else {
                        [void](Send-NotifierMessage $N 'ClassChange' (New-DownMessage $N $t 'NOW: ' 1) $Now)
                    }
                } elseif ($t.Interrupted -and $N.Esc) {
                    # Same outage resuming after a blind window; escalation already running.
                } else {
                    [void](Send-NotifierMessage $N 'Down' (New-DownMessage $N $t) $Now)
                }
            }
            'UP' {
                if (-not $t.RecoveredFrom) { break }
                Stop-Escalation $N $Now
                $N.Pending.Remove('Down')
                if ($quiet) { break }
                $start = if ($t.OutageStart) { [DateTimeOffset]$t.OutageStart } else { $t.Timestamp }
                $dur = Format-Duration -Span ($t.Timestamp - $start)
                $note = if ($t.Interrupted) { ' (outage interrupted by a blind window)' } else { '' }
                [void](Send-NotifierMessage $N 'Recovery' @{
                        Title = "Server UP — was down $dur"; Message = "Recovered from $($t.RecoveredFrom) at $(Format-HM $t.Timestamp).$note"
                        Priority = 0; Sound = $c.SoundUp; Timestamp = $t.Timestamp
                    } $Now)
            }
        }
    }

    # 3. Escalation: acknowledgement polling, expiry hand-off, reminders.
    if ($N.Esc -and $MonitorState.Current -notin $downStates) { $N.Esc = $null }
    if ($N.Esc -and -not $quiet) {
        $e = $N.Esc
        if ($e.Receipt -and -not $e.Acked -and -not $e.HandedOff) {
            if ($Now -ge $e.SentAt.AddSeconds($c.EmergencyExpireSeconds)) {
                $e.HandedOff = $true; $e.ReminderDue = $Now
            } elseif (($Now - $e.LastPoll).TotalSeconds -ge $c.ReceiptPollSeconds) {
                $e.LastPoll = $Now
                $p = $N.Transport.GetReceipt($e.Receipt)
                if ($p.Ok -and $p.Acknowledged) { $e.Acked = $true; $e.ReminderDue = $Now.AddMinutes($c.ReminderMinutes) }
                elseif ($p.Ok -and $p.Expired) { $e.HandedOff = $true; $e.ReminderDue = $Now }
            }
        }
        if ($null -ne $e.ReminderDue -and $Now -ge $e.ReminderDue) {
            $since = if ($MonitorState.OutageStart) { [DateTimeOffset]$MonitorState.OutageStart } else { [DateTimeOffset]$MonitorState.CurrentSince }
            [void](Send-NotifierMessage $N 'Reminder' @{
                    Title = "UT99 still down — $(Format-Duration -Span ($Now - $since))"
                    Message = "$($MonitorState.Current) since $(Format-HM $since)."; Priority = 1; Sound = $c.SoundDown; Timestamp = $Now
                } $Now)
            while ($e.ReminderDue -le $Now) { $e.ReminderDue = $e.ReminderDue.AddMinutes($c.ReminderMinutes) }
        }
    }

    # 4. Daily digest at the end of quiet hours.
    if (-not $quiet -and (Test-DigestDue -Now $Now -QuietEnd $c.QuietEnd -GraceHours $c.DigestGraceHours -StatePath $N.DigestStatePath)) {
        $rows = @(Read-StateChanges -CsvPath $CsvPath -WarningAction SilentlyContinue)
        $window = Get-QuietWindow -LocalDate $Now.ToLocalTime().Date -Start $c.QuietStart -End $c.QuietEnd
        $d = New-DigestMessage -Rows $rows -Window $window -CurrentState $MonitorState.Current -CurrentSince $MonitorState.CurrentSince -Now $Now
        $msg = @{ Title = $d.Title; Message = $d.Message; Priority = $d.Priority; Timestamp = $Now
            Sound = $(if ($d.Priority -eq 2) { $c.SoundDown } else { $c.SoundInfo }); Retry = $c.EmergencyRetrySeconds; Expire = $c.EmergencyExpireSeconds }
        if ($d.Priority -eq 2) { Stop-Escalation $N $Now }
        $r = $N.Transport.Send($msg)
        if ($r.Ok -or -not $r.Retryable) {
            Set-DigestSent -StatePath $N.DigestStatePath -Now $Now
            Write-MonitorLog -DataDir $N.DataDir -Now $Now -Message "DIGEST $(if ($r.Ok) { 'sent' } else { "failed (not retried): $($r.Error)" }) '$($d.Title)'"
            if ($r.Ok -and $d.Priority -eq 2 -and $r.Receipt) { $N.Esc = New-EscalationState -Receipt $r.Receipt -Now $Now }
        } else {
            Write-MonitorLog -DataDir $N.DataDir -Now $Now -Message "DIGEST send failed, will retry: $($r.Error)"
        }
    }

    # 5. Retry pending messages.
    if (-not $quiet) {
        foreach ($kind in @($N.Pending.Keys)) {
            $p = $N.Pending[$kind]
            if ($kind -eq 'Down' -and $MonitorState.Current -notin $downStates) {
                Write-MonitorLog -DataDir $N.DataDir -Now $Now -Message 'DROP pending Down (no longer down)'
                $N.Pending.Remove($kind); continue
            }
            if ($kind -ne 'Down' -and ($Now - $p.CreatedAt) -gt $script:PendingMaxAge) {
                Write-MonitorLog -DataDir $N.DataDir -Now $Now -Message "DROP pending $kind (older than 30 min)"
                $N.Pending.Remove($kind); continue
            }
            if ($p.CreatedAt -eq $Now) { continue }   # just failed this cycle
            [void](Send-NotifierMessage $N $kind $p.Msg $Now -FromPending)
        }
    }
}

function Send-StartupNotice {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Notifier, [Parameter(Mandatory)][DateTimeOffset]$Now, $Gap)
    $c = $Notifier.Config
    if (Test-InQuietHours -Now $Now -Start $c.QuietStart -End $c.QuietEnd) {
        Write-MonitorLog -DataDir $Notifier.DataDir -Now $Now -Message 'Startup notice suppressed (quiet hours)'
        return
    }
    $body = "Watching $($c.ServerAddress):$($c.QueryPort) every $($c.IntervalSeconds)s."
    if ($Gap -and $null -ne $Gap.GapStart) {
        $body += " Previous gap: $(Format-Duration -Span ([TimeSpan]::FromSeconds($Gap.GapSeconds))) unobserved (since $(Format-HM ([DateTimeOffset]$Gap.GapStart)))."
    }
    [void](Send-NotifierMessage $Notifier 'Startup' @{ Title = 'UT99 monitor started'; Message = $body; Priority = 0; Sound = $c.SoundInfo; Timestamp = $Now } $Now)
}
