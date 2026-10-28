#requires -Version 7.0
# Antigravity 安装的两个 module（安装 / 卸载共用同一 seam，逻辑只定义一次）。
# 都吃绝对路径参数、不读 $HOME：脚本负责算用户目录下的位置，测试用临时目录直测。
# 这些函数写的是用户机器上的真实配置，安装与卸载必须严格互逆。

# 在 mcp_config.json 中登记 / 移除 wpf-offscreen-render 服务器条目。
# 原文件解析失败时备份为 .bak 后重建：保留用户其他服务器条目，只动我们这一个键。
function Set-McpServerEntry([string]$Path, [bool]$Present, [string]$StartScriptPath, [string]$Name = 'wpf-offscreen-render') {
    $config = [ordered]@{}
    if (Test-Path -LiteralPath $Path) {
        $raw = Get-Content -LiteralPath $Path -Raw
        if ($raw.Trim()) {
            try { $config = $raw | ConvertFrom-Json -AsHashtable }
            catch {
                # 解析失败：备份原文件后从空配置开始，不静默丢弃用户的全部配置。
                Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force
                $config = [ordered]@{}
            }
        }
    }
    else {
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force
    }
    # ConvertFrom-Json -AsHashtable 与 [ordered]@{} 都是 OrderedDictionary：只有 Contains，没有 ContainsKey。
    if (-not $config.Contains('mcpServers') -or -not ($config.mcpServers -is [System.Collections.IDictionary])) {
        $config['mcpServers'] = [ordered]@{}
    }
    if ($Present) {
        $config['mcpServers'][$Name] = [ordered]@{
            command = 'pwsh'
            args = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $StartScriptPath)
        }
    }
    elseif ($config['mcpServers'].Contains($Name)) {
        $null = $config['mcpServers'].Remove($Name)
    }
    $json = $config | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($Path, $json + "`n", [Text.Encoding]::UTF8)
}

# 挂载 skill：优先 junction（指向插件内目录，插件更新后自动生效），失败（非 NTFS 等）回退为复制。
function Mount-Skill([string]$Target, [string]$Source) {
    if (-not (Test-Path -LiteralPath $Source)) { throw "skill 源目录不存在：$Source" }
    Unmount-Skill $Target
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Target) -Force
    try {
        $null = New-Item -ItemType Junction -Path $Target -Target $Source -Force
        'junction'
    }
    catch {
        Copy-Item -LiteralPath $Source -Destination $Target -Recurse -Force
        'copy'
    }
}

# 卸载 skill 挂载：联接 / 软链接按 reparse point 删除，普通目录递归删除。
function Unmount-Skill([string]$Target) {
    if (-not (Test-Path -LiteralPath $Target)) { return }
    $item = Get-Item -LiteralPath $Target -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { $item.Delete() }
    else { Remove-Item -LiteralPath $Target -Recurse -Force }
}
