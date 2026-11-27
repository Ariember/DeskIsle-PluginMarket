<#
.SYNOPSIS
    DeskIsle Magpie 高密度数据面板发布器（DeskIsle 插件协议 v1 / desktop.cards v2）。

.DESCRIPTION
    从本机（或指定地址）Magpie 网关读取用量与订阅额度，生成一张桌面卡片：
      - 顶部主读数：今日费用 / 请求数 / 会话数 / 错误数 + 右上角周期与时间胶囊
      - TOKEN 统计：双列紧凑指标格（总 Token 含输入/输出 + 缓存命中率含缓读/缓写）
      - 模型占比：按模型标注名称和百分比的灰色进度条
      - 订阅配额：各订阅账号剩余百分比进度条与重置倒计时
    通过原子替换写入 %APPDATA%\DeskIsle\plugins\magpie-usage.json（或指定目录）。

.EXAMPLE
    # 单次同步到 DeskIsle 桌面卡片
    pwsh -File .\publish-magpie-usage.ps1 -Once

.EXAMPLE
    # 使用近 7 日统计刷新桌面卡片
    pwsh -File .\publish-magpie-usage.ps1 -Period 7d

.EXAMPLE
    # 注册当前用户登录自启后台任务并立即启动（默认每 15 秒刷新）
    pwsh -File .\publish-magpie-usage.ps1 -InstallTask

.EXAMPLE
    # 卸载后台任务并撤下桌面卡片
    pwsh -File .\publish-magpie-usage.ps1 -UninstallTask -Remove
#>
[CmdletBinding()]
param(
    [ValidateSet('today', '7d', '30d', 'all')]
    [string]$Period = 'today',

    [ValidateRange(3, 3600)]
    [int]$IntervalSeconds = 15,

    [switch]$Once,
    [switch]$Watch,
    [switch]$InstallTask,
    [switch]$UninstallTask,
    [switch]$Remove,
    [switch]$DryRun,

    [string]$Endpoint,
    [string]$ApiKey,
    [string]$OutputDir,

    [ValidateRange(1, 30)]
    [int]$TimeoutSeconds = 15,

    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')]
    [string]$PluginId = 'magpie-usage'
)

$ErrorActionPreference = 'Stop'

$Script:PluginName = 'Magpie 数据面板'
$Script:PluginVersion = '1.1.0'
$Script:TaskName = 'DeskIsle-Magpie-Usage'

function Get-DefaultPluginsDir {
    if ($OutputDir) {
        return $OutputDir
    }
    $appData = [Environment]::GetFolderPath('ApplicationData')
    if ([string]::IsNullOrWhiteSpace($appData)) {
        throw '无法获取当前用户的 AppData 目录。'
    }
    return (Join-Path (Join-Path $appData 'DeskIsle') 'plugins')
}

function Get-MagpieSettingsPath {
    if ($env:XDG_CONFIG_HOME) {
        $xdg = Join-Path (Join-Path $env:XDG_CONFIG_HOME 'magpie') 'settings.json'
        if (Test-Path -LiteralPath $xdg) {
            return $xdg
        }
    }
    $homeDir = [Environment]::GetFolderPath('UserProfile')
    return (Join-Path (Join-Path (Join-Path $homeDir '.config') 'magpie') 'settings.json')
}

