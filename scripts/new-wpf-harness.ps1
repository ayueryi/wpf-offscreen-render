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
    [string]$FactoryFile
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'WPF 渲染需要 Windows。' }
if ($ViewType -and $Xaml) { throw '-ViewType 与 -Xaml 只能二选一。' }
if ($DataContextType -and $DataContextFactory) { throw '-DataContextType 与 -DataContextFactory 只能二选一。' }
if (($DataContextType -or $DataContextFactory) -and -not ($ViewType -or $Xaml)) { throw '-DataContextType / -DataContextFactory 需要配合 -ViewType 或 -Xaml。' }
if ($FactoryFile) { $FactoryFile = (Resolve-Path -LiteralPath $FactoryFile).Path }
if ($Xaml) { $Xaml = (Resolve-Path -LiteralPath $Xaml).Path }

# 读取程序集的 TargetFrameworkAttribute（如 .NETFramework,Version=v4.7.2）与位数要求，不加载程序集。
function Get-AssemblyTarget([string]$Path) {
    Add-Type -AssemblyName System.Reflection.Metadata
    $stream = [IO.File]::OpenRead($Path)
    $pe = [Reflection.PortableExecutable.PEReader]::new($stream)
    try {
        if (-not $pe.HasMetadata) { throw "不是托管程序集：$Path" }
        $headers = $pe.PEHeaders
        $flags = $headers.CorHeader.Flags
        $platform = switch ($headers.CoffHeader.Machine) {
            'Amd64' { 'x64' }
            'Arm64' { 'ARM64' }
            'I386' {
                # 纯 IL 且不要求 32 位为 AnyCPU。x86 编译、C++/CLI 混合程序集，以及"首选 32 位"的 exe
                # （VS 中 .NET Framework 程序的默认设置，业务程序实际以 32 位运行）都用 32 位宿主。
                $ilOnly = $flags.HasFlag([Reflection.PortableExecutable.CorFlags]::ILOnly)
                $requires32 = $flags.HasFlag([Reflection.PortableExecutable.CorFlags]::Requires32Bit)
                if ($ilOnly -and -not $requires32) { 'AnyCPU' } else { 'x86' }
            }
            default { 'AnyCPU' }
        }
        $reader = [Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($pe)
        $framework = $null
        foreach ($handle in $reader.GetAssemblyDefinition().GetCustomAttributes()) {
            $attribute = $reader.GetCustomAttribute($handle)
            if ($attribute.Constructor.Kind -ne [Reflection.Metadata.HandleKind]::MemberReference) { continue }
            $ctor = $reader.GetMemberReference([Reflection.Metadata.MemberReferenceHandle]$attribute.Constructor)
            if ($ctor.Parent.Kind -ne [Reflection.Metadata.HandleKind]::TypeReference) { continue }
            $type = $reader.GetTypeReference([Reflection.Metadata.TypeReferenceHandle]$ctor.Parent)
            if ($reader.GetString($type.Name) -ne 'TargetFrameworkAttribute') { continue }
            $blob = $reader.GetBlobReader($attribute.Value)
            if ($blob.ReadUInt16() -eq 1) { $framework = $blob.ReadSerializedString() }
            break
        }
        [pscustomobject]@{ Path = $Path; Framework = $framework; Platform = $platform }
    }
    finally { $pe.Dispose(); $stream.Dispose() }
}

# 统一成 Family（framework / core）+ 三段版本号，便于比较兼容性。
function ConvertTo-FrameworkInfo([string]$Value) {
    if ($Value -match '^net4(\d)(\d)?$') {
        $patch = if ($Matches[2]) { [int]$Matches[2] } else { 0 }
        return [pscustomobject]@{ Family = 'framework'; Version = [version]::new(4, [int]$Matches[1], $patch); Display = $Value }
    }
    if ($Value -match '^net(\d+)\.0-windows') {
        return [pscustomobject]@{ Family = 'core'; Version = [version]::new([int]$Matches[1], 0, 0); Display = $Value }
    }
    if ($Value -match '^\.NET(Framework|CoreApp),Version=v(\d+)\.(\d+)(?:\.(\d+))?') {
        $family = if ($Matches[1] -eq 'Framework') { 'framework' } else { 'core' }
        $patch = if ($Matches[4]) { [int]$Matches[4] } else { 0 }
        return [pscustomobject]@{ Family = $family; Version = [version]::new([int]$Matches[2], [int]$Matches[3], $patch); Display = $Value }
    }
    $null # .NETStandard 或未标注：两类宿主都可引用，不参与推断
}
if (-not $WorkDir) {
    $WorkDir = Join-Path ([IO.Path]::GetTempPath()) ('wpf-render-' + [guid]::NewGuid().ToString('N'))
}
$WorkDir = [IO.Path]::GetFullPath($WorkDir)
if (Test-Path -LiteralPath $WorkDir) { throw "拒绝覆盖已有目录：$WorkDir" }
$targets = foreach ($assembly in $AssemblyPath) {
    $resolved = (Resolve-Path -LiteralPath $assembly).Path
    if ([IO.Path]::GetExtension($resolved) -notin '.dll', '.exe') { throw "需要 DLL / EXE 引用：$resolved" }
    Get-AssemblyTarget $resolved
}

# 宿主必须与业务程序集同属 .NET Framework 或 .NET，且版本不低于其中最高者。
$required = $null
foreach ($target in $targets) {
    $info = ConvertTo-FrameworkInfo $target.Framework
    if (-not $info) { continue }
    if ($info.Family -eq 'core' -and $info.Version.Major -lt 5) {
        throw "$($target.Path) 面向 $($target.Framework)，WPF 宿主仅支持 .NET 5 及以上或 .NET Framework 4.7.2 及以上。"
    }
    if ($required -and $required.Family -ne $info.Family) {
        throw '-AssemblyPath 同时包含 .NET Framework 与 .NET 程序集，不能在同一宿主中加载。'
    }
    if (-not $required -or $info.Version -gt $required.Version) { $required = $info }
}
if ($TargetFramework) {
    $chosen = ConvertTo-FrameworkInfo $TargetFramework
    if ($required -and ($required.Family -ne $chosen.Family -or $chosen.Version -lt $required.Version)) {
        throw "-TargetFramework $TargetFramework 不能引用面向 $($required.Display) 的业务程序集；省略该参数可自动推断。"
    }
}
elseif (-not $required) { $TargetFramework = 'net8.0-windows' }
elseif ($required.Family -eq 'framework') {
    # 低于 4.7.2 的程序集可由 net472 宿主引用。
    $TargetFramework = if ($required.Version -lt [version]'4.7.2') { 'net472' }
        else { 'net4' + $required.Version.Minor + $(if ($required.Version.Build -gt 0) { $required.Version.Build }) }
}
else { $TargetFramework = "net$($required.Version.Major).0-windows" }
$isFramework = $TargetFramework -like 'net4*'

$platforms = @($targets.Platform | Where-Object { $_ -ne 'AnyCPU' } | Select-Object -Unique)
if ($platforms.Count -gt 1) { throw "-AssemblyPath 的位数要求冲突：$($platforms -join ', ')" }
if ($Platform) {
    if ($platforms.Count -eq 1 -and $Platform -ne $platforms[0]) { throw "-Platform $Platform 与业务程序集要求的 $($platforms[0]) 不一致。" }
}
else { $Platform = if ($platforms.Count -eq 1) { $platforms[0] } else { 'AnyCPU' } }

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
$config = [ordered]@{
    viewType = if ($ViewType) { $ViewType } else { $null }
    xaml = if ($Xaml) { $Xaml } else { $null }
    dataContextType = if ($DataContextType) { $DataContextType } else { $null }
    dataContextFactory = if ($DataContextFactory) { $DataContextFactory } else { $null }
    resourceDictionaries = @($ResourceDictionary)
}
$configPath = Join-Path $WorkDir 'harness.json'
[IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 3), $utf8)
Copy-Item -Path (Join-Path $PSScriptRoot '..\assets\*.cs') -Destination $WorkDir
if ($FactoryFile) { Copy-Item -LiteralPath $FactoryFile -Destination (Join-Path $WorkDir 'ViewFactory.cs') -Force }
[pscustomobject]@{
    WorkDir = $WorkDir; ProjectPath = Join-Path $WorkDir 'RenderHarness.csproj'; ConfigPath = $configPath
    TargetFramework = $TargetFramework; Platform = $Platform
}
