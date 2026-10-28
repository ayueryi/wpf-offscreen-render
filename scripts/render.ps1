#requires -Version 7.0
# 一步渲染：生成（或复用缓存的）宿主工程并渲染，最后输出 summary JSON。
# 适合免代码接入（-ViewType / -Xaml）；需要定制 ViewFactory.cs 时改用 new-wpf-harness.ps1 + invoke-wpf-render.ps1。
#
# 缓存：同一组 程序集路径 + TFM + 位数 + 工具版本 复用 %TEMP%\wpf-render-cache 下的同一个宿主。
# 视图配置每次重写 harness.json；业务程序集的大小 / 修改时间未变时跳过构建，变化时重新构建。
#
# 多组合：-Theme / -Dpi / -Size 传多个值时渲染全部组合（只构建一次，每个组合独立进程），
# 输出 matrix-* 目录，内含 matrix.json 与拼好的 overview.png；返回该目录。
#
# 预设：-Preset 从业务仓库的 wpf-render.json 读取视图配置（-Config 指定文件或目录，省略时从当前目录向上查找），
# 显式传入的参数优先；-Build 先在配置文件所在目录执行其 build 命令。
[CmdletBinding()]
param(
    [string[]]$AssemblyPath = @(),
    [string]$ViewType,
    [string]$Xaml,
    [string]$DataContextType,
    # 无参静态工厂方法 "Namespace.Type.Method"，与 -DataContextType 二选一。
    [string]$DataContextFactory,
    [string[]]$ResourceDictionary = @(),
    # 替换生成工程中 ViewFactory.cs 的文件（业务仓库中受版本管理的预览工厂）。
    [string]$FactoryFile,
    [string]$Preset,
    [string]$Config,
    [switch]$Build,
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
    # 交互步骤：JSON 数组字符串或文件路径；每步执行后截图并检查（见 docs/design/interaction-steps.md）。不能与多主题 / 尺寸 / DPI 同时使用。
    [string]$Steps,
    [switch]$ContinueOnError,
    [ValidateSet('live', 'settle')][string]$Animations = 'live',
    [int]$TimeoutSeconds = 120,
    [string]$CacheRoot = (Join-Path ([IO.Path]::GetTempPath()) 'wpf-render-cache'),
    # 忽略缓存，生成一次性宿主（位于 %TEMP%\wpf-render-<GUID>）。
    [switch]$NoCache,
    # 超过该天数未使用的缓存宿主与渲染结果会被清理。
    [ValidateRange(1, 365)][int]$RetentionDays = 7
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'WPF 渲染需要 Windows。' }
# 相对路径按 PowerShell 当前位置解析：.NET 文件 API 使用进程工作目录，Set-Location 不会改变它。
$CacheRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CacheRoot)

# 预设的查找、解析与合并规则在 Preset.ps1 中统一维护（list-views.ps1 共用），本脚本只处理参数覆盖与构建。
if ($Preset -or $Config -or $Build) {
    . (Join-Path $PSScriptRoot 'Preset.ps1')
    $Config = Resolve-WpfRenderConfig $Config
    $configDir = Split-Path -Parent $Config
    $presetFile = Read-WpfRenderConfigFile $Config
    $settings = Merge-WpfRenderPreset $presetFile $Preset

    # 相对路径相对于配置文件所在目录；pack URI（/Asm;component/...）、其他 URI 与绝对路径保持原样。
    $resolve = { param($value) if ([IO.Path]::IsPathRooted($value) -or $value -like '*;component/*' -or $value -match '^(pack|file|https?)://') { $value } else { [IO.Path]::GetFullPath((Join-Path $configDir $value)) } }
    $mapping = [ordered]@{
        assemblyPaths = 'AssemblyPath', $true; viewType = 'ViewType', $false; xaml = 'Xaml', $true; dataContextType = 'DataContextType', $false
        dataContextFactory = 'DataContextFactory', $false; factoryFile = 'FactoryFile', $true; resourceDictionaries = 'ResourceDictionary', $true
        targetFramework = 'TargetFramework', $false; platform = 'Platform', $false; themes = 'Theme', $false; sizes = 'Size', $false; dpis = 'Dpi', $false
        width = 'Width', $false; height = 'Height', $false; background = 'Background', $false; windowHost = 'WindowHost', $false; element = 'Element', $false
        steps = 'Steps', $false; continueOnError = 'ContinueOnError', $false; animations = 'Animations', $false
    }
    # 显式参数覆盖预设：互斥的一组参数中显式传了任一个，预设里同组的键都不再生效（互斥表在 Preset.ps1）。
    $overridden = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $PSBoundParameters.Keys) {
        $null = $overridden.Add($name)
        foreach ($other in $script:ExplicitParameterOverrides[$name]) { $null = $overridden.Add($other) }
    }
    foreach ($key in $mapping.Keys) {
        $parameter, $isPath = $mapping[$key]
        if (-not $settings.ContainsKey($key) -or $overridden.Contains($parameter)) { continue }
        $value = $settings[$key]
        if ($isPath) { $value = @($value | ForEach-Object { & $resolve $_ }); if ($parameter -in 'Xaml', 'FactoryFile') { $value = $value[0] } }
        if ($parameter -in 'WindowHost', 'ContinueOnError') { $value = [switch][bool]$value }
        # 预设中的步骤是 JSON 数组，转回字符串交给 -Steps。
        if ($parameter -eq 'Steps') { $value = ConvertTo-Json -InputObject @($value) -Depth 12 -Compress }
        Set-Variable -Name $parameter -Value $value
    }

    if ($Build) {
        # build 为参数数组（不经过 shell），如 ["dotnet", "build", "src/MyApp/MyApp.csproj", "-c", "Debug"]。
        $command = @($settings.build)
        if (-not $command -or -not $command[0]) { throw "$Config 没有为 $Preset 配置 build 命令。" }
        $buildLog = Join-Path ([IO.Path]::GetTempPath()) ('wpf-render-build-' + [guid]::NewGuid().ToString('N') + '.log')
        Push-Location -LiteralPath $configDir
        # 先清零：build 是 .ps1 脚本时在当前进程中运行，不一定设置 $LASTEXITCODE，会沿用上一次渲染的退出码。
        $global:LASTEXITCODE = 0
        try { & $command[0] @($command | Select-Object -Skip 1) *> $buildLog; $buildCode = $LASTEXITCODE }
        finally { Pop-Location }
        if ($buildCode -ne 0) {
            $tail = (Get-Content -LiteralPath $buildLog -Tail 30) -join "`n"
            throw "业务项目构建失败（退出码 $buildCode，完整日志 $buildLog）：`n$tail"
        }
        Remove-Item -LiteralPath $buildLog -ErrorAction SilentlyContinue
    }
}