function Resolve-MagpieEndpoint {
    param([string]$ExplicitEndpoint)
    if (-not [string]::IsNullOrWhiteSpace($ExplicitEndpoint)) {
        return $ExplicitEndpoint.TrimEnd('/')
    }
    $port = 3425
    $settingsPath = Get-MagpieSettingsPath
    if (Test-Path -LiteralPath $settingsPath) {
        try {
            $raw = [System.IO.File]::ReadAllText($settingsPath, [System.Text.Encoding]::UTF8)
            $cfg = $raw | ConvertFrom-Json
            if ($null -ne $cfg.port) {
                $parsed = 0
                if ([int]::TryParse([string]$cfg.port, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 65535) {
                    $port = $parsed
                }
            }
        } catch {
            # Ignore unreadable or partial settings.json and fall back to default 3425.
        }
    }
    return "http://127.0.0.1:$port"
}

function Invoke-MagpieJson {
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$BearerKey,
        [int]$TimeoutSec = 5
    )
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method = 'GET'
    $request.Accept = 'application/json'
    $request.UserAgent = "DeskIsle-Magpie-Usage/$Script:PluginVersion"
    $request.Timeout = $TimeoutSec * 1000
    $request.ReadWriteTimeout = $TimeoutSec * 1000
    $request.AllowAutoRedirect = $false
    if (-not [string]::IsNullOrWhiteSpace($BearerKey)) {
        $request.Headers.Add('Authorization', "Bearer $BearerKey")
    }

    $response = $null
    try {
        $response = $request.GetResponse()
        $stream = $response.GetResponseStream()
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true)
        try {
            $body = $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
            $stream.Dispose()
        }
        return ($body | ConvertFrom-Json)
    } catch [System.Net.WebException] {
        $status = $null
        if ($null -ne $_.Exception.Response) {
            try {
                $status = [int]$_.Exception.Response.StatusCode
            } catch {
                $status = $null
            }
        }
        if ($null -ne $status) {
            throw "Magpie 返回 HTTP $status ($Url)"
        }
        throw "无法连接 Magpie 网关 ($Url)：$($_.Exception.Message)"
    } finally {
        if ($null -ne $response) {
            $response.Dispose()
        }
    }
}

function Sanitize-CardText {
    param(
        [AllowEmptyString()][string]$Text,
        [int]$MaxLength
    )
    if ($null -eq $Text) {
        return ''
    }
    $sb = [System.Text.StringBuilder]::new($Text.Length)
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if ($code -eq 0x09 -or $code -eq 0x0A -or $code -eq 0x0D -or $code -eq 0x2028 -or $code -eq 0x2029) {
            [void]$sb.Append(' ')
        } elseif (($code -lt 0x20) -or ($code -ge 0x7F -and $code -le 0x9F)) {
            continue
        } else {
            [void]$sb.Append($ch)
        }
    }
    $clean = ([regex]::Replace($sb.ToString(), '\s+', ' ')).Trim()
    if ($MaxLength -gt 0 -and $clean.Length -gt $MaxLength) {
        if ($MaxLength -le 1) {
            return $clean.Substring(0, $MaxLength)
        }
        return ($clean.Substring(0, $MaxLength - 1).TrimEnd() + '…')
    }
    return $clean
}

function Format-TokenCount {
    param([double]$Count)
    if ($Count -lt 0) { $Count = 0 }
    if ($Count -ge 1000000000) {
        return ('{0:0.00}B' -f ($Count / 1000000000))
    }
    if ($Count -ge 10000000) {
        return ('{0:0}M' -f ($Count / 1000000))
    }
    if ($Count -ge 1000000) {
        return ('{0:0.0}M' -f ($Count / 1000000))
    }
    if ($Count -ge 100000) {
        return ('{0:0}K' -f ($Count / 1000))
    }
    if ($Count -ge 1000) {
        return ('{0:0.0}K' -f ($Count / 1000))
    }
    return ([string][int64][Math]::Round($Count))
}

function Format-CostUsd {
    param([double]$Amount)
    if ($Amount -le 0) {
        return '$0.00'
    }
    if ($Amount -lt 0.01) {
        return '<$0.01'
    }
    if ($Amount -ge 1000) {
        return ('${0:N0}' -f $Amount)
    }
    if ($Amount -ge 100) {
        return ('${0:0.0}' -f $Amount)
    }
    return ('${0:0.00}' -f $Amount)
}

function Format-Percent {
    param([double]$Ratio)
    $pct = $Ratio * 100.0
    if ($pct -gt 0 -and $pct -lt 1) {
        return '<1%'
    }
    return ('{0:0}%' -f [Math]::Round($pct))
}

function Get-ShortModelName {
    param(
        [string]$Name,
        [int]$MaxChars = 10
    )
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return 'unknown'
    }
    $s = $Name.Trim()
    if ($s.Contains('/')) {
        $parts = $s.Split('/')
        $s = $parts[$parts.Length - 1]
    }
    if ($s.Length -gt $MaxChars) {
        $s = $s -replace '^(claude|gemini|deepseek|qwen)-', ''
    }
    if ($s.Length -gt $MaxChars) {
        $s = $s.Substring(0, $MaxChars - 1) + '…'
    }
    return $s
}

