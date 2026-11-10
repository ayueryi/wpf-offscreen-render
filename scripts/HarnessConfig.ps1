# harness.json 的唯一写入形状。new-agent-harness.ps1 与 render.ps1 的缓存路径都走这里，避免两边各写一遍十一个键。
function Write-HarnessConfig {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Stack,
        [string]$ViewType,
        [string]$Xaml,
        [string]$DataContextType,
        [string]$DataContextFactory,
        [string[]]$ResourceDictionary = @(),
        # 业务程序集的完整路径；写入时只留文件名（不含扩展名）。
        [string[]]$AssemblyPath = @(),
        $Steps,
        [bool]$ContinueOnError,
        [string]$Animations
    )
    $config = [ordered]@{
        stack = $Stack
        viewType = if ($ViewType) { $ViewType } else { $null }
        xaml = if ($Xaml) { $Xaml } else { $null }
        dataContextType = if ($DataContextType) { $DataContextType } else { $null }
        dataContextFactory = if ($DataContextFactory) { $DataContextFactory } else { $null }
        resourceDictionaries = @($ResourceDictionary)
        assemblies = @($AssemblyPath | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) })
        steps = $Steps
        continueOnError = [bool]$ContinueOnError
        animations = $Animations
    }
    [IO.File]::WriteAllText($Path, ($config | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}
