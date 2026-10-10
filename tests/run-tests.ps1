#requires -Version 7.0
# 端到端回归测试：构建 fixtures 中的样例程序集，逐个生成宿主并渲染，断言退出码、summary 与 manifest。
# 也可用作环境自检：-Quick 只跑内置样例与一个松散 XAML，确认本机 SDK / 运行时可用。
[CmdletBinding()]
param(
    # 测试产物目录；默认在 %TEMP% 新建，通过后删除（-KeepArtifacts 保留）。
    [string]$ArtifactsDir,
    [switch]$KeepArtifacts,
    [switch]$Quick,
    # 只运行名称匹配该通配符的用例。
    [string]$Filter = '*'
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'WPF 渲染测试需要 Windows。' }

$root = Split-Path -Parent $PSScriptRoot
$generator = Join-Path $root 'scripts\new-wpf-harness.ps1'
$renderer = Join-Path $root 'scripts\invoke-wpf-render.ps1'
$oneStep = Join-Path $root 'scripts\render.ps1'
$fixtures = Join-Path $PSScriptRoot 'fixtures'
$userArtifacts = [bool]$ArtifactsDir
if (-not $ArtifactsDir) { $ArtifactsDir = Join-Path ([IO.Path]::GetTempPath()) ('wpf-render-tests-' + [guid]::NewGuid().ToString('N')) }
$ArtifactsDir = [IO.Path]::GetFullPath($ArtifactsDir)
# 生成器拒绝覆盖已有工程目录，复用非空目录会让用例误报失败。
if ((Test-Path -LiteralPath $ArtifactsDir) -and (Get-ChildItem -LiteralPath $ArtifactsDir -Force | Select-Object -First 1)) {
    throw "产物目录非空：$ArtifactsDir"
}
$null = New-Item -ItemType Directory -Path $ArtifactsDir -Force

# 样例程序集：net472 AnyCPU / net472 x86 / net8.0-windows。--no-incremental 避免同一 obj 目录下切换位数时沿用旧产物。
$sampleProject = Join-Path $fixtures 'SampleViews\SampleViews.csproj'
$samples = @{}
if (-not $Quick) {
    foreach ($variant in @(
            @{ Name = 'net472'; Args = @('-f', 'net472') },
            @{ Name = 'net472-x86'; Args = @('-f', 'net472', '-p:PlatformTarget=x86') },
            @{ Name = 'net8'; Args = @('-f', 'net8.0-windows') })) {
        $out = Join-Path $ArtifactsDir "fixtures\$($variant.Name)"
        $log = Join-Path $ArtifactsDir "fixtures-$($variant.Name).log"
        & dotnet build $sampleProject -c Release --nologo --no-incremental -o $out @($variant.Args) *> $log
        if ($LASTEXITCODE -ne 0) { Get-Content -LiteralPath $log -Tail 30; throw "样例程序集构建失败：$($variant.Name)" }
        $samples[$variant.Name] = Join-Path $out 'SampleViews.dll'
    }
}

