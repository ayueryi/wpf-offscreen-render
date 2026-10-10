#requires -Version 7.0
# Stop hook（Claude Code 插件自动启用；Codex 可按 templates/codex-hooks.json 配置）：
# 代理结束本轮前，若改动了 wpf-render.json 中 watch 覆盖的文件，先构建再渲染受影响的视图；
# 有渲染失败或绑定问题时输出 {"decision":"block","reason":...}，让代理继续修复。
# 只在业务项目的 wpf-render.json 设置 "verifyOnStop": true 时生效；同一份改动只验证一次。
$ErrorActionPreference = 'Stop'

function Exit-Quietly { exit 0 }

$hookInput = try { [Console]::In.ReadToEnd() | ConvertFrom-Json -AsHashtable } catch { $null }
if ($null -eq $hookInput) { $hookInput = @{} }
if (-not $IsWindows) { Exit-Quietly }
$cwd = if ($hookInput.cwd) { $hookInput.cwd } else { (Get-Location).Path }

# 从会话工作目录向上查找 wpf-render.json。
$dir = $cwd
while ($dir -and -not (Test-Path -LiteralPath (Join-Path $dir 'wpf-render.json'))) { $dir = Split-Path -Parent $dir }
if (-not $dir) { Exit-Quietly }
$configPath = Join-Path $dir 'wpf-render.json'
$config = try { Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable } catch { $null }
if (-not $config -or $config.verifyOnStop -ne $true -or -not $config.views) { Exit-Quietly }

# 未提交的改动（含未跟踪文件），统一成正斜杠绝对路径。porcelain 输出中的路径相对于仓库根目录。
$repoRoot = & git -C $dir rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0 -or -not $repoRoot) { Exit-Quietly }
# core.quotepath=false：中文等非 ASCII 文件名不转义成八进制。
$changed = @(& git -C $dir -c core.quotepath=false status --porcelain=v1 -uall 2>$null | ForEach-Object {
        $path = $_.Substring(3)
        if ($path -match ' -> ') { $path = ($path -split ' -> ')[-1] }
        [IO.Path]::GetFullPath((Join-Path $repoRoot $path.Trim('"'))).Replace('\', '/')
    })
if ($changed.Count -eq 0) { Exit-Quietly }

# watch 模式相对于 wpf-render.json 所在目录：** 匹配任意层级，* 匹配单级，? 匹配单个字符。
function ConvertTo-Regex([string]$Pattern) {
    $full = [IO.Path]::GetFullPath((Join-Path $dir $Pattern)).Replace('\', '/')
    $escaped = [regex]::Escape($full) -replace '\\\*\\\*', '.*' -replace '\\\*', '[^/]*' -replace '\\\?', '.'
    "^$escaped$"
}
$defaults = if ($config.defaults) { $config.defaults } else { @{} }
$affected = @(foreach ($name in $config.views.Keys) {
        $view = $config.views[$name]
        $watch = @(if ($view.watch) { $view.watch } elseif ($defaults.watch) { $defaults.watch })
        $regexes = @($watch | Where-Object { $_ } | ForEach-Object { ConvertTo-Regex $_ })
        if ($regexes | Where-Object { $regex = $_; $changed | Where-Object { $_ -match $regex } }) { $name }
    })
if ($affected.Count -eq 0) { Exit-Quietly }

# 同一份改动（路径与内容）只验证一次，避免代理确认无法修复后被反复拦截。
$fingerprintSource = ($changed | Sort-Object | ForEach-Object {
        $_ + ':' + $(if (Test-Path -LiteralPath $_ -PathType Leaf) { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash } else { 'deleted' })
    }) -join "`n"
$fingerprint = (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($fingerprintSource))) -Algorithm SHA256).Hash
$stateDir = Join-Path ([IO.Path]::GetTempPath()) 'wpf-render-hook'
$null = New-Item -ItemType Directory -Path $stateDir -Force
$session = if ($hookInput.session_id) { $hookInput.session_id -replace '[^\w-]', '_' } else { 'default' }
$statePath = Join-Path $stateDir "$session.json"
$state = if (Test-Path -LiteralPath $statePath) { try { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } catch { $null } }
if ($state -and $state.fingerprint -eq $fingerprint) { Exit-Quietly }

$render = Join-Path $PSScriptRoot '..\scripts\render.ps1'
$problems = [Collections.Generic.List[string]]::new()
$passed = [Collections.Generic.List[string]]::new()
$builtCommands = [Collections.Generic.HashSet[string]]::new()
foreach ($name in $affected | Sort-Object) {
    $view = $config.views[$name]
    $buildCommand = @(if ($view.build) { $view.build } elseif ($defaults.build) { $defaults.build })
    # 同一构建命令只执行一次。
    $build = $buildCommand.Count -gt 0 -and $builtCommands.Add(($buildCommand -join ' '))
    try {
        # 只保留管道输出（渲染目录）：警告等流在 -File 模式下会写到 stdout，混进 hook 的 JSON 输出。
        $outDir = & $render -Config $configPath -Preset $name -Build:$build 3> $null 4> $null 5> $null 6> $null
        $resultPath = @('matrix.json', 'summary.json') | ForEach-Object { Join-Path "$outDir" $_ } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $resultPath) { $problems.Add("[$name] 没有得到渲染结果（$outDir）"); continue }
        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        $items = if ($result.results) { @($result.results) } else { @($result) }
        $viewProblems = foreach ($item in $items) {
            $label = if ($result.results) { "[$name $($item.theme) $($item.size) $($item.dpi)DPI]" } else { "[$name]" }
            if ("$($item.status)" -like 'failed*') {
                "$label 渲染失败（$($item.status)）：$(@($item.buildErrors) + @($item.error) | Where-Object { $_ } | Select-Object -First 5 | Join-String -Separator '；')。输出目录 $($item.outDir)"
            }
            elseif ($item.status -eq 'binding-issues') {
                "$label 绑定错误：$(@($item.bindingIssues) | Select-Object -First 5 | Join-String -Separator '；')。截图 $($item.snapshot)"
            }
            elseif ($config.blockOnLayoutIssues -eq $true -and $item.layoutIssueCount -gt 0) {
                "$label 布局问题 $($item.layoutIssueCount) 条：$(@($item.layoutIssues) | Select-Object -First 5 | Join-String -Separator '；')。截图 $($item.snapshot)"
            }
        }
        if ($viewProblems) { $viewProblems | ForEach-Object { $problems.Add($_) } } else { $passed.Add($name) }
    }
    catch { $problems.Add("[$name] $($_.Exception.Message)") }
}

[IO.File]::WriteAllText($statePath, ([ordered]@{ fingerprint = $fingerprint; passed = ($problems.Count -eq 0); at = (Get-Date).ToString('O') } | ConvertTo-Json),
    [Text.UTF8Encoding]::new($false))
if ($problems.Count -gt 0) {
    $reason = "WPF 渲染验证未通过（wpf-render.json：$configPath）。请修复后再结束；若确认属于预期，在回复中说明原因。`n" + ($problems -join "`n")
    [ordered]@{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress
    exit 0
}
Write-Output "WPF 渲染验证通过：$($passed -join '、')"
