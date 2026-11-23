# GameSpy.ps1 — UT99 \status\ query over UDP, with multi-packet reassembly (spec §6.1).

function ConvertFrom-GameSpyPackets {
    # Merges GameSpy reply packets (any arrival order). Returns $null unless the packet carrying
    # \final\ has arrived AND every fragment 1..n of that query id is present.
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$Packets = @())

    $data = @{}
    $fragments = @{}
    $finalFragment = $null
    $queryNumber = $null

    foreach ($packet in $Packets) {
        $parts = $packet.Split('\')
        # parts[0] is the empty string before the leading backslash.
        $fragment = $null
        $isFinal = $false
        for ($i = 1; $i -lt $parts.Length; $i += 2) {
            $key = $parts[$i]
            if ($key -eq '') { continue }
            if ($key -eq 'final') { $isFinal = $true; continue }
            $value = if ($i + 1 -lt $parts.Length) { $parts[$i + 1] } else { '' }
            if ($key -eq 'queryid') {
                $qp = $value.Split('.')
                $queryNumber = $qp[0]
                $fragment = if ($qp.Length -gt 1) { [int]$qp[1] } else { 1 }
                continue
            }
            $data[$key] = $value
        }
        if ($null -eq $fragment) { $fragment = 1 }
        $fragments[$fragment] = $true
        if ($isFinal) { $finalFragment = $fragment }
    }

    if ($null -eq $finalFragment) { return $null }
    for ($n = 1; $n -le $finalFragment; $n++) {
        if (-not $fragments.ContainsKey($n)) { return $null }
    }
    if ($null -ne $queryNumber) { $data['_queryid'] = $queryNumber }
    $data
}

function Invoke-GameSpyStatus {
    # Sends \status\ and accumulates replies until complete or TimeoutMs elapses. Never throws.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMs = 3000
    )

    $result = [pscustomobject]@{
        Ok = $false; LatencyMs = 0; Map = $null; NumPlayers = 0; MaxPlayers = 0; QueryId = 0; Error = $null
    }
    $client = $null
    try {
        $target = [Net.IPAddress]::None
        if (-not [Net.IPAddress]::TryParse($Address, [ref]$target)) {
            $target = ([Net.Dns]::GetHostAddresses($Address) | Where-Object AddressFamily -eq 'InterNetwork' | Select-Object -First 1)
        }
        $client = [Net.Sockets.UdpClient]::new([Net.Sockets.AddressFamily]::InterNetwork)
        $remote = [Net.IPEndPoint]::new($target, $Port)
        $query = [Text.Encoding]::ASCII.GetBytes('\status\')
        $sw = [Diagnostics.Stopwatch]::StartNew()
        [void]$client.Send($query, $query.Length, $remote)

        $packets = [Collections.Generic.List[string]]::new()
        while ($true) {
            $remaining = $TimeoutMs - [int]$sw.ElapsedMilliseconds
            if ($remaining -le 0) {
                $result.Error = if ($packets.Count) { "incomplete reply ($($packets.Count) packet(s)) after ${TimeoutMs}ms" } else { "no reply after ${TimeoutMs}ms" }
                break
            }
            $client.Client.ReceiveTimeout = $remaining
            $from = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0)
            try {
                $bytes = $client.Receive([ref]$from)
            } catch [Net.Sockets.SocketException] {
                $code = $_.Exception.SocketErrorCode
                if ($code -eq [Net.Sockets.SocketError]::TimedOut) { continue }
                $result.Error = if ($code -eq [Net.Sockets.SocketError]::ConnectionReset) { 'port unreachable' } else { "socket error: $code" }
                break
            }
            if (-not ($from.Address.Equals($target) -and $from.Port -eq $Port)) { continue }
            $packets.Add([Text.Encoding]::ASCII.GetString($bytes))
            $parsed = ConvertFrom-GameSpyPackets -Packets $packets
            if ($null -ne $parsed) {
                $result.Ok = $true
                $result.LatencyMs = [int]$sw.ElapsedMilliseconds
                $result.Map = $parsed['mapname']
                $result.NumPlayers = [int]("0" + $parsed['numplayers'])
                $result.MaxPlayers = [int]("0" + $parsed['maxplayers'])
                $result.QueryId = [int]("0" + $parsed['_queryid'])
                break
            }
        }
    } catch {
        $result.Ok = $false
        $result.Error = "probe error: $($_.Exception.Message)"
    } finally {
        if ($client) { $client.Dispose() }
    }
    $result
}
