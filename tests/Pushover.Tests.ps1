#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\UT99Monitor.psm1') -Force
    $script:Key = 'uFAKEUSERKEY0000000000000000000'
    $script:Tok = 'aFAKEAPPTOKEN000000000000000000'
    $script:Msg = @{ Title = 'UT99 CRASHED (VPS up)'; Message = 'body'; Priority = 2; Sound = 'siren'; Retry = 300; Expire = 10800
        Timestamp = [DateTimeOffset]::new(2026, 11, 23, 14, 0, 0, [TimeSpan]::Zero) }
    function New-HttpError([int]$code, [string]$text) {
        [Microsoft.PowerShell.Commands.HttpResponseException]::new($text, [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]$code))
    }
}

Describe 'New-PushoverTransport' {
    It 'priority 2 sends retry 300 and expire 10800 and returns the receipt' {
        Mock Invoke-RestMethod -ModuleName UT99Monitor { [pscustomobject]@{ status = 1; receipt = 'rABC123' } }
        $t = New-PushoverTransport -UserKey $Key -AppToken $Tok
        $r = $t.Send($Msg)
        $r.Ok | Should -BeTrue
        $r.Receipt | Should -Be 'rABC123'
        Should -Invoke Invoke-RestMethod -ModuleName UT99Monitor -Times 1 -ParameterFilter {
            $Uri -eq 'https://api.pushover.net/1/messages.json' -and $Method -eq 'Post' -and
            $Body.priority -eq 2 -and $Body.retry -eq 300 -and $Body.expire -eq 10800 -and
            $Body.token -eq $Tok -and $Body.user -eq $Key -and $Body.sound -eq 'siren' -and $Body.timestamp -eq 1795442400
        }
    }

    It 'priority 0 omits retry/expire' {
        Mock Invoke-RestMethod -ModuleName UT99Monitor { [pscustomobject]@{ status = 1 } }
        $t = New-PushoverTransport -UserKey $Key -AppToken $Tok
        $m = $Msg.Clone(); $m.Priority = 0
        $t.Send($m).Ok | Should -BeTrue
        Should -Invoke Invoke-RestMethod -ModuleName UT99Monitor -Times 1 -ParameterFilter {
            $Body.priority -eq 0 -and -not $Body.ContainsKey('retry') -and -not $Body.ContainsKey('expire')
        }
    }

    It '429 is retryable; 400 is not' {
        $t = New-PushoverTransport -UserKey $Key -AppToken $Tok
        Mock Invoke-RestMethod -ModuleName UT99Monitor { throw (New-HttpError 429 'rate limited') }
        $r = $t.Send($Msg)
        $r.Ok | Should -BeFalse
        $r.Retryable | Should -BeTrue
        Mock Invoke-RestMethod -ModuleName UT99Monitor { throw (New-HttpError 400 'bad request') }
        $r = $t.Send($Msg)
        $r.Ok | Should -BeFalse
        $r.Retryable | Should -BeFalse
    }

    It 'network failure is retryable' {
        Mock Invoke-RestMethod -ModuleName UT99Monitor { throw [Net.Http.HttpRequestException]::new('No such host is known.') }
        (New-PushoverTransport -UserKey $Key -AppToken $Tok).Send($Msg).Retryable | Should -BeTrue
    }

    It 'error text does not contain the key or token' {
        Mock Invoke-RestMethod -ModuleName UT99Monitor { throw "failed for token=$Tok user=$Key" }
        $r = (New-PushoverTransport -UserKey $Key -AppToken $Tok).Send($Msg)
        $r.Error | Should -Not -BeNullOrEmpty
        $r.Error | Should -Not -Match $Tok
        $r.Error | Should -Not -Match $Key
    }

    It 'the transport object does not display the keys' {
        $t = New-PushoverTransport -UserKey $Key -AppToken $Tok
        ($t | Format-List * | Out-String) | Should -Not -Match $Tok
    }

    It 'I5: truncates message to 1024 and title to 250 characters' {
        Mock Invoke-RestMethod -ModuleName UT99Monitor { [pscustomobject]@{ status = 1 } }
        $m = $Msg.Clone(); $m.Priority = 0; $m.Message = 'x' * 2000; $m.Title = 'y' * 300
        (New-PushoverTransport -UserKey $Key -AppToken $Tok).Send($m).Ok | Should -BeTrue
        Should -Invoke Invoke-RestMethod -ModuleName UT99Monitor -Times 1 -ParameterFilter {
            $Body.message.Length -eq 1024 -and $Body.message.EndsWith('...') -and $Body.title.Length -eq 250
        }
    }

    It 'GetReceipt maps acknowledged=1 and expired=1' {
        Mock Invoke-RestMethod -ModuleName UT99Monitor { [pscustomobject]@{ status = 1; acknowledged = 1; expired = 1 } }
        $r = (New-PushoverTransport -UserKey $Key -AppToken $Tok).GetReceipt('rABC123')
        $r.Ok | Should -BeTrue
        $r.Acknowledged | Should -BeTrue
        $r.Expired | Should -BeTrue
        Should -Invoke Invoke-RestMethod -ModuleName UT99Monitor -Times 1 -ParameterFilter {
            $Method -eq 'Get' -and $Uri -eq "https://api.pushover.net/1/receipts/rABC123.json?token=$Tok"
        }
    }

    It 'CancelReceipt posts to the cancel endpoint' {
        Mock Invoke-RestMethod -ModuleName UT99Monitor { [pscustomobject]@{ status = 1 } }
        (New-PushoverTransport -UserKey $Key -AppToken $Tok).CancelReceipt('rABC123').Ok | Should -BeTrue
        Should -Invoke Invoke-RestMethod -ModuleName UT99Monitor -Times 1 -ParameterFilter {
            $Method -eq 'Post' -and $Uri -eq 'https://api.pushover.net/1/receipts/rABC123/cancel.json' -and $Body.token -eq $Tok
        }
    }

    It 'rejects a malformed receipt id without calling the API' {
        Mock Invoke-RestMethod -ModuleName UT99Monitor { [pscustomobject]@{ status = 1 } }
        (New-PushoverTransport -UserKey $Key -AppToken $Tok).GetReceipt('../x?y').Ok | Should -BeFalse
        Should -Invoke Invoke-RestMethod -ModuleName UT99Monitor -Times 0
    }
}
