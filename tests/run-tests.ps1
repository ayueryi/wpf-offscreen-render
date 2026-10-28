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
$comparer = Join-Path $root 'scripts\compare-snapshots.ps1'
$fixtures = Join-Path $PSScriptRoot 'fixtures'
$userArtifacts = [bool]$ArtifactsDir
if (-not $ArtifactsDir) { $ArtifactsDir = Join-Path ([IO.Path]::GetTempPath()) ('wpf-render-tests-' + [guid]::NewGuid().ToString('N')) }
$ArtifactsDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ArtifactsDir)
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

$layoutProblemKinds = @('text-truncated:TextBlock#TruncatedTitle', 'clipped:Button#ClippedButton', 'overlap:TextBlock#OverlapA',
    'zero-size:TextBlock#ZeroSizeText', 'out-of-viewport:TextBlock#OffscreenNote')

$cases = @(
    @{ Name = 'sample-light'; Quick = $true
        Expect = @{ exitCode = 0; status = 'ok'; sourceViewType = 'System.Windows.Controls.Border'; pixelSize = '1280x800'; mode = 'layout-only'; layoutIssueCount = 0
            toolVersion = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -TotalCount 1).Trim() } }
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
        Expect = @{ exitCode = 0; layoutIssueCount = 5; layoutIssues = $layoutProblemKinds } }
    @{ Name = 'net8-scroll-no-false-positive'; Sample = 'net8'; Generate = @{ ViewType = 'SampleViews.ScrollListView' }
        Expect = @{ exitCode = 0; layoutIssueCount = 0 } }
    @{ Name = 'render-cache'; Kind = 'Cache'; OneStep = @{ ViewType = 'SampleViews.OrderView'; DataContextType = 'SampleViews.OrderPreviewVm' } }
    @{ Name = 'render-matrix'; Kind = 'Matrix' }
    @{ Name = 'cache-cleanup'; Kind = 'CacheCleanup' }
    @{ Name = 'compare-snapshots'; Kind = 'Compare' }
    @{ Name = 'global-json-isolation'; Kind = 'GlobalJson' }
    @{ Name = 'mcp-server'; Kind = 'Mcp' }
    @{ Name = 'factory-method'; Sample = 'net8'; Generate = @{ ViewType = 'SampleViews.OrderView'; DataContextFactory = 'SampleViews.PreviewData.CreateRemoteOrder' }
        Expect = @{ exitCode = 0; status = 'ok'; layoutText = 'Order #2048' } }
    @{ Name = 'factory-file'; Sample = 'net8'; Generate = @{ FactoryFile = Join-Path $fixtures 'CustomViewFactory.cs' }
        Expect = @{ exitCode = 0; status = 'ok'; sourceViewType = 'SampleViews.OrderView'; layoutText = 'Custom factory order' } }
    @{ Name = 'preset'; Kind = 'Preset' }
    @{ Name = 'preset-merge'; Kind = 'PresetMerge' }
    @{ Name = 'logic-tests'; Kind = 'LogicTests' }
    @{ Name = 'result-reader'; Kind = 'ResultReader' }
    @{ Name = 'watch-matcher'; Kind = 'WatchMatcher' }
    @{ Name = 'steps-net8'; Kind = 'Steps'; Sample = 'net8' }
    @{ Name = 'steps-net472'; Kind = 'Steps'; Sample = 'net472' }
    @{ Name = 'steps-layout-only'; Kind = 'StepsLayoutOnly' }
    @{ Name = 'steps-failure'; Kind = 'StepsFailure' }
    @{ Name = 'steps-custom'; Kind = 'StepsCustom' }
    @{ Name = 'stop-hook'; Kind = 'Hook' }
    @{ Name = 'net8-element'; Sample = 'net8'; Generate = @{ ViewType = 'SampleViews.LayoutProblemsView' }; Render = @{ Element = 'ClippedButton'; Dpi = 144 }
        Expect = @{ exitCode = 0; elementWidthDip = 300; elementPixelWidth = 450 } }
    @{ Name = 'net8-element-offset'; Sample = 'net8'; Generate = @{ ViewType = 'SampleViews.CenteredView' }; Render = @{ Element = 'CenteredButton' }
        Expect = @{ exitCode = 0; elementRectDip = '450,310,100,30' } }
    @{ Name = 'net8-element-missing'; Sample = 'net8'; Generate = @{ ViewType = 'SampleViews.LayoutProblemsView' }; Render = @{ Element = 'NoSuchElement' }
        Expect = @{ exitCode = 1; errorPattern = 'ClippedButton' } }
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
        Expect = @{ exitCode = 0; layoutIssueCount = 5; layoutIssues = $layoutProblemKinds } }
    # 生成器应拒绝的组合：不生成工程，只断言错误信息。
    @{ Name = 'reject-mixed-runtimes'; Samples = @('net472', 'net8'); ExpectGenerateError = '同时包含 .NET Framework 与 .NET' }
    @{ Name = 'reject-lower-tfm'; Sample = 'net8'; Generate = @{ TargetFramework = 'net6.0-windows' }; ExpectGenerateError = '不能引用面向' }
    @{ Name = 'reject-platform-conflict'; Sample = 'net472-x86'; Generate = @{ Platform = 'x64' }; ExpectGenerateError = '不一致' }
)

