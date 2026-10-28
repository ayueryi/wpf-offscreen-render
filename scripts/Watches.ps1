#requires -Version 7.0
# watch 匹配的单一 module（语义只在这一处定义，见 references/integration.md）：
# Stop hook 用它判断「本次未提交的改动命中哪些视图」。之前匹配逻辑焊在 hook 主体里，
# glob 语义（** 匹配任意层级含零层、* 单级内任意字符、? 单个字符）无法单独测试。
function ConvertTo-WatchRegex([string]$Pattern, [string]$BaseDir) {
    $full = [IO.Path]::GetFullPath((Join-Path $BaseDir $Pattern)).Replace('\', '/')
    $escaped = [regex]::Escape($full) -replace '\\\*\\\*/', '(?:.*/)?' -replace '\\\*\\\*', '.*' -replace '\\\*', '[^/]*' -replace '\\\?', '[^/]'
    "^$escaped$"
}

# 从 wpf-render.json 配置（含 defaults）与改动文件清单（正斜杠绝对路径）算出受影响视图与命中文件。
# 视图未配 watch 时继承 defaults.watch；命中规则按改动路径匹配任一 watch 模式。
function Select-AffectedViews($Config, [string]$BaseDir, [string[]]$ChangedFiles) {
    $defaults = if ($Config.defaults) { $Config.defaults } else { @{} }
    $relevant = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $views = @(foreach ($name in $Config.views.Keys) {
            $view = $Config.views[$name]
            $watch = @(if ($view.watch) { $view.watch } elseif ($defaults.watch) { $defaults.watch })
            $regexes = @($watch | Where-Object { $_ } | ForEach-Object { ConvertTo-WatchRegex $_ $BaseDir })
            $hits = @($ChangedFiles | Where-Object { $path = $_; $regexes | Where-Object { $path -match $_ } })
            if ($hits.Count -gt 0) { $hits | ForEach-Object { $null = $relevant.Add($_) }; $name }
        })
    [pscustomobject]@{ Views = @($views); Hits = @($relevant) }
}
