#requires -Version 7.0
# 授权业务项目的 wpf-render.json，使结束前自动验证（Stop hook）生效。
# hook 会执行配置中的 build 命令并运行业务程序集，请只授权自己信任的仓库；配置修改后需要重新授权。
#   trust-project.ps1                 授权当前目录（或向上最近）的 wpf-render.json
#   trust-project.ps1 -Path <目录或文件>
#   trust-project.ps1 -Revoke         撤销授权
#   trust-project.ps1 -List           列出已授权的配置
[CmdletBinding()]
param(
    [string]$Path = (Get-Location).Path,
    [switch]$Revoke,
    [switch]$List
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TrustStore.ps1')

if ($List) {
    $projects = @(Read-TrustStore)
    if ($projects.Count -eq 0) { Write-Output "没有已授权的项目（$(Get-TrustStorePath)）" }
    # 逐行输出文字：路径很长时表格格式在重定向输出中会被截空。
    foreach ($project in $projects) {
        $status = if (Test-Path -LiteralPath $project.config) { Get-ProjectTrust $project.config } else { 'missing' }
        $label = switch ($status) { 'trusted' { '已授权' } 'changed' { '授权后已修改，需要重新授权' } default { '配置文件不存在' } }
        Write-Output "[$label] $($project.config)（$($project.trustedAt)）"
    }
    return
}

# 配置已被删除或移动：-List 仍会列出它，按原路径撤销（不计算哈希）。-Path 是目录时先看该目录自己的记录，
# 不能向上找到父目录的配置并误撤销它。
if ($Revoke) {
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if ((Test-Path -LiteralPath $full -PathType Container) -or [IO.Path]::GetFileName($full) -ne 'wpf-render.json') { $full = Join-Path $full 'wpf-render.json' }
    if (-not (Test-Path -LiteralPath $full)) {
        $target = $full.Replace('\', '/')
        $all = @(Read-TrustStore)
        $kept = @($all | Where-Object { $_.config -ine $target })
        if ($kept.Count -lt $all.Count) {
            Write-TrustStore $kept
            Write-Output "已撤销授权：$target"
            return
        }
        if (-not (Test-Path -LiteralPath $Path)) { throw "没有找到 $target 的授权记录（-List 查看已授权的配置）。" }
    }
}

if (Test-Path -LiteralPath $Path -PathType Container) {
    $dir = (Resolve-Path -LiteralPath $Path).ProviderPath
    while ($dir -and -not (Test-Path -LiteralPath (Join-Path $dir 'wpf-render.json'))) { $dir = Split-Path -Parent $dir }
    if (-not $dir) { throw "从 $Path 向上没有找到 wpf-render.json。" }
    $Path = Join-Path $dir 'wpf-render.json'
}
$identity = Get-ConfigIdentity $Path
$others = @(Read-TrustStore | Where-Object { $_.config -ine $identity.Config })

if ($Revoke) {
    Write-TrustStore $others
    Write-Output "已撤销授权：$($identity.Config)"
    return
}

$config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
$builds = @(@($config.defaults) + @($config.views.Values) | Where-Object { $_ -and $_.build } | ForEach-Object { $_.build -join ' ' } | Select-Object -Unique)
Write-TrustStore ($others + [pscustomobject]@{ config = $identity.Config; sha256 = $identity.Sha256; trustedAt = (Get-Date).ToString('O') })
Write-Output "已授权：$($identity.Config)"
if ($builds) { Write-Output "结束前自动验证将执行的构建命令：`n  $($builds -join "`n  ")" }
Write-Output '配置文件修改后需要重新运行本脚本授权。'
