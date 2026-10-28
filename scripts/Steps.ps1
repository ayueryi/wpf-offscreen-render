# 交互步骤的规范化（由 new-wpf-harness.ps1 与 render.ps1 点引用）。
# 用户写法：每步一个对象，可选 name / waitMs / waitFor / timeoutMs / capture，加至多一个动作字段：
#   set / setData / invoke / command / state / focus / animate / custom（见 docs/design/interaction-steps.md）。
# 宿主（assets/Steps.cs）读取扁平结构：action + 字段；所有值统一写成不变区域字符串，JSON null 写成 clear=true。

$script:StepActions = 'set', 'setData', 'invoke', 'command', 'state', 'focus', 'animate', 'custom'
$script:StepCommonKeys = 'name', 'waitMs', 'waitFor', 'timeoutMs', 'capture'

# -Steps 可以是 JSON 数组字符串，或 JSON 文件路径。
function Read-StepsInput([string]$Steps) {
    if (-not $Steps) { return @() }
    $text = if ($Steps.TrimStart() -match '^[\[{]') { $Steps } else { Get-Content -LiteralPath (Resolve-Path -LiteralPath $Steps).ProviderPath -Raw }
    $parsed = try { ConvertFrom-Json -InputObject $text -AsHashtable -NoEnumerate } catch { throw "步骤不是合法的 JSON：$($_.Exception.Message)" }
    if ($parsed -isnot [array]) { throw '步骤应为 JSON 数组，每个元素是一步。' }
    , $parsed
}

function ConvertTo-StepValue($Value, [string]$Where) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return $(if ($Value) { 'True' } else { 'False' }) }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
    }
    throw "$Where 的值只能是字符串、数字、布尔或 null。"
}

function ConvertTo-StepElement($Element, [string]$Where) {
    if ($null -eq $Element) { return $null }
    if ($Element -is [string]) { return [ordered]@{ name = $Element } }
    if ($Element -isnot [System.Collections.IDictionary]) { throw "$Where 的 element 应为 x:Name 字符串或 { name / automationId / text / type / index } 对象。" }
    $result = [ordered]@{}
    foreach ($key in $Element.Keys) {
        if ($key -notin 'name', 'automationId', 'text', 'type', 'index') { throw "$Where 的 element 有未知字段 $key。" }
        $result[$key] = if ($key -eq 'index') { [int]$Element[$key] } else { [string]$Element[$key] }
    }
    $result
}

