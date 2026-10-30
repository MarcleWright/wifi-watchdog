[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [switch]$CheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'config.json' }

$script:WatchLogDirectory = Join-Path $PSScriptRoot 'logs'
$script:WatchSession = [guid]::NewGuid().ToString('N')
$script:WatchCycle = 0
$script:WatchRecovery = ''
$script:LastLogCleanup = [datetime]::MinValue

function Remove-ExpiredWatchLogs([datetime]$NowUtc = [datetime]::UtcNow) {
    $cutoff = $NowUtc.AddHours(-48)
    $boundary = $cutoff.ToString('yyyyMMdd-HH')
    foreach ($file in @(Get-ChildItem -LiteralPath $script:WatchLogDirectory -File -Filter 'watchdog-*.jsonl')) {
        if ($file.Name -notmatch '^watchdog-(\d{8}-\d{2})\.jsonl$') { continue }
        $bucket = $Matches[1]
        if ([string]::CompareOrdinal($bucket, $boundary) -lt 0) {
            Remove-Item -LiteralPath $file.FullName -Force
        }
        elseif ($bucket -eq $boundary) {
            # Prune the boundary hour by record time, rather than retaining an extra hour.
            $retained = @(Get-Content -LiteralPath $file.FullName -Encoding UTF8 | Where-Object {
                try { [datetimeoffset]::Parse(($_ | ConvertFrom-Json).Timestamp).UtcDateTime -ge $cutoff }
                catch { $false }
            })
            if ($retained.Count) { [IO.File]::WriteAllLines($file.FullName, [string[]]$retained, (New-Object Text.UTF8Encoding($false))) }
            else { Remove-Item -LiteralPath $file.FullName -Force }
        }
    }
}

function Write-WatchLog(
    [string]$Message,
    [string]$Event = 'message',
    [hashtable]$Data = @{},
    [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
) {
    $now = [datetimeoffset]::Now
    Write-Host ('{0} [{1}] {2}' -f $now.ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message)
    try {
        New-Item -ItemType Directory -Path $script:WatchLogDirectory -Force | Out-Null
        if (($now.UtcDateTime - $script:LastLogCleanup).TotalSeconds -ge 60) {
            try { Remove-ExpiredWatchLogs $now.UtcDateTime }
            catch { Write-Warning ('Cannot clean expired watchdog logs: {0}' -f $_.Exception.GetType().Name) }
            $script:LastLogCleanup = $now.UtcDateTime
        }
        $record = [ordered]@{ Timestamp = $now.ToString('o'); Level = $Level; Event = $Event
            SessionId = $script:WatchSession; Cycle = $script:WatchCycle; RecoveryId = $script:WatchRecovery
            Message = $Message; Data = $Data }
        $path = Join-Path $script:WatchLogDirectory ('watchdog-{0}.jsonl' -f $now.UtcDateTime.ToString('yyyyMMdd-HH'))
        $line = ConvertTo-Json -InputObject $record -Depth 8 -Compress
        [IO.File]::AppendAllText($path, $line + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    }
    catch {
        # Logging failure must not prevent network recovery. No raw exception text is persisted.
        Write-Warning ('Cannot write watchdog log: {0}' -f $_.Exception.GetType().Name)
    }
}

function Write-NetworkSnapshot($Config) {
    try {
        $adapter = Get-NetAdapter -Name $Config.InterfaceName
        $ips = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty IPAddress)
        $dns = @(Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 | ForEach-Object { $_.ServerAddresses })
        $routes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Select-Object InterfaceAlias, NextHop, RouteMetric)
        Write-WatchLog 'Network snapshot before recovery.' -Event 'network_snapshot' -Data @{
            Interface = $Config.InterfaceName; AdapterStatus = [string]$adapter.Status; IPv4 = $ips; DnsServers = $dns; DefaultRoutes = $routes }
    }
    catch { Write-WatchLog 'Network snapshot unavailable.' -Event 'snapshot_failed' -Level WARN -Data @{ ErrorType = $_.Exception.GetType().Name } }
}