if ($ViewType -and $Xaml) { throw '-ViewType 与 -Xaml 只能二选一。' }
if ($DataContextType -and $DataContextFactory) { throw '-DataContextType 与 -DataContextFactory 只能二选一。' }
if (($DataContextType -or $DataContextFactory) -and -not ($ViewType -or $Xaml)) { throw '-DataContextType / -DataContextFactory 需要配合 -ViewType 或 -Xaml。' }
if ($Xaml) { $Xaml = (Resolve-Path -LiteralPath $Xaml).ProviderPath }
if ($FactoryFile) { $FactoryFile = (Resolve-Path -LiteralPath $FactoryFile).ProviderPath }
$assemblies = @($AssemblyPath | ForEach-Object { (Resolve-Path -LiteralPath $_).ProviderPath })
# 资源字典：pack URI 与绝对路径保持原样；存在的相对路径按当前位置解析（{theme} 按 light 检查）。
$ResourceDictionary = @($ResourceDictionary | ForEach-Object {
        if ([IO.Path]::IsPathRooted($_) -or $_ -like '*;component/*' -or $_ -match '^(pack|file|https?)://' -or
            -not (Test-Path -LiteralPath $_.Replace('{theme}', 'light'))) { $_ }
        else { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($_) }
    })

$generator = Join-Path $PSScriptRoot 'new-wpf-harness.ps1'
$renderer = Join-Path $PSScriptRoot 'invoke-wpf-render.ps1'
$generate = @{ AssemblyPath = $assemblies; ViewType = $ViewType; Xaml = $Xaml; DataContextType = $DataContextType; DataContextFactory = $DataContextFactory
    ResourceDictionary = $ResourceDictionary; FactoryFile = $FactoryFile; Steps = $Steps; ContinueOnError = $ContinueOnError; Animations = $Animations }
if ($TargetFramework) { $generate.TargetFramework = $TargetFramework }
if ($Platform) { $generate.Platform = $Platform }
$render = @{ Background = $Background; WindowHost = $WindowHost; TimeoutSeconds = $TimeoutSeconds }
if ($Element) { $render.Element = $Element }
$sizes = if ($Size) { $Size } else { @("${Width}x$Height") }
$combos = @(foreach ($s in $sizes) { foreach ($t in $Theme) { foreach ($d in $Dpi) {
                $w, $h = $s -split 'x'
                [pscustomobject]@{ Theme = $t; Width = [int]$w; Height = [int]$h; Dpi = $d }
            } } })
if ($combos.Count -eq 0) { throw '没有可渲染的组合：-Theme / -Dpi / -Size（或预设的 themes / dpis / sizes）不能为空。' }
. (Join-Path $PSScriptRoot 'Steps.ps1')
$normalizedSteps = @(ConvertTo-HarnessSteps $Steps $FactoryFile)
if ($normalizedSteps.Count -gt 0 -and $combos.Count -gt 1) {
    throw "交互步骤不能与多个主题 / 尺寸 / DPI 同时使用（当前 $($combos.Count) 个组合）：请对每个组合分别渲染。"
}

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
            bindingTraceVerified = $summary.bindingTraceVerified
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

