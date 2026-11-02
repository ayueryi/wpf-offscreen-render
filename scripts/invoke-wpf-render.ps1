#requires -Version 7.0
# 兼容入口：渲染器已改名为 invoke-agent-render.ps1。
& (Join-Path $PSScriptRoot 'invoke-agent-render.ps1') @args
exit $LASTEXITCODE
