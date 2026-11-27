# Magpie 数据面板（DeskIsle 插件）

一张 DeskIsle 桌面卡片，显示所选周期的费用、请求数和 Token 用量。模型占比和订阅剩余额度使用带名称与百分比的灰色进度条。额度最低的账号排在最前面。网关返回缓存读数时，该行注明缓存时间。卡片底色和状态图标跟随 DeskIsle 主题。

所选周期没有请求时，卡片显示空状态，订阅额度仍可查看。

## 工作原理

发布器启动后立即向 Magpie 查询用量和额度，每轮结束后默认等待 15 秒再查。它从 `~/.config/magpie/settings.json` 读取网关端口（默认地址为 `http://127.0.0.1:3425`），访问 `/v1/magpie/usage` 与 `/v1/magpie/quotas`，并原子更新 `%APPDATA%\DeskIsle\plugins\magpie-usage.json`。DeskIsle 约每 3 秒读取一次这个文件。停止发布器后，桌面会保留最后一次结果。

## 快速使用

```powershell
# 1. 在前台持续同步（Ctrl+C 停止）
pwsh -File .\publishers\magpie-usage\publish-magpie-usage.ps1

# 2. 或注册登录自启任务，在后台持续同步
pwsh -File .\publishers\magpie-usage\publish-magpie-usage.ps1 -InstallTask

# 3. 前台按近 7 日统计，每轮间隔 30 秒（周期支持 today / 7d / 30d / all）
pwsh -File .\publishers\magpie-usage\publish-magpie-usage.ps1 -Period 7d -IntervalSeconds 30

# 4. 仅同步一次后退出
pwsh -File .\publishers\magpie-usage\publish-magpie-usage.ps1 -Once

# 5. 仅预览生成的 DeskIsle v2 JSON（不写文件）
pwsh -File .\publishers\magpie-usage\publish-magpie-usage.ps1 -DryRun

# 6. 停止自启任务并撤下桌面卡片
pwsh -File .\publishers\magpie-usage\publish-magpie-usage.ps1 -UninstallTask -Remove
```

更新脚本后，重启正在运行的发布器以加载新版。使用登录自启任务时，可先运行 `-UninstallTask`，再用原有参数运行 `-InstallTask`。

兼容 PowerShell 7（`pwsh`）与 Windows 自带 PowerShell 5.1（`powershell`）。在前台读取局域网其他主机时，可传 `-Endpoint "http://<ip>:<port>" -ApiKey "<gateway-key>"`。

## 验证测试

```powershell
pwsh -File .\publishers\magpie-usage\test-magpie-usage.ps1
```
