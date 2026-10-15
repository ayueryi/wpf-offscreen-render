#requires -Version 7.0
<#
.SYNOPSIS
    将 wpf-offscreen-render 安装到 Antigravity（配置 MCP 服务器与 Skill）。

.DESCRIPTION
    将 wpf-offscreen-render 注册为 Antigravity 的 MCP 工具服务与 Agent Skill。
    支持全局安装（~/.gemini/config/）或指定工作区安装。

.PARAMETER Scope
    安装范围：Global（默认，适用于所有 Antigravity 会话）或 Workspace（仅当前/指定工作区）。

.PARAMETER WorkspacePath
    当 Scope 为 Workspace 时，指定工作区根目录路径；默认为当前目录。

.PARAMETER Uninstall
    卸载 Antigravity 中的 wpf-offscreen-render 配置与 Skill 链接。

.PARAMETER Test
    安装/配置完成后执行快速自检（run-tests.ps1 -Quick）。

.EXAMPLE
    pwsh -File .\scripts\install-antigravity.ps1
    全局安装到 Antigravity。

.EXAMPLE
    pwsh -File .\scripts\install-antigravity.ps1 -Test
    全局安装并在完成后运行自检。

.EXAMPLE
    pwsh -File .\scripts\install-antigravity.ps1 -Scope Workspace -WorkspacePath C:\work\MyProject
    安装到指定工作区。

.EXAMPLE
    pwsh -File .\scripts\install-antigravity.ps1 -Uninstall
    卸载全局安装。
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Install')]
    [ValidateSet('Global', 'Workspace')]
    [string]$Scope = 'Global',

    [Parameter(ParameterSetName = 'Install')]
    [string]$WorkspacePath,

    [Parameter(ParameterSetName = 'Uninstall')]
    [switch]$Uninstall,

    [Parameter()]
    [switch]$Test
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

if (-not $IsWindows) {
    throw "wpf-offscreen-render 只能在 Windows 操作系统上运行。"
}

$geminiConfigDir = Join-Path $HOME '.gemini\config'
$globalMcpConfig = Join-Path $geminiConfigDir 'mcp_config.json'
$globalSkillsDir = Join-Path $geminiConfigDir 'skills'
$globalSkillTarget = Join-Path $globalSkillsDir 'wpf-offscreen-render'
$sourceSkillDir = Join-Path $root 'skills\wpf-offscreen-render'
$startScriptPath = (Join-Path $root 'mcp\start.ps1') -replace '\\', '/'

function Remove-ConfigPath([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $item.Delete()
        } else {
            Remove-Item -LiteralPath $Path -Recurse -Force
        }
    }
}

if ($Uninstall) {
    Write-Host "正在从 Antigravity 卸载 wpf-offscreen-render ..." -ForegroundColor Cyan

    if (Test-Path -LiteralPath $globalMcpConfig) {
        try {
            $jsonText = Get-Content -LiteralPath $globalMcpConfig -Raw
            $mcpConfig = if ($jsonText.Trim()) { $jsonText | ConvertFrom-Json -AsHashtable } else { @{} }
            if ($mcpConfig.mcpServers -and $mcpConfig.mcpServers.ContainsKey('wpf-offscreen-render')) {
                $null = $mcpConfig.mcpServers.Remove('wpf-offscreen-render')
                $updatedJson = $mcpConfig | ConvertTo-Json -Depth 10
                [IO.File]::WriteAllText($globalMcpConfig, $updatedJson + "`n", [Text.Encoding]::UTF8)
                Write-Host "已从 $globalMcpConfig 移除 wpf-offscreen-render MCP 服务器配置。" -ForegroundColor Green
            }
        } catch {
            Write-Warning "读取或更新 $globalMcpConfig 失败：$($_.Exception.Message)"
        }
    }

    if (Test-Path -LiteralPath $globalSkillTarget) {
        Remove-ConfigPath $globalSkillTarget
        Write-Host "已移除全局 Skill 链接：$globalSkillTarget" -ForegroundColor Green
    }

    if ($WorkspacePath) {
        $wsSkillTarget = Join-Path $WorkspacePath '.agents\skills\wpf-offscreen-render'
        if (Test-Path -LiteralPath $wsSkillTarget) {
            Remove-ConfigPath $wsSkillTarget
            Write-Host "已移除工作区 Skill 链接：$wsSkillTarget" -ForegroundColor Green
        }
    }

    Write-Host "卸载完成。" -ForegroundColor Green
    exit 0
}

