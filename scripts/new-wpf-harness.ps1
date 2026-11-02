#requires -Version 7.0
# 兼容入口：宿主生成器已改名为 new-agent-harness.ps1。
& (Join-Path $PSScriptRoot 'new-agent-harness.ps1') @args
exit $LASTEXITCODE
