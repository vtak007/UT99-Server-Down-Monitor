# Health.ps1 — per-cycle hook for an external dead-man's switch such as Healthchecks.io (spec §6.10, deferred).

function Invoke-CycleHook {
    # No-op unless a URL is configured. Never throws; at most 5 s.
    [CmdletBinding()]
    param([string]$Url)
    if (-not $Url) { return }
    try { [void](Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec 5 -UseBasicParsing) } catch { }
}
