[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Install', 'Start', 'Stop', 'Remove')][string]$Action)
$ErrorActionPreference = 'Stop'
$name = 'MarcleWifiWatchdog'
$task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
if ($Action -in @('Install', 'Start')) {
    & (Join-Path $PSScriptRoot 'Build-Host.ps1')
    $hostPath = Join-Path $PSScriptRoot 'WifiWatchdog.exe'
    if ($task -and [string]$task.State -eq 'Running') {
        if ($task.Actions.Execute -eq $hostPath) {
            Write-Host 'Background monitoring is already running (WifiWatchdog.exe).'
            return
        }
        # Stop the previous PowerShell task before migrating to the named host.
        Stop-ScheduledTask -TaskName $name
        $deadline = (Get-Date).AddSeconds(10)
        do {
            Start-Sleep -Milliseconds 300
            $task = Get-ScheduledTask -TaskName $name
        } while ([string]$task.State -eq 'Running' -and (Get-Date) -lt $deadline)
        if ([string]$task.State -eq 'Running') { throw 'Previous watchdog task did not stop.' }
    }
    & (Join-Path $PSScriptRoot 'Install-Autostart.ps1')
    Start-ScheduledTask -TaskName $name
    Write-Host 'Background monitoring started (WifiWatchdog.exe). Use the management menu to stop or remove it.'
    return
}
if (-not $task) { Write-Host 'No background task installed.'; return }
switch ($Action) {
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
