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

# 安装 / 卸载的配置读写与 skill 挂载逻辑在 AntigravityInstall.ps1（安装与卸载共用，测试直测这两个 module）。
. (Join-Path $PSScriptRoot 'AntigravityInstall.ps1')

if ($Uninstall) {
    Write-Host "正在从 Antigravity 卸载 wpf-offscreen-render ..." -ForegroundColor Cyan

    Set-McpServerEntry $globalMcpConfig $false $startScriptPath
    Write-Host "已从 $globalMcpConfig 移除 wpf-offscreen-render MCP 服务器配置。" -ForegroundColor Green

    if (Test-Path -LiteralPath $globalSkillTarget) {
        Unmount-Skill $globalSkillTarget
        Write-Host "已移除全局 Skill 链接：$globalSkillTarget" -ForegroundColor Green
    }

    if ($WorkspacePath) {
        $wsSkillTarget = Join-Path $WorkspacePath '.agents\skills\wpf-offscreen-render'
        if (Test-Path -LiteralPath $wsSkillTarget) {
            Unmount-Skill $wsSkillTarget
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

    # 1. 配置全局 mcp_config.json
    Set-McpServerEntry $globalMcpConfig $true $startScriptPath
    Write-Host "已配置全局 MCP 服务器：$globalMcpConfig" -ForegroundColor Green

    # 2. 挂载全局 Skill
    $mode = Mount-Skill $globalSkillTarget $sourceSkillDir
    Write-Host "已$(if ($mode -eq 'junction') { '创建全局 Skill 联接' } else { '复制全局 Skill 目录' })：$globalSkillTarget -> $sourceSkillDir" -ForegroundColor Green
} else {
    $targetWs = if ($WorkspacePath) { $WorkspacePath } else { (Get-Location).Path }
    Write-Host "正在为工作区配置 Antigravity Skill：$targetWs ..." -ForegroundColor Cyan

    $wsSkillsDir = Join-Path $targetWs '.agents\skills'
    $wsSkillTarget = Join-Path $wsSkillsDir 'wpf-offscreen-render'

    $mode = Mount-Skill $wsSkillTarget $sourceSkillDir
    Write-Host "已$(if ($mode -eq 'junction') { '创建工作区 Skill 联接' } else { '复制工作区 Skill 目录' })：$wsSkillTarget -> $sourceSkillDir" -ForegroundColor Green
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
