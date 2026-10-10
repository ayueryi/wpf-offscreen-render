#requires -Version 7.0
# 一步渲染：生成（或复用缓存的）宿主工程并渲染，最后输出 summary JSON。
# 适合免代码接入（-ViewType / -Xaml）；需要定制 ViewFactory.cs 时改用 new-wpf-harness.ps1 + invoke-wpf-render.ps1。
#
# 缓存：同一组 程序集路径 + TFM + 位数 + 工具版本 复用 %TEMP%\wpf-render-cache 下的同一个宿主。
# 视图配置每次重写 harness.json；业务程序集的大小 / 修改时间未变时跳过构建，变化时重新构建。
#
# 多组合：-Theme / -Dpi / -Size 传多个值时渲染全部组合（只构建一次，每个组合独立进程），
# 输出 matrix-* 目录，内含 matrix.json 与拼好的 overview.png；返回该目录。
[CmdletBinding()]
param(
    [string[]]$AssemblyPath = @(),
    [string]$ViewType,
    [string]$Xaml,
    [string]$DataContextType,
    [string[]]$ResourceDictionary = @(),
    [string]$TargetFramework,
    [string]$Platform,
    [int]$Width = 1280,
    [int]$Height = 800,
    # 多个视口尺寸，形如 1280x800；指定后忽略 -Width / -Height。
    [ValidatePattern('^\d+x\d+$')][string[]]$Size,
    [int[]]$Dpi = @(96),
    [string[]]$Theme = @('light'),
    [string]$Background = 'auto',
    [switch]$WindowHost,
    [string]$Element,
    [int]$TimeoutSeconds = 120,
    [string]$CacheRoot = (Join-Path ([IO.Path]::GetTempPath()) 'wpf-render-cache'),
    # 忽略缓存，生成一次性宿主（位于 %TEMP%\wpf-render-<GUID>）。
    [switch]$NoCache,
    # 超过该天数未使用的缓存宿主与渲染结果会被清理。
    [ValidateRange(1, 365)][int]$RetentionDays = 7
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'WPF 渲染需要 Windows。' }
if ($ViewType -and $Xaml) { throw '-ViewType 与 -Xaml 只能二选一。' }
if ($DataContextType -and -not ($ViewType -or $Xaml)) { throw '-DataContextType 需要配合 -ViewType 或 -Xaml。' }
if ($Xaml) { $Xaml = (Resolve-Path -LiteralPath $Xaml).Path }
$assemblies = @($AssemblyPath | ForEach-Object { (Resolve-Path -LiteralPath $_).Path })

$generator = Join-Path $PSScriptRoot 'new-wpf-harness.ps1'
$renderer = Join-Path $PSScriptRoot 'invoke-wpf-render.ps1'
$generate = @{ AssemblyPath = $assemblies; ViewType = $ViewType; Xaml = $Xaml; DataContextType = $DataContextType; ResourceDictionary = $ResourceDictionary }
if ($TargetFramework) { $generate.TargetFramework = $TargetFramework }
if ($Platform) { $generate.Platform = $Platform }
$render = @{ Background = $Background; WindowHost = $WindowHost; TimeoutSeconds = $TimeoutSeconds }
if ($Element) { $render.Element = $Element }
$sizes = if ($Size) { $Size } else { @("${Width}x$Height") }
$combos = @(foreach ($s in $sizes) { foreach ($t in $Theme) { foreach ($d in $Dpi) {
                $w, $h = $s -split 'x'
                [pscustomobject]@{ Theme = $t; Width = [int]$w; Height = [int]$h; Dpi = $d }
            } } })