# PNG 头部 IHDR 中的宽度（大端 4 字节，偏移 16）。先转 int：PowerShell 对 byte 移位结果仍是 byte，会截掉高位。
function Get-PngWidth([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    ([int]$bytes[16] -shl 24) -bor ([int]$bytes[17] -shl 16) -bor ([int]$bytes[18] -shl 8) -bor [int]$bytes[19]
}

# 过期缓存清理：正被其他进程使用（持有互斥量）的目录不能删除，空闲的过期目录应被删除。
function Test-CacheCleanup($case) {
    $failures = [Collections.Generic.List[string]]::new()
    $cacheRoot = Join-Path $ArtifactsDir "$($case.Name)-cache"
    # 缓存目录名为 16 位十六进制；无关目录（名称不符或没有 cache.json）即使很旧也不能删除。
    $busy = [guid]::NewGuid().ToString('N').Substring(0, 16)
    $idle = [guid]::NewGuid().ToString('N').Substring(0, 16)
    $foreign = Join-Path $cacheRoot 'unrelated-data'
    # 名称恰好是 16 位十六进制、但没有 cache.json / RenderHarness.csproj 的目录同样不属于本工具。
    $hexForeign = Join-Path $cacheRoot ([guid]::NewGuid().ToString('N').Substring(0, 16))
    foreach ($dir in $foreign, $hexForeign) {
        $null = New-Item -ItemType Directory -Path $dir -Force
        Set-Content -LiteralPath (Join-Path $dir 'keep.txt') -Value 1
        (Get-Item -LiteralPath $dir).LastWriteTime = (Get-Date).AddDays(-30)
    }
    foreach ($name in $busy, $idle) {
        $dir = Join-Path $cacheRoot $name
        $null = New-Item -ItemType Directory -Path $dir -Force
        Set-Content -LiteralPath (Join-Path $dir 'cache.json') -Value '{}'
        (Get-Item -LiteralPath (Join-Path $dir 'cache.json')).LastWriteTime = (Get-Date).AddDays(-30)
    }
    # 同一线程可以重入互斥量，因此由另一个进程持有。Start-Process 不给参数加引号，脚本用 -EncodedCommand 传递。
    $signal = Join-Path $ArtifactsDir "$($case.Name)-held"
    $holdScript = "`$m = [Threading.Mutex]::new(`$false, 'Local\wpf-render-$busy'); `$null = `$m.WaitOne(); Set-Content -LiteralPath '$signal' -Value 1; Start-Sleep -Seconds 120"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($holdScript))
    $holder = Start-Process -FilePath 'pwsh' -PassThru -WindowStyle Hidden -ArgumentList "-NoProfile -EncodedCommand $encoded"
    try {
        $deadline = (Get-Date).AddSeconds(30)
        while (-not (Test-Path -LiteralPath $signal) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
        if (-not (Test-Path -LiteralPath $signal)) { $failures.Add('持有互斥量的进程未就绪'); return $failures }
        $null = & $oneStep -Width 320 -Height 200 -CacheRoot $cacheRoot 6> $null
        if (-not (Test-Path -LiteralPath (Join-Path $cacheRoot $busy))) { $failures.Add('正在使用的过期缓存被删除了') }
        if (Test-Path -LiteralPath (Join-Path $cacheRoot $idle)) { $failures.Add('空闲的过期缓存没有被删除') }
        foreach ($dir in $foreign, $hexForeign) {
            if (-not (Test-Path -LiteralPath (Join-Path $dir 'keep.txt'))) { $failures.Add("缓存根目录下的无关目录被删除了：$dir") }
        }
    }
    finally { Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue }
    $failures
}

# render.ps1 多组合：只构建一次，matrix.json 汇总全部组合并生成 overview.png。
function Test-Matrix($case) {
    $failures = [Collections.Generic.List[string]]::new()
    $matrixDir = & $oneStep -Theme light, dark -Dpi 96, 144 -Width 640 -Height 360 -CacheRoot (Join-Path $ArtifactsDir "$($case.Name)-cache") 6> $null
    $exitCode = $LASTEXITCODE
    $matrixPath = Join-Path "$matrixDir" 'matrix.json'
    if (-not (Test-Path -LiteralPath $matrixPath)) { $failures.Add("缺少 matrix.json（返回 $matrixDir）"); return $failures }
    $matrix = Get-Content -LiteralPath $matrixPath -Raw | ConvertFrom-Json
    if ($exitCode -ne 0 -or $matrix.status -ne 'ok') { $failures.Add("期望 ok / 0，实际 $($matrix.status) / $exitCode") }
    if ($matrix.rendered -ne 4) { $failures.Add("期望渲染 4 个组合，实际 $($matrix.rendered)") }
    if (@($matrix.results | Where-Object { $_.bindingTraceVerified -ne $true }).Count -ne 0) { $failures.Add('矩阵结果缺少可信的绑定监听标记') }
    if (-not $matrix.overview -or -not (Test-Path -LiteralPath $matrix.overview)) { $failures.Add('缺少 overview.png') }
    $built = @($matrix.results | Where-Object { Test-Path -LiteralPath (Join-Path $_.outDir 'build.log') })
    if ($built.Count -ne 1) { $failures.Add("期望只构建一次，实际 $($built.Count) 次") }
    $pixel = @($matrix.results | Where-Object dpi -eq 144 | ForEach-Object { Get-PngWidth $_.snapshot } | Select-Object -Unique)
    if ("$pixel" -ne '960') { $failures.Add("144 DPI 截图宽度期望 960，实际 $pixel") }
    $failures
}

# 交互步骤：生成宿主并带 -Steps 渲染，返回摘要、退出码与 steps.json。
function Invoke-Steps([string]$Name, [string]$Sample, $Steps, [hashtable]$Generate = @{}, [hashtable]$Render = @{}) {
    $generateArgs = @{ WorkDir = Join-Path $ArtifactsDir "harness\$Name"; AssemblyPath = $samples[$Sample]; ViewType = 'SampleViews.InteractionView'
        Steps = (ConvertTo-Json -InputObject @($Steps) -Depth 10 -Compress) } + $Generate
    $harness = & $generator @generateArgs
    $outDir = & $renderer -HarnessDir $harness.WorkDir @Render 6> $null
    $exitCode = $LASTEXITCODE
    $summary = Get-Content -LiteralPath (Join-Path "$outDir" 'summary.json') -Raw | ConvertFrom-Json
    $stepsPath = Join-Path "$outDir" 'steps.json'
    [pscustomobject]@{ OutDir = "$outDir"; ExitCode = $exitCode; Summary = $summary
        Steps = if (Test-Path -LiteralPath $stepsPath) { @(Get-Content -LiteralPath $stepsPath -Raw | ConvertFrom-Json) } else { @() } }
}

# 某一步截图对应的 layout.json 中是否有该文本。
function Test-StepText($Step, [string]$Text) {
    if (-not $Step.snapshot) { return $false }
    $layoutPath = Join-Path (Split-Path -Parent $Step.snapshot) 'layout.json'
    if (-not (Test-Path -LiteralPath $layoutPath)) { return $false }
    [bool](@((Get-Content -LiteralPath $layoutPath -Raw | ConvertFrom-Json).nodes) | Where-Object { "$($_.text)" -eq $Text })
}

# 完整流程（窗口模式）：展开、输入、提交（命令 + 提交后出现的错误绑定）、VSM 悬停、动画取帧、WPF 对话框、MessageBox、setData。
function Test-Steps($case) {
    $failures = [Collections.Generic.List[string]]::new()
    $steps = @(
        @{ name = 'initial' }
        @{ name = 'expand'; set = @{ element = 'DetailsExpander'; property = 'IsExpanded'; value = $true } }
        @{ name = 'type'; set = @{ element = 'CustomerBox'; property = 'Text'; value = 'Fabrikam' } }
        @{ name = 'submit'; invoke = 'SubmitButton'; waitFor = 'data:Status=Submitted' }
        @{ name = 'hover'; state = @{ element = 'VsmButton'; state = 'MouseOver' } }
        @{ name = 'fade'; animate = @{ storyboard = 'FadeIn'; atMs = @(0, 150, 300) } }
        @{ name = 'dialog'; invoke = @{ element = @{ text = 'Open dialog' } } }
        @{ name = 'message'; invoke = 'MessageButton' }
        @{ name = 'data'; setData = @{ path = 'Status'; value = 'Done' } }
    )
    $run = Invoke-Steps $case.Name $case.Sample $steps -Render @{ WindowHost = $true }
    $byName = @{}
    foreach ($step in $run.Steps) { $byName[$step.name] = $step }
    if ($run.Summary.status -ne 'binding-issues' -or $run.ExitCode -ne 2) { $failures.Add("期望 binding-issues / 2（提交后的错误绑定），实际 $($run.Summary.status) / $($run.ExitCode)：$($run.Summary.error -join '; ')") }
    $notOk = @($run.Steps | Where-Object status -ne 'ok')
    if ($run.Steps.Count -ne 9 -or $notOk) { $failures.Add("期望 9 步全部 ok，实际 $($run.Steps.Count) 步；失败：$(@($notOk | ForEach-Object { "$($_.name): $($_.status) $($_.error)" }) -join '; ')") }
    if ($run.Steps.Count -ne 9) { return $failures }
    if (Test-StepText $byName.initial 'Order details: 3 items') { $failures.Add('初始画面不应显示折叠的明细') }
    if (-not (Test-StepText $byName.expand 'Order details: 3 items')) { $failures.Add('展开后 layout.json 中应出现明细文本') }
    if (-not $byName.expand.changedBoundsDip) { $failures.Add('展开后应有变化区域') }
    if (-not (Test-StepText $byName.type 'Customer: Fabrikam')) { $failures.Add('输入后双向绑定应更新 CustomerEcho') }
    if (-not (Test-StepText $byName.submit 'Submitted')) { $failures.Add('提交后 StatusText 应为 Submitted') }
    $bindingSteps = @($run.Steps | Where-Object { $_.bindingIssueCount -gt 0 } | ForEach-Object name)
    if ("$bindingSteps" -ne 'submit' -or "$($byName.submit.bindingIssues)" -notlike '*Mesage*') { $failures.Add("错误绑定应只归属到 submit 步：$bindingSteps / $($byName.submit.bindingIssues)") }
    if (-not $byName.hover.changedBoundsDip) { $failures.Add('VSM 悬停后按钮背景应变化') }
    $frames = @($byName.fade.frames)
    if ($frames.Count -ne 3 -or -not $frames[1].changedBoundsDip -or -not $frames[2].changedBoundsDip) {
        $failures.Add("淡入应得到 3 帧且第 2、3 帧各有变化：$($frames.Count) 帧，变化 $(@($frames | ForEach-Object { $_.changedPixels }) -join ',')")
    }
    $dialog = @($byName.dialog.dialogs)
    if ($dialog.Count -ne 1 -or $dialog[0].kind -ne 'window' -or $dialog[0].title -ne 'Confirm' -or -not (Test-Path -LiteralPath "$($dialog[0].snapshot)")) { $failures.Add("应截取并关闭 Confirm 对话框：$($dialog | ConvertTo-Json -Compress)") }
    if (-not (Test-StepText $byName.dialog 'Dialog closed')) { $failures.Add('对话框关闭后业务代码应继续执行（Status = Dialog closed）') }
    $message = @($byName.message.dialogs)
    if ($message.Count -ne 1 -or $message[0].kind -ne 'messageBox' -or $message[0].text -ne 'Saved successfully') { $failures.Add("应记录并关闭 MessageBox：$($message | ConvertTo-Json -Compress)") }
    if (-not (Test-StepText $byName.data 'Done')) { $failures.Add('setData 后 StatusText 应为 Done') }
    if (-not $run.Summary.stepsOverview -or -not (Test-Path -LiteralPath $run.Summary.stepsOverview)) { $failures.Add('缺少 steps-overview.png') }
    if (@($byName.dialog.warnings) -notmatch '本地化') { $failures.Add('按文本定位应给出本地化提示') }
    $failures
}

# 默认模式（无窗口）：属性设置与动画取帧不依赖窗口；同样的步骤两次渲染像素一致（取帧可复现）。
function Test-StepsLayoutOnly($case) {
    $failures = [Collections.Generic.List[string]]::new()
    $steps = @(
        @{ name = 'expand'; set = @{ element = 'DetailsExpander'; property = 'IsExpanded'; value = $true } }
        @{ name = 'fade'; animate = @{ storyboard = 'FadeIn'; atMs = @(0, 150, 300) } }
    )
    $first = Invoke-Steps "$($case.Name)-1" 'net8' $steps
    $second = Invoke-Steps "$($case.Name)-2" 'net8' $steps
    if ($first.Summary.status -ne 'ok') { $failures.Add("期望 ok，实际 $($first.Summary.status)：$($first.Summary.error -join '; ')"); return $failures }
    $frames = @($first.Steps[1].frames)
    if ($frames.Count -ne 3 -or -not $frames[1].changedBoundsDip -or -not $frames[2].changedBoundsDip) {
        $failures.Add("默认模式下动画取帧应逐帧变化：$(@($frames | ForEach-Object { $_.changedPixels }) -join ',')")
    }
    $hash = { param($run) @($run.Steps[1].frames | ForEach-Object { (Get-FileHash -LiteralPath $_.snapshot -Algorithm SHA256).Hash }) -join ',' }
    if ((& $hash $first) -ne (& $hash $second)) { $failures.Add('两次渲染的动画帧应完全一致') }
    $failures
}

# 失败语义：禁用按钮无法调用时停止并记录；continueOnError 时继续；默认主题按钮的悬停给出明确原因。
function Test-StepsFailure($case) {
    $failures = [Collections.Generic.List[string]]::new()
    $stop = Invoke-Steps "$($case.Name)-stop" 'net8' @(
        @{ name = 'disabled'; invoke = 'DisabledButton' }
        @{ name = 'after'; set = @{ element = 'DetailsExpander'; property = 'IsExpanded'; value = $true } }
    )
    if ($stop.Summary.status -ne 'failed:step' -or $stop.ExitCode -ne 3) { $failures.Add("期望 failed:step / 3，实际 $($stop.Summary.status) / $($stop.ExitCode)") }
    if ($stop.Steps[0].status -ne 'failed' -or $stop.Steps[0].error -notlike '*禁用*' -or -not (Test-Path -LiteralPath "$($stop.Steps[0].snapshot)")) { $failures.Add("第 1 步应失败（已禁用）并保留失败画面：$($stop.Steps[0] | ConvertTo-Json -Compress -Depth 4)") }
    if ($stop.Steps[1].status -ne 'skipped') { $failures.Add("失败后应跳过后续步骤：$($stop.Steps[1].status)") }
    if ("$($stop.Summary.error)" -notlike '*步骤 1*') { $failures.Add("摘要 error 应包含失败步骤：$($stop.Summary.error)") }

    $continue = Invoke-Steps "$($case.Name)-continue" 'net8' @(
        @{ name = 'theme-hover'; state = @{ element = 'SubmitButton'; state = 'MouseOver' } }
        @{ name = 'missing'; set = @{ element = 'NoSuchElement'; property = 'IsEnabled'; value = $false } }
        @{ name = 'after'; set = @{ element = 'DetailsExpander'; property = 'IsExpanded'; value = $true } }
    ) -Generate @{ ContinueOnError = $true }
    if ($continue.Steps[0].error -notlike '*样式触发器*') { $failures.Add("默认主题按钮的悬停应说明无法模拟：$($continue.Steps[0].error)") }
    if ($continue.Steps[1].error -notlike '*DetailsExpander*') { $failures.Add("找不到元素时应列出可用名称：$($continue.Steps[1].error)") }
    if ($continue.Steps[2].status -ne 'ok') { $failures.Add("continueOnError 时应继续执行后续步骤：$($continue.Steps[2].status)") }

    try { $null = & $generator -WorkDir (Join-Path $ArtifactsDir "harness\$($case.Name)-bad") -Steps '[{"set":{"element":"x"}}]'; $failures.Add('写法有误的步骤应在生成时报错') }
    catch { if ($_.Exception.Message -notlike '*缺少 property*') { $failures.Add("步骤校验信息不明确：$($_.Exception.Message)") } }
    $failures
}

# custom 步骤：自定义工厂实现 RunStepAsync 时可用；默认工厂未实现时只有用到 custom 才报错。
function Test-StepsCustom($case) {
    $failures = [Collections.Generic.List[string]]::new()
    $steps = @(@{ name = 'custom'; custom = @{ action = 'SetStatus'; args = @{ status = 'From factory' } } })
    $with = Invoke-Steps "$($case.Name)-with" 'net8' $steps -Generate @{ FactoryFile = Join-Path $fixtures 'StepsViewFactory.cs' }
    if ($with.Summary.status -ne 'ok' -or -not (Test-StepText $with.Steps[0] 'From factory')) { $failures.Add("custom 步骤应调用 RunStepAsync：$($with.Summary.status) $($with.Summary.error -join '; ')") }
    $without = Invoke-Steps "$($case.Name)-without" 'net8' $steps
    if ($without.Steps[0].error -notlike '*RunStepAsync*') { $failures.Add("未实现 RunStepAsync 时应明确报错：$($without.Steps[0].error)") }
    $failures
}

# 业务仓库锁定了本机没有的 SDK（global.json）：在该仓库目录下运行时，宿主仍应使用本机 SDK 构建。
function Test-GlobalJson($case) {
    $failures = [Collections.Generic.List[string]]::new()
    $repo = Join-Path $ArtifactsDir "$($case.Name)-repo"
    $null = New-Item -ItemType Directory -Path $repo
    Set-Content -LiteralPath (Join-Path $repo 'global.json') -Value '{ "sdk": { "version": "6.0.100", "rollForward": "disable" } }'
    Push-Location -LiteralPath $repo
    try {
        $harness = & $generator -WorkDir (Join-Path $repo 'harness')
        $outDir = & $renderer -HarnessDir $harness.WorkDir -Width 320 -Height 200 6> $null
        $summary = Get-Content -LiteralPath (Join-Path "$outDir" 'summary.json') -Raw | ConvertFrom-Json
        if ($summary.status -ne 'ok') { $failures.Add("期望 ok，实际 $($summary.status)：$(@($summary.buildErrors) + @($summary.error) -join '; ')") }
    }
    finally { Pop-Location }
    $failures
}

# compare-snapshots.ps1：同条件两次渲染应相同；换主题应不同，并报告环境差异。
function Test-Compare($case) {
    $failures = [Collections.Generic.List[string]]::new()
    $harness = & $generator -WorkDir (Join-Path $ArtifactsDir "harness\$($case.Name)")
    $first = & $renderer -HarnessDir $harness.WorkDir -Width 640 -Height 360 6> $null
    $second = & $renderer -HarnessDir $harness.WorkDir -Width 640 -Height 360 -NoBuild 6> $null
    $dark = & $renderer -HarnessDir $harness.WorkDir -Width 640 -Height 360 -Theme dark -NoBuild 6> $null
    $same = & $comparer -Before $first -After $second | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $same.status -ne 'same' -or $same.changedPixels -ne 0) { $failures.Add("同条件渲染应相同：$($same.status)，$($same.changedPixels) 像素") }
    $different = & $comparer -Before $first -After $dark | ConvertFrom-Json
    if ($LASTEXITCODE -ne 1 -or $different.status -ne 'different') { $failures.Add("换主题应判为不同：$($different.status)") }
    if (-not (@($different.environmentDifferences) -match '^theme: light -> dark$')) { $failures.Add("环境差异缺少 theme：$($different.environmentDifferences -join '; ')") }
    if (-not $different.changedBoundsPx -or -not (Test-Path -LiteralPath $different.diff)) { $failures.Add('缺少变化区域或差异图') }
    $failures
}

