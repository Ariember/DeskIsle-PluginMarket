# Magpie 数据面板（DeskIsle 插件）

基于 DeskIsle 插件协议 v1（`desktop.cards` v2 高密度液态玻璃卡面），通过本地零依赖发布器读取 Magpie 网关数据，将四组核心指标整合进 **1 张高密度液态玻璃磁贴**：

- **顶部主指标**：周期费用（或调用次数）、请求数、会话数、错误数，右上角胶囊显示统计周期与更新时间。
- **TOKEN 统计**：双列磨砂指标格，左格显示总 Token 与输入/输出拆解，右格显示缓存命中率与缓存读/写（或推理 Token）。
- **模型占比**：多色分段占比进度条与颜色图例，一目了然呈现主力模型分布。
- **订阅配额**：自动读取 `/v1/magpie/quotas`，按剩余最紧排序展示各订阅账号的彩色进度条与重置倒计时。

## 工作原理

DeskIsle 宿主每 3 秒轮询 `%APPDATA%\DeskIsle\plugins\*.json`。本插件的发布器读取本机 Magpie 网关（自动读取 `~/.config/magpie/settings.json` 中的 `port`，默认 `http://127.0.0.1:3425`）的 `/v1/magpie/usage` 与 `/v1/magpie/quotas`，通过原子写入更新 `%APPDATA%\DeskIsle\plugins\magpie-usage.json`。

## 快速使用

```powershell
# 1. 单次同步到桌面（立即生效）
pwsh -File .\publishers\magpie-usage\publish-magpie-usage.ps1

# 2. 注册登录自启后台任务并立即启动（默认每 15 秒刷新）
pwsh -File .\publishers\magpie-usage\publish-magpie-usage.ps1 -InstallTask

# 3. 切换统计周期（支持 today / 7d / 30d / all）
pwsh -File .\publishers\magpie-usage\publish-magpie-usage.ps1 -Period 7d

# 4. 前台实时轮询调试
pwsh -File .\publishers\magpie-usage\publish-magpie-usage.ps1 -Watch -IntervalSeconds 15

# 5. 仅预览生成的 DeskIsle v2 JSON（不写文件）
pwsh -File .\publishers\magpie-usage\publish-magpie-usage.ps1 -DryRun

# 6. 停止自启任务并撤下桌面卡片
pwsh -File .\publishers\magpie-usage\publish-magpie-usage.ps1 -UninstallTask -Remove
```

> 兼容 PowerShell 7（`pwsh`）与 Windows 自带 PowerShell 5.1（`powershell`）。如果 Magpie 运行在局域网其他主机，可传 `-Endpoint "http://<ip>:<port>" -ApiKey "<gateway-key>"`。

## 验证测试

```powershell
pwsh -File .\publishers\magpie-usage\test-magpie-usage.ps1
```
