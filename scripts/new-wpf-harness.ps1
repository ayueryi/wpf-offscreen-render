#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidatePattern('^net(8|9|[1-9][0-9]+)\.0-windows$')]
    [string]$TargetFramework = 'net8.0-windows',
    [string]$WorkDir,
    [string[]]$AssemblyPath = @()
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'WPF 渲染需要 Windows。' }
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
  </PropertyGroup>
  <ItemGroup>
$($references -join [Environment]::NewLine)
  </ItemGroup>
</Project>
"@
$null = New-Item -ItemType Directory -Path $WorkDir
[IO.File]::WriteAllText((Join-Path $WorkDir 'RenderHarness.csproj'), $project, [Text.UTF8Encoding]::new($false))
$assetRoot = Join-Path $PSScriptRoot '..\assets'
Copy-Item -LiteralPath (Join-Path $assetRoot 'Program.cs'), (Join-Path $assetRoot 'ViewFactory.cs') -Destination $WorkDir
[pscustomobject]@{ WorkDir = $WorkDir; ProjectPath = Join-Path $WorkDir 'RenderHarness.csproj' }
