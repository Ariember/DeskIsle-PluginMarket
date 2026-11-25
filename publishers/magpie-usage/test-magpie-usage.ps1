# Self-contained tests for the Magpie Usage DeskIsle v2 high-density card publisher.
[CmdletBinding()]
param(
    [string]$DeskIsleExe
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'publish-magpie-usage.ps1')

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -cne $Expected) {
        throw "断言失败 [$Message]：期望 '$Expected'，实际 '$Actual'"
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw "断言失败 [$Message]"
    }
}

# 1. Formatting helpers
Assert-Equal (Format-TokenCount 0) '0' 'token 0'
Assert-Equal (Format-TokenCount 950) '950' 'token 950'
Assert-Equal (Format-TokenCount 12340) '12.3K' 'token 12.3K'
Assert-Equal (Format-TokenCount 245000) '245K' 'token 245K'
Assert-Equal (Format-TokenCount 1420000) '1.4M' 'token 1.4M'
Assert-Equal (Format-TokenCount 267251369) '267M' 'token 267M'
Assert-Equal (Format-TokenCount 1250000000) '1.25B' 'token 1.25B'

Assert-Equal (Format-CostUsd 0) '$0.00' 'cost 0'
Assert-Equal (Format-CostUsd 0.004) '<$0.01' 'cost tiny'
Assert-Equal (Format-CostUsd 12.345) '$12.35' 'cost normal'
Assert-Equal (Format-CostUsd 158.058) '$158.1' 'cost >100'

Assert-Equal (Sanitize-CardText "hello`r`nworld`t!" 64) 'hello world !' 'sanitize newlines'
Assert-Equal (Sanitize-CardText ('a' * 20) 10) 'aaaaaaaaa…' 'sanitize truncate'

# 2. Active usage + quotas fixture (combined 1 high-density card)
$now = [datetimeoffset]::Parse('2026-11-25T10:15:00+08:00')
$usageActive = [pscustomobject]@{
    period       = 'today'
    calls        = 4251
    errors       = 23
    input        = 846315
    output       = 1402213
    cache_read   = 247899492
    cache_write  = 17103349
    reasoning    = 0
    cost         = 158.058497
    unpriced     = 1
    sessionCount = 34
    models       = @(
        [pscustomobject]@{ id = 'devin/claude-opus-5-5'; name = 'claude-opus-5-5'; calls = 4057; input = 94409; output = 1322883; cache_read = 228532280; cache_write = 17103349 }
        [pscustomobject]@{ id = 'devin/swe-2'; name = 'swe-2'; calls = 193; input = 693390; output = 69230; cache_read = 19334528; cache_write = 0 }
        [pscustomobject]@{ id = 'aws-quick/smart'; name = 'smart'; calls = 1; input = 58516; output = 10100; cache_read = 32684; cache_write = 0 }
    )
}
$quotasActive = [pscustomobject]@{
    data = @(
        [pscustomobject]@{
            provider = 'codex'
            name     = 'Codex'
            windows  = @(
                [pscustomobject]@{ name = '7 days'; used = 94; remaining = 6; resetsAt = '2026-11-25T10:31:24+08:00' }
                [pscustomobject]@{ name = 'Image generation'; used = 0; remaining = 100; display = 'Unknown'; text = $true }
            )
        }
        [pscustomobject]@{
            provider = 'devin'
            name     = 'Devin'
            windows  = @(
                [pscustomobject]@{ name = '7 days'; used = 88; remaining = 12; resetsAt = '2026-11-29T08:00:00Z' }
            )
        }
    )
}

$cards = Build-MagpieCards -Usage $usageActive -Quotas $quotasActive -PeriodKey 'today' -Now $now
Assert-Equal $cards.Count 1 'single combined card'
$card = $cards[0]
Assert-Equal $card.title 'Magpie 数据面板' 'card title'
Assert-Equal $card.value '$158.1' 'hero cost'
Assert-Equal $card.badge '今日 · 10:15' 'card badge'
Assert-True ($card.detail.Contains('4251 次请求') -and $card.detail.Contains('34 会话') -and $card.detail.Contains('23 错')) 'hero detail'
Assert-Equal $card.blocks.Count 3 'three structured blocks'

$metrics = $card.blocks[0]
Assert-Equal $metrics.type 'metrics' 'block1 type'
Assert-Equal $metrics.items[0].value '267M' 'total tokens'
Assert-Equal $metrics.items[1].value '93%' 'cache hit rate'