$cases = @(
    @{ Name = 'sample-light'; Quick = $true
        Expect = @{ exitCode = 0; status = 'ok'; sourceViewType = 'System.Windows.Controls.Border'; pixelSize = '1280x800'; mode = 'layout-only'; layoutIssueCount = 0 } }
    @{ Name = 'xaml-ok'; Quick = $true; Generate = @{ Xaml = Join-Path $fixtures 'ok.xaml' }
        Expect = @{ exitCode = 0; status = 'ok'; sourceViewType = 'System.Windows.Controls.Border'; layoutIssueCount = 0 } }
    @{ Name = 'sample-dark-dpi144'; Render = @{ Theme = 'dark'; Dpi = 144; Width = 640; Height = 360 }
        Expect = @{ exitCode = 0; pixelSize = '960x540'; background = '#FF1E1E1E' } }
    @{ Name = 'sample-window-host'; Render = @{ WindowHost = $true; Width = 800; Height = 600 }
        Expect = @{ exitCode = 0; mode = 'window-host'; actualSizeDip = '800x600' } }
    @{ Name = 'sample-transparent'; Render = @{ Background = 'transparent' }; Expect = @{ exitCode = 0; background = 'transparent' } }
    @{ Name = 'sample-net10'; Generate = @{ TargetFramework = 'net10.0-windows' }
        Expect = @{ exitCode = 0; harnessTfm = 'net10.0-windows'; targetFramework = '.NETCoreApp,Version=v10.0' } }
    @{ Name = 'xaml-binding-error'; Generate = @{ Xaml = Join-Path $fixtures 'binding-error.xaml' }
        Expect = @{ exitCode = 2; status = 'binding-issues'; bindingIssuePattern = 'MissingProperty' } }
    @{ Name = 'net8-view'; Sample = 'net8'; Generate = @{ ViewType = 'SampleViews.OrderView'; DataContextType = 'SampleViews.OrderPreviewVm' }
        Expect = @{ exitCode = 0; status = 'ok'; sourceViewType = 'SampleViews.OrderView'; harnessTfm = 'net8.0-windows'; harnessPlatform = 'AnyCPU'; layoutIssueCount = 0 } }
    @{ Name = 'net8-broken-binding'; Sample = 'net8'; Generate = @{ ViewType = 'SampleViews.BrokenBindingView'; DataContextType = 'SampleViews.OrderPreviewVm' }
        Expect = @{ exitCode = 2; bindingIssuePattern = 'TextBlock.Text <- Path=CustomerNmae（数据源 OrderPreviewVm）' } }
    @{ Name = 'net8-layout-problems'; Sample = 'net8'; Generate = @{ ViewType = 'SampleViews.LayoutProblemsView' }
        Expect = @{ exitCode = 0; layoutIssueCount = 5
            layoutIssues = @('text-truncated:TextBlock#TruncatedTitle', 'clipped:Button#ClippedButton', 'overlap:TextBlock#OverlapA',
                'zero-size:TextBlock#ZeroSizeText', 'out-of-viewport:TextBlock#OffscreenNote') } }
    @{ Name = 'net8-scroll-no-false-positive'; Sample = 'net8'; Generate = @{ ViewType = 'SampleViews.ScrollListView' }
        Expect = @{ exitCode = 0; layoutIssueCount = 0 } }
    @{ Name = 'render-cache'; OneStep = @{ ViewType = 'SampleViews.OrderView'; DataContextType = 'SampleViews.OrderPreviewVm' } }
    @{ Name = 'net472-view'; Sample = 'net472'; Generate = @{ ViewType = 'SampleViews.OrderView'; DataContextType = 'SampleViews.OrderPreviewVm' }
        Expect = @{ exitCode = 0; status = 'ok'; harnessTfm = 'net472'; harnessPlatform = 'AnyCPU'
            targetFramework = '.NETFramework,Version=v4.7.2'; runtimePattern = '^\.NET Framework'; processArchitecture = 'X64' } }
    @{ Name = 'net472-window-host'; Sample = 'net472'; Generate = @{ ViewType = 'SampleViews.OrderView'; DataContextType = 'SampleViews.OrderPreviewVm' }
        Render = @{ WindowHost = $true }; Expect = @{ exitCode = 0; mode = 'window-host' } }
    @{ Name = 'net472-x86-view'; Sample = 'net472-x86'; Generate = @{ ViewType = 'SampleViews.OrderView'; DataContextType = 'SampleViews.OrderPreviewVm' }
        Expect = @{ exitCode = 0; harnessTfm = 'net472'; harnessPlatform = 'x86'; processArchitecture = 'X86' } }
    @{ Name = 'net472-broken-binding'; Sample = 'net472'; Generate = @{ ViewType = 'SampleViews.BrokenBindingView'; DataContextType = 'SampleViews.OrderPreviewVm' }
        Expect = @{ exitCode = 2; bindingIssuePattern = 'CustomerNmae' } }
    @{ Name = 'net472-layout-problems'; Sample = 'net472'; Generate = @{ ViewType = 'SampleViews.LayoutProblemsView' }
        Expect = @{ exitCode = 0; layoutIssueCount = 5 } }
    # 生成器应拒绝的组合：不生成工程，只断言错误信息。
    @{ Name = 'reject-mixed-runtimes'; Samples = @('net472', 'net8'); ExpectGenerateError = '同时包含 .NET Framework 与 .NET' }
    @{ Name = 'reject-lower-tfm'; Sample = 'net8'; Generate = @{ TargetFramework = 'net6.0-windows' }; ExpectGenerateError = '不能引用面向' }
    @{ Name = 'reject-platform-conflict'; Sample = 'net472-x86'; Generate = @{ Platform = 'x64' }; ExpectGenerateError = '不一致' }
)

