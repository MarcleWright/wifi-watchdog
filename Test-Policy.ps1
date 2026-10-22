$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WifiWatchdog.ps1')
$c = Get-Content (Join-Path $PSScriptRoot 'config.example.json') -Raw | ConvertFrom-Json
$c.PrimaryProfile = 'OfficeWiFi'
$c.FallbackProfile = 'BackupWiFi'
$script:profile = $c.PrimaryProfile
$script:healthy = $false
$script:calls = @()
$script:succeedOn = ''
function Write-WatchLog([string]$Message) {}
function Write-NetworkSnapshot($Config) {}
function Get-WifiProfile($Config) { return $script:profile }
function Test-WifiInternet($Config) { return $script:healthy }
function Connect-WifiProfile($Config, [string]$Profile) {
    $script:calls += $Profile
    return ($Profile -eq $script:succeedOn)
}
function New-State { return @{Failures=0; NextRecovery=[datetime]::MinValue; LastStatus=''} }
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$s = New-State
Invoke-WatchCycle $c $s
Invoke-WatchCycle $c $s
Assert ($script:calls.Count -eq 0) 'Transient failures must not switch networks.'
$script:healthy = $true
Invoke-WatchCycle $c $s
Assert ($s.Failures -eq 0) 'A healthy poll must reset consecutive failures.'
$script:healthy = $false
1..3 | ForEach-Object { Invoke-WatchCycle $c $s }
Assert (($script:calls -join '|') -eq "$($c.PrimaryProfile)|$($c.PrimaryProfile)|$($c.FallbackProfile)") 'Recovery order must be primary twice then fallback.'
1..4 | ForEach-Object { Invoke-WatchCycle $c $s }
Assert ($script:calls.Count -eq 3) 'Cooldown must prevent repeated recovery.'
$script:calls = @()
$script:profile = $c.FallbackProfile
$script:healthy = $true
Invoke-WatchCycle $c (New-State)
Assert ($script:calls.Count -eq 0) 'Healthy fallback must stay connected.'
$script:healthy = $false
$script:profile = 'Unrelated WiFi'
$s = New-State
1..4 | ForEach-Object { Invoke-WatchCycle $c $s }
Assert ($script:calls.Count -eq 0) 'Other user-selected networks must be left alone.'
$script:profile = $c.PrimaryProfile
$script:succeedOn = $c.PrimaryProfile
$s = New-State
1..3 | ForEach-Object { Invoke-WatchCycle $c $s }
Assert ($script:calls.Count -eq 1) 'Primary success must stop recovery before fallback.'
Write-Host 'PASS: transient failure, reset, recovery order, cooldown, stable fallback, manual selection, early success.'