function Format-ResetCountdown {
    param(
        [string]$IsoTimestamp,
        [datetimeoffset]$Now
    )
    if ([string]::IsNullOrWhiteSpace($IsoTimestamp)) {
        return ''
    }
    $target = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse($IsoTimestamp, [ref]$target)) {
        return ''
    }
    $span = $target - $Now
    if ($span.TotalMinutes -le 1) {
        return '即将重置'
    }
    if ($span.TotalHours -lt 1) {
        return ('{0}分重置' -f [int][Math]::Ceiling($span.TotalMinutes))
    }
    if ($span.TotalDays -lt 1) {
        $h = [int][Math]::Floor($span.TotalHours)
        $m = [int][Math]::Floor($span.Minutes)
        if ($m -gt 0 -and $h -lt 6) {
            return ('{0}时{1}分重置' -f $h, $m)
        }
        return ('{0}时重置' -f [int][Math]::Round($span.TotalHours))
    }
    return ('{0}天重置' -f [int][Math]::Round($span.TotalDays))
}

function Get-PeriodLabel {
    param([string]$PeriodKey)
    switch ($PeriodKey) {
        'today' { return '今日' }
        '7d'    { return '近7日' }
        '30d'   { return '近30日' }
        'all'   { return '累计' }
        default { return '今日' }
    }
}

function Get-NumericProp {
    param($Obj, [string]$PropName)
    if ($null -eq $Obj) { return 0.0 }
    $prop = $Obj.PSObject.Properties[$PropName]
    if ($null -eq $prop -or $null -eq $prop.Value) { return 0.0 }
    return [double]$prop.Value
}