function Read-WatchConfig([string]$Path) {
    $c = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($key in @('InterfaceName', 'PrimaryProfile', 'FallbackProfile')) {
        if ([string]::IsNullOrWhiteSpace($c.$key)) { throw "Configure $key in $Path first." }
    }
    if ($c.PrimaryProfile -eq $c.FallbackProfile) { throw 'Primary and fallback must be different.' }
    foreach ($key in @('PollSeconds', 'FailureThreshold', 'PrimaryAttempts', 'ConnectWaitSeconds', 'CooldownSeconds', 'ProbeTimeoutSeconds')) {
        if ($c.$key -isnot [int] -and $c.$key -isnot [long]) { throw "$key must be an integer." }
        if ($c.$key -lt 1) { throw "$key must be positive." }
    }
    if (@($c.Probes).Count -lt 1) { throw 'Configure at least one connectivity probe.' }
    foreach ($probe in $c.Probes) {
        $uri = [uri]$probe.Url
        if ($uri.Scheme -notin @('http', 'https') -or [string]::IsNullOrEmpty($probe.ExpectedBody)) {
            throw 'Each probe needs an HTTP(S) URL and an exact expected body.'
        }
    }
    Get-Command netsh.exe, curl.exe -ErrorAction Stop | Out-Null
    Get-NetAdapter -Name $c.InterfaceName -ErrorAction Stop | Out-Null
    foreach ($profile in @($c.PrimaryProfile, $c.FallbackProfile)) {
        & netsh.exe wlan show profile "name=$profile" "interface=$($c.InterfaceName)" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Saved Wi-Fi profile not found: $profile" }
    }
    return $c
}

function Get-WifiProfile($Config) {
    # Restrict parsing to the configured interface; supports English and Chinese Windows.
    $lines = @(& netsh.exe wlan show interfaces 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot query Wi-Fi interfaces.' }
    $inside = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*(?:Name|\u540d\u79f0)\s*[:\uff1a]\s*(.*?)\s*$') {
            $inside = ($Matches[1] -eq $Config.InterfaceName)
        }
        if ($inside -and $line -match '^\s*(?:Profile|\u914d\u7f6e\u6587\u4ef6)\s*[:\uff1a]\s*(.*?)\s*$') {
            return $Matches[1]
        }
    }
    return ''
}

function Test-WifiInternet($Config) {
    $adapter = Get-NetAdapter -Name $Config.InterfaceName -ErrorAction Stop
    if ($adapter.Status -ne 'Up') {
        Write-WatchLog 'Wi-Fi adapter is not up.' -Event 'adapter_unavailable' -Level WARN -Data @{ Status = [string]$adapter.Status }
        return $false
    }
    $addresses = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.AddressState -eq 'Preferred' -and $_.IPAddress -notlike '169.254.*' })
    if ($addresses.Count -eq 0) {
        Write-WatchLog 'No usable Wi-Fi IPv4 address.' -Event 'ipv4_unavailable' -Level WARN
        return $false
    }
    foreach ($probe in $Config.Probes) {
        # A real response body rejects captive portals. Do not follow redirects.
        # Bind the source address and bypass application proxies; TUN/DNS can still affect routing.
        $args = @('--disable', '--silent', '--noproxy', '*', '--ipv4', '--interface', $addresses[0].IPAddress,
            '--connect-timeout', [string]$Config.ProbeTimeoutSeconds, '--max-time', [string]$Config.ProbeTimeoutSeconds,
            '--max-filesize', '4096', '--write-out', '\n%{http_code}|%{remote_ip}|%{local_ip}|%{time_total}', '--url', [string]$probe.Url)
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $reply = @(& curl.exe @args 2>$null)
        $exitCode = $LASTEXITCODE
        $timer.Stop()
        $meta = @('', '', '', '')
        if ($reply.Count -gt 0) { $meta = @(([string]$reply[-1]) -split '\|', 4) }
        $http = if ($meta.Count -eq 4) { $meta[0] } else { '' }
        $matched = $false
        if ($exitCode -eq 0 -and $reply.Count -ge 2 -and $http -eq '200') {
            $body = ($reply[0..($reply.Count - 2)] -join "`n").Trim()
            $matched = ($body -ceq ([string]$probe.ExpectedBody).Trim())
        }
        $reason = if ($exitCode -ne 0) { switch ($exitCode) {
            5 { 'proxy_resolution_failed' }; 6 { 'dns_resolution_failed' }; 7 { 'connection_failed' }
            28 { 'timeout' }; 45 { 'interface_bind_failed' }; 60 { 'tls_verification_failed' }
            63 { 'response_too_large' }; default { 'curl_failed' }
        } } elseif ($http -match '^3\d\d$') { 'http_redirect_possible_login' }
        elseif ($http -ne '200') { 'http_status_failed' }
        elseif (-not $matched) { 'body_mismatch_possible_login' } else { 'ok' }
        $data = @{ ProbeHost = ([uri]$probe.Url).DnsSafeHost; LocalIPv4 = $addresses[0].IPAddress
            CurlExit = $exitCode; HttpStatus = $http; BodyMatched = $matched; Reason = $reason
            DurationMs = [math]::Round($timer.Elapsed.TotalMilliseconds) }
        # IP metadata is diagnostic only; never retain response bodies, headers, or redirect URLs.
        if ($meta.Count -eq 4) { $data.RemoteIP = $meta[1]; $data.ActualLocalIP = $meta[2] }
        $level = if ($matched) { 'INFO' } else { 'WARN' }
        Write-WatchLog "Probe: $reason" -Event 'probe_result' -Level $level -Data $data
        if ($matched) { return $true }
    }
    return $false
}

