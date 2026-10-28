#requires -Version 7.0
[CmdletBinding()]
param(
    # .NET Framework 4.7.2 / 4.8 / 4.8.1，或 .NET 5 及以上的 -windows TFM（可带平台版本）。
    # 省略时按 -AssemblyPath 的 TargetFrameworkAttribute 推断，没有业务程序集时为 net8.0-windows。
    [ValidatePattern('^(net472|net48|net481|net([5-9]|[1-9][0-9])\.0-windows([0-9]+(\.[0-9]+){1,3})?)$')]
    [string]$TargetFramework,
    # 省略时按 -AssemblyPath 的 PE 头推断：存在仅 x86 / x64 的程序集就跟随它，否则 AnyCPU。
    [ValidateSet('AnyCPU', 'x86', 'x64', 'ARM64')]
    [string]$Platform,
    [string]$WorkDir,
    [string[]]$AssemblyPath = @(),
    # 以下参数写入 harness.json，可免改 ViewFactory.cs；之后直接编辑 harness.json 无需重新构建。
    [string]$ViewType,
    [string]$Xaml,
    [string]$DataContextType,
    # 无参静态工厂方法 "Namespace.Type.Method"，与 -DataContextType 二选一。
    [string]$DataContextFactory,
    [string[]]$ResourceDictionary = @(),
    # 用这个文件替换生成工程中的 ViewFactory.cs（业务仓库中受版本管理的预览工厂）。
    [string]$FactoryFile,
    # 交互步骤：JSON 数组字符串或文件路径（见 docs/design/interaction-steps.md），写入 harness.json，改动无需重新构建。
    [string]$Steps,
    # 某步失败后继续执行其余步骤（默认停止）。
    [switch]$ContinueOnError,
    # live：保持动画原样；settle：每次截图前把事件触发器启动的 Storyboard 跳到结束状态。
    [ValidateSet('live', 'settle')][string]$Animations = 'live',
    # 只推断并返回 TargetFramework / Platform，不生成工程（render.ps1 用来判断缓存宿主是否需要重新生成）。
    [switch]$InferOnly
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'WPF 渲染需要 Windows。' }
if ($ViewType -and $Xaml) { throw '-ViewType 与 -Xaml 只能二选一。' }
if ($DataContextType -and $DataContextFactory) { throw '-DataContextType 与 -DataContextFactory 只能二选一。' }
if (($DataContextType -or $DataContextFactory) -and -not ($ViewType -or $Xaml)) { throw '-DataContextType / -DataContextFactory 需要配合 -ViewType 或 -Xaml。' }
. (Join-Path $PSScriptRoot 'Steps.ps1')
$normalizedSteps = @(ConvertTo-HarnessSteps $Steps $FactoryFile) # 先校验（含 custom 步骤的工厂实现检查），写法有误时在生成工程前报错
# ProviderPath：UNC 路径（\\server\share）的 .Path 带 PowerShell 提供程序前缀，.NET API 无法使用。
if ($FactoryFile) { $FactoryFile = (Resolve-Path -LiteralPath $FactoryFile).ProviderPath }
if ($Xaml) { $Xaml = (Resolve-Path -LiteralPath $Xaml).ProviderPath }
# 资源字典：pack URI（/Asm;component/...）与绝对路径保持原样；存在的相对路径按当前位置解析（{theme} 按 light 检查）。
$ResourceDictionary = @($ResourceDictionary | ForEach-Object {
        if ([IO.Path]::IsPathRooted($_) -or $_ -like '*;component/*' -or $_ -match '^(pack|file|https?)://' -or
            -not (Test-Path -LiteralPath $_.Replace('{theme}', 'light'))) { $_ }
        else { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($_) }
    })

# 宿主 TFM 与位数推断在 HostFrameworks.ps1 中统一维护（fixtures 直测，不必起渲染）。
. (Join-Path $PSScriptRoot 'HostFrameworks.ps1')
$inferred = Get-HostFrameworks $AssemblyPath $TargetFramework $Platform
$TargetFramework = $inferred.TargetFramework
$Platform = $inferred.Platform
$isFramework = $TargetFramework -like 'net4*'
# 生成器仍需要每个程序集的解析路径（csproj 引用与 harness.json 的 assemblies 列表）。
$targets = foreach ($assembly in $AssemblyPath) {
    $resolved = (Resolve-Path -LiteralPath $assembly).ProviderPath
    if ([IO.Path]::GetExtension($resolved) -notin '.dll', '.exe') { throw "需要 DLL / EXE 引用：$resolved" }
    [pscustomobject]@{ Path = $resolved; Name = [Security.SecurityElement]::Escape([IO.Path]::GetFileNameWithoutExtension($resolved)) }
}
if ($InferOnly) { return [pscustomobject]@{ TargetFramework = $TargetFramework; Platform = $Platform } }

