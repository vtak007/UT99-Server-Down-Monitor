#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\UT99Monitor.psm1') -Force

    $script:Frag1 = '\hostname\FMJ\mapname\DM-Deck16][\numplayers\3\queryid\92.1'
    $script:Frag2 = '\maxplayers\16\player_0\Bob\queryid\92.2'
    $script:Frag3 = '\player_1\Alice\queryid\92.3\final\'

    # Starts a loopback UDP "server" that answers one query with the given packets, in the given order.
    # Returns @{ Port; Job; Client }.
    function Start-FakeGameSpyServer {
        param([string[]]$Replies, [switch]$Silent)
        $client = [Net.Sockets.UdpClient]::new([Net.IPEndPoint]::new([Net.IPAddress]::Loopback, 0))
        $port = $client.Client.LocalEndPoint.Port
        $job = Start-ThreadJob -ArgumentList $client, $Replies, $Silent.IsPresent -ScriptBlock {
            param($c, $replies, $silent)
            $c.Client.ReceiveTimeout = 5000
            $ep = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0)
            try { [void]$c.Receive([ref]$ep) } catch { return }
            if ($silent) { return }
            foreach ($r in $replies) {
                $b = [Text.Encoding]::ASCII.GetBytes($r)
                [void]$c.Send($b, $b.Length, $ep)
            }
        }
        @{ Port = $port; Job = $job; Client = $client }
    }

    function Stop-FakeGameSpyServer($srv) {
        $srv.Job | Wait-Job -Timeout 6 | Out-Null
        $srv.Job | Remove-Job -Force
        $srv.Client.Dispose()
    }
}

Describe 'ConvertFrom-GameSpyPackets' {
    It 'parses a single-packet reply' {
        $r = ConvertFrom-GameSpyPackets -Packets @('\hostname\FMJ\mapname\DM-Deck16][\numplayers\3\maxplayers\16\queryid\92.1\final\')
        $r.mapname | Should -Be 'DM-Deck16]['
        $r.numplayers | Should -Be '3'
        $r._queryid | Should -Be '92'
        $r.ContainsKey('final') | Should -BeFalse
        $r.ContainsKey('queryid') | Should -BeFalse
    }

    It 'merges three fragments received out of order' {
        $r = ConvertFrom-GameSpyPackets -Packets @($Frag3, $Frag1, $Frag2)
        $r.mapname | Should -Be 'DM-Deck16]['
        $r.maxplayers | Should -Be '16'
        $r.player_1 | Should -Be 'Alice'
    }

    It 'returns null when the final fragment has not arrived' {
        ConvertFrom-GameSpyPackets -Packets @($Frag1, $Frag2) | Should -BeNullOrEmpty
    }

    It 'returns null when a middle fragment is missing' {
        ConvertFrom-GameSpyPackets -Packets @($Frag1, $Frag3) | Should -BeNullOrEmpty
    }

    It 'ignores an absurd fragment number quickly' {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        ConvertFrom-GameSpyPackets -Packets @('\a\b\queryid\5.2147483647\final\') | Should -BeNullOrEmpty
        $sw.ElapsedMilliseconds | Should -BeLessThan 500
    }

    It 'ignores a non-numeric fragment number without throwing' {
        { ConvertFrom-GameSpyPackets -Packets @('\a\b\queryid\5.x\final\') } | Should -Not -Throw
        ConvertFrom-GameSpyPackets -Packets @('\a\b\queryid\5.x\final\') | Should -BeNullOrEmpty
    }

    It 'does not mix fragments from different query ids' {
        $q93a = '\maxplayers\16\queryid\93.2'
        $q93b = '\player_1\Alice\queryid\93.3\final\'
        ConvertFrom-GameSpyPackets -Packets @($Frag1, $q93a, $q93b) | Should -BeNullOrEmpty
    }

    It 'completes one query id even with a stray packet from another' {
        $stray = '\hostname\EVIL\mapname\DM-Fake\queryid\93.1'
        $r = ConvertFrom-GameSpyPackets -Packets @($stray, $Frag1, $Frag2, $Frag3)
        $r.mapname | Should -Be 'DM-Deck16]['
        $r.hostname | Should -Be 'FMJ'
    }
}

Describe 'Invoke-GameSpyStatus' {
    It 'queries a loopback fake server' {
        $srv = Start-FakeGameSpyServer -Replies @($Frag2, $Frag3, $Frag1)
        try {
            $r = Invoke-GameSpyStatus -Address '127.0.0.1' -Port $srv.Port -TimeoutMs 2000
        } finally { Stop-FakeGameSpyServer $srv }
        $r.Ok | Should -BeTrue
        $r.Map | Should -Be 'DM-Deck16]['
        $r.NumPlayers | Should -Be 3
        $r.MaxPlayers | Should -Be 16
        $r.QueryId | Should -Be 92
        $r.LatencyMs | Should -BeGreaterOrEqual 0
    }

    It 'times out cleanly when nothing replies' {
        $srv = Start-FakeGameSpyServer -Replies @() -Silent
        try {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-GameSpyStatus -Address '127.0.0.1' -Port $srv.Port -TimeoutMs 500
            $sw.Stop()
        } finally { Stop-FakeGameSpyServer $srv }
        $r.Ok | Should -BeFalse
        $r.Error | Should -Not -BeNullOrEmpty
        $sw.ElapsedMilliseconds | Should -BeLessThan 1500
    }

    It 'times out when only part of a multi-packet reply arrives' {
        $srv = Start-FakeGameSpyServer -Replies @($Frag1, $Frag3)
        try {
            $r = Invoke-GameSpyStatus -Address '127.0.0.1' -Port $srv.Port -TimeoutMs 500
        } finally { Stop-FakeGameSpyServer $srv }
        $r.Ok | Should -BeFalse
    }

    It 'treats port-unreachable as failure, not exception' {
        $tmp = [Net.Sockets.UdpClient]::new([Net.IPEndPoint]::new([Net.IPAddress]::Loopback, 0))
        $port = $tmp.Client.LocalEndPoint.Port
        $tmp.Dispose()
        { $script:pu = Invoke-GameSpyStatus -Address '127.0.0.1' -Port $port -TimeoutMs 500 } | Should -Not -Throw
        $script:pu.Ok | Should -BeFalse
    }
}
