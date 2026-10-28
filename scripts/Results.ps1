#requires -Version 7.0
# 渲染结果读取的单一 module（契约只在这一处定义）：
# render.ps1 的输出目录里有两种结果形态——多组合的 matrix.json（results 数组）与单组合的 summary.json。
# 之前 hook、MCP 服务器、测试各自解析这两种形态；现在全部经 Read-WpfRenderResult 拿统一的 items 数组。
# 返回：
#   kind  = 'matrix' | 'render'
#   items = matrix 时为 results[]（每项含 theme / size / dpi / outDir），单结果时为长度 1 的数组（即 summary）
#   raw   = 原始 JSON 对象（matrix 的 overview / exitCode 等元数据从这里取）
# 目录里两份文件都没有，或 JSON 残缺时抛错：调用方按渲染失败处理，不做格式容错。
function Read-WpfRenderResult([string]$OutDir) {
    if (-not (Test-Path -LiteralPath $OutDir -PathType Container)) { throw "渲染输出目录不存在：$OutDir" }
    $matrixPath = Join-Path $OutDir 'matrix.json'
    if (Test-Path -LiteralPath $matrixPath) {
        $matrix = Get-Content -LiteralPath $matrixPath -Raw | ConvertFrom-Json
        # @($null) 是含一个 null 的数组而不是空数组：results 缺失时过滤掉，调用方看到的是「没有结果」。
        return [pscustomobject]@{ kind = 'matrix'; items = @($matrix.results | Where-Object { $_ }); raw = $matrix }
    }
    $summaryPath = Join-Path $OutDir 'summary.json'
    if (-not (Test-Path -LiteralPath $summaryPath)) { throw "$OutDir 里没有 matrix.json 或 summary.json（渲染是否失败？）" }
    $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
    return [pscustomobject]@{ kind = 'render'; items = @($summary); raw = $summary }
}

# 结果项的统一标签：matrix 项标「[视图 主题 尺寸 DPI]」，单结果标「[视图]」——hook 与测试的错误前缀共用。
function Get-WpfRenderItemLabel($Raw, $Item, [string]$Name) {
    if ($Raw.results) { "[$Name $($Item.theme) $($Item.size) $($Item.dpi)DPI]" }
    else { "[$Name]" }
}
