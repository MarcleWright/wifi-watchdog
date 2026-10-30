$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'WifiWatchdogHost.cs'
$output = Join-Path $PSScriptRoot 'WifiWatchdog.exe'
if ((Test-Path -LiteralPath $output) -and
    (Get-Item -LiteralPath $output).LastWriteTimeUtc -ge (Get-Item -LiteralPath $source).LastWriteTimeUtc -and
    (Get-Item -LiteralPath $output).LastWriteTimeUtc -ge (Get-Item -LiteralPath $PSCommandPath).LastWriteTimeUtc) { return }
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw 'Windows .NET Framework 4.x C# compiler not found.' }
if ($PSVersionTable.PSEdition -eq 'Core') { throw 'Build using Windows PowerShell 5.1, not PowerShell 7.' }
$automation = [System.Management.Automation.PowerShell].Assembly.Location
$temporary = Join-Path $PSScriptRoot ('host-build-' + [guid]::NewGuid().ToString('N') + '.exe')
try {
    & $compiler /nologo /target:winexe /platform:x64 /optimize+ "/reference:$automation" "/out:$temporary" $source
    if ($LASTEXITCODE -ne 0) { throw 'Background host compilation failed.' }
    Copy-Item -LiteralPath $temporary -Destination $output -Force
}
finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