# 缓存键、构建戳与过期清理在 Cache.ps1 中统一维护。
. (Join-Path $PSScriptRoot 'Cache.ps1')
$key = Get-WpfRenderCacheKey $generator (Join-Path $PSScriptRoot '..\assets') $TargetFramework $Platform "$FactoryFile" $assemblies
$workDir = Join-Path $CacheRoot $key
$null = New-Item -ItemType Directory -Path $CacheRoot -Force

# 同一缓存宿主同一时间只允许一个渲染，避免并发构建写同一个 out\。
$mutex = [Threading.Mutex]::new($false, "Local\wpf-render-$key")
try {
    # 持有者可能在构建并渲染多个组合（每个最长 TimeoutSeconds），等待上限按 16 个组合加构建时间估算。
    try { if (-not $mutex.WaitOne([TimeSpan]::FromSeconds(($TimeoutSeconds + 60) * 16 + 900))) { throw "等待缓存宿主超时：$workDir（另一个渲染长时间占用）" } }
    catch [Threading.AbandonedMutexException] { } # 上一个持有者异常退出，锁已转交

    $stampPath = Join-Path $workDir 'cache.json'
    # 立即标记为“正在使用”，避免其他进程按过期时间清理这个目录。
    if (Test-Path -LiteralPath $stampPath) { (Get-Item -LiteralPath $stampPath).LastWriteTime = Get-Date }
    # 构建会连同依赖一起复制，所以记录业务程序集所在目录中全部 dll / exe 的大小与修改时间；
    # ViewFactory.cs 编进宿主：内容变化时需要重新构建。
    $factorySource = if ($FactoryFile) { $FactoryFile } else { Join-Path $PSScriptRoot '..\assets\ViewFactory.cs' }
    $stamps = Get-WpfRenderBuildStamps $assemblies $factorySource
    $noBuild = $false
    $projectPath = Join-Path $workDir 'RenderHarness.csproj'
    if (Test-Path -LiteralPath $projectPath) {
        $cache = if (Test-Path -LiteralPath $stampPath) { try { Get-Content -LiteralPath $stampPath -Raw | ConvertFrom-Json } catch { $null } }
        $noBuild = $cache -and $cache.built -and ((@($cache.stamps) -join "`n") -eq ($stamps -join "`n"))
        if (-not $noBuild) {
            # 程序集路径不变但 TFM / 位数变了（如 4.6.1 升级到 4.8、切换“首选 32 位”）：缓存工程中的设置已过时，需要重新生成。
            $inferred = & $generator @generate -InferOnly
            $current = ([xml](Get-Content -LiteralPath $projectPath -Raw)).Project.PropertyGroup
            if ("$($current.TargetFramework)".Trim() -ne $inferred.TargetFramework -or "$($current.PlatformTarget)".Trim() -ne $inferred.Platform) {
                Remove-Item -LiteralPath $workDir -Recurse -Force
            }
        }
    }
    if (Test-Path -LiteralPath $projectPath) {
        # 视图配置只影响 harness.json，不需要重新构建。
        # 注意不能叫 $config：PowerShell 变量不区分大小写，会覆盖 [string]$Config 参数。
        $harnessConfig = [ordered]@{
            viewType = if ($ViewType) { $ViewType } else { $null }
            xaml = if ($Xaml) { $Xaml } else { $null }
            dataContextType = if ($DataContextType) { $DataContextType } else { $null }
            dataContextFactory = if ($DataContextFactory) { $DataContextFactory } else { $null }
            resourceDictionaries = @($ResourceDictionary)
            assemblies = @($assemblies | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) })
            steps = $normalizedSteps
            continueOnError = [bool]$ContinueOnError
            animations = $Animations
        }
        [IO.File]::WriteAllText((Join-Path $workDir 'harness.json'), ($harnessConfig | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        Copy-Item -LiteralPath $factorySource -Destination (Join-Path $workDir 'ViewFactory.cs') -Force
    }
    else {
        if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force } # 上次生成中断留下的残缺目录
        $null = & $generator @generate -WorkDir $workDir
    }

    $run = Invoke-Combos $workDir $noBuild
    $firstStatus = if ($run.Matrix) { $run.FirstStatus } else { (Get-Content -LiteralPath (Join-Path $run.OutDir 'summary.json') -Raw | ConvertFrom-Json).status }
    # 构建失败或找不到产物（-NoBuild 但产物被删）时记为未构建，下次重新构建。
    $built = [bool]$firstStatus -and $firstStatus -notin 'failed:build', 'failed:locate'
    [IO.File]::WriteAllText($stampPath, ([ordered]@{ built = $built; stamps = $stamps; lastUsed = (Get-Date).ToUniversalTime().ToString('O') } | ConvertTo-Json),
        [Text.UTF8Encoding]::new($false))
}
finally {
    try { $mutex.ReleaseMutex() } catch [ApplicationException] { }
    $mutex.Dispose()
}

# 清理过期缓存与渲染结果（策略在 Cache.ps1）。
Remove-ExpiredWpfRenderCache $CacheRoot $workDir $RetentionDays

$global:LASTEXITCODE = $run.ExitCode
$run.OutDir
