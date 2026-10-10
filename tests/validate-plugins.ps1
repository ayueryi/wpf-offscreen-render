#requires -Version 7.0
# 插件清单一致性检查（跨平台）：JSON 可解析、引用路径存在、名称与版本在各清单和 MCP 服务器之间一致。
# Claude Code 清单的完整校验由 `claude plugin validate --strict` 负责；Codex 没有对应命令，这里覆盖其清单。
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failures = [Collections.Generic.List[string]]::new()
function Read-Json([string]$Relative) {
    $path = Join-Path $root $Relative
    if (-not (Test-Path -LiteralPath $path)) { $failures.Add("缺少 $Relative"); return $null }
    try { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable } catch { $failures.Add("$Relative 不是合法 JSON：$($_.Exception.Message)"); $null }
}
function Assert-Path([string]$Relative, [string]$Owner) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $Relative))) { $failures.Add("$Owner 引用的路径不存在：$Relative") }
}

$claude = Read-Json '.claude-plugin/plugin.json'
$codex = Read-Json '.codex-plugin/plugin.json'
$mcp = Read-Json 'codex.mcp.json'
$codexMarket = Read-Json '.agents/plugins/marketplace.json'
$claudeMarket = Read-Json '.claude-plugin/marketplace.json'
[xml]$project = Get-Content -LiteralPath (Join-Path $root 'mcp/WpfRenderMcp/WpfRenderMcp.csproj') -Raw
$serverVersion = "$($project.Project.PropertyGroup.Version)".Trim()
$toolVersion = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -TotalCount 1).Trim()
if ($serverVersion -ne $toolVersion) { $failures.Add("VERSION（$toolVersion）与 MCP 服务器版本 $serverVersion 不一致") }
$badge = [regex]::Match((Get-Content -LiteralPath (Join-Path $root 'README.md') -Raw), 'badge/version-([0-9][0-9.]*)-')
if (-not $badge.Success -or $badge.Groups[1].Value -ne $toolVersion) { $failures.Add("README 版本徽章（$($badge.Groups[1].Value)）与 VERSION（$toolVersion）不一致") }

if ($claude -and $codex) {
    foreach ($pair in @(@('name', $claude.name, $codex.name), @('version', $claude.version, $codex.version))) {
        if ($pair[1] -ne $pair[2]) { $failures.Add("Claude Code 与 Codex 清单的 $($pair[0]) 不一致：$($pair[1]) / $($pair[2])") }
    }
    if ($claude.version -ne $serverVersion) { $failures.Add("插件版本 $($claude.version) 与 MCP 服务器版本 $serverVersion 不一致") }
    Assert-Path $codex.skills '.codex-plugin/plugin.json skills'
    Assert-Path $codex.mcpServers '.codex-plugin/plugin.json mcpServers'
    $skillFiles = @(Get-ChildItem -LiteralPath (Join-Path $root $codex.skills) -Filter SKILL.md -Recurse)
    if ($skillFiles.Count -eq 0) { $failures.Add("$($codex.skills) 下没有 SKILL.md") }
    foreach ($skill in $skillFiles) {
        $front = (Get-Content -LiteralPath $skill.FullName -Raw) -split '(?m)^---\s*$'
        if ($front.Count -lt 3 -or $front[1] -notmatch '(?m)^name:\s*(\S+)' ) { $failures.Add("$($skill.FullName) 缺少 frontmatter name"); continue }
        if ($Matches[1] -ne $skill.Directory.Name) { $failures.Add("skill 名称 $($Matches[1]) 与目录名 $($skill.Directory.Name) 不一致") }
        # SKILL.md 中的相对链接必须能解析（插件安装后保持目录结构）。
        foreach ($link in [regex]::Matches((Get-Content -LiteralPath $skill.FullName -Raw), '\]\((?!https?:)([^)#]+)')) {
            $target = Join-Path $skill.DirectoryName $link.Groups[1].Value
            if (-not (Test-Path -LiteralPath $target)) { $failures.Add("$($skill.Name) 的链接失效：$($link.Groups[1].Value)") }
        }
    }
}
foreach ($server in @($mcp.mcpServers.Values) + @($claude.mcpServers.Values)) {
    $script = @($server.args) | Where-Object { $_ -like '*start.ps1' } | Select-Object -First 1
    if (-not $script) { $failures.Add('MCP 服务器配置没有指向 mcp/start.ps1'); continue }
    Assert-Path ($script -replace '^\$\{CLAUDE_PLUGIN_ROOT\}/', '' -replace '^\./', '') 'MCP 服务器配置'
}
foreach ($market in @($codexMarket, $claudeMarket)) {
    if ($market -and -not (@($market.plugins) | Where-Object { $_.name -eq $claude.name })) { $failures.Add("市场清单 $($market.name) 未列出插件 $($claude.name)") }
}

if ($failures.Count) { $failures | ForEach-Object { Write-Host "FAIL $_" }; exit 1 }
Write-Host "插件清单检查通过（$($claude.name) $($claude.version)）"