$segments = $card.blocks[1]
Assert-Equal $segments.type 'segments' 'block2 type'
Assert-Equal $segments.items.Count 3 '3 model segments'
Assert-Equal $segments.items[0].label 'opus-5-5' 'top model label'
Assert-Equal $segments.items[0].share 92 'top model share'
Assert-Equal $segments.items[2].value '<1%' 'small model pct label'

$meters = $card.blocks[2]
Assert-Equal $meters.type 'meters' 'block3 type'
Assert-Equal $meters.items.Count 2 '2 quota meters'
Assert-Equal $meters.items[0].label 'Codex' 'tightest quota first'
Assert-Equal $meters.items[0].value '剩 6%' 'codex value'
Assert-Equal $meters.items[0].detail '17分重置' 'codex reset'
Assert-Equal $meters.items[0].tone 'danger' 'codex danger tone'

# 3. Zero usage fixture
$usageZero = [pscustomobject]@{
    period = 'today'; calls = 0; errors = 0; input = 0; output = 0; cache_read = 0; cache_write = 0; reasoning = 0; cost = 0; unpriced = 0; sessionCount = 0; models = @()
}
$zeroCards = Build-MagpieCards -Usage $usageZero -Quotas ([pscustomobject]@{ data = @() }) -PeriodKey 'today' -Now $now
Assert-Equal $zeroCards.Count 1 'zero combined card'
Assert-Equal $zeroCards[0].value '$0.00' 'zero hero cost'
Assert-Equal $zeroCards[0].blocks[0].items[0].value '0' 'zero tokens'
Assert-Equal $zeroCards[0].blocks[1].items[0].share 0 'zero model share'
Assert-Equal $zeroCards[0].blocks[2].items[0].value '暂无配额' 'zero quota'

# 4. Atomic write + DeskIsle v2 CLI protocol validation
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("deskisle-magpie-test-" + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($tempRoot)
try {
    $docActive = ConvertTo-PublicationJson (New-PublicationDocument -Cards $cards)
    $docZero = ConvertTo-PublicationJson (New-PublicationDocument -Cards $zeroCards)
    $docError = ConvertTo-PublicationJson (New-PublicationDocument -Cards (Build-ErrorCards -Reason '请先启动 Magpie' -Now $now))

    $p1 = Write-PluginDocumentAtomic -PluginsDir $tempRoot -Id 'magpie-usage' -JsonContent $docActive
    Assert-True (Test-Path -LiteralPath $p1) 'atomic write active'
    $p2 = Write-PluginDocumentAtomic -PluginsDir $tempRoot -Id 'magpie-usage' -JsonContent $docError
    Assert-Equal $p1 $p2 'atomic replace path'

    if ([string]::IsNullOrWhiteSpace($DeskIsleExe)) {
        $candidate = Join-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) 'DeskIsle\target\release\deskisle.exe'
        if (Test-Path -LiteralPath $candidate) {
            $DeskIsleExe = $candidate
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($DeskIsleExe) -and (Test-Path -LiteralPath $DeskIsleExe)) {
        foreach ($pair in @(
            @{ Name = 'active'; Content = $docActive },
            @{ Name = 'zero'; Content = $docZero },
            @{ Name = 'error'; Content = $docError }
        )) {
            $f = Join-Path $tempRoot "$($pair.Name).json"
            [System.IO.File]::WriteAllText($f, $pair.Content, [System.Text.UTF8Encoding]::new($false))
            $psi = [System.Diagnostics.ProcessStartInfo]::new($DeskIsleExe, "plugins validate magpie-usage `"$f`"")
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false
            $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
            $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
            $proc = [System.Diagnostics.Process]::Start($psi)
            $stdout = $proc.StandardOutput.ReadToEnd()
            $stderr = $proc.StandardError.ReadToEnd()
            $proc.WaitForExit()
            if ($proc.ExitCode -ne 0) {
                throw "deskisle.exe 校验 $($pair.Name) 失败（exit $($proc.ExitCode)）：$stderr $stdout"
            }
        }
        Write-Output "全部断言与 deskisle.exe v2 协议校验通过（active / zero / error）。"
    } else {
        Write-Output "全部断言通过（未检测到 deskisle.exe，跳过宿主 CLI 校验）。"
    }
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
