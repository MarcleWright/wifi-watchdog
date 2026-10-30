[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WifiWatchdog.ps1')
$script:ManageRoot = $PSScriptRoot
$script:ManageConfigPath = Join-Path $script:ManageRoot 'config.json'

function ConvertFrom-SavedWifiProfiles([string[]]$Lines) {
    foreach ($line in $Lines) {
        if ($line -match '^\s*(?:All User Profile|Current User Profile|Group Policy Profile|所有用户配置文件|当前用户配置文件|组策略配置文件)\s*[:：]\s*(.+?)\s*$') {
            $Matches[1]
        }
    }
}

function Get-SavedWifiProfiles([string]$Interface) {
    $lines = @(& netsh.exe wlan show profiles "interface=$Interface" 2>&1)
    if ($LASTEXITCODE -ne 0) { throw '无法读取已保存的 Wi-Fi 配置。' }
    return @(ConvertFrom-SavedWifiProfiles $lines | Select-Object -Unique)
}

function Read-WifiChoice([string[]]$Profiles, [string]$Prompt, [string]$Exclude = '') {
    while ($true) {
        $answer = Read-Host "$Prompt（输入编号，0 取消）"
        $number = 0
        if (-not [int]::TryParse($answer, [ref]$number) -or $number -lt 0 -or $number -gt $Profiles.Count) {
            Write-Host '请输入列表中的编号。'; continue
        }
        if ($number -eq 0) { return $null }
        $selected = $Profiles[$number - 1]
        if ($selected -eq $Exclude) { Write-Host '主要和兜底 Wi-Fi 不能相同，请重新选择。'; continue }
        return $selected
    }
}

function Save-WifiSelection([string]$Primary, [string]$Fallback) {
    if ($Primary -eq $Fallback) { throw '主要和兜底 Wi-Fi 不能相同。' }
    $config = Get-Content -LiteralPath $script:ManageConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $available = @(Get-SavedWifiProfiles $config.InterfaceName)
    if ($Primary -notin $available -or $Fallback -notin $available) { throw '所选 Wi-Fi 已不在保存列表中，请重新选择。' }
    if ($config.PrimaryProfile -eq $Primary -and $config.FallbackProfile -eq $Fallback) {
        Write-Host '配置没有变化，后台无需重启。'; return
    }
    $config.PrimaryProfile = $Primary
    $config.FallbackProfile = $Fallback
    $temporary = Join-Path $script:ManageRoot ('config-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, ($config | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        Read-WatchConfig $temporary | Out-Null
        # Replace only after the complete candidate passes the watchdog's own validation.
        [IO.File]::Replace($temporary, $script:ManageConfigPath, ($temporary + '.bak'))
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
        if (Test-Path -LiteralPath ($temporary + '.bak')) { Remove-Item -LiteralPath ($temporary + '.bak') }
    }
    Write-WatchLog 'Wi-Fi preferences changed from management menu.' -Event 'configuration_changed' -Data @{ Primary = $Primary; Fallback = $Fallback }
    Write-Host 'Wi-Fi 设置已保存。保存设置本身不会主动切换当前网络。'
    $task = Get-ScheduledTask -TaskName MarcleWifiWatchdog -ErrorAction SilentlyContinue
    if ($task -and [string]$task.State -eq 'Running') {
        try {
            Stop-ScheduledTask -TaskName MarcleWifiWatchdog
            $deadline = (Get-Date).AddSeconds(10)
            do {
                Start-Sleep -Milliseconds 300
                $task = Get-ScheduledTask -TaskName MarcleWifiWatchdog
            } while ([string]$task.State -eq 'Running' -and (Get-Date) -lt $deadline)
            if ([string]$task.State -eq 'Running') { throw '后台任务尚未停止。' }
            Start-ScheduledTask -TaskName MarcleWifiWatchdog
            Write-Host '后台已重新启动，正在加载新设置。'
        }
        catch { Write-Host "配置已保存，但后台重启未完成：$($_.Exception.Message) 请从主菜单重新启用后台。" -ForegroundColor Yellow }
    }
    else { Write-Host '后台当前未运行，下次启动时使用新设置。前台运行的脚本需手动重启。' }
}

function Show-WifiSettings {
    $config = Get-Content -LiteralPath $script:ManageConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $profiles = @(Get-SavedWifiProfiles $config.InterfaceName)
    if ($profiles.Count -lt 2) { Write-Host '至少需要两个已保存的 Wi-Fi，请先通过 Windows 连接并保存网络。'; return }
    Write-Host "`n当前主要：$($config.PrimaryProfile)"
    Write-Host "当前兜底：$($config.FallbackProfile)"
    Write-Host "`n已保存的 Wi-Fi（不代表当前都在附近）："
    for ($i = 0; $i -lt $profiles.Count; $i++) { Write-Host ('{0,2}. {1}' -f ($i + 1), $profiles[$i]) }
    $primary = Read-WifiChoice $profiles '选择主要 Wi-Fi'
    if ($null -eq $primary) { return }
    $fallback = Read-WifiChoice $profiles '选择兜底 Wi-Fi' $primary
    if ($null -eq $fallback) { return }
    Write-Host "`n主要：$primary`n兜底：$fallback"
    if ((Read-Host '输入 S 保存并应用，其他输入取消') -ieq 'S') { Save-WifiSelection $primary $fallback }
}

function Show-WifiStatus {
    $config = Get-Content -LiteralPath $script:ManageConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $profile = Get-WifiProfile $config
    $task = Get-ScheduledTask -TaskName MarcleWifiWatchdog -ErrorAction SilentlyContinue
    $state = if (-not $task) { '未安装' } elseif ([string]$task.State -eq 'Running') { '运行中' } else { '已安装，未运行' }
    Write-Host "`n当前 Wi-Fi：$profile`n主要：$($config.PrimaryProfile)`n兜底：$($config.FallbackProfile)`n后台：$state"
    Write-Host '正在只读检查联网状态……'
    & (Join-Path $script:ManageRoot 'WifiWatchdog.ps1') -CheckOnly
}

function Start-WifiManagementMenu {
    if (-not (Test-Path -LiteralPath $script:ManageConfigPath)) {
        Copy-Item -LiteralPath (Join-Path $script:ManageRoot 'config.example.json') -Destination $script:ManageConfigPath
        Write-Host '已创建本机配置，请先选择 6 设置主要和兜底 Wi-Fi。'
    }
    while ($true) {
        Write-Host "`n========== Wi-Fi 自动恢复管理 =========="
        Write-Host "1. 查看当前状态`n2. 启用后台监测（登录后自动运行）`n3. 停止后台监测（保留自动运行）`n4. 移除后台任务（取消自动运行）`n5. 打开日志文件夹`n6. Wi-Fi 设置（选择主要 / 兜底）`n0. 退出"
        $choice = Read-Host '请选择'
        try {
            switch ($choice) {
                '0' { return }
                '1' { Show-WifiStatus }
                '2' {
                    Read-WatchConfig $script:ManageConfigPath | Out-Null
                    & (Join-Path $script:ManageRoot 'Background.ps1') -Action Start
                }
                '3' { & (Join-Path $script:ManageRoot 'Background.ps1') -Action Stop }
                '4' { & (Join-Path $script:ManageRoot 'Background.ps1') -Action Remove }
                '5' {
                    $logs = Join-Path $script:ManageRoot 'logs'
                    New-Item -ItemType Directory -Path $logs -Force | Out-Null
                    Invoke-Item -LiteralPath $logs
                }
                '6' { Show-WifiSettings }
                default { Write-Host '请输入菜单编号。' }
            }
        }
        catch { Write-Host "操作失败：$($_.Exception.Message)" -ForegroundColor Red }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $previousTitle = $null
    try {
        try {
            $previousTitle = $Host.UI.RawUI.WindowTitle
            $Host.UI.RawUI.WindowTitle = 'Wi-Fi 管理菜单（可关闭）'
        } catch { }
        Write-Host '此窗口是管理菜单，可以关闭。后台监测进程为 WifiWatchdog.exe。'
        Start-WifiManagementMenu
    }
    finally {
        if ($null -ne $previousTitle) {
            try { $Host.UI.RawUI.WindowTitle = $previousTitle } catch { }
        }
    }
}
