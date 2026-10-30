$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'Build-Host.ps1')
$testRoot = Join-Path $PSScriptRoot ('test-host-' + [guid]::NewGuid().ToString('N') + ' space')
New-Item -ItemType Directory -Path $testRoot | Out-Null
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
try {
    $exe = Join-Path $testRoot 'WifiWatchdog.exe'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'WifiWatchdog.exe') -Destination $exe
    # A local companion fixture isolates host tests from Wi-Fi and the installed task.
    $fixture = @'
param([string]$ConfigPath, [switch]$CheckOnly)
if ($ConfigPath -like '*reject.json') { throw 'PRIVATE_TEST_ERROR_TEXT' }
Write-Host 'This console stream must be suppressed by the background host.'
$result = @{ ProcessName = [Diagnostics.Process]::GetCurrentProcess().ProcessName; PID = $PID
    ConfigPath = $ConfigPath; CheckOnly = [bool]$CheckOnly }
$result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'result.json') -Encoding UTF8
'@
    Set-Content -LiteralPath (Join-Path $testRoot 'WifiWatchdog.ps1') -Value $fixture -Encoding UTF8
    $config = Join-Path $testRoot 'custom settings.json'
    $process = Start-Process -FilePath $exe -ArgumentList @('--check', '--config', ('"' + $config + '"')) -WindowStyle Hidden -PassThru -Wait
    Assert ($process.ExitCode -eq 0) 'Named host check must exit successfully.'
    $result = Get-Content -LiteralPath (Join-Path $testRoot 'result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ($result.ProcessName -eq 'WifiWatchdog' -and $result.PID -eq $process.Id) 'The engine must execute in the named host process.'
    Assert ($result.CheckOnly -and $result.ConfigPath -eq $config) 'Arguments containing spaces must survive without string interpolation.'
    $bytes = [IO.File]::ReadAllBytes($exe)
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
    Assert ([BitConverter]::ToUInt16($bytes, $peOffset + 24 + 68) -eq 2) 'The host must use the Windows GUI subsystem, with no console.'
    $failed = Start-Process -FilePath $exe -ArgumentList @('--check', '--config', ('"' + (Join-Path $testRoot 'reject.json') + '"')) -WindowStyle Hidden -PassThru -Wait
    Assert ($failed.ExitCode -eq 1) 'Fatal engine errors must return nonzero for task restart policy.'
    $logPath = Get-ChildItem -LiteralPath (Join-Path $testRoot 'logs') -Filter '*.jsonl' | Select-Object -First 1 -ExpandProperty FullName
    $log = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8
    Assert (($log | ConvertFrom-Json).Event -eq 'host_failure') 'Host failure must be logged.'
    Assert (-not $log.Contains('PRIVATE_TEST_ERROR_TEXT')) 'Raw exception text must not be persisted.'
    Write-Host 'PASS: in-process engine, argument quoting, console-free binary, failure exit code and safe host diagnostics.'
}
finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $parent = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected test directory.' }
    $logs = Join-Path $resolved 'logs'
    if (Test-Path -LiteralPath $logs) {
        Get-ChildItem -LiteralPath $logs -File | ForEach-Object { Remove-Item -LiteralPath $_.FullName }
        Remove-Item -LiteralPath $logs
    }
    Get-ChildItem -LiteralPath $resolved -File | ForEach-Object { Remove-Item -LiteralPath $_.FullName }
    Remove-Item -LiteralPath $resolved
}
