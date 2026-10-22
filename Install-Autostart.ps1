$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'WifiWatchdog.ps1'
$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`"" -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([timespan]::Zero) -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
Register-ScheduledTask -TaskName 'MarcleWifiWatchdog' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Reconnect office Wi-Fi and use a configured fallback after repeated connectivity failures.' -Force | Out-Null
Write-Host 'Installed. Starts at next sign-in. Use the management menu to start it now.'
