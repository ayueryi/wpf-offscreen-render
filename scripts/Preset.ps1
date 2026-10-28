#requires -Version 7.0
# 预设（wpf-render.json）的查找、解析与合并 —— render.ps1 与 list-views.ps1 共用同一套规则，
# 合并行为只在这里定义；两端不得各自复刻（此前曾在脚本与 MCP 服务器中各写一份而漂移）。
#
# 合并规则：defaults 为底层、视图为顶层；互斥的键在一层中设置了其中一个，
# 就不再从下层继承与之互斥的键；显式参数（render.ps1）永远优先于预设。

# 互斥键：某层设置左侧的键时，右侧的键不再从下层继承。
# 注意只有 width / height 屏蔽 sizes（设置单尺寸时多尺寸列表无意义）；
# 反向不成立：视图设置 sizes 时保留下层的 width / height，显式 -Width 覆盖 sizes 后高度仍取预设默认值。
$script:PresetExclusiveKeys = @{
    viewType         = @('xaml'); xaml = @('viewType')
    dataContextType  = @('dataContextFactory'); dataContextFactory = @('dataContextType')
    width            = @('sizes'); height = @('sizes')
}

# 显式参数与预设中同组键的互斥：显式传了任一个，预设里同组的键都不再生效
# （否则预设的 viewType 与显式的 -Xaml 会冲突，预设的 sizes 会让显式的 -Width / -Height 被忽略）。
# 键名为 render.ps1 的参数名，与 $script:PresetExclusiveKeys 的配置键一一对应。
$script:ExplicitParameterOverrides = @{
    ViewType            = 'Xaml'; Xaml = 'ViewType'
    DataContextType     = 'DataContextFactory'; DataContextFactory = 'DataContextType'
    Width               = 'Size'; Height = 'Size'
}

# 找到配置文件：-Config 是文件或目录；省略时从当前目录向上查找。
function Resolve-WpfRenderConfig([string]$Config) {
    if (-not $Config) {
        $dir = (Get-Location).Path
        while ($dir -and -not (Test-Path -LiteralPath (Join-Path $dir 'wpf-render.json'))) { $dir = Split-Path -Parent $dir }
        if (-not $dir) { throw "从 $((Get-Location).Path) 向上没有找到 wpf-render.json，请用 -Config 指定。" }
        return (Resolve-Path -LiteralPath (Join-Path $dir 'wpf-render.json')).ProviderPath
    }
    if (Test-Path -LiteralPath $Config -PathType Container) { $Config = Join-Path $Config 'wpf-render.json' }
    if (-not (Test-Path -LiteralPath $Config)) { throw "找不到配置文件 $Config。" }
    return (Resolve-Path -LiteralPath $Config).ProviderPath
}

# ConvertFrom-Json 与渲染管线一致地容忍注释与尾逗号；解析失败时带上文件路径。
function Read-WpfRenderConfigFile([string]$Path) {
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable }
    catch { throw "无法解析 $Path：$($_.Exception.Message)" }
}

# 合并 defaults 与指定视图，返回设置哈希表；视图不存在时在错误中列出可用名称。
function Merge-WpfRenderPreset($ConfigFile, [string]$PresetName) {
    $views = if ($ConfigFile.views) { $ConfigFile.views } else { @{} }
    $available = @($views.Keys) -join ', '
    if (-not $PresetName) { throw "需要 -Preset。可用视图：$available" }
    if (-not $views.ContainsKey($PresetName)) { throw "没有视图 $PresetName。可用：$available" }
    $settings = @{}
    foreach ($source in @($ConfigFile.defaults, $views[$PresetName])) {
        if (-not $source) { continue }
        foreach ($k in @($source.Keys)) { foreach ($drop in $script:PresetExclusiveKeys[$k]) { $settings.Remove($drop) } }
        foreach ($k in $source.Keys) { $settings[$k] = $source[$k] }
    }
    return $settings
}
