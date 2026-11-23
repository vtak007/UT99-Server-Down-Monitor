# QuietHours.ps1 — the local wall-clock notification-suppression window (spec §6.6).

function Test-InQuietHours {
    # Start inclusive, End exclusive; Start > End means the window crosses midnight.
    [CmdletBinding()]
    param([Parameter(Mandatory)][DateTimeOffset]$Now, [Parameter(Mandatory)][TimeSpan]$Start, [Parameter(Mandatory)][TimeSpan]$End)
    $t = $Now.ToLocalTime().TimeOfDay
    if ($Start -eq $End) { return $false }
    if ($Start -lt $End) { return ($t -ge $Start -and $t -lt $End) }
    ($t -ge $Start -or $t -lt $End)
}

function Get-QuietWindow {
    # The window that ENDS on LocalDate. Each bound is converted through local time separately, so a
    # DST night simply yields a 7 h or 9 h window.
    [CmdletBinding()]
    param([Parameter(Mandatory)][DateTime]$LocalDate, [Parameter(Mandatory)][TimeSpan]$Start, [Parameter(Mandatory)][TimeSpan]$End)
    $day = $LocalDate.Date
    $fromDay = if ($Start -gt $End) { $day.AddDays(-1) } else { $day }
    $from = [DateTime]::SpecifyKind($fromDay.Add($Start), [DateTimeKind]::Local)
    $to = [DateTime]::SpecifyKind($day.Add($End), [DateTimeKind]::Local)
    @{ From = [DateTimeOffset]$from; To = [DateTimeOffset]$to }
}