# 环境前置检查
$dotnetVersion = & dotnet --version 2>$null
if (-not $dotnetVersion) {
    throw "未检测到 dotnet 命令，请先安装 .NET 8 或更高版本的 SDK。"
}
$major = [int]($dotnetVersion -split '\.')[0]
if ($major -lt 8) {
    throw "检测到 .NET SDK 版本为 $dotnetVersion，wpf-offscreen-render MCP 服务器需要 .NET 8 或更高版本的 SDK。"
}

Write-Host "检测到 .NET SDK: $dotnetVersion" -ForegroundColor Gray

if ($Scope -eq 'Global') {
    Write-Host "正在为 Antigravity 配置全局 MCP 服务器与 Skill ..." -ForegroundColor Cyan

    if (-not (Test-Path -LiteralPath $geminiConfigDir)) {
        $null = New-Item -ItemType Directory -Path $geminiConfigDir -Force
    }

    # 1. 配置全局 mcp_config.json
    $mcpConfig = [ordered]@{}
    if (Test-Path -LiteralPath $globalMcpConfig) {
        try {
            $raw = Get-Content -LiteralPath $globalMcpConfig -Raw
            if ($raw.Trim()) {
                $mcpConfig = $raw | ConvertFrom-Json -AsHashtable
            }
        } catch {
            Write-Warning "原 $globalMcpConfig 解析失败，将创建备份并重新写入。"
            Copy-Item -LiteralPath $globalMcpConfig -Destination "$globalMcpConfig.bak" -Force
            $mcpConfig = [ordered]@{}
        }
    }
    if (-not $mcpConfig.ContainsKey('mcpServers') -or -not ($mcpConfig.mcpServers -is [System.Collections.IDictionary])) {
        $mcpConfig['mcpServers'] = [ordered]@{}
    }

    $mcpConfig['mcpServers']['wpf-offscreen-render'] = [ordered]@{
        command = 'pwsh'
        args = @(
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            $startScriptPath
        )
    }

    $updatedJson = $mcpConfig | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($globalMcpConfig, $updatedJson + "`n", [Text.Encoding]::UTF8)
    Write-Host "已配置全局 MCP 服务器：$globalMcpConfig" -ForegroundColor Green

    # 2. 挂载全局 Skill
    if (-not (Test-Path -LiteralPath $globalSkillsDir)) {
        $null = New-Item -ItemType Directory -Path $globalSkillsDir -Force
    }
    Remove-ConfigPath $globalSkillTarget
    try {
        $null = New-Item -ItemType Junction -Path $globalSkillTarget -Target $sourceSkillDir -Force
        Write-Host "已创建全局 Skill 联接：$globalSkillTarget -> $sourceSkillDir" -ForegroundColor Green
    } catch {
        Copy-Item -LiteralPath $sourceSkillDir -Destination $globalSkillTarget -Recurse -Force
        Write-Host "已复制全局 Skill 目录：$globalSkillTarget" -ForegroundColor Green
    }
} else {
    $targetWs = if ($WorkspacePath) { $WorkspacePath } else { (Get-Location).Path }
    Write-Host "正在为工作区配置 Antigravity Skill：$targetWs ..." -ForegroundColor Cyan

    $wsSkillsDir = Join-Path $targetWs '.agents\skills'
    $wsSkillTarget = Join-Path $wsSkillsDir 'wpf-offscreen-render'

    if (-not (Test-Path -LiteralPath $wsSkillsDir)) {
        $null = New-Item -ItemType Directory -Path $wsSkillsDir -Force
    }
    Remove-ConfigPath $wsSkillTarget
    try {
        $null = New-Item -ItemType Junction -Path $wsSkillTarget -Target $sourceSkillDir -Force
        Write-Host "已创建工作区 Skill 联接：$wsSkillTarget -> $sourceSkillDir" -ForegroundColor Green
    } catch {
        Copy-Item -LiteralPath $sourceSkillDir -Destination $wsSkillTarget -Recurse -Force
        Write-Host "已复制工作区 Skill 目录：$wsSkillTarget" -ForegroundColor Green
    }
}

if ($Test) {
    Write-Host "`n正在执行快速自检 ..." -ForegroundColor Cyan
    $testScript = Join-Path $root 'tests\run-tests.ps1'
    & $testScript -Quick
    if ($LASTEXITCODE -ne 0) {
        throw "自检未通过，请检查上方日志。"
    }
}

Write-Host "`nAntigravity 安装配置成功！" -ForegroundColor Green
Write-Host "提示：如需在业务项目中开启任务结束前自动检查，可在项目根目录配置 wpf-render.json 并参考 templates/antigravity-hooks.json。" -ForegroundColor Gray
