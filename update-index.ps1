# Run with PowerShell 7. Paths are relative to this repository.
[CmdletBinding()]
param([switch]$Check)
$ErrorActionPreference = 'Stop'

$indexPath = Join-Path $PSScriptRoot 'index.json'
$packages = Join-Path $PSScriptRoot 'packages'
$index = Get-Content -LiteralPath $indexPath -Raw -Encoding utf8 | ConvertFrom-Json
if ($index.schema -ne 1 -or $index.plugins -isnot [array]) {
    throw '索引必须使用 schema 1 并包含 plugins 数组。'
}

$seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$entries = @(foreach ($entry in $index.plugins) {
    $id = $entry.id
    if ($id -isnot [string] -or $id -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}\z' -or
        $id -match '^(con|prn|aux|nul|com[0-9]|lpt[0-9])$' -or !$seen.Add($id)) {
        throw "插件 ID 无效或重复：$id"
    }
    if ($entry.description -isnot [string] -or [string]::IsNullOrWhiteSpace($entry.description)) {
        throw "缺少市场简介：$id"
    }
    $file = Join-Path $packages "$id.json"
    $package = Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-Json
    $digest = (Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash.ToLowerInvariant()
    if ($Check -and ($entry.name -cne $package.name -or $entry.version -cne $package.version -or $entry.sha256 -cne $digest)) {
        throw "索引与插件包不一致：$id"
    }
    [ordered]@{
        id = $id
        name = $package.name
        version = $package.version
        description = $entry.description
        sha256 = $digest
    }
})

foreach ($file in Get-ChildItem -LiteralPath $packages -Filter '*.json' -File) {
    if (!$seen.Contains($file.BaseName)) { throw "插件包尚未加入索引：$($file.Name)" }
}
if ($Check) {
    Write-Output "已核对 $($entries.Count) 个插件包。"
} else {
    $json = [ordered]@{ schema = 1; plugins = $entries } | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($indexPath, $json.Replace("`r`n", "`n") + "`n", [Text.UTF8Encoding]::new($false))
}
