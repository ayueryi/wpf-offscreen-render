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
    [switch]$NoBuild,
    [ValidateRange(5,600)][int]$TimeoutSeconds = 120
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'WPF 渲染需要 Windows。' }
$HarnessDir = (Resolve-Path -LiteralPath $HarnessDir).Path
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
    $buildErrors = @(if ($Stage -eq 'build' -and (Test-Path -LiteralPath $buildLog)) {
        @(Select-String -LiteralPath $buildLog -Pattern ': error ' | Select-Object -First 10 | ForEach-Object { $_.Line.Trim() } | Select-Object -Unique)
    })
    $summary = [ordered]@{
        status = switch ($ExitCode) { 0 { 'ok' } 2 { 'binding-issues' } default { "failed:$Stage" } }
        exitCode = $ExitCode
        outDir = $outDir
        snapshot = if (Test-Path -LiteralPath $snapshot) { $snapshot } else { $null }
        sourceViewType = $manifest.sourceViewType
        mode = $manifest.mode
        theme = $Theme
        pixelSize = if ($manifest) { "$($manifest.pixelWidth)x$($manifest.pixelHeight)" } else { $null }
        actualSizeDip = if ($manifest) { "$($manifest.actualWidthDip)x$($manifest.actualHeightDip)" } else { $null }
        background = $manifest.background
        bindingTraceVerified = $manifest.bindingTraceVerified
        bindingIssueCount = $manifest.bindingWarningOrErrorCount
        bindingIssues = @(& $read 'binding-errors.txt' 5)
        buildErrors = $buildErrors
        error = @(& $read 'error.txt' 15)
    }
    $json = $summary | ConvertTo-Json -Depth 3
    [IO.File]::WriteAllText((Join-Path $outDir 'summary.json'), $json, [Text.UTF8Encoding]::new($false))
    Write-Host $json
    $global:LASTEXITCODE = $ExitCode
    Write-Output $outDir
}

if (-not $NoBuild) {
    & dotnet build $projectPath -c Debug --nologo -o $binDir *> (Join-Path $outDir 'build.log')
    if ($LASTEXITCODE -ne 0) { Complete-Render 1 'build'; return }
}
$dll = Join-Path $binDir 'RenderHarness.dll'
if (-not (Test-Path -LiteralPath $dll)) {
    # 兼容旧版生成器的工程：未使用 -o 时产物位于 bin\Debug\<TFM>。
    $legacy = Get-ChildItem -LiteralPath (Join-Path $HarnessDir 'bin\Debug') -Filter 'RenderHarness.dll' -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $legacy) {
        [IO.File]::WriteAllText((Join-Path $outDir 'error.txt'), "渲染程序集不存在：$dll（使用了 -NoBuild 但尚未构建？）")
        Complete-Render 1 'locate'; return
    }
    $dll = $legacy.FullName
}
$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = (Get-Command dotnet -ErrorAction Stop).Source
$startInfo.WorkingDirectory = $HarnessDir
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$arguments = @($dll, '--out', $outDir, '--width', "$Width", '--height', "$Height", '--dpi', "$Dpi", '--theme', $Theme,
    '--background', $Background)
$configPath = Join-Path $HarnessDir 'harness.json'
if (Test-Path -LiteralPath $configPath) { $arguments += '--config', $configPath }
if ($WindowHost) { $arguments += '--window-host' }
foreach ($argument in $arguments) { $startInfo.ArgumentList.Add($argument) }
$process = [Diagnostics.Process]::new()
$process.StartInfo = $startInfo
$exitCode = 1
try {
    $null = $process.Start()
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not $process.WaitForExit(250)) {
        if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            $process.Kill($true)
            $process.WaitForExit()
            [IO.File]::WriteAllText((Join-Path $outDir 'error.txt'), "渲染子进程超过 $TimeoutSeconds 秒，已终止。")
            break
        }
    }
    [IO.File]::WriteAllText((Join-Path $outDir 'render.stdout.log'), $stdout.GetAwaiter().GetResult())
    [IO.File]::WriteAllText((Join-Path $outDir 'render.stderr.log'), $stderr.GetAwaiter().GetResult())
    if (-not (Test-Path -LiteralPath (Join-Path $outDir 'error.txt'))) { $exitCode = $process.ExitCode }
}
finally { $process.Dispose() }
Complete-Render $exitCode 'render'