function Build-MagpieCards {
    param(
        $Usage,
        $Quotas,
        [string]$PeriodKey = 'today',
        [datetimeoffset]$Now = [datetimeoffset]::Now,
        [string]$QuotasError = ''
    )

    $periodLabel = Get-PeriodLabel -PeriodKey $PeriodKey
    $updatedAt = $Now.ToString('HH:mm')

    $calls = [int64](Get-NumericProp $Usage 'calls')
    $errors = [int64](Get-NumericProp $Usage 'errors')
    $inputTok = Get-NumericProp $Usage 'input'
    $outputTok = Get-NumericProp $Usage 'output'
    $cacheRead = Get-NumericProp $Usage 'cache_read'
    $cacheWrite = Get-NumericProp $Usage 'cache_write'
    $reasoning = Get-NumericProp $Usage 'reasoning'
    $cost = Get-NumericProp $Usage 'cost'
    $unpriced = [int64](Get-NumericProp $Usage 'unpriced')
    $sessions = [int64](Get-NumericProp $Usage 'sessionCount')
    $totalTokens = $inputTok + $outputTok + $cacheRead + $cacheWrite

    # 1. Hero section: Usage overview (cost + calls + sessions + errors)
    if ($calls -eq 0) {
        $heroValue = if ($PeriodKey -eq 'today') { '今天还没有请求' } else { "${periodLabel}暂无请求" }
        $heroDetail = '统计网关调用与 Agent 会话日志。'
    } else {
        if ($cost -gt 0) {
            $heroValue = Format-CostUsd -Amount $cost
        } else {
            $heroValue = "$calls 次调用"
        }
        $parts = [System.Collections.Generic.List[string]]::new()
        $parts.Add("$calls 次请求")
        if ($sessions -gt 0) {
            $parts.Add("$sessions 会话")
        }
        if ($errors -gt 0) {
            $parts.Add("$errors 错")
        }
        if ($cost -le 0 -and $unpriced -gt 0) {
            $parts.Add('含未计价')
        }
        $heroDetail = ($parts -join ' · ')
    }

    # 2. Block 1 (metrics): Token summary & cache efficiency
    $tokTotalStr = Format-TokenCount -Count $totalTokens
    $tokSub = "入 $(Format-TokenCount $inputTok) · 出 $(Format-TokenCount $outputTok)"

    $cacheDenom = $inputTok + $cacheRead + $cacheWrite
    if ($cacheRead -gt 0 -and $cacheDenom -gt 0) {
        $hitRatio = $cacheRead / $cacheDenom
        $cacheVal = Format-Percent $hitRatio
        $cacheSub = if ($cacheWrite -gt 0) {
            "读 $(Format-TokenCount $cacheRead) · 写 $(Format-TokenCount $cacheWrite)"
        } elseif ($reasoning -gt 0) {
            "读 $(Format-TokenCount $cacheRead) · 推 $(Format-TokenCount $reasoning)"
        } else {
            "读 $(Format-TokenCount $cacheRead)"
        }
        $rightMetric = [ordered]@{
            label = '缓存命中'
            value = Sanitize-CardText $cacheVal 32
            sub   = Sanitize-CardText $cacheSub 48
            tone  = 'neutral'
        }
    } elseif ($reasoning -gt 0) {
        $rightMetric = [ordered]@{
            label = '推理 Token'
            value = Sanitize-CardText (Format-TokenCount $reasoning) 32
            sub   = Sanitize-CardText "缓写 $(Format-TokenCount $cacheWrite)" 48
            tone  = 'neutral'
        }
    } else {
        $rightMetric = [ordered]@{
            label = '缓存命中'
            value = '0%'
            sub   = '读 0 · 写 0'
            tone  = 'neutral'
        }
    }

    $metricsBlock = [ordered]@{
        type  = 'metrics'
        title = 'Token 用量'
        items = @(
            [ordered]@{
                label = '总 Token'
                value = Sanitize-CardText $tokTotalStr 32
                sub   = Sanitize-CardText $tokSub 48
                tone  = 'neutral'
            },
            $rightMetric
        )
    }

    $blocks = [System.Collections.Generic.List[object]]::new()
    if ($calls -gt 0) {
        $blocks.Add($metricsBlock)
    }

    # Each model gets a labelled bar so its share can be read without a colour key.
    if ($calls -gt 0 -and $null -ne $Usage.models -and @($Usage.models).Count -gt 0) {
        $modelMeters = [System.Collections.Generic.List[object]]::new()
        $ranked = @(foreach ($m in $Usage.models) {
            $mTokens = (Get-NumericProp $m 'input') + (Get-NumericProp $m 'output') + (Get-NumericProp $m 'cache_read') + (Get-NumericProp $m 'cache_write')
            $mCalls = Get-NumericProp $m 'calls'
            $displayName = if ($m.name) { [string]$m.name } elseif ($m.model) { [string]$m.model } else { [string]$m.id }
            [pscustomobject]@{
                Name   = $displayName
                Tokens = $mTokens
                Calls  = $mCalls
            }
        })

        $useTokens = ($totalTokens -gt 0)
        if ($useTokens) {
            $ranked = @($ranked | Sort-Object -Property @{ Expression = 'Tokens'; Descending = $true }, @{ Expression = 'Calls'; Descending = $true })
        } else {
            $ranked = @($ranked | Sort-Object -Property @{ Expression = 'Calls'; Descending = $true })
        }

        $maxVisible = if ($ranked.Count -gt 3) { 2 } else { $ranked.Count }
        $shownRatio = 0.0
        for ($i = 0; $i -lt $maxVisible; $i++) {
            $item = $ranked[$i]
            $ratio = if ($useTokens) { $item.Tokens / $totalTokens } else { $item.Calls / $calls }
            $shownRatio += $ratio
            $shareInt = [int][Math]::Round($ratio * 100.0)
            if ($ratio -gt 0 -and $shareInt -eq 0) {
                $shareInt = 1
            }
            if ($shareInt -gt 100) { $shareInt = 100 }
            $modelMeters.Add([ordered]@{
                label = Sanitize-CardText (Get-ShortModelName -Name $item.Name -MaxChars 9) 32
                percent = $shareInt
                value = Sanitize-CardText (Format-Percent $ratio) 24
                tone  = 'neutral'
            })
        }
        if ($ranked.Count -gt 3) {
            $restRatio = [Math]::Max(0.0, 1.0 - $shownRatio)
            $restShare = [int][Math]::Round($restRatio * 100.0)
            if ($restRatio -gt 0 -and $restShare -eq 0) {
                $restShare = 1
            }
            if ($restShare -gt 100) { $restShare = 100 }
            $modelMeters.Add([ordered]@{
                label = '其他'
                percent = $restShare
                value = Sanitize-CardText (Format-Percent $restRatio) 24
                tone  = 'neutral'
            })
        }
        $blocks.Add([ordered]@{
            type  = 'meters'
            title = "模型占比 · 共 $($ranked.Count) 个"
            items = $modelMeters.ToArray()
        })
    }

    # 4. Block 3 (meters): Subscription quotas progress bars
    $meterItems = [System.Collections.Generic.List[object]]::new()
    if (-not [string]::IsNullOrWhiteSpace($QuotasError)) {
        $meterItems.Add([ordered]@{
            label   = '配额接口异常'
            value   = '读取失败'
            detail  = Sanitize-CardText $QuotasError 48
            percent = 0
            tone    = 'neutral'
        })
    } else {
        $quotaEntries = @()
        if ($null -ne $Quotas -and $null -ne $Quotas.data) {
            $quotaEntries = @($Quotas.data)
        }
        $summaries = [System.Collections.Generic.List[object]]::new()
        foreach ($q in $quotaEntries) {
            $windows = @()
            if ($null -ne $q.windows) {
                $windows = @($q.windows)
            }
            $numericWindows = @(foreach ($w in $windows) {
                $isText = $false
                if ($null -ne $w.PSObject.Properties['text'] -and $w.text) {
                    $isText = $true
                }
                $displayVal = if ($null -ne $w.PSObject.Properties['display']) { [string]$w.display } else { '' }
                if ($isText -or $displayVal -eq 'Unknown') {
                    continue
                }
                if ($null -ne $w.PSObject.Properties['remaining'] -and $null -ne $w.remaining) {
                    $w
                }
            })
            if ($numericWindows.Count -eq 0) {
                continue
            }
            $tightest = @($numericWindows | Sort-Object -Property @{ Expression = { [double]$_.remaining }; Ascending = $true })[0]
            $provName = if ($q.name) { [string]$q.name } elseif ($q.provider) { [string]$q.provider } else { '订阅' }
            $rem = [int][Math]::Round([double]$tightest.remaining)
            if ($rem -lt 0) { $rem = 0 }
            if ($rem -gt 100) { $rem = 100 }
            $detail = ''
            if ($q.asOf) {
                $sampleTime = $q.asOf -as [datetimeoffset]
                $detail = if ($null -eq $sampleTime) { '缓存读数' } else { '缓存 ' + $sampleTime.ToLocalTime().ToString('MM-dd HH:mm') }
            } elseif ($tightest.resetsAt) {
                $detail = Format-ResetCountdown -IsoTimestamp ([string]$tightest.resetsAt) -Now $Now
            }
            $summaries.Add([pscustomobject]@{
                Name      = $provName
                Remaining = $rem
                Detail    = $detail
            })
        }

        if ($summaries.Count -eq 0) {
            $meterItems.Add([ordered]@{
                label   = '订阅账号'
                value   = '暂无配额'
                detail  = '未检测到订阅配额'
                percent = 0
                tone    = 'neutral'
            })
        } else {
            $ordered = @($summaries | Sort-Object -Property @{ Expression = 'Remaining'; Ascending = $true }, @{ Expression = 'Name'; Ascending = $true })
            $qLimit = [Math]::Min($ordered.Count, 4)
            for ($i = 0; $i -lt $qLimit; $i++) {
                $item = $ordered[$i]
                $valLabel = if ($item.Remaining -le 0) { '已用尽' } else { "剩 $($item.Remaining)%" }
                $meterItems.Add([ordered]@{
                    label   = Sanitize-CardText $item.Name 32
                    value   = Sanitize-CardText $valLabel 24
                    detail  = Sanitize-CardText $item.Detail 48
                    percent = $item.Remaining
                    tone    = 'neutral'
                })
            }
        }
    }

    $blocks.Add([ordered]@{
        type  = 'meters'
        title = '订阅配额'
        items = $meterItems.ToArray()
    })

    $card = [ordered]@{
        title  = Sanitize-CardText $Script:PluginName 64
        value  = Sanitize-CardText $heroValue 64
        detail = Sanitize-CardText $heroDetail 160
        state  = 'ready'
        badge  = Sanitize-CardText "${periodLabel} · $updatedAt" 24
        blocks = $blocks.ToArray()
    }

    return , @($card)
}

