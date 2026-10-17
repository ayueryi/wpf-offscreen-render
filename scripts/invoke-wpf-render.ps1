#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$HarnessDir,
    [ValidateRange(1,6000)][int]$Width = 1280,
    [ValidateRange(1,6000)][int]$Height = 800,
    [ValidateRange(48,384)][int]$Dpi = 96,
    [ValidateSet('light','dark')][string]$Theme = 'light',
    # auto | transparent | WPF 颜色（#RRGGBB、#AARRGGBB 或颜色名）
    [ValidatePattern('^(auto|transparent|#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})|[A-Za-z]+)$')]
    [string]$Background = 'auto',
    [switch]$WindowHost,
    # 另存该 x:Name 元素的截图为 element.png（整页 snapshot.png 照常生成）。
    [string]$Element,
    [switch]$NoBuild,
    [ValidateRange(5,600)][int]$TimeoutSeconds = 120
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'WPF 渲染需要 Windows。' }
$HarnessDir = (Resolve-Path -LiteralPath $HarnessDir).ProviderPath
$projectPath = Join-Path $HarnessDir 'RenderHarness.csproj'
if (-not (Test-Path -LiteralPath $projectPath)) { throw "工程不存在：$projectPath" }
if ([math]::Ceiling($Width * $Dpi / 96.0) * [math]::Ceiling($Height * $Dpi / 96.0) -gt 60000000) {
    throw '输出超过 6000 万像素，请减小尺寸或 DPI。'
}
$outDir = Join-Path $HarnessDir ('render-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $outDir
$binDir = Join-Path $HarnessDir 'out'

# 汇总本次结果到 summary.json 并打印，代理一次调用即可拿到结论。
function Complete-Render([int]$ExitCode, [string]$Stage) {
    $read = { param($name, $count) $p = Join-Path $outDir $name; if (Test-Path -LiteralPath $p) { @(Get-Content -LiteralPath $p -TotalCount $count) } else { @() } }
    $manifestPath = Join-Path $outDir 'manifest.json'
    $manifest = if (Test-Path -LiteralPath $manifestPath) { Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json } else { $null }
    $snapshot = Join-Path $outDir 'snapshot.png'
    $buildLog = Join-Path $outDir 'build.log'
    $readJson = { param($name) $p = Join-Path $outDir $name; if (Test-Path -LiteralPath $p) { Get-Content -LiteralPath $p -Raw | ConvertFrom-Json } }
    # 绑定问题优先用宿主解析后的单行结论（目标元素.属性 <- 路径（数据源）：原因），旧宿主回退到原始日志。
    $bindingJson = & $readJson 'binding-errors.json'
    $bindingIssues = if ($null -ne $bindingJson) { @(@($bindingJson) | Select-Object -First 5 | ForEach-Object summary) } else { @(& $read 'binding-errors.txt' 5) }
    $layout = & $readJson 'layout.json'
    $layoutIssues = @(@($layout.issues) | Where-Object { $_ } | Select-Object -First 10 | ForEach-Object { "[$($_.kind)] $($_.element)：$($_.message)" })
    $buildErrors = @(if ($Stage -eq 'build' -and (Test-Path -LiteralPath $buildLog)) {
        @(Select-String -LiteralPath $buildLog -Pattern ': error ' | Select-Object -First 10 | ForEach-Object { $_.Line.Trim() } | Select-Object -Unique)
    })
    # 没有 error.txt 的崩溃（如缺少 WindowsDesktop 运行时，宿主在 Main 之前退出）：用 stderr 末尾说明原因。
    $errorLines = @(& $read 'error.txt' 15)
    $stderrLog = Join-Path $outDir 'render.stderr.log'
    if ($errorLines.Count -eq 0 -and $ExitCode -notin 0, 2, 3 -and (Test-Path -LiteralPath $stderrLog)) {
        $errorLines = @(Get-Content -LiteralPath $stderrLog -Tail 15 | Where-Object { $_.Trim() })
    }
    # 交互步骤：每步一行摘要，失败步骤的原因并入 error；所有截图（含动画帧）拼成总览图。
    $stepsData = & $readJson 'steps.json'
    $steps = $null
    $stepsOverview = $null
    if ($null -ne $stepsData) {
        $stepsData = @($stepsData)
        $steps = @($stepsData | ForEach-Object {
                [ordered]@{
                    index = $_.index; name = $_.name; action = $_.action; status = $_.status; error = $_.error
                    snapshot = $_.snapshot; changedBoundsDip = $_.changedBoundsDip
                    bindingIssues = @($_.bindingIssues | Select-Object -First 3); layoutIssueCount = $_.layoutIssueCount
                    frames = @($_.frames | Where-Object { $_ } | ForEach-Object { [ordered]@{ atMs = $_.atMs; snapshot = $_.snapshot; changedBoundsDip = $_.changedBoundsDip } })
                    dialogs = @($_.dialogs | Where-Object { $_ } | ForEach-Object { "$($_.kind)：$($_.title) $($_.text)".Trim() })
                    warnings = @($_.warnings)
                }
            })
        $failedSteps = @($stepsData | Where-Object status -eq 'failed')
        if ($failedSteps) { $errorLines = @($failedSteps | ForEach-Object { "[步骤 $($_.index) $($_.name)] $($_.error)" }) + $errorLines }
        $tiles = [Collections.Generic.List[object]]::new()
        if (Test-Path -LiteralPath $snapshot) { $tiles.Add(@($snapshot, '0 · 初始')) }
        foreach ($step in $stepsData) {
            if ($step.frames) { foreach ($frame in $step.frames) { $tiles.Add(@($frame.snapshot, "$($step.index) · $($step.name) @$($frame.atMs)ms")) } }
            elseif ($step.snapshot) { $tiles.Add(@($step.snapshot, "$($step.index) · $($step.name)$(if ($step.status -ne 'ok') { " · $($step.status)" })")) }
        }
        $tiles = @($tiles | Where-Object { Test-Path -LiteralPath $_[0] })
        if ($tiles.Count -gt 1) {
            try {
                . (Join-Path $PSScriptRoot 'ImageTools.ps1')
                $stepsOverview = Join-Path $outDir 'steps-overview.png'
                [WpfOffscreenRender.ImageTools]::ContactSheet([string[]]@($tiles | ForEach-Object { $_[0] }), [string[]]@($tiles | ForEach-Object { $_[1] }), $stepsOverview, 360)
            }
            catch { $stepsOverview = $null; Write-Warning "步骤总览图生成失败：$($_.Exception.Message)" }
        }
    }
    $summary = [ordered]@{
        status = switch ($ExitCode) { 0 { 'ok' } 2 { 'binding-issues' } 3 { 'failed:step' } default { "failed:$Stage" } }
        toolVersion = $manifest.toolVersion
        exitCode = $ExitCode
        outDir = $outDir
        snapshot = if (Test-Path -LiteralPath $snapshot) { $snapshot } else { $null }
        elementSnapshot = if (Test-Path -LiteralPath (Join-Path $outDir 'element.png')) { Join-Path $outDir 'element.png' } else { $null }
        elementRectDip = $manifest.elementRectDip
        elementError = $manifest.elementError
        warning = $manifest.warning
        sourceViewType = $manifest.sourceViewType
        mode = $manifest.mode
        theme = $Theme
        pixelSize = if ($manifest) { "$($manifest.pixelWidth)x$($manifest.pixelHeight)" } else { $null }
        actualSizeDip = if ($manifest) { "$($manifest.actualWidthDip)x$($manifest.actualHeightDip)" } else { $null }
        background = $manifest.background
        bindingTraceVerified = $manifest.bindingTraceVerified
        bindingIssueCount = $manifest.bindingWarningOrErrorCount
        bindingIssues = $bindingIssues
        layoutIssueCount = $manifest.layoutIssueCount
        layoutIssues = $layoutIssues
        buildErrors = $buildErrors
        error = $errorLines
    }
    if ($null -ne $steps) { $summary.steps = $steps; $summary.stepsOverview = $stepsOverview }
    $json = $summary | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText((Join-Path $outDir 'summary.json'), $json, [Text.UTF8Encoding]::new($false))
    Write-Host $json
    $global:LASTEXITCODE = $ExitCode
    Write-Output $outDir
}

if (-not $NoBuild) {
    # dotnet 按当前目录查找 global.json：在宿主目录内构建，才会用到宿主自带的空 global.json，而不是业务仓库锁定的 SDK。
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        [IO.File]::WriteAllText((Join-Path $outDir 'error.txt'), '找不到 dotnet：需要安装 .NET 8 或更高版本的 SDK，并确保 dotnet 在 PATH 中。')
        Complete-Render 1 'build'; return
    }
    Push-Location -LiteralPath $HarnessDir
    try { & dotnet build $projectPath -c Debug --nologo -o $binDir *> (Join-Path $outDir 'build.log'); $buildCode = $LASTEXITCODE }
    finally { Pop-Location }
    if ($buildCode -ne 0) { Complete-Render 1 'build'; return }
}
# .NET Framework 与启用 apphost 的工程直接运行 exe（位数由 PlatformTarget 决定）；其余经 dotnet 宿主运行 dll。
$properties = ([xml](Get-Content -LiteralPath $projectPath -Raw)).Project.PropertyGroup
$useAppHost = "$($properties.TargetFramework)" -like 'net4*' -or "$($properties.UseAppHost)".Trim() -eq 'true'
$entry = Join-Path $binDir ($(if ($useAppHost) { 'RenderHarness.exe' } else { 'RenderHarness.dll' }))
if (-not (Test-Path -LiteralPath $entry)) {
    # 兼容旧版生成器的工程：未使用 -o 时产物位于 bin\Debug\<TFM>。
    $legacy = Get-ChildItem -LiteralPath (Join-Path $HarnessDir 'bin\Debug') -Filter ([IO.Path]::GetFileName($entry)) -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $legacy) {
        [IO.File]::WriteAllText((Join-Path $outDir 'error.txt'), "渲染程序集不存在：$entry（使用了 -NoBuild 但尚未构建？）")
        Complete-Render 1 'locate'; return
    }
    $entry = $legacy.FullName
}
$startInfo = [Diagnostics.ProcessStartInfo]::new()
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
$arguments = @('--out', $outDir, '--width', "$Width", '--height', "$Height", '--dpi', "$Dpi", '--theme', $Theme,
    '--background', $Background)
