Wi-Fi 自动恢复（Windows PowerShell 5.1）

Windows 本地 Wi-Fi 自动恢复工具：主网络不可用时重连，失败后切换到备用网络。
可复制整个文件夹离线使用。无需下载依赖，使用 Windows 自带 netsh、curl.exe 和 PowerShell。
密码由 Windows 已保存的 Wi-Fi 配置管理，脚本不读取或保存密码。

使用：
首次使用会由管理菜单从 config.example.json 创建本机 config.json；先选 6 设置网络。
接口名默认为 WLAN，其他电脑请先在 config.json 中改成本机接口名（netsh wlan show interfaces 可查看）。
config.json 和 logs/ 仅保留在本机，Git 不跟踪，不会随代码上传。
1. 双击唯一入口 Wi-Fi管理.cmd，按编号选择查看状态、启用、停止或移除后台任务。
2. 选择 6“Wi-Fi 设置”：从已保存的网络中按编号选择主要和兜底 Wi-Fi，输入 S 保存。
   两个网络不能相同，0 可取消。列表是已保存配置，不表示这些网络当前都在附近。
   新网络需先通过 Windows 连接并保存密码，再进入菜单选择；菜单不会读取密码。
   保存前验证配置，保存后正在运行的后台任务会重启加载新配置；未运行则保持停止。
   设置相同配置不会重启。保存不会立即要求连接主网络；后续仍按监测策略工作。
3. 日志在 logs 文件夹，以 UTC 小时分文件，格式为 watchdog-YYYYMMDD-HH.jsonl。

日志排查：
- 保留最近 48 小时的记录；启动时及运行期间写日志时每分钟清理一次，边界小时按记录时间裁剪。
  停止运行、休眠或关机期间无法清理，下一次启动/恢复写日志时补清理。
- 每行是一条 JSON 记录，用记事本即可查看。Timestamp 含本地时区，文件名按 UTC 时间命名。
- 每轮都有 poll_started 和探测结果；没有新记录可能表示进程停止、睡眠或日志写入失败。
- 记录 HTTP 状态码、正文是否匹配、curl 错误码、耗时及连接端 IP；不保存探测网页正文、
  响应头、跳转地址或 Wi-Fi 密码。网络名和本地 IP 属于排障信息，分享日志前可自行打码。
- 恢复前记录网卡状态、IPv4、DNS 和默认路由，方便结合 Clash TUN 判断问题。
- SessionId 标识一次脚本启动，Cycle 标识轮询，RecoveryId 串起同一轮重连和备用切换。
- 查故障时先找 recovery_started，再看 recovery_attempt、connect_request_result、
  connection_verification、probe_result、fallback_started、connection_succeeded 或 recovery_failed。
  cooldown_active 表示尚在冷却，不会重新发起连接。
- probe_result 的 Reason 常见值：timeout 超时；dns_resolution_failed 域名解析失败；
  interface_bind_failed 接口绑定失败；http_redirect_possible_login 收到重定向；
  body_mismatch_possible_login 响应正文不符合预期，可能需要登录，不能仅凭此确定原因。
- startup_failed/cycle_exception 记录异常类型及错误编号。正常退出尽量记录 shutdown；
  强制结束进程、断电等情况下不能保证写入退出记录。
- 日志写入失败会提示警告，恢复网络的逻辑继续执行；日志无法保证覆盖进程被挂起或强制终止期间。

默认策略（修改 config.json 后重启脚本生效）：
- 每轮检查结束后等待 60 秒；两个外网探测站点任意一个返回预期内容即视为正常。
- 连续失败的检测窗口约 2 至 3 分钟，另有探测耗时；不是每分钟重连网络。
- 连续 3 次失败后，断开并重连公司网络，最多尝试 2 次，再尝试备用网络。
- 每次连接等待约 25 秒，另有探测耗时；netsh 返回成功后仍需验证实际可用。
- 一轮恢复结束后冷却 300 秒；都不可用时继续监测，冷却结束再重试。
- 备用网络正常时保持连接。想回公司网络可在 Windows 中手动选择。
- 用户选择这两个配置以外的其他 Wi-Fi 时暂停接管；断开后恢复接管。
- 只操作指定接口；不修改全局代理、DNS、已保存配置顺序或其他网络。

可选：登录 Windows 后自动后台运行
管理菜单选 2：安装或启动后台监测，已经运行则无需重启。
管理菜单选 3：停止本次后台监测，下次登录仍会启动。
管理菜单选 4：停止并删除计划任务，取消自动运行。
管理菜单选 5：打开日志文件夹。
清除任务后可以直接删除整个文件夹。
也可通过 Windows“任务计划程序”找到 MarcleWifiWatchdog，先结束再删除。
这是当前用户的计划任务，不安装 Windows 服务；锁屏后继续，注销后停止。
电脑睡眠期间暂停，唤醒后继续；不要求保存 Windows 密码。

若只想安装而暂不启动，在本目录打开 PowerShell，执行：
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-Autostart.ps1
这会注册当前用户的计划任务 MarcleWifiWatchdog，下次登录开始运行。
系统策略限制任务注册时需要联系管理员。脚本本身不自动申请提权。
移动文件夹后需要重新安装任务。
停止后台任务：
  Stop-ScheduledTask -TaskName MarcleWifiWatchdog
取消自动运行（先停止任务）：
  Unregister-ScheduledTask -TaskName MarcleWifiWatchdog -Confirm:$false

限制：
- 离线可启动和重连，但判断外网可用仍需要探测请求；两个探测站点都被公司策略屏蔽时，
  应把 Probes 换成该环境中可直接访问、响应稳定的地址及其 ExpectedBody。
- 探测不是网速测试，也不能证明所有网站和应用都能访问。若公司登录前已放行探测地址，
  可能把“待登录”误判为正常；需要用真实的未登录场景校准探测地址。
- 不同环境可能限制某个探测站点，请在目标环境验证探测地址后使用；未登录场景也需验证。
- 探测使用指定 Wi-Fi 的 IPv4，绕过应用代理；仅允许通过代理联网的环境需要调整方案。
  VPN 的路由策略仍可能影响判断。
- 网页认证、短信/MFA、过期账号凭据、硬件无线开关、飞行模式或被禁用的网卡需人工处理。
- 电脑睡眠或关机时无法执行；恢复唤醒后会继续。不会阻止系统睡眠。
- 在其他 Wi-Fi 下暂停接管依赖 netsh 的英文或中文字段；本机英文输出已核对。
- Windows 服务或自动连接行为可能自行改变网络；脚本不改系统连接优先级。

自检（模拟策略，不切换网络）：
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Policy.ps1
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Logging.ps1
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Management.ps1

参考：
https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/netsh-wlan
https://curl.se/docs/manpage.html