function Build-ErrorCards {
    param(
        [string]$Reason,
        [datetimeoffset]$Now = [datetimeoffset]::Now
    )
    $time = $Now.ToString('HH:mm')
    return , @(
        [ordered]@{
            title  = $Script:PluginName
            value  = '未连接'
            detail = Sanitize-CardText $Reason 160
            state  = 'error'
            badge  = Sanitize-CardText "异常 · $time" 24
            footer = '确认 Magpie 已启动后将自动恢复同步'
        }
    )
}

function New-PublicationDocument {
    param([array]$Cards)
    return [ordered]@{
        protocol      = 1
        name          = $Script:PluginName
        version       = $Script:PluginVersion
        contributions = @(
            [ordered]@{
                point   = 'desktop.cards'
                version = 2
                data    = [ordered]@{
                    cards = @($Cards)
                }
            }
        )
    }
}

function ConvertTo-PublicationJson {
    param($Document)
    $json = $Document | ConvertTo-Json -Depth 12
    return ($json.Replace("`r`n", "`n") + "`n")
}

function Write-PluginDocumentAtomic {
    param(
        [Parameter(Mandatory)][string]$PluginsDir,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$JsonContent
    )
    if (-not (Test-Path -LiteralPath $PluginsDir)) {
        [void][System.IO.Directory]::CreateDirectory($PluginsDir)
    }
    $target = Join-Path $PluginsDir "$Id.json"
    $tmp = Join-Path $PluginsDir (".{0}.{1}.{2}.tmp" -f $Id, $PID, ([guid]::NewGuid().ToString('N')))
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    try {
        [System.IO.File]::WriteAllText($tmp, $JsonContent, $utf8NoBom)
        if (Test-Path -LiteralPath $target) {
            [System.IO.File]::Replace($tmp, $target, [NullString]::Value)
        } else {
            [System.IO.File]::Move($tmp, $target)
        }
    } catch {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
        throw
    }
    return $target
}

