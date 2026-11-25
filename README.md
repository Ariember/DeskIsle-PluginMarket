# DeskIsle 插件市场

这个仓库为 DeskIsle 提供可直接安装的桌面卡片及配套动态发布器，目前收录「Windows 快捷键速查」与「Magpie 数据面板」（配套本地发布器见 `publishers/magpie-usage/`）。

## 安装插件

使用支持 GitHub 市场的 DeskIsle，在「管理面板 → 插件 → 插件市场」点击「浏览」，找到插件后点击「安装」。打开「显示桌面卡片」即可在主屏查看。已安装的插件保存在当前用户的 `%APPDATA%\DeskIsle\plugins`，重启后仍会加载。

宿主通过 GitHub 查询最新正式发布，从该发布标签读取 `index.json` 和 `packages/<id>.json`。使用公开市场无需登录 GitHub。[市场发布](https://github.com/Ariember/DeskIsle-PluginMarket/releases/latest) · [DeskIsle 主项目](https://github.com/Ariember/DeskIsle)

支持命令行的宿主也可以这样安装：

```powershell
.\deskisle.exe plugins list | ConvertFrom-Json
.\deskisle.exe plugins install deskisle-windows-shortcuts
```

## 提交插件

1. 在 `packages/<id>.json` 编写 UTF-8 插件文档，使用宿主支持的扩展点。请为包选择稳定 ID。例如 `packages/deskisle-windows-shortcuts.json`。
2. 运行 `deskisle.exe plugins validate <id> packages/<id>.json` 校验包。在 `index.json` 的 `plugins` 数组添加带 `id`、`description` 的条目。升级时沿用 ID 并更新包内的 `version`。
3. 在市场根目录运行 `pwsh -File ./update-index.ps1`，将包内的名称、版本及实际文件字节的 SHA-256 写入索引。运行 `pwsh -File ./update-index.ps1 -Check` 核对索引，然后把索引和包放在同一个提交里。
4. 向本仓库提交 Pull Request。维护者合并后，以该提交创建形如 `v1.1.0` 的新标签，并在 GitHub 发布正式 Release。用户下次浏览或刷新市场时即可发现新内容。已发布标签应保留原内容，修订时发布新标签。

要在发布前预览工作区版本，在市场根目录执行以下设置，再从同一 PowerShell 会话启动 DeskIsle。清除变量后重新启动即可恢复 GitHub 市场。

```powershell
$env:DESKISLE_MARKET_INDEX = (Resolve-Path .\index.json).Path
# 恢复默认来源
Remove-Item Env:\DESKISLE_MARKET_INDEX
```

市场包采用声明式 JSON。宿主在写入安装目录前核对索引摘要、插件元数据和扩展点协议。
