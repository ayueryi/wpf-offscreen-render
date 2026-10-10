#requires -Version 7.0
# 一步渲染：生成（或复用缓存的）宿主工程并渲染，最后输出 summary JSON。
# 适合免代码接入（-ViewType / -Xaml）；需要定制 ViewFactory.cs 时改用 new-wpf-harness.ps1 + invoke-wpf-render.ps1。
#
# 缓存：同一组 程序集路径 + TFM + 位数 + 工具版本 复用 %TEMP%\wpf-render-cache 下的同一个宿主。
# 视图配置每次重写 harness.json；业务程序集的大小 / 修改时间未变时跳过构建，变化时重新构建。
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
    [int]$Dpi = 96,
    [string]$Theme = 'light',
    [string]$Background = 'auto',
    [switch]$WindowHost,
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
$render = @{ Width = $Width; Height = $Height; Dpi = $Dpi; Theme = $Theme; Background = $Background; WindowHost = $WindowHost; TimeoutSeconds = $TimeoutSeconds }

if ($NoCache) {
    $harness = & $generator @generate
    return & $renderer -HarnessDir $harness.WorkDir @render
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

    $outDir = & $renderer -HarnessDir $workDir -NoBuild:$noBuild @render
    $exitCode = $LASTEXITCODE
    $summary = Get-Content -LiteralPath (Join-Path $outDir 'summary.json') -Raw | ConvertFrom-Json
    $built = $noBuild -or $summary.status -ne 'failed:build'
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
Get-ChildItem -LiteralPath $workDir -Directory -Filter 'render-*' | Where-Object { $_.LastWriteTime -lt $cutoff } |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

$global:LASTEXITCODE = $exitCode
$outDir