function Remove-PluginDocument {
    param(
        [Parameter(Mandatory)][string]$PluginsDir,
        [Parameter(Mandatory)][string]$Id
    )
    $target = Join-Path $PluginsDir "$Id.json"
    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Force
        return $true
    }
    return $false
}

function Publish-Once {
    param(
        [string]$BaseUrl,
        [string]$BearerKey,
        [string]$PeriodKey,
        [int]$TimeoutSec,
        [string]$PluginsDir,
        [string]$Id,
        [switch]$Dry
    )
    $now = [datetimeoffset]::Now
    $cards = $null
    $status = 'ok'
    try {
        $usageUrl = "$BaseUrl/v1/magpie/usage?period=$([uri]::EscapeDataString($PeriodKey))"
        $usage = Invoke-MagpieJson -Url $usageUrl -BearerKey $BearerKey -TimeoutSec $TimeoutSec

        $quotas = $null
        $quotasError = ''
        try {
            $quotas = Invoke-MagpieJson -Url "$BaseUrl/v1/magpie/quotas" -BearerKey $BearerKey -TimeoutSec $TimeoutSec
        } catch {
            $quotasError = '请确认 Magpie 配额接口可用'
        }
        $cards = Build-MagpieCards -Usage $usage -Quotas $quotas -PeriodKey $PeriodKey -Now $now -QuotasError $quotasError
    } catch {
        $status = 'error'
        $cards = Build-ErrorCards -Reason "请先启动 Magpie（$BaseUrl）" -Now $now
    }

    $doc = New-PublicationDocument -Cards $cards
    $json = ConvertTo-PublicationJson -Document $doc
    if ($Dry) {
        return [pscustomobject]@{ Status = $status; Path = $null; CardCount = $cards.Count; Json = $json }
    }
    $path = Write-PluginDocumentAtomic -PluginsDir $PluginsDir -Id $Id -JsonContent $json
    return [pscustomobject]@{ Status = $status; Path = $path; CardCount = $cards.Count; Json = $json }
}

function Get-PowerShellHostPath {
    $pwshCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($null -ne $pwshCmd) {
        return $pwshCmd.Source
    }
    return (Join-Path $PSHOME 'powershell.exe')
}

