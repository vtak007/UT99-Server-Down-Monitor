<#
.SYNOPSIS
    First-run setup for the UT99 Server Down Monitor (spec §6.9).
.DESCRIPTION
    1. Prompts (hidden input) for the Pushover User Key and App Token and writes config.ini.
       The keys are never echoed or logged.
    2. Sends a test notification.
    3. Registers the scheduled task "UT99 Server Down Monitor": at logon, as the current user
       (never SYSTEM), hidden window, restart on failure.
.PARAMETER ConfigPath
    Default: config.ini next to this script.
.PARAMETER SkipTask
    Do not register the scheduled task.
.PARAMETER SkipTest
    Do not send the test notification.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.ini'),
    [switch]$SkipTask,
    [switch]$SkipTest
)

$script:TaskName = 'UT99 Server Down Monitor'

function Write-ConfigWithKeys {
    # Copies TemplatePath to OutPath, replacing only the UserKey= and AppToken= lines.
    param([Parameter(Mandatory)][string]$TemplatePath, [Parameter(Mandatory)][string]$OutPath,
        [Parameter(Mandatory)][string]$UserKey, [Parameter(Mandatory)][string]$AppToken)
    $lines = [IO.File]::ReadAllLines($TemplatePath)
    $out = foreach ($l in $lines) {
        if ($l -match '^\s*UserKey\s*=') { "UserKey=$UserKey" }
        elseif ($l -match '^\s*AppToken\s*=') { "AppToken=$AppToken" }
        else { $l }
    }
    [IO.File]::WriteAllLines($OutPath, [string[]]$out)
}

function New-MonitorTaskDefinition {
    # Returns the scheduled-task parts without registering anything.
    param([Parameter(Mandatory)][string]$RepoRoot, [string]$UserId = "$env:USERDOMAIN\$env:USERNAME")
    $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
    $script = Join-Path $RepoRoot 'UT99-Monitor.ps1'
    @{
        Action    = New-ScheduledTaskAction -Execute $pwsh -WorkingDirectory $RepoRoot `
            -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""
        Trigger   = New-ScheduledTaskTrigger -AtLogOn -User $UserId
        Principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive -RunLevel Limited
        Settings  = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
            -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    }
}

function Read-SecretInput([string]$Prompt) {
    $s = Read-Host -Prompt $Prompt -AsSecureString
    ConvertFrom-SecureString -SecureString $s -AsPlainText
}

function Invoke-Setup {
    $ErrorActionPreference = 'Stop'
    Import-Module (Join-Path $PSScriptRoot 'src\UT99Monitor.psm1') -Force
    $template = Join-Path $PSScriptRoot 'config.template'

    $existing = $null
    if (Test-Path -LiteralPath $ConfigPath) {
        $existing = Read-MonitorConfig -Path $ConfigPath
        Write-Host "config.ini already exists. Press Enter at a prompt to keep the current value."
    }

    $userKey = Read-SecretInput 'Pushover User Key (input hidden)'
    $appToken = Read-SecretInput 'Pushover App Token (input hidden)'
    if (-not $userKey -and $existing) { $userKey = $existing.PushoverUserKey }
    if (-not $appToken -and $existing) { $appToken = $existing.PushoverAppToken }
    if (-not $userKey -or -not $appToken) { throw 'Both the User Key and the App Token are required.' }
    foreach ($pair in @(@('User Key', $userKey), @('App Token', $appToken))) {
        if ($pair[1] -notmatch '^[A-Za-z0-9]{30}$') { Write-Warning "The $($pair[0]) is not 30 letters/digits; check it if the test notification fails." }
    }

    $source = if ($existing) { $ConfigPath } else { $template }
    Write-ConfigWithKeys -TemplatePath $source -OutPath $ConfigPath -UserKey $userKey -AppToken $appToken
    Write-Host "Wrote $ConfigPath (keys not shown)."
    $config = Read-MonitorConfig -Path $ConfigPath

    if (-not $SkipTest) {
        $t = New-PushoverTransport -UserKey $config.PushoverUserKey -AppToken $config.PushoverAppToken
        $r = $t.Send(@{ Title = 'UT99 monitor: test notification'; Message = 'Setup.ps1 can reach Pushover. You will get this for real alerts.'
                Priority = 0; Sound = $config.SoundInfo; Timestamp = [DateTimeOffset]::Now })
        if ($r.Ok) { Write-Host 'Test notification sent - check your phone.' }
        else { Write-Warning "Test notification failed: $($r.Error)" }
    }

    if (-not $SkipTask) {
        $d = New-MonitorTaskDefinition -RepoRoot $PSScriptRoot
        Register-ScheduledTask -TaskName $script:TaskName -Description 'UT99 server watchdog (UT99 Server Down Monitor). Runs at logon as this user.' `
            -Action $d.Action -Trigger $d.Trigger -Principal $d.Principal -Settings $d.Settings -Force | Out-Null
        Write-Host "Registered scheduled task '$script:TaskName' (at logon, as $($d.Principal.UserId))."
        $answer = Read-Host 'Start the monitor now? [Y/n]'
        if ($answer -eq '' -or $answer -match '^[Yy]') {
            Start-ScheduledTask -TaskName $script:TaskName
            Write-Host 'Started. A "UT99 monitor started" notification should arrive shortly (not during quiet hours).'
        }
    }
}

# Run only when executed, not when dot-sourced by the tests.
if ($MyInvocation.InvocationName -ne '.') { Invoke-Setup }
