# Probes.ps1 — ICMP echo, and one probe cycle resolved to a classification (spec §6.2–6.3).

function Test-IcmpEcho {
    # Ok if any of Count echoes is answered within TimeoutMs. Never throws.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Target,
        [int]$TimeoutMs = 1000,
        [int]$Count = 2
    )
    $ping = [Net.NetworkInformation.Ping]::new()
    try {
        for ($i = 0; $i -lt [Math]::Max(1, $Count); $i++) {
            try {
                $reply = $ping.Send($Target, $TimeoutMs)
                if ($reply.Status -eq [Net.NetworkInformation.IPStatus]::Success) {
                    return @{ Ok = $true; LatencyMs = [int]$reply.RoundtripTime }
                }
            } catch {
                # PingException (e.g. no route): counts as no reply.
            }
        }
        @{ Ok = $false; LatencyMs = 0 }
    } finally {
        $ping.Dispose()
    }
}

function Invoke-ProbeCycle {
    # Game probe; host ping only if the game fails; link pings only if the host fails too.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [scriptblock]$GameProbe,
        [scriptblock]$PingProbe
    )
    if (-not $GameProbe) {
        $GameProbe = { Invoke-GameSpyStatus -Address $Config.ServerAddress -Port $Config.QueryPort -TimeoutMs $Config.GameTimeoutMs }
    }
    if (-not $PingProbe) {
        $PingProbe = { param($Target) Test-IcmpEcho -Target $Target -TimeoutMs $Config.PingTimeoutMs -Count $Config.PingCount }
    }

    $result = [pscustomobject]@{
        Classification = $null; Game = $null; HostPing = $null; LinkPings = $null; Snapshot = $null
    }

    $result.Game = & $GameProbe
    if ($result.Game.Ok) {
        $result.Classification = 'UP'
        $result.Snapshot = @{ Map = $result.Game.Map; NumPlayers = $result.Game.NumPlayers; MaxPlayers = $result.Game.MaxPlayers }
        return $result
    }

    $result.HostPing = & $PingProbe $Config.ServerAddress
    if ($result.HostPing.Ok) {
        $result.Classification = 'GAME_DOWN'
        return $result
    }

    $links = @()
    $linkUp = $false
    foreach ($t in $Config.LinkTargets) {
        $r = & $PingProbe $t
        $links += , @{ Target = $t; Ok = [bool]$r.Ok; LatencyMs = $r.LatencyMs }
        if ($r.Ok) { $linkUp = $true; break }
    }
    $result.LinkPings = $links
    $result.Classification = if ($linkUp) { 'HOST_DOWN' } else { 'LINK_DOWN' }
    $result
}