function Install-PublisherTask {
    $scriptPath = $PSCommandPath
    $shellExe = Get-PowerShellHostPath

    $argList = @(
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle', 'Hidden',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$scriptPath`"",
        '-Watch',
        '-Period', $Period,
        '-IntervalSeconds', $IntervalSeconds,
        '-TimeoutSeconds', $TimeoutSeconds,
        '-PluginId', $PluginId
    )
    if (-not [string]::IsNullOrWhiteSpace($Endpoint)) {
        $argList += @('-Endpoint', "`"$Endpoint`"")
    }
    if (-not [string]::IsNullOrWhiteSpace($OutputDir)) {
        $argList += @('-OutputDir', "`"$OutputDir`"")
    }
    $arguments = $argList -join ' '

    $action = New-ScheduledTaskAction -Execute $shellExe -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1)

    Register-ScheduledTask -TaskName $Script:TaskName -Action $action -Trigger $trigger -Settings $settings -Description '同步 Magpie 实时用量与配额到 DeskIsle 桌面磁贴' -Force | Out-Null
    Start-ScheduledTask -TaskName $Script:TaskName
    Write-Output "已注册并启动后台任务：$($Script:TaskName)（周期：$Period，间隔：${IntervalSeconds}s）"
}

function Uninstall-PublisherTask {
    $existing = Get-ScheduledTask -TaskName $Script:TaskName -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        Stop-ScheduledTask -TaskName $Script:TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $Script:TaskName -Confirm:$false
        Write-Output "已停止并移除后台任务：$($Script:TaskName)"
    } else {
        Write-Output "未找到已注册的后台任务：$($Script:TaskName)"
    }
}

function Start-MagpiePublisher {
    param([string]$BaseUrl, [string]$PluginsDir)

    $poll = $Watch -or (-not $Once -and -not $DryRun)
    $mutex = $null
    if ($poll) {
        $createdNew = $false
        $mutex = [System.Threading.Mutex]::new($true, "Local\DeskIsle-$PluginId-Publisher", [ref]$createdNew)
        if (-not $createdNew) {
            $mutex.Dispose()
            Write-Output "已有运行中的发布器实例（$PluginId），退出重复进程。"
            return
        }
        if (-not $DryRun) {
            Write-Output "正在持续同步 Magpie（间隔：${IntervalSeconds}s），按 Ctrl+C 停止。"
        }
    }
    try {
        do {
            $res = Publish-Once -BaseUrl $BaseUrl -BearerKey $ApiKey -PeriodKey $Period -TimeoutSec $TimeoutSeconds -PluginsDir $PluginsDir -Id $PluginId -Dry:$DryRun
            if ($DryRun) {
                Write-Output $res.Json
            } elseif (-not $poll) {
                Write-Output "已发布 Magpie 数据面板（状态：$($res.Status)，卡片数：$($res.CardCount)）-> $($res.Path)"
            }
            if ($poll) { Start-Sleep -Seconds $IntervalSeconds }
        } while ($poll)
    } finally {
        if ($null -ne $mutex) {
            $mutex.ReleaseMutex()
            $mutex.Dispose()
        }
    }
}

# Only execute CLI entrypoint when invoked directly (allows dot-sourcing for tests).
if ($MyInvocation.InvocationName -ne '.') {
    $pluginsDir = Get-DefaultPluginsDir

    if ($UninstallTask) {
        Uninstall-PublisherTask
        if ($Remove) {
            [void](Remove-PluginDocument -PluginsDir $pluginsDir -Id $PluginId)
            Write-Output "已撤下插件卡片：$PluginId"
        }
        exit 0
    }

    if ($Remove) {
        $removed = Remove-PluginDocument -PluginsDir $pluginsDir -Id $PluginId
        if ($removed) {
            Write-Output "已撤下插件卡片：$PluginId"
        } else {
            Write-Output "未找到已发布的插件文件：$PluginId"
        }
        exit 0
    }

    if ($InstallTask) {
        $baseUrl = Resolve-MagpieEndpoint -ExplicitEndpoint $Endpoint
        [void](Publish-Once -BaseUrl $baseUrl -BearerKey $ApiKey -PeriodKey $Period -TimeoutSec $TimeoutSeconds -PluginsDir $pluginsDir -Id $PluginId)
        Install-PublisherTask
        exit 0
    }

    $baseUrl = Resolve-MagpieEndpoint -ExplicitEndpoint $Endpoint
    Start-MagpiePublisher -BaseUrl $baseUrl -PluginsDir $pluginsDir
}