function Connect-WifiProfile($Config, [string]$Profile) {
    $current = Get-WifiProfile $Config
    if ($current -and $current -notin @($Config.PrimaryProfile, $Config.FallbackProfile)) {
        throw "Recovery stopped because another Wi-Fi was selected: $current"
    }
    Write-WatchLog "Connecting: $Profile" -Event 'connection_started' -Data @{ Target = $Profile; Previous = $current }
    $disconnectOutput = @(& netsh.exe wlan disconnect "interface=$($Config.InterfaceName)" 2>&1)
    $disconnectExit = $LASTEXITCODE
    Write-WatchLog 'Disconnect request completed.' -Event 'disconnect_result' -Data @{ ExitCode = $disconnectExit }
    Start-Sleep -Seconds 2
    $connectOutput = @(& netsh.exe wlan connect "name=$Profile" "interface=$($Config.InterfaceName)" 2>&1)
    $connectExit = $LASTEXITCODE
    # This command only reports connection requests; its output contains no saved keys.
    $summary = ($connectOutput -join ' ').Trim()
    if ($summary.Length -gt 1200) { $summary = $summary.Substring(0, 1200) }
    Write-WatchLog 'Connect request completed.' -Event 'connect_request_result' -Data @{ Target = $Profile; ExitCode = $connectExit; Summary = $summary }
    if ($connectExit -ne 0) { Write-WatchLog "Connection request failed: $Profile" -Event 'connection_failed' -Level WARN; return $false }
    # netsh success only acknowledges the request; verify association and actual access.
    $deadline = (Get-Date).AddSeconds($Config.ConnectWaitSeconds)
    do {
        Start-Sleep -Seconds 3
        $actual = Get-WifiProfile $Config
        Write-WatchLog 'Checking connection result.' -Event 'connection_verification' -Data @{ Target = $Profile; Actual = $actual }
        if ($actual -eq $Profile -and (Test-WifiInternet $Config)) {
            Write-WatchLog "Connected and internet verified: $Profile" -Event 'connection_succeeded'
            return $true
        }
    } while ((Get-Date) -lt $deadline)
    Write-WatchLog "Internet verification failed: $Profile" -Event 'connection_timed_out' -Level WARN -Data @{ Actual = $actual }
    return $false
}

