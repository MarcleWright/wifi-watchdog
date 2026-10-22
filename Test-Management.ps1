$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Manage.ps1')
$testRoot = Join-Path $PSScriptRoot ('test-management-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$fixture = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$fixture.PrimaryProfile = 'OfficeWiFi'
$fixture.FallbackProfile = 'BackupWiFi'
$original = $fixture | ConvertTo-Json -Depth 8
$script:ManageRoot = $testRoot
$script:ManageConfigPath = Join-Path $testRoot 'config.json'
$script:WatchLogDirectory = Join-Path $testRoot 'logs'
Set-Content -LiteralPath $script:ManageConfigPath -Value $original -Encoding UTF8
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Write-WatchLog([string]$Message) {}
$script:mockState = 'Running'
$script:starts = 0
$script:stops = 0
$script:invalid = $false
function Get-ScheduledTask { [pscustomobject]@{ State = $script:mockState } }
function Stop-ScheduledTask { $script:stops++; $script:mockState = 'Ready' }
function Start-ScheduledTask { $script:starts++; $script:mockState = 'Running' }
function Start-Sleep {}
function Get-SavedWifiProfiles { @('OfficeWiFi', 'BackupWiFi') }
function Read-WatchConfig([string]$Path) {
    if ($script:invalid) { throw 'Simulated invalid configuration.' }
    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}
try {
    $parsed = @(ConvertFrom-SavedWifiProfiles @('Profiles on interface WLAN:', '    All User Profile : office:5G', '    Current User Profile : backup', '    <None>'))
    Assert ($parsed.Count -eq 2 -and $parsed[0] -eq 'office:5G') 'Saved-profile parser must retain colon-containing names and ignore headings.'
    $before = Get-Content -LiteralPath $script:ManageConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Save-WifiSelection $before.PrimaryProfile $before.FallbackProfile
    Assert ($script:starts -eq 0 -and $script:stops -eq 0) 'Unchanged preferences must not restart the task.'
    Save-WifiSelection 'BackupWiFi' 'OfficeWiFi'
    $changed = Get-Content -LiteralPath $script:ManageConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ($changed.PrimaryProfile -eq 'BackupWiFi' -and $changed.FallbackProfile -eq 'OfficeWiFi') 'Both roles must save atomically.'
    Assert ($changed.PollSeconds -eq $before.PollSeconds -and $changed.Probes[0].Url -eq $before.Probes[0].Url) 'Other policy settings must remain intact.'
    Assert ($script:starts -eq 1 -and $script:stops -eq 1) 'A running task must restart exactly once.'
    $script:invalid = $true
    $rejected = $false
    try { Save-WifiSelection 'OfficeWiFi' 'BackupWiFi' } catch { $rejected = $true }
    Assert $rejected 'Invalid candidate must be rejected.'
    $after = Get-Content -LiteralPath $script:ManageConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ($after.PrimaryProfile -eq $changed.PrimaryProfile -and $script:starts -eq 1) 'Validation failure must preserve config and running task.'
    $script:invalid = $false
    $script:mockState = 'Ready'
    Save-WifiSelection 'OfficeWiFi' 'BackupWiFi'
    Assert ($script:starts -eq 1) 'Saving preferences must leave a stopped task stopped.'
    $rejected = $false
    try { Save-WifiSelection 'OfficeWiFi' 'OfficeWiFi' } catch { $rejected = $true }
    Assert $rejected 'Identical primary and fallback must be rejected.'
    $script:answers = [Collections.Generic.Queue[string]]::new()
    @('bad', '99', '1', '2') | ForEach-Object { $script:answers.Enqueue($_) }
    function Read-Host { $script:answers.Dequeue() }
    $choice = Read-WifiChoice @('OfficeWiFi', 'BackupWiFi') 'test' 'OfficeWiFi'
    Assert ($choice -eq 'BackupWiFi') 'Invalid indexes and duplicate selection must re-prompt.'
    $script:answers.Enqueue('0')
    Assert ($null -eq (Read-WifiChoice @('a','b') 'test')) 'Zero must cancel.'
    Write-Host 'PASS: profile parsing, no-op save, atomic save, unchanged policy, restart, validation rollback, stopped task, selection and cancel.'
}
finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $parent = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected test path.' }
    Get-ChildItem -LiteralPath $resolved -File | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
    Remove-Item -LiteralPath $resolved
}