if (-not $WorkDir) {
    $WorkDir = Join-Path ([IO.Path]::GetTempPath()) ('wpf-render-' + [guid]::NewGuid().ToString('N'))
}
# 相对路径按 PowerShell 当前位置解析（[IO.Path]::GetFullPath 用的是进程工作目录，Set-Location 不会改变它）。
$WorkDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WorkDir)
if (Test-Path -LiteralPath $WorkDir) { throw "拒绝覆盖已有目录：$WorkDir" }

$references = foreach ($target in $targets) {
    $resolved = $target.Path
    $name = [Security.SecurityElement]::Escape([IO.Path]::GetFileNameWithoutExtension($resolved))
    $hint = [Security.SecurityElement]::Escape($resolved)
    "    <Reference Include=`"$name`"><HintPath>$hint</HintPath><Private>true</Private></Reference>"
}
$project = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>$TargetFramework</TargetFramework>
    <UseWPF>true</UseWPF>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <LangVersion>latest</LangVersion>
    <PlatformTarget>$Platform</PlatformTarget>
    <!-- .NET Framework 直接运行 RenderHarness.exe；.NET 在固定位数时用 apphost 选对应架构的运行时，否则 dotnet RenderHarness.dll -->
    <UseAppHost>$(if ($isFramework -or $Platform -ne 'AnyCPU') { 'true' } else { 'false' })</UseAppHost>
    <!-- .NET 宿主在本机没有对应主版本的 WindowsDesktop 运行时时前滚到更高版本（如只装了 .NET 10）。 -->
    <RollForward>Major</RollForward>
    <EnableDefaultPageItems>false</EnableDefaultPageItems>
    <DefaultItemExcludes>`$(DefaultItemExcludes);out/**;render-*/**</DefaultItemExcludes>
  </PropertyGroup>
  <ItemGroup>
$($references -join [Environment]::NewLine)$(if ($isFramework) { [Environment]::NewLine + '    <Reference Include="System.Runtime.Serialization" />' })
  </ItemGroup>
</Project>
"@
$utf8 = [Text.UTF8Encoding]::new($false)
$null = New-Item -ItemType Directory -Path $WorkDir
[IO.File]::WriteAllText((Join-Path $WorkDir 'RenderHarness.csproj'), $project, $utf8)
# 截断向上查找，避免 WorkDir 位于业务仓库内时继承其构建配置与集中包管理。
$isolation = '<Project><!-- 隔离上层目录的 MSBuild 配置 --></Project>'
foreach ($file in 'Directory.Build.props', 'Directory.Build.targets') {
    [IO.File]::WriteAllText((Join-Path $WorkDir $file), $isolation, $utf8)
}
[IO.File]::WriteAllText((Join-Path $WorkDir 'Directory.Packages.props'),
    '<Project><PropertyGroup><ManagePackageVersionsCentrally>false</ManagePackageVersionsCentrally></PropertyGroup></Project>', $utf8)
# 空的 global.json 截断 SDK 版本查找：上层仓库锁定的 SDK（可能未安装或过旧）不影响宿主构建，使用本机最新 SDK。
[IO.File]::WriteAllText((Join-Path $WorkDir 'global.json'), '{}', $utf8)
$config = [ordered]@{
    viewType = if ($ViewType) { $ViewType } else { $null }
    xaml = if ($Xaml) { $Xaml } else { $null }
    dataContextType = if ($DataContextType) { $DataContextType } else { $null }
    dataContextFactory = if ($DataContextFactory) { $DataContextFactory } else { $null }
    resourceDictionaries = @($ResourceDictionary)
    assemblies = @($targets | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Path) })
    steps = $normalizedSteps
    continueOnError = [bool]$ContinueOnError
    animations = $Animations
}
$configPath = Join-Path $WorkDir 'harness.json'
[IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 8), $utf8)
# 按字面路径复制：安装目录含 [ ] 时 -Path 会被当作通配符。
Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..\assets') -Filter '*.cs' | Copy-Item -Destination $WorkDir
if ($FactoryFile) { Copy-Item -LiteralPath $FactoryFile -Destination (Join-Path $WorkDir 'ViewFactory.cs') -Force }
[pscustomobject]@{
    WorkDir = $WorkDir; ProjectPath = Join-Path $WorkDir 'RenderHarness.csproj'; ConfigPath = $configPath
    TargetFramework = $TargetFramework; Platform = $Platform
}
