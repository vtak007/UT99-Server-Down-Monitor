# Pushover.ps1 — HTTP transport for Pushover: send, receipt status, receipt cancel (spec §6.5).
# The transport is an object with script methods Send / GetReceipt / CancelReceipt; the keys are held in
# module scope (keyed by transport id) so they never appear when the object is displayed or logged.

$script:PushoverApi = 'https://api.pushover.net/1'
$script:PushoverSecrets = @{}

function Get-PushoverFailure {
    # Maps an exception to @{ Retryable; Error } with secrets redacted.
    param($ErrorRecord, [string[]]$Secrets)
    $ex = $ErrorRecord.Exception
    $status = $null
    if ($ex -is [Microsoft.PowerShell.Commands.HttpResponseException] -and $ex.Response) { $status = [int]$ex.Response.StatusCode }
    $retryable = ($null -eq $status) -or $status -eq 429 -or $status -ge 500
    $text = if ($status) { "HTTP ${status}: $($ex.Message)" } else { $ex.Message }
    foreach ($s in $Secrets) { if ($s) { $text = $text.Replace($s, '***') } }
    @{ Retryable = $retryable; Error = $text }
}

function Invoke-PushoverSend {
    param([string]$Id, [hashtable]$Msg)
    $k = $script:PushoverSecrets[$Id]
    $body = @{
        token = $k.AppToken; user = $k.UserKey; title = $Msg.Title; message = $Msg.Message
        priority = [int]$Msg.Priority
    }
    if ($Msg.Sound) { $body.sound = $Msg.Sound }
    if ($Msg.Timestamp) { $body.timestamp = ([DateTimeOffset]$Msg.Timestamp).ToUnixTimeSeconds() }
    if ([int]$Msg.Priority -eq 2) { $body.retry = [int]$Msg.Retry; $body.expire = [int]$Msg.Expire }
    try {
        $r = Invoke-RestMethod -Method Post -Uri "$script:PushoverApi/messages.json" -Body $body -TimeoutSec 15
        $receipt = if ($r.PSObject.Properties['receipt']) { [string]$r.receipt } else { $null }
        @{ Ok = $true; Receipt = $receipt; Retryable = $false; Error = $null }
    } catch {
        $f = Get-PushoverFailure $_ @($k.AppToken, $k.UserKey)
        @{ Ok = $false; Receipt = $null; Retryable = $f.Retryable; Error = $f.Error }
    }
}

function Invoke-PushoverGetReceipt {
    param([string]$Id, [string]$Receipt)
    if ($Receipt -notmatch '^[A-Za-z0-9]{1,64}$') { return @{ Ok = $false; Acknowledged = $false; Expired = $false; Error = 'invalid receipt id' } }
    $k = $script:PushoverSecrets[$Id]
    try {
        $r = Invoke-RestMethod -Method Get -Uri "$script:PushoverApi/receipts/$Receipt.json?token=$($k.AppToken)" -TimeoutSec 15
        @{ Ok = $true; Acknowledged = ([int]$r.acknowledged -eq 1); Expired = ([int]$r.expired -eq 1); Error = $null }
    } catch {
        $f = Get-PushoverFailure $_ @($k.AppToken, $k.UserKey)
        @{ Ok = $false; Acknowledged = $false; Expired = $false; Error = $f.Error }
    }
}

function Invoke-PushoverCancelReceipt {
    param([string]$Id, [string]$Receipt)
    if ($Receipt -notmatch '^[A-Za-z0-9]{1,64}$') { return @{ Ok = $false; Error = 'invalid receipt id' } }
    $k = $script:PushoverSecrets[$Id]
    try {
        [void](Invoke-RestMethod -Method Post -Uri "$script:PushoverApi/receipts/$Receipt/cancel.json" -Body @{ token = $k.AppToken } -TimeoutSec 15)
        @{ Ok = $true; Error = $null }
    } catch {
        $f = Get-PushoverFailure $_ @($k.AppToken, $k.UserKey)
        @{ Ok = $false; Error = $f.Error }
    }
}

function New-PushoverTransport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$UserKey, [Parameter(Mandatory)][string]$AppToken)
    $id = [guid]::NewGuid().ToString('N')
    $script:PushoverSecrets[$id] = @{ UserKey = $UserKey; AppToken = $AppToken }
    $t = [pscustomobject]@{ Kind = 'Pushover'; Id = $id }
    $t | Add-Member -MemberType ScriptMethod -Name Send -Value { param($Msg) Invoke-PushoverSend -Id $this.Id -Msg $Msg }
    $t | Add-Member -MemberType ScriptMethod -Name GetReceipt -Value { param($Receipt) Invoke-PushoverGetReceipt -Id $this.Id -Receipt $Receipt }
    $t | Add-Member -MemberType ScriptMethod -Name CancelReceipt -Value { param($Receipt) Invoke-PushoverCancelReceipt -Id $this.Id -Receipt $Receipt }
    $t
}
