#requires -Version 7.0
# Stop hook（Claude Code 插件自动启用；Codex 可按 templates/codex-hooks.json 配置）：
# 代理结束本轮前，若改动了 wpf-render.json 中 watch 覆盖的文件，先构建再渲染受影响的视图；
# 有渲染失败或绑定问题时输出 {"decision":"block","reason":...}，让代理继续修复。
# 只在业务项目的 wpf-render.json 设置 "verifyOnStop": true、且用户用 scripts/trust-project.ps1 授权过该配置时生效；
# 同一份改动只验证一次。
$ErrorActionPreference = 'Stop'

function Exit-Quietly { exit 0 }

# hook 的输入输出都是 UTF-8；控制台默认代码页（中文 Windows 为 GBK）会把中文路径与提示变成乱码。
# OutputEncoding 同时决定 pwsh 如何解码 git 等外部命令的输出。
$utf8 = [Text.UTF8Encoding]::new($false)
try { [Console]::OutputEncoding = $utf8 } catch { }
$hookInput = try { [IO.StreamReader]::new([Console]::OpenStandardInput(), $utf8).ReadToEnd() | ConvertFrom-Json -AsHashtable } catch { $null }
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

# hook 会执行仓库配置的 build 命令并运行业务程序集：未经用户授权（或授权后配置被修改）时不执行，
# 每个会话只提示一次如何授权。
. (Join-Path $PSScriptRoot '..\scripts\TrustStore.ps1')
$trust = Get-ProjectTrust $configPath
if ($trust -ne 'trusted') {
    $noticeDir = Join-Path ([IO.Path]::GetTempPath()) 'wpf-render-hook'
    $null = New-Item -ItemType Directory -Path $noticeDir -Force
    $sessionKey = if ($hookInput.session_id) { $hookInput.session_id -replace '[^\w-]', '_' } else { 'default' }
    # 按会话、配置文件与授权状态各提示一次：先“未授权”后“授权后被修改”时仍会再次提示。
    $configKey = (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($configPath.ToLowerInvariant()))) -Algorithm SHA256).Hash.Substring(0, 12)
    $notice = Join-Path $noticeDir "$sessionKey-$configKey-$trust.notice"
    if (-not (Test-Path -LiteralPath $notice)) {
        Set-Content -LiteralPath $notice -Value $configPath
        $why = if ($trust -eq 'changed') { 'wpf-render.json 在授权后被修改过' } else { '这个项目还没有授权' }
        $trustScript = Join-Path $PSScriptRoot '..\scripts\trust-project.ps1'
        [ordered]@{ systemMessage = "wpf-offscreen-render：$configPath 启用了结束前自动验证，但$why，本次跳过。确认信任后运行：pwsh -ExecutionPolicy Bypass -File `"$([IO.Path]::GetFullPath($trustScript))`" -Path `"$configPath`"" } |
            ConvertTo-Json -Compress -EscapeHandling EscapeNonAscii
    }
    exit 0
}

# 未提交的改动（含未跟踪文件），统一成正斜杠绝对路径。porcelain 输出中的路径相对于仓库根目录。
$repoRoot = & git -C $dir rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0 -or -not $repoRoot) { Exit-Quietly }
# -z：路径不加引号、不转义，记录以 NUL 分隔；重命名 / 复制记录后紧跟原路径，两者都算改动
# （watch 覆盖的文件被移走同样可能破坏视图）。
$records = ((& git -C $dir status --porcelain=v1 -z -uall 2>$null) -join "`n") -split "`0"
$changed = @(for ($i = 0; $i -lt $records.Count; $i++) {
        $record = $records[$i].Trim("`n")
        if ($record.Length -lt 4) { continue }
        $record.Substring(3)
        # 重命名 / 复制可能记录在暂存区列（X）或工作区列（Y，如 git add -N 之后）。
        if ($record[0] -in 'R', 'C' -or $record[1] -in 'R', 'C') { $i++; if ($i -lt $records.Count) { $records[$i].Trim("`n") } }
    }) | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $repoRoot $_)).Replace('\', '/') }
$changed = @($changed)
if ($changed.Count -eq 0) { Exit-Quietly }

# watch 模式的语义（** 匹配任意层级含零层、* 单级、? 单字符）与 defaults 继承在 Watches.ps1 中统一定义。
. (Join-Path $PSScriptRoot '..\scripts\Watches.ps1')
$selection = Select-AffectedViews $config $dir $changed
$affected = $selection.Views
$relevant = $selection.Hits
if ($affected.Count -eq 0) { Exit-Quietly }
# 渲染循环仍要用 defaults.build 选择构建命令（匹配用的 defaults 已内聚在 Watches.ps1）。
$defaults = if ($config.defaults) { $config.defaults } else { @{} }

# 同一份改动只验证一次，避免代理确认无法修复后被反复拦截。只对命中 watch 的文件（路径与内容）计算指纹，
# 构建产物等其他变化不影响判断。
$fingerprintSource = ($relevant | Sort-Object | ForEach-Object {
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
        # 结果形态（matrix / 单结果）的解析统一在 Results.ps1。
        . (Join-Path $PSScriptRoot '..\scripts\Results.ps1')
        try { $result = Read-WpfRenderResult "$outDir" }
        catch { $problems.Add("[$name] 没有得到渲染结果（$outDir）：$($_.Exception.Message)"); continue }
        $viewProblems = foreach ($item in $result.items) {
            $label = Get-WpfRenderItemLabel $result.raw $item $name
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
    [ordered]@{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress -EscapeHandling EscapeNonAscii
    exit 0
}
Write-Output "WPF 渲染验证通过：$($passed -join '、')"