# 渲染全部组合：单个组合时照常打印摘要；多个组合时只有第一个可能构建，其余 -NoBuild，最后汇总。
function Invoke-Combos([string]$HarnessDir, [bool]$SkipBuild) {
    if ($combos.Count -eq 1) {
        $c = $combos[0]
        $out = & $renderer -HarnessDir $HarnessDir -NoBuild:$SkipBuild -Theme $c.Theme -Width $c.Width -Height $c.Height -Dpi $c.Dpi @render
        return [pscustomobject]@{ OutDir = "$out"; ExitCode = $LASTEXITCODE; Matrix = $false }
    }
    $results = foreach ($c in $combos) {
        $out = & $renderer -HarnessDir $HarnessDir -NoBuild:$SkipBuild -Theme $c.Theme -Width $c.Width -Height $c.Height -Dpi $c.Dpi @render 6> $null
        $code = $LASTEXITCODE
        $SkipBuild = $true
        $summary = Get-Content -LiteralPath (Join-Path "$out" 'summary.json') -Raw | ConvertFrom-Json
        [pscustomobject]@{
            theme = $c.Theme; size = "$($c.Width)x$($c.Height)"; dpi = $c.Dpi; status = $summary.status; exitCode = $code
            snapshot = $summary.snapshot; bindingIssueCount = $summary.bindingIssueCount; layoutIssueCount = $summary.layoutIssueCount
            bindingIssues = $summary.bindingIssues; layoutIssues = $summary.layoutIssues; error = $summary.error; buildErrors = $summary.buildErrors; outDir = "$out"
        }
        if ($summary.status -eq 'failed:build') { break } # 构建失败时其余组合无法渲染
    }
    $results = @($results)
    $matrixDir = Join-Path $HarnessDir ('matrix-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Path $matrixDir
    $shots = @($results | Where-Object { $_.snapshot })
    $overview = $null
    if ($shots.Count -gt 0) {
        try {
            . (Join-Path $PSScriptRoot 'ImageTools.ps1')
            $overview = Join-Path $matrixDir 'overview.png'
            $labels = @($shots | ForEach-Object { "$($_.theme) · $($_.size) · $($_.dpi) DPI · $($_.status)" })
            [WpfOffscreenRender.ImageTools]::ContactSheet([string[]]@($shots.snapshot), [string[]]$labels, $overview, 480)
        }
        catch { $overview = $null; Write-Warning "总览图生成失败：$($_.Exception.Message)" }
    }
    # 退出码取最严重者：任一失败为 1，否则任一绑定问题为 2。
    $codes = @($results.exitCode)
    $exit = if ($results.Count -lt $combos.Count -or ($codes | Where-Object { $_ -notin 0, 2 })) { 1 } elseif ($codes -contains 2) { 2 } else { 0 }
    $matrix = [ordered]@{
        status = switch ($exit) { 0 { 'ok' } 2 { 'binding-issues' } default { 'failed' } }
        exitCode = $exit; combinations = $combos.Count; rendered = $results.Count; overview = $overview; results = $results
    }
    $json = $matrix | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText((Join-Path $matrixDir 'matrix.json'), $json, [Text.UTF8Encoding]::new($false))
    Write-Host $json
    [pscustomobject]@{ OutDir = $matrixDir; ExitCode = $exit; Matrix = $true; FirstStatus = $results[0].status }
}

if ($NoCache) {
    $harness = & $generator @generate
    $run = Invoke-Combos $harness.WorkDir $false
    $global:LASTEXITCODE = $run.ExitCode
    return $run.OutDir
}

# 工具版本：生成器与宿主模板的内容哈希，模板更新后自动换新缓存。
$toolFiles = @($generator) + @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..\assets') -Filter '*.cs' | Sort-Object Name | ForEach-Object FullName)
$keySource = [Text.StringBuilder]::new()
foreach ($file in $toolFiles) { $null = $keySource.AppendLine((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash) }
$null = $keySource.AppendLine("tfm=$TargetFramework;platform=$Platform")
foreach ($assembly in $assemblies | Sort-Object) { $null = $keySource.AppendLine($assembly.ToLowerInvariant()) }
$keyStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($keySource.ToString()))
$key = (Get-FileHash -InputStream $keyStream -Algorithm SHA256).Hash.Substring(0, 16).ToLowerInvariant()
$workDir = Join-Path $CacheRoot $key
$null = New-Item -ItemType Directory -Path $CacheRoot -Force

# 同一缓存宿主同一时间只允许一个渲染，避免并发构建写同一个 out\。
$mutex = [Threading.Mutex]::new($false, "Local\wpf-render-$key")
try {
    try { if (-not $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds + 300))) { throw "等待缓存宿主超时：$workDir" } }
    catch [Threading.AbandonedMutexException] { } # 上一个持有者异常退出，锁已转交

    $stampPath = Join-Path $workDir 'cache.json'
    # 构建会连同依赖一起复制，所以记录业务程序集所在目录中全部 dll / exe 的大小与修改时间。
    $stamps = @($assemblies | ForEach-Object { Split-Path -Parent $_ } | Sort-Object -Unique |
        ForEach-Object { Get-ChildItem -LiteralPath $_ -File | Where-Object Extension -in '.dll', '.exe' } |
        Sort-Object FullName | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" })
    $noBuild = $false
    if (Test-Path -LiteralPath (Join-Path $workDir 'RenderHarness.csproj')) {
        $cache = if (Test-Path -LiteralPath $stampPath) { Get-Content -LiteralPath $stampPath -Raw | ConvertFrom-Json }
        $noBuild = $cache -and $cache.built -and ((@($cache.stamps) -join "`n") -eq ($stamps -join "`n"))
        # 视图配置只影响 harness.json，不需要重新构建。
        $config = [ordered]@{
            viewType = if ($ViewType) { $ViewType } else { $null }
            xaml = if ($Xaml) { $Xaml } else { $null }
            dataContextType = if ($DataContextType) { $DataContextType } else { $null }
            resourceDictionaries = @($ResourceDictionary)
        }
        [IO.File]::WriteAllText((Join-Path $workDir 'harness.json'), ($config | ConvertTo-Json -Depth 3), [Text.UTF8Encoding]::new($false))
    }
    else {
        if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force } # 上次生成中断留下的残缺目录
        $null = & $generator @generate -WorkDir $workDir
    }

    $run = Invoke-Combos $workDir $noBuild
    $firstStatus = if ($run.Matrix) { $run.FirstStatus } else { (Get-Content -LiteralPath (Join-Path $run.OutDir 'summary.json') -Raw | ConvertFrom-Json).status }
    $built = $noBuild -or $firstStatus -ne 'failed:build'
    [IO.File]::WriteAllText($stampPath, ([ordered]@{ built = $built; stamps = $stamps; lastUsed = (Get-Date).ToUniversalTime().ToString('O') } | ConvertTo-Json),
        [Text.UTF8Encoding]::new($false))
}
finally {
    try { $mutex.ReleaseMutex() } catch [ApplicationException] { }
    $mutex.Dispose()
}

# 清理过期缓存与渲染结果；正在使用的宿主（本次的 $workDir）不受影响。
$cutoff = (Get-Date).AddDays(-$RetentionDays)
foreach ($dir in Get-ChildItem -LiteralPath $CacheRoot -Directory) {
    if ($dir.FullName -eq $workDir) { continue }
    $stamp = Join-Path $dir.FullName 'cache.json'
    $lastUsed = if (Test-Path -LiteralPath $stamp) { (Get-Item -LiteralPath $stamp).LastWriteTime } else { $dir.LastWriteTime }
    if ($lastUsed -lt $cutoff) { Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue }
}
Get-ChildItem -LiteralPath $workDir -Directory | Where-Object { $_.Name -like 'render-*' -or $_.Name -like 'matrix-*' } |
    Where-Object { $_.LastWriteTime -lt $cutoff } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

$global:LASTEXITCODE = $run.ExitCode
$run.OutDir