if ($useAppHost) { $startInfo.FileName = $entry }
else {
    $startInfo.FileName = if ($dotnet) { $dotnet.Source } else { 'dotnet' }
    $arguments = @($entry) + $arguments
}
$startInfo.WorkingDirectory = $HarnessDir
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$versionFile = Join-Path $PSScriptRoot '..\VERSION'
if (Test-Path -LiteralPath $versionFile) { $arguments += '--tool-version', (Get-Content -LiteralPath $versionFile -TotalCount 1).Trim() }
$configPath = Join-Path $HarnessDir 'harness.json'
if (Test-Path -LiteralPath $configPath) { $arguments += '--config', $configPath }
if ($WindowHost) { $arguments += '--window-host' }
if ($Element) { $arguments += '--element', $Element }
foreach ($argument in $arguments) { $startInfo.ArgumentList.Add($argument) }
$process = [Diagnostics.Process]::new()
$process.StartInfo = $startInfo
$exitCode = 1
$stage = 'render'
try {
    # 进程无法启动（AppLocker / 软件限制策略拦截 %TEMP% 下的 exe、找不到 dotnet 等）也要写出 summary.json。
    try { $null = $process.Start() }
    catch {
        [IO.File]::WriteAllText((Join-Path $outDir 'error.txt'), "无法启动渲染进程 $($startInfo.FileName)：$($_.Exception.Message)（若被 AppLocker 等策略拦截，用 -WorkDir / -CacheRoot 把宿主放到允许执行的目录）")
        Complete-Render 1 'start'; return
    }
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not $process.WaitForExit(250)) {
        if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            $process.Kill($true)
            $process.WaitForExit()
            [IO.File]::WriteAllText((Join-Path $outDir 'error.txt'), "渲染子进程超过 $TimeoutSeconds 秒，已终止（检查 WaitUntilReadyAsync 是否在等待永不完成的信号，或调大 -TimeoutSeconds）。")
            $stage = 'timeout'
            break
        }
    }
    # 业务代码启动的子进程会继承输出管道：宿主退出后管道可能仍未关闭，读取不能无限等待。
    foreach ($stream in @(@($stdout, 'render.stdout.log'), @($stderr, 'render.stderr.log'))) {
        $text = if ($stream[0].Wait(5000)) { $stream[0].Result } else { '（输出管道仍被业务代码启动的子进程占用，未读取完）' }
        [IO.File]::WriteAllText((Join-Path $outDir $stream[1]), $text)
    }
    if (-not (Test-Path -LiteralPath (Join-Path $outDir 'error.txt'))) { $exitCode = $process.ExitCode }
}
finally { $process.Dispose() }
Complete-Render $exitCode $stage
