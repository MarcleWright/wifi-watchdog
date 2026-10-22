$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WifiWatchdog.ps1')
$testRoot = Join-Path $PSScriptRoot ('test-logs-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$script:WatchLogDirectory = $testRoot
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
try {
    $now = [datetime]::UtcNow.Date.AddHours(12).AddMinutes(30)
    $cutoff = $now.AddHours(-48)
    $oldPath = Join-Path $testRoot ('watchdog-{0}.jsonl' -f $now.AddHours(-49).ToString('yyyyMMdd-HH'))
    $edgePath = Join-Path $testRoot ('watchdog-{0}.jsonl' -f $cutoff.ToString('yyyyMMdd-HH'))
    $recentPath = Join-Path $testRoot ('watchdog-{0}.jsonl' -f $now.AddHours(-1).ToString('yyyyMMdd-HH'))
    $otherPath = Join-Path $testRoot 'unrelated.txt'
    Set-Content -LiteralPath $oldPath -Value '{"old":true}' -Encoding UTF8
    $expired = @{ Timestamp = $cutoff.AddMinutes(-1).ToString('o'); Event = 'expired' } | ConvertTo-Json -Compress
    $retained = @{ Timestamp = $cutoff.AddMinutes(1).ToString('o'); Event = 'retained' } | ConvertTo-Json -Compress
    Set-Content -LiteralPath $edgePath -Value @($expired, $retained) -Encoding UTF8
    Set-Content -LiteralPath $recentPath -Value $retained -Encoding UTF8
    Set-Content -LiteralPath $otherPath -Value 'keep' -Encoding UTF8
    Remove-ExpiredWatchLogs $now
    Assert (-not (Test-Path -LiteralPath $oldPath)) 'A file older than 48 hours must be deleted.'
    $edge = @(Get-Content -LiteralPath $edgePath -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
    Assert ($edge.Count -eq 1 -and $edge[0].Event -eq 'retained') 'The boundary file must lose only expired records.'
    Assert (Test-Path -LiteralPath $recentPath) 'Recent files must remain.'
    Assert (Test-Path -LiteralPath $otherPath) 'Unrelated files must remain.'
    Write-WatchLog 'Logging test.' -Event 'test_event' -Data @{ ExitCode = 28; Reason = 'timeout' }
    $today = Join-Path $testRoot ('watchdog-{0}.jsonl' -f [datetime]::UtcNow.ToString('yyyyMMdd-HH'))
    $record = Get-Content -LiteralPath $today -Encoding UTF8 | Select-Object -Last 1 | ConvertFrom-Json
    Assert ($record.Event -eq 'test_event' -and $record.Data.ExitCode -eq 28 -and $record.SessionId) 'Structured diagnostic fields must survive serialization.'
    # Mock only OS/network access; exercise actual probe classification and logging.
    function Get-NetAdapter { return [pscustomobject]@{ Status = 'Up'; ifIndex = 15 } }
    function Get-NetIPAddress { return [pscustomobject]@{ AddressState = 'Preferred'; IPAddress = '192.0.2.2' } }
    function curl.exe { $global:LASTEXITCODE = $script:MockCurlExit; return $script:MockCurlReply }
    $c = [pscustomobject]@{ InterfaceName = 'WLAN'; ProbeTimeoutSeconds = 1
        Probes = @([pscustomobject]@{ Url = 'http://test.invalid/probe'; ExpectedBody = 'expected' }) }
    $script:MockCurlExit = 0
    $script:MockCurlReply = @('expected', '200|192.0.2.1|192.0.2.2|0.1')
    Assert (Test-WifiInternet $c) 'A matching HTTP response must succeed.'
    $script:MockCurlReply = @('PRIVATE_LOGIN_PAGE', '302|192.0.2.1|192.0.2.2|0.1')
    Assert (-not (Test-WifiInternet $c)) 'A login redirect must fail.'
    $script:MockCurlReply = @('PRIVATE_LOGIN_PAGE', '200|192.0.2.1|192.0.2.2|0.1')
    Assert (-not (Test-WifiInternet $c)) 'A 200 login page must fail body validation.'
    $script:MockCurlExit = 28
    $script:MockCurlReply = @('', '000|||1.0')
    Assert (-not (Test-WifiInternet $c)) 'Timeout must fail.'
    $records = @(Get-Content -LiteralPath $today -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
    $reasons = @($records | Where-Object Event -eq 'probe_result' | ForEach-Object { $_.Data.Reason })
    Assert (($reasons -join '|') -eq 'ok|http_redirect_possible_login|body_mismatch_possible_login|timeout') 'Probe logs must preserve precise failure categories.'
    Assert (-not ((Get-Content -LiteralPath $today -Raw) -match 'PRIVATE_LOGIN_PAGE')) 'Response bodies must not enter logs.'
    # An unwritable log location must not interrupt canonical network handling.
    $script:WatchLogDirectory = $otherPath
    Write-WatchLog 'Expected write failure.' -Event 'test_write_failure' -WarningAction SilentlyContinue
    Write-Host 'PASS: 48-hour expiry, boundary pruning, JSON fields, success/redirect/body-mismatch/timeout diagnostics, body exclusion, write-failure isolation.'
}
finally {
    # Only the explicitly created test directory is eligible for cleanup.
    $resolvedTest = [IO.Path]::GetFullPath($testRoot)
    $expectedParent = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    if (-not $resolvedTest.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected test path.' }
    Get-ChildItem -LiteralPath $resolvedTest -File | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
    Remove-Item -LiteralPath $resolvedTest
}
