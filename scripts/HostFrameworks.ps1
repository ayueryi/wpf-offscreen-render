#requires -Version 7.0
# 宿主 TFM 与位数推断的单一 module（语义只在这一处定义）。
# 从 new-wpf-harness.ps1 抽出：宿主能否加载业务程序集取决于这段规则（net4x 三段版本回落、
# I386+ILOnly-Requires32Bit→AnyCPU、Framework 与 Core 不得混载），它值得独立测试——
# 以前只能靠三个 fixtures 变体跑完整渲染间接验证。

# 读取程序集的 TargetFrameworkAttribute（如 .NETFramework,Version=v4.7.2）与位数要求，不加载程序集。
function Get-AssemblyTarget([string]$Path) {
    Add-Type -AssemblyName System.Reflection.Metadata
    $stream = [IO.File]::OpenRead($Path)
    $pe = [Reflection.PortableExecutable.PEReader]::new($stream)
    try {
        if (-not $pe.HasMetadata) { throw "不是托管程序集：$Path" }
        $headers = $pe.PEHeaders
        $flags = $headers.CorHeader.Flags
        $platform = switch ($headers.CoffHeader.Machine) {
            'Amd64' { 'x64' }
            'Arm64' { 'ARM64' }
            'I386' {
                # 纯 IL 且不要求 32 位为 AnyCPU。x86 编译、C++/CLI 混合程序集，以及"首选 32 位"的 exe
                # （VS 中 .NET Framework 程序的默认设置，业务程序实际以 32 位运行）都用 32 位宿主。
                $ilOnly = $flags.HasFlag([Reflection.PortableExecutable.CorFlags]::ILOnly)
                $requires32 = $flags.HasFlag([Reflection.PortableExecutable.CorFlags]::Requires32Bit)
                if ($ilOnly -and -not $requires32) { 'AnyCPU' } else { 'x86' }
            }
            default { 'AnyCPU' }
        }
        $reader = [Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($pe)
        $framework = $null
        foreach ($handle in $reader.GetAssemblyDefinition().GetCustomAttributes()) {
            $attribute = $reader.GetCustomAttribute($handle)
            if ($attribute.Constructor.Kind -ne [Reflection.Metadata.HandleKind]::MemberReference) { continue }
            $ctor = $reader.GetMemberReference([Reflection.Metadata.MemberReferenceHandle]$attribute.Constructor)
            if ($ctor.Parent.Kind -ne [Reflection.Metadata.HandleKind]::TypeReference) { continue }
            $type = $reader.GetTypeReference([Reflection.Metadata.TypeReferenceHandle]$ctor.Parent)
            if ($reader.GetString($type.Name) -ne 'TargetFrameworkAttribute') { continue }
            $blob = $reader.GetBlobReader($attribute.Value)
            if ($blob.ReadUInt16() -eq 1) { $framework = $blob.ReadSerializedString() }
            break
        }
        [pscustomobject]@{ Path = $Path; Framework = $framework; Platform = $platform }
    }
    finally { $pe.Dispose(); $stream.Dispose() }
}

# 统一成 Family（framework / core）+ 三段版本号，便于比较兼容性。
function ConvertTo-FrameworkInfo([string]$Value) {
    if ($Value -match '^net4(\d)(\d)?$') {
        $patch = if ($Matches[2]) { [int]$Matches[2] } else { 0 }
        return [pscustomobject]@{ Family = 'framework'; Version = [version]::new(4, [int]$Matches[1], $patch); Display = $Value }
    }
    if ($Value -match '^net(\d+)\.0-windows') {
        return [pscustomobject]@{ Family = 'core'; Version = [version]::new([int]$Matches[1], 0, 0); Display = $Value }
    }
    if ($Value -match '^\.NET(Framework|CoreApp),Version=v(\d+)\.(\d+)(?:\.(\d+))?') {
        $family = if ($Matches[1] -eq 'Framework') { 'framework' } else { 'core' }
        $patch = if ($Matches[4]) { [int]$Matches[4] } else { 0 }
        return [pscustomobject]@{ Family = $family; Version = [version]::new([int]$Matches[2], [int]$Matches[3], $patch); Display = $Value }
    }
    $null # .NETStandard 或未标注：两类宿主都可引用，不参与推断
}

# 从业务程序集推断宿主的 TFM 与位数。显式传入时校验其可引用性（引不了就报错，不让构建到一半才失败）。
function Get-HostFrameworks([string[]]$AssemblyPath, [string]$TargetFramework, [string]$Platform) {
    $targets = foreach ($assembly in $AssemblyPath) {
        $resolved = (Resolve-Path -LiteralPath $assembly).ProviderPath
        if ([IO.Path]::GetExtension($resolved) -notin '.dll', '.exe') { throw "需要 DLL / EXE 引用：$resolved" }
        Get-AssemblyTarget $resolved
    }

    # 宿主必须与业务程序集同属 .NET Framework 或 .NET，且版本不低于其中最高者。
    $required = $null
    foreach ($target in $targets) {
        $info = ConvertTo-FrameworkInfo $target.Framework
        if (-not $info) { continue }
        if ($info.Family -eq 'core' -and $info.Version.Major -lt 5) {
            throw "$($target.Path) 面向 $($target.Framework)，WPF 宿主仅支持 .NET 5 及以上或 .NET Framework 4.7.2 及以上。"
        }
        if ($required -and $required.Family -ne $info.Family) {
            throw '-AssemblyPath 同时包含 .NET Framework 与 .NET 程序集，不能在同一宿主中加载。'
        }
        if (-not $required -or $info.Version -gt $required.Version) { $required = $info }
    }
    if ($TargetFramework) {
        $chosen = ConvertTo-FrameworkInfo $TargetFramework
        if ($required -and ($required.Family -ne $chosen.Family -or $chosen.Version -lt $required.Version)) {
            throw "-TargetFramework $TargetFramework 不能引用面向 $($required.Display) 的业务程序集；省略该参数可自动推断。"
        }
    }
    elseif (-not $required) { $TargetFramework = 'net8.0-windows' }
    elseif ($required.Family -eq 'framework') {
        # 低于 4.7.2 的程序集可由 net472 宿主引用。
        $TargetFramework = if ($required.Version -lt [version]'4.7.2') { 'net472' }
            else { 'net4' + $required.Version.Minor + $(if ($required.Version.Build -gt 0) { $required.Version.Build }) }
    }
    else { $TargetFramework = "net$($required.Version.Major).0-windows" }

    $platforms = @($targets.Platform | Where-Object { $_ -ne 'AnyCPU' } | Select-Object -Unique)
    if ($platforms.Count -gt 1) { throw "-AssemblyPath 的位数要求冲突：$($platforms -join ', ')" }
    if ($Platform) {
        if ($platforms.Count -eq 1 -and $Platform -ne $platforms[0]) { throw "-Platform $Platform 与业务程序集要求的 $($platforms[0]) 不一致。" }
    }
    else { $Platform = if ($platforms.Count -eq 1) { $platforms[0] } else { 'AnyCPU' } }

    [pscustomobject]@{ TargetFramework = $TargetFramework; Platform = $Platform }
}
