<#
.SYNOPSIS
    Prints a ticket-ready downtime summary from data\state-changes.csv.
.PARAMETER From
    Period start (local). Default: the 1st of the current month, 00:00.
.PARAMETER To
    Period end (local). Default: now.
.PARAMETER ConfigPath
    Config file. Default: config.ini next to this script, or config.template if config.ini is absent.
.PARAMETER OutFile
    Also write the report to this file.
#>
[CmdletBinding()]
param(
    [DateTime]$From,
    [DateTime]$To,
    [string]$ConfigPath,
    [string]$OutFile
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src\UT99Monitor.psm1') -Force

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $PSScriptRoot 'config.ini'
    if (-not (Test-Path $ConfigPath)) { $ConfigPath = Join-Path $PSScriptRoot 'config.template' }
}
$config = Read-MonitorConfig -Path $ConfigPath

$now = Get-Date
if (-not $PSBoundParameters.ContainsKey('To')) { $To = $now }
if (-not $PSBoundParameters.ContainsKey('From')) { $From = [DateTime]::new($now.Year, $now.Month, 1) }
$fromOffset = [DateTimeOffset][DateTime]::SpecifyKind($From, [DateTimeKind]::Local)
$toOffset = [DateTimeOffset][DateTime]::SpecifyKind($To, [DateTimeKind]::Local)

$rows = @(Read-StateChanges -CsvPath (Join-Path $config.DataDir 'state-changes.csv'))
$report = Format-DowntimeReport -Rows $rows -From $fromOffset -To $toOffset -Server "$($config.ServerAddress):$($config.GamePort)"
if ($OutFile) { Set-Content -LiteralPath $OutFile -Value $report -Encoding utf8 }
$report
