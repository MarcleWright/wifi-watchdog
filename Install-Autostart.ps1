$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'Build-Host.ps1')
$hostPath = Join-Path $PSScriptRoot 'WifiWatchdog.exe'
$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$action = New-ScheduledTaskAction -Execute $hostPath -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([timespan]::Zero) -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
Register-ScheduledTask -TaskName 'MarcleWifiWatchdog' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Reconnect office Wi-Fi and use a configured fallback after repeated connectivity failures.' -Force | Out-Null
Write-Host 'Installed. Starts at next sign-in. Use the management menu to start it now.'
