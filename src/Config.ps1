# Config.ps1 — reads config.ini (INI format) into a typed object, filling defaults for missing keys.

$script:ConfigDefaults = [ordered]@{
    'Server.Address'                = '74.91.119.21'
    'Server.QueryPort'              = '7778'
    'Server.GamePort'               = '7777'
    'Probe.IntervalSeconds'         = '30'
    'Probe.GameTimeoutMs'           = '3000'
    'Probe.PingTimeoutMs'           = '1000'
    'Probe.PingCount'               = '2'
    'Probe.LinkTargets'             = '1.1.1.1,8.8.8.8'
    'Debounce.DownThreshold'        = '3'
    'Debounce.UpThreshold'          = '3'
    'Notify.QuietStart'             = '01:00'
    'Notify.QuietEnd'               = '09:00'
    'Notify.EmergencyRetrySeconds'  = '300'
    'Notify.EmergencyExpireSeconds' = '10800'
    'Notify.ReminderMinutes'        = '15'
    'Notify.ReceiptPollSeconds'     = '60'
    'Notify.SoundDown'              = 'siren'
    'Notify.SoundUp'                = 'magic'
    'Notify.SoundInfo'              = 'pushover'
    'Notify.DigestGraceHours'       = '3'
    'Pushover.UserKey'              = ''
    'Pushover.AppToken'             = ''
    'Data.DataDir'                  = 'data'
    'Data.RawRetentionMonths'       = '12'
    'Health.PingUrl'                = ''
}

function Read-IniFile {
    param([Parameter(Mandatory)][string]$Path)
    $values = @{}
    $section = ''
    foreach ($raw in [IO.File]::ReadAllLines($Path)) {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith(';') -or $line.StartsWith('#')) { continue }
        if ($line -match '^\[(.+)\]$') { $section = $Matches[1].Trim(); continue }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }
        $key = $line.Substring(0, $eq).Trim()
        $value = $line.Substring($eq + 1)
        # Inline comment: ';' preceded by whitespace.
        $value = ($value -replace '\s+;.*$', '').Trim()
        $values["$section.$key"] = $value
    }
    $values
}

function Read-MonitorConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Config file not found: $Path. Run Setup.ps1 to create config.ini."
    }
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    $ini = Read-IniFile -Path $full
    $v = @{}
    foreach ($k in $script:ConfigDefaults.Keys) {
        $v[$k] = if ($ini.ContainsKey($k)) { $ini[$k] } else { $script:ConfigDefaults[$k] }
    }

    $dataDir = $v['Data.DataDir']
    if (-not [IO.Path]::IsPathRooted($dataDir)) {
        $dataDir = [IO.Path]::GetFullPath((Join-Path (Split-Path $full -Parent) $dataDir))
    }

    $c = [pscustomobject]@{
        ServerAddress          = $v['Server.Address']
        QueryPort              = [int]$v['Server.QueryPort']
        GamePort               = [int]$v['Server.GamePort']
        IntervalSeconds        = [int]$v['Probe.IntervalSeconds']
        GameTimeoutMs          = [int]$v['Probe.GameTimeoutMs']
        PingTimeoutMs          = [int]$v['Probe.PingTimeoutMs']
        PingCount              = [int]$v['Probe.PingCount']
        LinkTargets            = [string[]]@($v['Probe.LinkTargets'] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        DownThreshold          = [int]$v['Debounce.DownThreshold']
        UpThreshold            = [int]$v['Debounce.UpThreshold']
        QuietStart             = [TimeSpan]::Parse($v['Notify.QuietStart'])
        QuietEnd               = [TimeSpan]::Parse($v['Notify.QuietEnd'])
        EmergencyRetrySeconds  = [int]$v['Notify.EmergencyRetrySeconds']
        EmergencyExpireSeconds = [int]$v['Notify.EmergencyExpireSeconds']
        ReminderMinutes        = [int]$v['Notify.ReminderMinutes']
        ReceiptPollSeconds     = [int]$v['Notify.ReceiptPollSeconds']
        SoundDown              = $v['Notify.SoundDown']
        SoundUp                = $v['Notify.SoundUp']
        SoundInfo              = $v['Notify.SoundInfo']
        DigestGraceHours       = [int]$v['Notify.DigestGraceHours']
        PushoverUserKey        = $v['Pushover.UserKey']
        PushoverAppToken       = $v['Pushover.AppToken']
        DataDir                = $dataDir
        RawRetentionMonths     = [int]$v['Data.RawRetentionMonths']
        HealthcheckUrl         = $v['Health.PingUrl']
    }

    if ($c.EmergencyRetrySeconds -lt 30) { throw "EmergencyRetrySeconds must be >= 30 (Pushover limit); got $($c.EmergencyRetrySeconds)." }
    if ($c.EmergencyExpireSeconds -gt 10800) { throw "EmergencyExpireSeconds must be <= 10800 (Pushover limit); got $($c.EmergencyExpireSeconds)." }
    if ($c.DownThreshold -lt 1 -or $c.UpThreshold -lt 1) { throw 'DownThreshold and UpThreshold must be >= 1.' }
    if ($c.ReminderMinutes -lt 1) { throw "ReminderMinutes must be >= 1; got $($c.ReminderMinutes)." }
    if ($c.ReceiptPollSeconds -lt 1) { throw "ReceiptPollSeconds must be >= 1; got $($c.ReceiptPollSeconds)." }
    if ($c.IntervalSeconds -lt 0) { throw "IntervalSeconds must be >= 0; got $($c.IntervalSeconds)." }
    if ($c.LinkTargets.Count -lt 1) { throw 'LinkTargets must list at least one host (e.g. 1.1.1.1,8.8.8.8).' }
    $c
}
