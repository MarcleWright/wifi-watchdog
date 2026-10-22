[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Install', 'Start', 'Stop', 'Remove')][string]$Action)
$ErrorActionPreference = 'Stop'
$name = 'MarcleWifiWatchdog'
if ($Action -eq 'Install') {
    & (Join-Path $PSScriptRoot 'Install-Autostart.ps1')
    Start-ScheduledTask -TaskName $name
    Write-Host 'Background monitoring started. Use the management menu to stop or remove it.'
    return
}
$task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
if (-not $task) { Write-Host 'No background task installed.'; return }
switch ($Action) {
    'Start' { Start-ScheduledTask -TaskName $name; Write-Host 'Background monitoring started.' }
    'Stop' {
        Stop-ScheduledTask -TaskName $name
        Write-Host 'Background monitoring stopped. Automatic start at next sign-in is still enabled.'
    }
    'Remove' {
        Stop-ScheduledTask -TaskName $name
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
        if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) { throw 'Task removal could not be verified.' }
        Write-Host 'Background task removed. Automatic start disabled. You can now delete this folder.'
    }
}