function ConvertTo-HarnessSteps([string]$Steps, [string]$FactoryFile) {
    $list = Read-StepsInput $Steps
    # custom 步骤由业务 ViewFactory.RunStepAsync 承接（运行时反射查找，未实现不影响编译）。
    # 错误左移：在生成宿主之前就检查工厂是否实现了它，省得用户等完整构建完才在执行时发现。
    # 判定与运行时反射同一约定、同一来源（同一份工厂文件）：内容含 RunStepAsync 即视为已实现。
    if ($list | Where-Object { $_.custom }) {
        $factorySource = if ($FactoryFile) { $FactoryFile } else { Join-Path $PSScriptRoot '..\assets\ViewFactory.cs' }
        if (-not (Test-Path -LiteralPath $factorySource)) { throw "找不到工厂文件：$factorySource" }
        $factoryText = Get-Content -LiteralPath $factorySource -Raw
        if ($factoryText -notmatch 'RunStepAsync') {
            throw "步骤里有 custom，但工厂$(if ($FactoryFile) { " $FactoryFile" } else { '（默认 ViewFactory.cs）' })没有实现 RunStepAsync。" +
                "请在工厂中实现 RunStepAsync(FrameworkElement view, string action, IReadOnlyDictionary<string, string> args)，或去掉 custom 步骤。"
        }
    }
    $index = 0
    foreach ($step in $list) {
        $index++
        if ($step -isnot [System.Collections.IDictionary]) { throw "第 $index 步不是对象。" }
        $where = "第 $index 步$(if ($step.name) { "（$($step.name)）" })"
        $unknown = @($step.Keys | Where-Object { $_ -notin $script:StepActions -and $_ -notin $script:StepCommonKeys })
        if ($unknown) { throw "${where}有未知字段：$($unknown -join ', ')。动作字段为 $($script:StepActions -join ' / ')。" }
        $actions = @($step.Keys | Where-Object { $_ -in $script:StepActions })
        if ($actions.Count -gt 1) { throw "${where}只能有一个动作字段，实际：$($actions -join ', ')。" }

        $out = [ordered]@{}
        if ($step.name) { $out.name = [string]$step.name }
        if ($actions.Count -eq 1) {
            $action = $actions[0]
            $out.action = $action
            $p = $step[$action]
            if ($action -eq 'focus' -or $action -eq 'invoke') {
                # 简写："invoke": "SubmitButton"
                if ($p -is [string]) { $p = @{ element = $p } }
            }
            if ($p -isnot [System.Collections.IDictionary]) { throw "${where}的 $action 应为对象。" }
            $allowed = switch ($action) {
                'set' { 'element', 'property', 'value' }
                'setData' { 'path', 'value' }
                'invoke' { 'element' }
                'command' { 'element', 'path', 'parameter' }
                'state' { 'element', 'state' }
                'focus' { 'element' }
                'animate' { 'element', 'storyboard', 'trigger', 'atMs' }
                'custom' { 'action', 'args' }
            }
            $extra = @($p.Keys | Where-Object { $_ -notin $allowed })
            if ($extra) { throw "${where}的 $action 有未知字段：$($extra -join ', ')（可用：$($allowed -join ', ')）。" }
            $need = switch ($action) {
                'set' { 'element', 'property', 'value' }
                'setData' { 'path', 'value' }
                'invoke' { 'element' }
                'state' { 'element', 'state' }
                'focus' { 'element' }
                'custom' { 'action' }
                default { @() }
            }
            foreach ($key in $need) { if (-not $p.ContainsKey($key)) { throw "${where}的 $action 缺少 $key。" } }
            if ($action -eq 'command' -and -not ($p.ContainsKey('element') -xor $p.ContainsKey('path'))) { throw "${where}的 command 需要 element 或 path 之一。" }
            if ($action -eq 'animate' -and -not ($p.ContainsKey('storyboard') -xor $p.ContainsKey('trigger'))) { throw "${where}的 animate 需要 storyboard 或 trigger 之一。" }

            if ($p.ContainsKey('element')) { $out.element = ConvertTo-StepElement $p.element $where }
            foreach ($key in 'property', 'path', 'state', 'storyboard', 'trigger') { if ($p.ContainsKey($key)) { $out[$key] = [string]$p[$key] } }
            if ($p.ContainsKey('parameter')) { $out.parameter = ConvertTo-StepValue $p.parameter "${where}的 parameter" }
            if ($p.ContainsKey('value')) {
                if ($null -eq $p.value) { $out.clear = $true } else { $out.value = ConvertTo-StepValue $p.value "${where}的 value" }
            }
            if ($p.ContainsKey('atMs')) { $out.atMs = @($p.atMs | ForEach-Object { [int]$_ }) }
            if ($action -eq 'custom') {
                $out.action = 'custom'
                $out.customAction = [string]$p.action
                $out.args = @(if ($p.args) {
                        if ($p.args -isnot [System.Collections.IDictionary]) { throw "${where}的 custom.args 应为对象。" }
                        foreach ($key in $p.args.Keys) { [ordered]@{ key = [string]$key; value = ConvertTo-StepValue $p.args[$key] "${where}的 args.$key" } }
                    })
            }
        }
        foreach ($key in 'waitMs', 'timeoutMs') { if ($step.ContainsKey($key)) { $out[$key] = [int]$step[$key] } }
        if ($step.ContainsKey('waitFor')) { $out.waitFor = [string]$step.waitFor }
        if ($step.ContainsKey('capture')) { $out.capture = [bool]$step.capture }
        $out
    }
}