# render.ps1：同一配置第二次应复用缓存宿主并跳过构建；业务程序集更新后应重新构建。
function Test-OneStep($case) {
    $failures = [Collections.Generic.List[string]]::new()
    $source = Join-Path $ArtifactsDir "$($case.Name)-src"
    Copy-Item -LiteralPath (Split-Path -Parent $samples['net8']) -Destination $source -Recurse
    $params = @{ AssemblyPath = Join-Path $source 'SampleViews.dll'; CacheRoot = Join-Path $ArtifactsDir "$($case.Name)-cache" } + $case.OneStep
    $runs = foreach ($step in 'first', 'cached', 'changed') {
        if ($step -eq 'changed') { (Get-Item -LiteralPath $params.AssemblyPath).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(1) }
        $outDir = & $oneStep @params 6> $null
        [pscustomobject]@{ Step = $step; OutDir = "$outDir"; ExitCode = $LASTEXITCODE; Built = Test-Path -LiteralPath (Join-Path "$outDir" 'build.log') }
    }
    foreach ($run in $runs) {
        $expectBuilt = $run.Step -ne 'cached'
        if ($run.ExitCode -ne 0) { $failures.Add("$($run.Step)：退出码 $($run.ExitCode)（outDir=$($run.OutDir)）") }
        if ($run.Built -ne $expectBuilt) { $failures.Add("$($run.Step)：期望$(if ($expectBuilt) { '' } else { '不' })构建，实际$(if ($run.Built) { '' } else { '未' })构建") }
    }
    $harnessDirs = @($runs | ForEach-Object { Split-Path -Parent $_.OutDir } | Select-Object -Unique)
    if ($harnessDirs.Count -ne 1) { $failures.Add("三次渲染应复用同一宿主，实际：$($harnessDirs -join ', ')") }
    $failures
}