# MCP 服务器：经 mcp/start.ps1 启动（全新编译缓存），用 MCP 客户端调用全部工具。
function Test-Mcp($case) {
    $failures = [Collections.Generic.List[string]]::new()
    $env:WPF_RENDER_MCP_CACHE = Join-Path $ArtifactsDir "$($case.Name)-cache"
    try {
        $lines = & dotnet run --project (Join-Path $root 'mcp\WpfRenderMcp.Tests') -c Release -- --root $root --sample $samples['net8'] 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    }
    finally { Remove-Item Env:WPF_RENDER_MCP_CACHE -ErrorAction SilentlyContinue }
    $lines | Where-Object { $_ -like 'FAIL *' } | ForEach-Object { $failures.Add($_) }
    if ($code -ne 0 -and $failures.Count -eq 0) { $failures.Add("MCP 测试退出码 $code"); $lines | Select-Object -Last 20 | ForEach-Object { $failures.Add("  $_") } }
    $failures
}

# 生成一个业务项目式的预设目录：wpf-render.json 的 build 命令把样例程序集构建到 ./bin。
function New-PresetProject([string]$Name) {
    $dir = Join-Path $ArtifactsDir $Name
    $null = New-Item -ItemType Directory -Path $dir
    $preset = [ordered]@{
        verifyOnStop = $true
        defaults = [ordered]@{
            assemblyPaths = @('bin/SampleViews.dll')
            build = @('dotnet', 'build', $sampleProject, '-f', 'net8.0-windows', '-c', 'Release', '-o', 'bin', '--nologo')
            width = 640; height = 360
            # 视图写了 xaml 时不应继承这里的 viewType（见 Loose 预设）。
            viewType = 'SampleViews.OrderView'
        }
        views = [ordered]@{
            Order = [ordered]@{ viewType = 'SampleViews.OrderView'; dataContextFactory = 'SampleViews.PreviewData.CreateRemoteOrder'; watch = @('src/Order/**') }
            # src/Broken/**/*.txt 也应匹配 src/Broken 下的直接子文件（** 可为零层目录）。
            Broken = [ordered]@{ viewType = 'SampleViews.BrokenBindingView'; dataContextType = 'SampleViews.OrderPreviewVm'; watch = @('src/Broken/**/*.txt') }
            Loose = [ordered]@{ xaml = Join-Path $fixtures 'ok.xaml' }
            Interactive = [ordered]@{ viewType = 'SampleViews.InteractionView'; steps = @(@{ name = 'expand'; set = @{ element = 'DetailsExpander'; property = 'IsExpanded'; value = $true } }) }
            Sized = [ordered]@{ viewType = 'SampleViews.OrderView'; dataContextType = 'SampleViews.OrderPreviewVm'; sizes = @('800x600', '1024x768') }
            Themes = [ordered]@{ viewType = 'SampleViews.OrderView'; dataContextType = 'SampleViews.OrderPreviewVm'; themes = @('light', 'dark') }
        }
    }
    [IO.File]::WriteAllText((Join-Path $dir 'wpf-render.json'), ($preset | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    $dir
}

# 预设：-Build 先构建业务项目；显式参数覆盖预设；多主题预设得到汇总；未知预设列出可用名称。
function Test-Preset($case) {
    $failures = [Collections.Generic.List[string]]::new()
    $dir = New-PresetProject $case.Name
    $cache = Join-Path $ArtifactsDir "$($case.Name)-cache"
    $order = & $oneStep -Config $dir -Preset Order -Build -CacheRoot $cache 6> $null
    $summary = Get-Content -LiteralPath (Join-Path "$order" 'summary.json') -Raw | ConvertFrom-Json
    if ($summary.status -ne 'ok' -or $summary.pixelSize -ne '640x360') { $failures.Add("Order：期望 ok / 640x360，实际 $($summary.status) / $($summary.pixelSize)") }
    $layout = Get-Content -LiteralPath (Join-Path "$order" 'layout.json') -Raw | ConvertFrom-Json
    if (-not (@($layout.nodes) | Where-Object { "$($_.text)" -eq 'Order #2048' })) { $failures.Add('Order：dataContextFactory 未生效') }
    $wide = & $oneStep -Config (Join-Path $dir 'wpf-render.json') -Preset Order -Width 900 -CacheRoot $cache 6> $null
    $wideSummary = Get-Content -LiteralPath (Join-Path "$wide" 'summary.json') -Raw | ConvertFrom-Json
    if ($wideSummary.pixelSize -ne '900x360') { $failures.Add("显式 -Width 应覆盖预设：$($wideSummary.pixelSize)") }
    # 显式 -Width 覆盖预设的 sizes（高度仍取预设默认值），显式 -Xaml 覆盖预设的 viewType。
    $sized = & $oneStep -Config $dir -Preset Sized -Width 700 -CacheRoot $cache 6> $null
    $sizedSummary = Get-Content -LiteralPath (Join-Path "$sized" 'summary.json') -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
    if ($sizedSummary.pixelSize -ne '700x360') { $failures.Add("显式 -Width 应覆盖预设 sizes：$($sizedSummary.pixelSize)（$sized）") }
    try {
        $xamlRun = & $oneStep -Config $dir -Preset Order -Xaml (Join-Path $fixtures 'ok.xaml') -CacheRoot $cache 6> $null
        $xamlSummary = Get-Content -LiteralPath (Join-Path "$xamlRun" 'summary.json') -Raw | ConvertFrom-Json
        if ($xamlSummary.status -ne 'ok' -or $xamlSummary.sourceViewType -ne 'System.Windows.Controls.Border') {
            $failures.Add("显式 -Xaml 应覆盖预设 viewType：$($xamlSummary.status) / $($xamlSummary.sourceViewType)")
        }
        # 视图层的 xaml 同样覆盖 defaults 中的 viewType。
        $looseRun = & $oneStep -Config $dir -Preset Loose -CacheRoot $cache 6> $null
        $looseSummary = Get-Content -LiteralPath (Join-Path "$looseRun" 'summary.json') -Raw | ConvertFrom-Json
        if ($looseSummary.sourceViewType -ne 'System.Windows.Controls.Border') { $failures.Add("视图的 xaml 应覆盖 defaults 的 viewType：$($looseSummary.sourceViewType)") }
    }
    catch { $failures.Add("显式 -Xaml / 视图 xaml 应覆盖 viewType：$($_.Exception.Message)") }
    # 预设中的 steps；与多主题同时使用时报错。
    $interactive = & $oneStep -Config $dir -Preset Interactive -CacheRoot $cache 6> $null
    $interactiveSummary = Get-Content -LiteralPath (Join-Path "$interactive" 'summary.json') -Raw | ConvertFrom-Json
    if ($interactiveSummary.status -ne 'ok' -or @($interactiveSummary.steps).Count -ne 1) { $failures.Add("预设 steps 应执行 1 步：$($interactiveSummary.status) / $(@($interactiveSummary.steps).Count)") }
    try { $null = & $oneStep -Config $dir -Preset Interactive -Theme light, dark -CacheRoot $cache 6> $null; $failures.Add('steps 与多主题同时使用应报错') }
    catch { if ($_.Exception.Message -notlike '*交互步骤不能*') { $failures.Add("steps 与多主题冲突的报错不明确：$($_.Exception.Message)") } }
    $themes = & $oneStep -Config $dir -Preset Themes -CacheRoot $cache 6> $null
    . (Join-Path $root 'scripts\Results.ps1')
    $themesResult = try { Read-WpfRenderResult "$themes" } catch { $null }
    if (-not $themesResult -or @($themesResult.items).Count -ne 2) { $failures.Add("Themes 预设应渲染 2 个组合：$(@($themesResult.items).Count)") }
    $null = & $oneStep -Config $dir -Preset Broken -CacheRoot $cache 6> $null
    if ($LASTEXITCODE -ne 2) { $failures.Add("Broken 预设应以退出码 2 报告绑定问题：$LASTEXITCODE") }
    try { $null = & $oneStep -Config $dir -Preset Missing -CacheRoot $cache 6> $null; $failures.Add('未知预设应报错') }
    catch { if ($_.Exception.Message -notlike '*Order*Broken*' -and $_.Exception.Message -notlike '*Broken*Order*') { $failures.Add("未知预设的报错应列出可用视图：$($_.Exception.Message)") } }
    $failures
}

# Preset.ps1 合并规则：render.ps1 与 list-views.ps1（MCP list_views）共用，互斥键不得在两层各自漂移。
function Test-PresetMerge($case) {
    $failures = [Collections.Generic.List[string]]::new()
    $dir = New-PresetProject $case.Name
    $list = & (Join-Path $root 'scripts\list-views.ps1') -Config $dir | ConvertFrom-Json
    if ("$(@($list.views) | ForEach-Object name | Sort-Object)" -ne 'Broken Interactive Loose Order Sized Themes') {
        $failures.Add("list-views 列出的视图不符：$(@($list.views) | ForEach-Object name | Sort-Object -join ', ')")
    }
    $loose = @($list.views | Where-Object name -eq 'Loose')[0]
    # 视图层的 xaml 覆盖 defaults 的 viewType（互斥），且解析为绝对路径。
    if ($loose.xaml -notlike '*.xaml' -or [IO.Path]::IsPathRooted($loose.xaml) -eq $false -or $loose.viewType) {
        $failures.Add("Loose 应解析 xaml 为绝对路径且不继承 viewType：$($loose | ConvertTo-Json -Compress)")
    }
    $order = @($list.views | Where-Object name -eq 'Order')[0]
    if ($order.viewType -ne 'SampleViews.OrderView' -or -not $order.hasBuild) {
        $failures.Add("Order 应合并 defaults 的 build：$($order | ConvertTo-Json -Compress)")
    }
    $themesView = @($list.views | Where-Object name -eq 'Themes')[0]
    if (@($themesView.themes).Count -ne 2) { $failures.Add("Themes 应列出预设 themes：$($themesView.themes -join ',')") }
    $sized = @($list.views | Where-Object name -eq 'Sized')[0]
    if ("$(@($sized.sizes) -join ',')" -ne '800x600,1024x768') { $failures.Add("Sized 应列出预设 sizes：$($sized.sizes -join ',')") }
    # Merge-WpfRenderPreset 与 list-views 的合并结果一致（同源函数的直接断言）。
    . (Join-Path $root 'scripts\Preset.ps1')
    $file = Read-WpfRenderConfigFile (Join-Path $dir 'wpf-render.json')
    $merged = Merge-WpfRenderPreset $file 'Loose'
    if ($merged.xaml -ne $loose.xaml) { $failures.Add('Merge-WpfRenderPreset 与 list-views 的结果不一致') }
    $failures
}

# Results.ps1（渲染结果读取的单一 module）：matrix 展开 / 单结果包装 / 缺文件与残缺 JSON 报错。
function Test-ResultReader($case) {
    $failures = [Collections.Generic.List[string]]::new()
    . (Join-Path $root 'scripts\Results.ps1')
    # 单结果：kind=render、items 长度 1。
    $dir = Join-Path $ArtifactsDir "$($case.Name)-single"
    $null = New-Item -ItemType Directory -Path $dir
    Set-Content -LiteralPath (Join-Path $dir 'summary.json') -Value '{"status":"ok","snapshot":"s.png"}'
    $single = Read-WpfRenderResult $dir
    if ($single.kind -ne 'render' -or @($single.items).Count -ne 1 -or $single.items[0].status -ne 'ok') {
        $failures.Add("单结果应包装为长度 1 的 items：$($single | ConvertTo-Json -Compress -Depth 3)")
    }
    # matrix：items 展开 results[]，raw 保留 overview 等元数据。
    $dir = Join-Path $ArtifactsDir "$($case.Name)-matrix"
    $null = New-Item -ItemType Directory -Path $dir
    Set-Content -LiteralPath (Join-Path $dir 'matrix.json') -Value '{"status":"ok","overview":"o.png","results":[{"theme":"light"},{"theme":"dark"}]}'
    $matrix = Read-WpfRenderResult $dir
    if ($matrix.kind -ne 'matrix' -or @($matrix.items).Count -ne 2 -or $matrix.raw.overview -ne 'o.png') {
        $failures.Add("matrix 应展开 results：$($matrix | ConvertTo-Json -Compress -Depth 3)")
    }
    # 缺文件与残缺 JSON 都要抛错。
    $dir = Join-Path $ArtifactsDir "$($case.Name)-empty"
    $null = New-Item -ItemType Directory -Path $dir
    try { Read-WpfRenderResult $dir | Out-Null; $failures.Add('没有结果文件时应抛错') } catch { }
    Set-Content -LiteralPath (Join-Path $dir 'summary.json') -Value '{broken'
    try { Read-WpfRenderResult $dir | Out-Null; $failures.Add('残缺 JSON 应抛错') } catch { }
    try { Read-WpfRenderResult (Join-Path $ArtifactsDir 'no-such-dir') | Out-Null; $failures.Add('目录不存在时应抛错') } catch { }
    $failures
}

# Watches.ps1（watch 匹配的单一 module）：glob 语义、defaults 继承、命中文件返回，表驱动直测。
function Test-WatchMatcher($case) {
    $failures = [Collections.Generic.List[string]]::new()
    . (Join-Path $root 'scripts\Watches.ps1')
    $base = (Get-Location).Path.Replace('\', '/')
    # 表：watch 模式 → 改动路径 → 是否命中。** 匹配零层是语义核心（src/**/*.xaml 也匹配 src/A.xaml）。
    $table = @(
        @{ Pattern = 'src/Order/**'; Path = "$base/src/Order/a.xaml"; Expect = $true }
        @{ Pattern = 'src/Order/**'; Path = "$base/src/Order/sub/b.xaml"; Expect = $true }
        @{ Pattern = 'src/Broken/**/*.txt'; Path = "$base/src/Broken/b.txt"; Expect = $true }
        @{ Pattern = 'src/Broken/**/*.txt'; Path = "$base/src/Broken/sub/c.txt"; Expect = $true }
        @{ Pattern = 'src/Broken/**/*.txt'; Path = "$base/src/Broken/other.xaml"; Expect = $false }
        @{ Pattern = 'src/*/a.xaml'; Path = "$base/src/Order/a.xaml"; Expect = $true }
        @{ Pattern = 'src/*/a.xaml'; Path = "$base/src/Order/sub/a.xaml"; Expect = $false }
        @{ Pattern = 'src/a?.xaml'; Path = "$base/src/a1.xaml"; Expect = $true }
        @{ Pattern = 'src/a?.xaml'; Path = "$base/src/a12.xaml"; Expect = $false }
        @{ Pattern = 'src/Order/**'; Path = "$base/src/Other/a.xaml"; Expect = $false }
    )
    foreach ($row in $table) {
        $hit = @($row.Path) | Where-Object { $_ -match (ConvertTo-WatchRegex $row.Pattern $base) }
        if ([bool]$hit -ne $row.Expect) { $failures.Add("glob $($row.Pattern) 对 $($row.Path) 应$(if (-not $row.Expect) { '不' })命中") }
    }
    # Select-AffectedViews：defaults 继承、命中文件与视图一起返回。
    $config = @{
        defaults = @{ watch = @('common/**') }
        views = @{
            Order = @{ watch = @('src/Order/**') }
            Broken = @{ watch = @('src/Broken/**/*.txt') }
            Common = @{ }
        }
    }
    $selection = Select-AffectedViews $config $base @("$base/src/Order/a.xaml", "$base/common/x.xaml")
    if ("$(@($selection.Views) | Sort-Object)" -ne 'Common Order') { $failures.Add("应命中 Order 与继承 defaults 的 Common：$(@($selection.Views) -join ', ')") }
    if (@($selection.Hits).Count -ne 2) { $failures.Add("Hits 应含两个命中文件：$(@($selection.Hits) -join ', ')") }
    $none = Select-AffectedViews $config $base @("$base/src/Other/b.xaml")
    if ($none.Views.Count -ne 0) { $failures.Add("无命中时应返回空视图列表：$($none.Views -join ', ')") }
    $failures
}

# 宿主纯逻辑单元测试（BindingIssues / Json）：改解析与序列化逻辑时先跑这里，快于端到端。
function Test-LogicTests($case) {
    $failures = [Collections.Generic.List[string]]::new()
    & dotnet test (Join-Path $root 'tests\WpfRenderLogic.Tests\WpfRenderLogic.Tests.csproj') -c Release --nologo 2>&1 |
        ForEach-Object { "$_" } | Where-Object { $_ -match '^\s+Failed |error ' } | ForEach-Object { $failures.Add($_) }
    if ($LASTEXITCODE -ne 0 -and $failures.Count -eq 0) { $failures.Add("单元测试退出码 $LASTEXITCODE") }
    $failures
}

# Stop hook：改动 watch 覆盖的文件后，绑定错误阻止结束；同一份改动不重复拦截；改动正常视图时放行。
function Test-Hook($case) {
    $failures = [Collections.Generic.List[string]]::new()
    # 中文目录：hook 的输入（cwd）与 git 输出必须按 UTF-8 解码，否则找不到 wpf-render.json、匹配不到改动。
    $dir = New-PresetProject "$($case.Name)-中文目录"
    foreach ($file in 'src/Order/a.txt', 'src/Broken/b.txt') {
        $path = Join-Path $dir $file
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
        Set-Content -LiteralPath $path -Value 'v1'
    }
    $null = & git -C $dir init -q 2>&1
    $null = & git -C $dir -c user.name=test -c user.email=test@example.com add -A 2>&1
    $null = & git -C $dir -c user.name=test -c user.email=test@example.com commit -q -m init 2>&1
    $hook = Join-Path $root 'hooks\verify-on-stop.ps1'
    $trustScript = Join-Path $root 'scripts\trust-project.ps1'
    $session = 'test-' + [guid]::NewGuid().ToString('N')
    $payload = @{ cwd = $dir; session_id = $session; stop_hook_active = $false; hook_event_name = 'Stop' } | ConvertTo-Json -Compress
    $invoke = { (($payload | & pwsh -NoProfile -NonInteractive -File $hook) -join "`n").Trim() }
    # 授权记录写到测试目录，不影响本机。
    $previousTrust = $env:WPF_RENDER_TRUST_FILE
    $env:WPF_RENDER_TRUST_FILE = Join-Path $ArtifactsDir "$($case.Name)-trust.json"
    try {

    Set-Content -LiteralPath (Join-Path $dir 'src/Broken/b.txt') -Value 'v2'
    # 未授权：不执行构建与渲染，只提示一次如何授权。
    $untrusted = (((@{ cwd = $dir; session_id = "$session-untrusted" } | ConvertTo-Json -Compress) | & pwsh -NoProfile -NonInteractive -File $hook) -join '').Trim()
    $notice = try { $untrusted | ConvertFrom-Json } catch { $null }
    if ($notice.decision -or $notice.systemMessage -notlike '*trust-project.ps1*') { $failures.Add("未授权时应只提示授权方法：$untrusted") }
    if (Test-Path -LiteralPath (Join-Path $dir 'bin')) { $failures.Add('未授权时不应执行 build') }
    $null = & $trustScript -Path $dir

    $first = & $invoke
    $decision = try { $first | ConvertFrom-Json } catch { $null }
    if ($decision.decision -ne 'block' -or $decision.reason -notlike '*CustomerNmae*') { $failures.Add("改动 Broken 后应阻止结束并给出绑定结论：$first") }
    $second = & $invoke
    # 只看输出为空不够：hook 崩溃时也没有标准输出。
    if ($second -or $LASTEXITCODE -ne 0) { $failures.Add("同一份改动不应重复拦截：$second（退出码 $LASTEXITCODE）") }

    $null = & git -C $dir checkout -q -- src/Broken/b.txt 2>&1
    Set-Content -LiteralPath (Join-Path $dir 'src/Order/a.txt') -Value 'v2'
    $third = & $invoke
    if ($third -like '*"decision"*' -or $third -notlike '*Order*') { $failures.Add("改动正常视图时应放行并报告通过：$third") }

    $unrelated = @{ cwd = $ArtifactsDir; session_id = $session } | ConvertTo-Json -Compress
    $quiet = (($unrelated | & pwsh -NoProfile -NonInteractive -File $hook) -join '').Trim()
    if ($quiet -or $LASTEXITCODE -ne 0) { $failures.Add("没有 wpf-render.json 的目录应静默退出：$quiet（退出码 $LASTEXITCODE）") }

    # 授权后修改配置（例如 build 命令）：授权失效，提示重新授权。
    Add-Content -LiteralPath (Join-Path $dir 'wpf-render.json') -Value ' '
    Set-Content -LiteralPath (Join-Path $dir 'src/Broken/b.txt') -Value 'v3'
    $changed = (((@{ cwd = $dir; session_id = "$session-changed" } | ConvertTo-Json -Compress) | & pwsh -NoProfile -NonInteractive -File $hook) -join '').Trim()
    $changedNotice = try { $changed | ConvertFrom-Json } catch { $null }
    if ($changedNotice.decision -or $changedNotice.systemMessage -notlike '*修改*') { $failures.Add("配置修改后应要求重新授权：$changed") }
    }
    finally { $env:WPF_RENDER_TRUST_FILE = $previousTrust }
    $failures
}

# render.ps1：同一配置第二次应复用缓存宿主并跳过构建；业务程序集更新后应重新构建。
function Test-Cache($case) {
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
    if ($case.Kind) { return & "Test-$($case.Kind)" $case }
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
        layoutIssueCount = $summary.layoutIssueCount; toolVersion = $summary.toolVersion
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
            'elementWidthDip' {
                if ("$(@($manifest.elementRectDip)[2])" -ne "$expected") { $failures.Add("元素宽度期望 $expected，实际 $(@($manifest.elementRectDip)[2])") }
            }
            'elementRectDip' {
                if ((@($manifest.elementRectDip) -join ',') -ne $expected) { $failures.Add("元素矩形期望 $expected，实际 $(@($manifest.elementRectDip) -join ',')") }
            }
            'elementPixelWidth' {
                $width = if ($summary.elementSnapshot) { Get-PngWidth $summary.elementSnapshot }
                if ("$width" -ne "$expected") { $failures.Add("element.png 宽度期望 $expected，实际 $width") }
            }
            'errorPattern' {
                if (-not (@($summary.error) -match [regex]::Escape($expected))) { $failures.Add("error 中没有 $expected") }
            }
            'layoutText' {
                if (-not (@($layout.nodes) | Where-Object { "$($_.text)" -like "*$expected*" })) { $failures.Add("layout.json 中没有文本 $expected") }
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