function Invoke-WatchCycle($Config, [hashtable]$State) {
    $script:WatchCycle++
    $profile = Get-WifiProfile $Config
    Write-WatchLog 'Polling Wi-Fi.' -Event 'poll_started' -Data @{ Profile = $profile; Interface = $Config.InterfaceName }
    # Leave other networks selected by the user alone, including a manual office/home switch.
    if ($profile -and $profile -notin @($Config.PrimaryProfile, $Config.FallbackProfile)) {
        $State.Failures = 0
        if ($State.LastStatus -ne "unmanaged:$profile") { Write-WatchLog "Other Wi-Fi selected; monitoring paused: $profile" }
        $State.LastStatus = "unmanaged:$profile"
        return
    }
    if (Test-WifiInternet $Config) {
        $State.Failures = 0
        if ($State.LastStatus -ne "healthy:$profile") { Write-WatchLog "Healthy: $profile" }
        $State.LastStatus = "healthy:$profile"
        return
    }
    $State.Failures++
    $State.LastStatus = 'unhealthy'
    Write-WatchLog "Connectivity failure $($State.Failures)/$($Config.FailureThreshold); profile=$profile"
    if ($State.Failures -lt $Config.FailureThreshold) { return }
    if ((Get-Date) -lt $State.NextRecovery) {
        Write-WatchLog 'Recovery deferred during cooldown.' -Event 'cooldown_active' -Data @{ NextRecovery = $State.NextRecovery.ToString('o') }
        return
    }
    $script:WatchRecovery = [guid]::NewGuid().ToString('N')
    Write-WatchLog 'Recovery started.' -Event 'recovery_started'
    Write-NetworkSnapshot $Config
    try {
        for ($attempt = 1; $attempt -le $Config.PrimaryAttempts; $attempt++) {
            Write-WatchLog 'Trying primary network.' -Event 'recovery_attempt' -Data @{ Attempt = $attempt; Target = $Config.PrimaryProfile }
            if (Connect-WifiProfile $Config $Config.PrimaryProfile) { return }
        }
        Write-WatchLog 'Trying fallback network.' -Event 'fallback_started' -Data @{ Target = $Config.FallbackProfile }
        if (Connect-WifiProfile $Config $Config.FallbackProfile) { return }
        Write-WatchLog 'Both networks unavailable. Will retry after cooldown.' -Event 'recovery_failed' -Level ERROR
    }
    finally {
        $State.Failures = 0
        $State.NextRecovery = (Get-Date).AddSeconds($Config.CooldownSeconds)
        Write-WatchLog 'Recovery finished; cooldown set.' -Event 'recovery_finished' -Data @{ NextRecovery = $State.NextRecovery.ToString('o') }
        $script:WatchRecovery = ''
    }
}

function Start-WifiWatchdog {
    Write-WatchLog 'Validating startup configuration.' -Event 'startup'
    try { $config = Read-WatchConfig $ConfigPath }
    catch {
        Write-WatchLog 'Startup validation failed.' -Event 'startup_failed' -Level ERROR -Data @{ ErrorType = $_.Exception.GetType().Name; ErrorId = $_.FullyQualifiedErrorId }
        throw
    }
    Write-WatchLog 'Configuration validated.' -Event 'configuration' -Data @{ Interface = $config.InterfaceName
        Primary = $config.PrimaryProfile; Fallback = $config.FallbackProfile; PollSeconds = $config.PollSeconds
        FailureThreshold = $config.FailureThreshold; PrimaryAttempts = $config.PrimaryAttempts
        CooldownSeconds = $config.CooldownSeconds; ConnectWaitSeconds = $config.ConnectWaitSeconds; RetentionHours = 48
        ProcessName = [Diagnostics.Process]::GetCurrentProcess().ProcessName; ProcessId = $PID }
    if ($CheckOnly) {
        $profile = Get-WifiProfile $config
        $healthy = Test-WifiInternet $config
        Write-WatchLog 'Read-only check completed.' -Event 'check_completed' -Data @{ Profile = $profile; Internet = $healthy }
        Write-Host "Interface=$($config.InterfaceName); Profile=$profile; Internet=$healthy"
        return
    }
    $mutex = New-Object System.Threading.Mutex($false, 'Local\MarcleWifiWatchdog')
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) {
            Write-WatchLog 'Another watchdog is already running.' -Event 'duplicate_instance' -Level WARN
            throw 'Wi-Fi watchdog is already running in this session.'
        }
        Write-WatchLog 'Watchdog started. Use the management menu to stop background monitoring.'
        $state = @{ Failures = 0; NextRecovery = [datetime]::MinValue; LastStatus = '' }
        while ($true) {
            try { Invoke-WatchCycle $config $state }
            catch { Write-WatchLog 'Check failed; retry next poll.' -Event 'cycle_exception' -Level ERROR -Data @{ ErrorType = $_.Exception.GetType().Name; ErrorId = $_.FullyQualifiedErrorId } }
            Start-Sleep -Seconds $config.PollSeconds
        }
    }
    finally {
        if ($owned) {
            Write-WatchLog 'Watchdog stopping.' -Event 'shutdown'
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

if ($MyInvocation.InvocationName -ne '.') { Start-WifiWatchdog }
