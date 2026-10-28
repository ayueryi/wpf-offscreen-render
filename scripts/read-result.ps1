#requires -Version 7.0
# MCP 服务器读取渲染结果的桥接：Results.ps1 的 CLI 形态（与 list-views.ps1 之于 Preset.ps1 相同）。
param([Parameter(Mandatory)][string]$OutDir)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Results.ps1')
$result = Read-WpfRenderResult $OutDir
[ordered]@{ kind = $result.kind; items = @($result.items); raw = $result.raw } | ConvertTo-Json -Depth 6 -Compress
