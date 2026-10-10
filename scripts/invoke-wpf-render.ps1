#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$HarnessDir,
    [ValidateRange(1,6000)][int]$Width = 1280,
    [ValidateRange(1,6000)][int]$Height = 800,
    [ValidateRange(48,384)][int]$Dpi = 96,
    [ValidateSet('light','dark')][string]$Theme = 'light',
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
if (-not $NoBuild) {
    & dotnet build $projectPath -c Debug --nologo *> (Join-Path $outDir 'build.log')
    if ($LASTEXITCODE -ne 0) {
        Write-Host "构建失败：$(Join-Path $outDir 'build.log')"
        $global:LASTEXITCODE = 1
        return
    }
}
[xml]$projectXml = Get-Content -LiteralPath $projectPath -Raw
$tfm = [string]$projectXml.Project.PropertyGroup.TargetFramework
$dll = Join-Path $HarnessDir "bin\Debug\$tfm\RenderHarness.dll"
if (-not (Test-Path -LiteralPath $dll)) { throw "渲染程序集不存在：$dll" }
$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = (Get-Command dotnet -ErrorAction Stop).Source
$startInfo.WorkingDirectory = $HarnessDir
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$arguments = @($dll, '--out', $outDir, '--width', "$Width", '--height', "$Height", '--dpi', "$Dpi", '--theme', $Theme)
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
Write-Host "渲染退出码：$exitCode；输出：$outDir"
$global:LASTEXITCODE = $exitCode
Write-Output $outDir
