#requires -Version 7.0
# 把 assets/icon*.svg 导出成插件与文档使用的 PNG（需要 Windows + Edge 或 Chrome）。
#   pwsh -File scripts/export-icon.ps1
# 产物：
#   .claude-plugin/icon.png   512×512  白底方形磁贴，插件市场列表用（校验器只接受方形 PNG/JPEG）
#   docs/images/logo.png      512×512  同上，README 与文档引用
#   docs/images/logo-32.png   32×32    透明底图标，Favicon / 小尺寸位
[CmdletBinding()]
param(
    [string]$Browser
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw '图标导出需要 Windows（依赖 Edge / Chrome 的无头截图）。' }
$root = Split-Path -Parent $PSScriptRoot

if (-not $Browser) {
    $Browser = @(
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $Browser) { throw '没有找到 Edge 或 Chrome，请用 -Browser 指定可执行文件路径。' }

# 每个产物：源 SVG、边长、衬底（transparent 时透明）、目标路径。
$outputs = @(
    @{ Svg = 'assets/icon-tile.svg'; Size = 512; Background = '#FFFFFF'; Target = '.claude-plugin/icon.png' },
    @{ Svg = 'assets/icon-tile.svg'; Size = 512; Background = '#FFFFFF'; Target = 'docs/images/logo.png' },
    @{ Svg = 'assets/icon.svg'; Size = 32; Background = 'transparent'; Target = 'docs/images/logo-32.png' }
)

$work = Join-Path ([IO.Path]::GetTempPath()) ('wpf-render-icon-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $work
try {
    foreach ($output in $outputs) {
        $svg = (Join-Path $root $output.Svg) -replace '\\', '/'
        $page = Join-Path $work 'page.html'
        # 页面尺寸与目标边长一致，SVG 铺满整页；无头截图按窗口尺寸出图，不依赖缩放。
        $html = @"
<!doctype html><meta charset="utf-8">
<style>
  html,body{margin:0;padding:0;background:transparent;overflow:hidden}
  img{display:block;width:$($output.Size)px;height:$($output.Size)px}
</style>
<img src="file:///$svg">
"@
        [IO.File]::WriteAllText($page, $html, [Text.UTF8Encoding]::new($false))
        $target = Join-Path $root $output.Target
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force
        # 先拼成单个字符串再放进数组：在数组字面量里写 '...' + $x 会被拆成两个元素，
        # 浏览器于是看到两个目标地址，headless 模式直接报 "Multiple targets are not supported"。
        $background = if ($output.Background -eq 'transparent') { '00000000' } else { 'FFFFFFFF' }
        $backgroundArg = '--default-background-color=' + $background
        # 不能叫 $args：PowerShell 的自动变量，赋值会被忽略或产生意外行为。
        $browserArgs = @(
            '--headless=new', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=1',
            "--screenshot=$target", "--window-size=$($output.Size),$($output.Size)",
            $backgroundArg,
            ('file:///' + ($page -replace '\\', '/'))
        )
        # 直接用调用运算符：Edge 是 GUI 程序，退出码不可靠，以产物是否出现为准。
        & $Browser @browserArgs 2>&1 | Out-Null
        # 少数机器上浏览器进程会稍晚才把文件落盘，最多等 10 秒。
        for ($i = 0; $i -lt 100 -and -not (Test-Path -LiteralPath $target); $i++) { Start-Sleep -Milliseconds 100 }
        if (-not (Test-Path -LiteralPath $target)) { throw "导出失败：$($output.Target)" }
        if (-not (Test-Path -LiteralPath $target)) { throw "导出失败：$($output.Target)" }
        $size = (Get-Item -LiteralPath $target).Length
        Write-Host "$($output.Target)  $($output.Size)×$($output.Size)  $([math]::Round($size / 1KB)) KB"
    }
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
