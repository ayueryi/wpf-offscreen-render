#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidatePattern('^net(8|9|[1-9][0-9]+)\.0-windows$')]
    [string]$TargetFramework = 'net8.0-windows',
    [string]$WorkDir,
    [string[]]$AssemblyPath = @(),
    # 以下参数写入 harness.json，可免改 ViewFactory.cs；之后直接编辑 harness.json 无需重新构建。
    [string]$ViewType,
    [string]$Xaml,
    [string]$DataContextType,
    [string[]]$ResourceDictionary = @()
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'WPF 渲染需要 Windows。' }
if ($ViewType -and $Xaml) { throw '-ViewType 与 -Xaml 只能二选一。' }
if ($DataContextType -and -not ($ViewType -or $Xaml)) { throw '-DataContextType 需要配合 -ViewType 或 -Xaml。' }
if ($Xaml) { $Xaml = (Resolve-Path -LiteralPath $Xaml).Path }
if (-not $WorkDir) {
    $WorkDir = Join-Path ([IO.Path]::GetTempPath()) ('wpf-render-' + [guid]::NewGuid().ToString('N'))
}
$WorkDir = [IO.Path]::GetFullPath($WorkDir)
if (Test-Path -LiteralPath $WorkDir) { throw "拒绝覆盖已有目录：$WorkDir" }
$references = foreach ($assembly in $AssemblyPath) {
    $resolved = (Resolve-Path -LiteralPath $assembly).Path
    if ([IO.Path]::GetExtension($resolved) -ne '.dll') { throw "需要 DLL 引用：$resolved" }
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
    <UseAppHost>false</UseAppHost>
    <EnableDefaultPageItems>false</EnableDefaultPageItems>
    <DefaultItemExcludes>`$(DefaultItemExcludes);out/**;render-*/**</DefaultItemExcludes>
  </PropertyGroup>
  <ItemGroup>
$($references -join [Environment]::NewLine)
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
    resourceDictionaries = @($ResourceDictionary)
}
$configPath = Join-Path $WorkDir 'harness.json'
[IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 3), $utf8)
$assetRoot = Join-Path $PSScriptRoot '..\assets'
Copy-Item -LiteralPath (Join-Path $assetRoot 'Program.cs'), (Join-Path $assetRoot 'ViewFactory.cs'),
    (Join-Path $assetRoot 'ConfiguredView.cs') -Destination $WorkDir
[pscustomobject]@{ WorkDir = $WorkDir; ProjectPath = Join-Path $WorkDir 'RenderHarness.csproj'; ConfigPath = $configPath }
