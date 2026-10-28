#requires -Version 7.0
# 列出 wpf-render.json 中的视图（名称、合并 defaults 后的设置），供 MCP 的 list_views 调用。
# 合并规则来自 Preset.ps1，与 render.ps1 完全一致；输出 JSON 由工具原样转发。
param(
    [string]$Config
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Preset.ps1')
$path = Resolve-WpfRenderConfig $Config
$configDir = Split-Path -Parent $path
$file = Read-WpfRenderConfigFile $path

$settings = @{}
if ($file.defaults) { foreach ($k in $file.defaults.Keys) { $settings[$k] = $file.defaults[$k] } }

$views = @()
foreach ($name in @($file.views.Keys | Sort-Object)) {
    $merged = Merge-WpfRenderPreset $file $name
    $view = [ordered]@{
        name = $name
        viewType = $merged.viewType; xaml = $merged.xaml
        themes = $merged.themes; sizes = $merged.sizes; dpis = $merged.dpis
        watch = $merged.watch; hasBuild = $null -ne $merged.build
    }
    # xaml 的相对路径解析为相对配置文件所在目录（pack URI 等保持原样），与渲染时一致；viewType 是类型名，不解析。
    if ($view.xaml -is [string]) {
        $view.xaml = if ([IO.Path]::IsPathRooted($view.xaml) -or $view.xaml -like '*;component/*' -or $view.xaml -match '^(pack|file|https?)://') {
            $view.xaml
        } else { [IO.Path]::GetFullPath((Join-Path $configDir $view.xaml)) }
    }
    $views += $view
}
[ordered]@{ config = $path; verifyOnStop = $file.verifyOnStop; views = $views } | ConvertTo-Json -Depth 6