function Test-Case($case) {
    if ($case.OneStep) { return Test-OneStep $case }
    $failures = [Collections.Generic.List[string]]::new()
    $generate = @{ WorkDir = Join-Path $ArtifactsDir "harness\$($case.Name)" }
    if ($case.Generate) { $generate += $case.Generate }
    $assemblies = @($case.Samples) + @($case.Sample) | Where-Object { $_ } | ForEach-Object { $samples[$_] }
    if ($assemblies) { $generate.AssemblyPath = @($assemblies) }

    try { $harness = & $generator @generate }
    catch {
        if ($case.ExpectGenerateError -and $_.Exception.Message -like "*$($case.ExpectGenerateError)*") { return $failures }
        $failures.Add("生成器异常：$($_.Exception.Message)"); return $failures
    }
    if ($case.ExpectGenerateError) { $failures.Add("生成器应报错（$($case.ExpectGenerateError)），但成功生成了工程"); return $failures }

    $render = @{ HarnessDir = $harness.WorkDir }
    if ($case.Render) { $render += $case.Render }
    $outDir = & $renderer @render 6> $null
    $exitCode = $LASTEXITCODE
    $summaryPath = Join-Path "$outDir" 'summary.json'
    if (-not (Test-Path -LiteralPath $summaryPath)) { $failures.Add("缺少 summary.json（outDir=$outDir）"); return $failures }
    $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
    $manifestPath = Join-Path $outDir 'manifest.json'
    $manifest = if (Test-Path -LiteralPath $manifestPath) { Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json }
    $layoutPath = Join-Path $outDir 'layout.json'
    $layout = if (Test-Path -LiteralPath $layoutPath) { Get-Content -LiteralPath $layoutPath -Raw | ConvertFrom-Json }

    $actual = @{
        exitCode = $exitCode; status = $summary.status; sourceViewType = $summary.sourceViewType; mode = $summary.mode
        pixelSize = $summary.pixelSize; actualSizeDip = $summary.actualSizeDip; background = $summary.background
        harnessTfm = $harness.TargetFramework; harnessPlatform = $harness.Platform
        targetFramework = $manifest.targetFramework; processArchitecture = $manifest.processArchitecture
        layoutIssueCount = $summary.layoutIssueCount
    }
    foreach ($key in $case.Expect.Keys) {
        $expected = $case.Expect[$key]
        switch ($key) {
            'bindingIssuePattern' {
                if (-not (@($summary.bindingIssues) -match [regex]::Escape($expected))) { $failures.Add("绑定问题中没有 $expected") }
            }
            'layoutIssues' {
                # 形如 kind:元素前缀，按 layout.json 的 issues 逐条匹配。
                $found = @($layout.issues | Where-Object { $_ } | ForEach-Object { "$($_.kind):$($_.element)" })
                foreach ($item in $expected) {
                    if (-not ($found | Where-Object { $_.StartsWith($item, [StringComparison]::Ordinal) })) { $failures.Add("缺少布局问题 $item") }
                }
            }
            'runtimePattern' {
                if ("$($manifest.runtime)" -notmatch $expected) { $failures.Add("runtime：期望匹配 $expected，实际 $($manifest.runtime)") }
            }
            default {
                if ("$($actual[$key])" -ne "$expected") { $failures.Add("$key：期望 $expected，实际 $($actual[$key])") }
            }
        }
    }
    # 成功渲染时必须有 PNG，且绑定监听自检命中。
    if ($exitCode -in 0, 2) {
        if (-not $summary.snapshot -or -not (Test-Path -LiteralPath $summary.snapshot)) { $failures.Add('缺少 snapshot.png') }
        if ($summary.bindingTraceVerified -ne $true) { $failures.Add('绑定监听自检未命中') }
    }
    if ($failures.Count -gt 0) {
        $failures.Add("outDir=$outDir")
        foreach ($line in @($summary.error) + @($summary.buildErrors) + @($summary.layoutIssues)) { if ($line) { $failures.Add("  $line") } }
    }
    $failures
}

$results = foreach ($case in $cases) {
    if ($Quick -and -not $case.Quick) { continue }
    if ($case.Name -notlike $Filter) { continue }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $failures = @(Test-Case $case)
    $result = [pscustomobject]@{
        Case = $case.Name; Result = if ($failures.Count) { 'FAIL' } else { 'PASS' }
        Seconds = [math]::Round($timer.Elapsed.TotalSeconds, 1); Details = $failures -join [Environment]::NewLine
    }
    Write-Host ('{0,-4} {1} ({2}s)' -f $result.Result, $result.Case, $result.Seconds)
    if ($failures.Count) { $failures | ForEach-Object { Write-Host "     $_" } }
    $result
}

$failed = @($results | Where-Object Result -eq 'FAIL')
Write-Host ''
Write-Host ("{0} 通过，{1} 失败；产物：{2}" -f ($results.Count - $failed.Count), $failed.Count, $ArtifactsDir)
if (-not $failed -and -not $KeepArtifacts -and -not $userArtifacts) { Remove-Item -LiteralPath $ArtifactsDir -Recurse -Force }
exit $(if ($failed) { 1 } else { 0 })
