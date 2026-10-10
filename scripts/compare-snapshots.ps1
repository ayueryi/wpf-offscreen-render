#requires -Version 7.0
# 比较前后两次渲染：输出差异图（变化像素标红）、变化像素占比与变化区域，并指出两次渲染环境（主题、尺寸、DPI、运行时等）的差别。
# -Before / -After 可以是 snapshot.png 路径，也可以是渲染输出目录。退出码：0 = 无差异（或在 -Tolerance 内），1 = 有差异。
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Before,
    [Parameter(Mandatory)][string]$After,
    # 差异图输出路径；默认写到 After 所在目录的 diff.png。
    [string]$DiffPath,
    # 单个颜色通道的差值不超过该值时视为相同，用于忽略抗锯齿等微小差异。
    [ValidateRange(0, 255)][int]$Tolerance = 0
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw '图像比较依赖 Windows 上的 System.Drawing。' }
. (Join-Path $PSScriptRoot 'ImageTools.ps1')

function Resolve-Snapshot([string]$Path) {
    $resolved = (Resolve-Path -LiteralPath $Path).ProviderPath
    if (Test-Path -LiteralPath $resolved -PathType Container) { $resolved = Join-Path $resolved 'snapshot.png' }
    if (-not (Test-Path -LiteralPath $resolved)) { throw "找不到截图：$resolved" }
    $manifestPath = Join-Path (Split-Path -Parent $resolved) 'manifest.json'
    [pscustomobject]@{
        Image = $resolved
        Manifest = if (Test-Path -LiteralPath $manifestPath) { Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json }
    }
}

$beforeShot = Resolve-Snapshot $Before
$afterShot = Resolve-Snapshot $After
if (-not $DiffPath) { $DiffPath = Join-Path (Split-Path -Parent $afterShot.Image) 'diff.png' }
# 按 PowerShell 当前位置解析（[IO.Path]::GetFullPath 使用进程工作目录，Set-Location 不改变它）。
$DiffPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DiffPath)

$result = [WpfOffscreenRender.ImageTools]::Compare($beforeShot.Image, $afterShot.Image, $DiffPath, $Tolerance)
$identical = (Get-FileHash -LiteralPath $beforeShot.Image).Hash -eq (Get-FileHash -LiteralPath $afterShot.Image).Hash

# 环境不一致时，像素差异可能来自渲染条件而不是界面改动。
$environmentDifferences = @(
    if ($beforeShot.Manifest -and $afterShot.Manifest) {
        foreach ($field in 'sourceViewType', 'mode', 'theme', 'widthDip', 'heightDip', 'dpi', 'background', 'targetFramework', 'runtime', 'processArchitecture', 'machineName') {
            $a = $beforeShot.Manifest.$field; $b = $afterShot.Manifest.$field
            if ("$a" -ne "$b") { "${field}: $a -> $b" }
        }
    }
)

# 变化区域同时给出 DIP 坐标，便于对照 layout.json。
$dpi = if ($afterShot.Manifest.dpi) { [double]$afterShot.Manifest.dpi } else { 96.0 }
$bounds = $result.ChangedBounds
$summary = [ordered]@{
    status = if ($result.ChangedPixels -eq 0) { 'same' } else { 'different' }
    identicalBytes = $identical
    sameSize = $result.BeforeWidth -eq $result.AfterWidth -and $result.BeforeHeight -eq $result.AfterHeight
    beforeSize = "$($result.BeforeWidth)x$($result.BeforeHeight)"
    afterSize = "$($result.AfterWidth)x$($result.AfterHeight)"
    changedPixels = $result.ChangedPixels
    changedRatio = [math]::Round($result.ChangedPixels / [double]$result.TotalPixels, 6)
    changedBoundsPx = if ($bounds) { @($bounds) } else { $null }
    changedBoundsDip = if ($bounds) { @($bounds | ForEach-Object { [math]::Round($_ * 96.0 / $dpi, 1) }) } else { $null }
    tolerance = $Tolerance
    environmentDifferences = $environmentDifferences
    before = $beforeShot.Image
    after = $afterShot.Image
    diff = $DiffPath
}
$summary | ConvertTo-Json -Depth 3
exit $(if ($result.ChangedPixels -eq 0) { 0 } else { 1 })
