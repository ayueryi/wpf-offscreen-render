#requires -Version 7.0
# 技术栈判定与 Avalonia 宿主推断的单一 module。
# 判定：显式 -Stack 优先；未指定时按程序集的 AssemblyRef 识别 Avalonia / WPF，两者同时出现则报错。
# Avalonia 宿主：TFM 跟随业务程序集（不低于 net8.0）；包版本按业务程序集引用的主版本选基线，
# 同一主版本内跟随更高的引用版本。
. (Join-Path $PSScriptRoot 'HostFrameworks.ps1')

# 每个主版本钉一个已验证的包版本；未列出的主版本明确拒绝。
# 12 已用 12.0.1 / 12.1.0 / 12.1.4 的真实业务视图验证，宿主源码同时兼容 11 / 12。
$script:AvaloniaHostBaselines = [ordered]@{
    '11' = [version]'11.3.22'
    '12' = [version]'12.1.4'
}
# 没有业务程序集（纯松散 AXAML）时的默认主版本：跟随当前稳定版。
$script:AvaloniaDefaultMajor = 12

# 读取程序集的 AssemblyRef 名称与版本，不加载程序集。
function Get-AssemblyReferences([string]$Path) {
    $stream = [IO.File]::OpenRead((Resolve-Path -LiteralPath $Path).ProviderPath)
    try {
        $pe = [Reflection.PortableExecutable.PEReader]::new($stream)
        try {
            if (-not $pe.HasMetadata) { return @() }
            $reader = [Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($pe)
            foreach ($handle in $reader.AssemblyReferences) {
                $reference = $reader.GetAssemblyReference($handle)
                [pscustomobject]@{ Name = $reader.GetString($reference.Name); Version = $reference.Version }
            }
        }
        finally { $pe.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Get-AgentRenderStack([string[]]$AssemblyPath, [string]$RequestedStack) {
    if ($RequestedStack) {
        $requested = $RequestedStack.ToLowerInvariant()
        if ($requested -notin 'wpf', 'avalonia') { throw "未知的技术栈 $RequestedStack：只支持 wpf、avalonia。" }
        return $requested
    }
    $avalonia = [Collections.Generic.List[string]]::new()
    $wpf = [Collections.Generic.List[string]]::new()
    foreach ($path in $AssemblyPath) {
        $names = @(Get-AssemblyReferences $path | ForEach-Object Name)
        if ($names | Where-Object { $_ -match '^Avalonia(\.|$)' }) { $avalonia.Add($path) }
        # 只看 PresentationFramework：WindowsBase 等被很多非 UI 库引用，不能作为 WPF 的依据。
        if ($names -contains 'PresentationFramework') { $wpf.Add($path) }
    }
    if ($avalonia.Count -gt 0 -and $wpf.Count -gt 0) {
        throw "-AssemblyPath 同时引用了 Avalonia（$($avalonia -join '、')）与 WPF（$($wpf -join '、')），无法判定技术栈：请分别渲染，或用 -Stack 显式指定。"
    }
    if ($avalonia.Count -gt 0) { return 'avalonia' }
    'wpf'
}

# 推断 Avalonia 宿主的 TFM / 位数 / Avalonia 包版本。显式 TFM 不能低于业务程序集所需版本。
function Get-AvaloniaHostInfo([string[]]$AssemblyPath, [string]$TargetFramework, [string]$Platform) {
    $targets = @(foreach ($assembly in $AssemblyPath) {
            $resolved = (Resolve-Path -LiteralPath $assembly).ProviderPath
            if ([IO.Path]::GetExtension($resolved) -notin '.dll', '.exe') { throw "需要 DLL / EXE 引用：$resolved" }
            Get-AssemblyTarget $resolved
        })

    $required = $null
    foreach ($target in $targets) {
        $info = ConvertTo-FrameworkInfo $target.Framework
        if (-not $info) { continue }
        if ($info.Family -eq 'framework') {
            throw "$($target.Path) 面向 $($target.Framework)：Avalonia 宿主运行在 .NET 8 及以上，不能加载 .NET Framework 程序集。"
        }
        if (-not $required -or $info.Version -gt $required.Version) { $required = $info }
    }
    $minimumMajor = 8
    if ($TargetFramework) {
        if ($TargetFramework -notmatch '^net([5-9]|[1-9][0-9])\.0$') { throw "Avalonia 宿主只支持不带 -windows 的 net5.0 及以上 TFM：$TargetFramework" }
        if ($required -and [int]$Matches[1] -lt $required.Version.Major) {
            throw "-TargetFramework $TargetFramework 不能引用面向 $($required.Display) 的业务程序集；省略该参数可自动推断。"
        }
    }
    else { $TargetFramework = 'net{0}.0' -f [math]::Max($minimumMajor, $(if ($required) { $required.Version.Major } else { 0 })) }

    $platforms = @($targets.Platform | Where-Object { $_ -and $_ -ne 'AnyCPU' } | Select-Object -Unique)
    if ($platforms.Count -gt 1) { throw "-AssemblyPath 的位数要求冲突：$($platforms -join ', ')" }
    if ($Platform) {
        if ($platforms.Count -eq 1 -and $Platform -ne $platforms[0]) { throw "-Platform $Platform 与业务程序集要求的 $($platforms[0]) 不一致。" }
    }
    else { $Platform = if ($platforms.Count -eq 1) { $platforms[0] } else { 'AnyCPU' } }

    # Avalonia 包版本：按业务程序集引用的主版本选基线；同一主版本内跟随更高的引用版本。
    $references = @(foreach ($assembly in $AssemblyPath) {
            $base = Get-AssemblyReferences $assembly | Where-Object Name -eq 'Avalonia.Base' | Select-Object -First 1
            if (-not $base) { continue }
            [pscustomobject]@{
                Path = $assembly
                Version = [version]::new($base.Version.Major, $base.Version.Minor, [math]::Max($base.Version.Build, 0))
            }
        })
    $majors = @($references | ForEach-Object { $_.Version.Major } | Select-Object -Unique)
    if ($majors.Count -gt 1) {
        throw "-AssemblyPath 同时引用了 Avalonia $(($majors | Sort-Object) -join ' 与 ').x（$($references.Path -join '、')）：一个宿主只能使用一个主版本，请分别渲染。"
    }
    $major = if ($majors.Count -eq 1) { "$($majors[0])" } else { "$($script:AvaloniaDefaultMajor)" }
    if (-not $script:AvaloniaHostBaselines.Contains($major)) {
        throw "宿主只支持 Avalonia $(($script:AvaloniaHostBaselines.Keys | Sort-Object) -join ' / ').x：业务程序集引用了 Avalonia $major.x。"
    }
    $package = $script:AvaloniaHostBaselines[$major]
    foreach ($reference in $references) {
        if ($reference.Version -gt $package) { $package = $reference.Version }
    }
    [pscustomobject]@{ TargetFramework = $TargetFramework; Platform = $Platform; AvaloniaVersion = $package.ToString() }
}
