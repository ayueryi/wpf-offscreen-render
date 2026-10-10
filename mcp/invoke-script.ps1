#requires -Version 7.0
# MCP 服务器调用 scripts/ 下脚本的桥接：参数从 JSON 文件读成哈希表后 splat（数组、开关参数都保持原类型），
# 结果（管道输出、退出码、异常）写回 JSON 文件。避免经命令行传数组时被拼成单个字符串。
param(
    [Parameter(Mandatory)][string]$Script,
    [Parameter(Mandatory)][string]$ArgsFile,
    [Parameter(Mandatory)][string]$ResultFile,
    # 同时收集 Write-Host 输出（自检脚本的结论只写在主机流里）。
    [switch]$CaptureHost
)
$ErrorActionPreference = 'Stop'
$result = [ordered]@{ output = @(); exitCode = $null; error = $null }
try {
    $arguments = Get-Content -LiteralPath $ArgsFile -Raw | ConvertFrom-Json -AsHashtable
    if ($null -eq $arguments) { $arguments = @{} }
    $global:LASTEXITCODE = 0
    $output = if ($CaptureHost) { & $Script @arguments *>&1 } else { & $Script @arguments 6> $null }
    $result.exitCode = $LASTEXITCODE
    $result.output = @($output | ForEach-Object { "$_" })
}
catch {
    $result.error = $_.Exception.Message
    $result.exitCode = 1
}
[IO.File]::WriteAllText($ResultFile, ($result | ConvertTo-Json -Depth 3), [Text.UTF8Encoding]::new($false))
