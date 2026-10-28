#requires -Version 7.0
# 宿主缓存的键、构建戳与过期清理 —— render.ps1 使用，缓存策略只在这里定义。
# 策略：同一组 程序集路径 + TFM + 位数 + 工具版本 复用 %TEMP%\wpf-render-cache 下的同一宿主；
# 缓存目录名为 16 位十六进制键；同一键的并发渲染由 Local\wpf-render-<键> 互斥量保护（render.ps1 持有）。

# 工具版本键：生成器与 assets 宿主模板的内容哈希，加 TFM / 位数 / 工厂 / 程序集。模板更新后自动换新缓存。
function Get-WpfRenderCacheKey([string]$GeneratorPath, [string]$AssetsDir,
    [string]$TargetFramework, [string]$Platform, [string]$FactoryFile, [string[]]$AssemblyPaths) {
    $toolFiles = @($GeneratorPath) + @(Get-ChildItem -LiteralPath $AssetsDir -Filter '*.cs' | Sort-Object Name | ForEach-Object FullName)
    $keySource = [Text.StringBuilder]::new()
    foreach ($file in $toolFiles) { $null = $keySource.AppendLine((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash) }
    $null = $keySource.AppendLine("tfm=$TargetFramework;platform=$Platform;factory=$("$FactoryFile".ToLowerInvariant())")
    foreach ($assembly in $AssemblyPaths | Sort-Object) { $null = $keySource.AppendLine($assembly.ToLowerInvariant()) }
    $keyStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($keySource.ToString()))
    (Get-FileHash -InputStream $keyStream -Algorithm SHA256).Hash.Substring(0, 16).ToLowerInvariant()
}

# 构建会连同依赖一起复制，所以记录业务程序集所在目录中全部 dll / exe 的大小与修改时间；
# ViewFactory.cs 编进宿主：内容变化时需要重新构建。
function Get-WpfRenderBuildStamps([string[]]$AssemblyPaths, [string]$FactorySource) {
    @($AssemblyPaths | ForEach-Object { Split-Path -Parent $_ } | Sort-Object -Unique |
        ForEach-Object { Get-ChildItem -LiteralPath $_ -File | Where-Object Extension -in '.dll', '.exe' } |
        Sort-Object FullName | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" }) +
    "factory|$((Get-FileHash -LiteralPath $FactorySource -Algorithm SHA256).Hash)"
}

# 清理过期缓存与渲染结果。只删除能立即拿到互斥量的目录：拿不到说明另一个进程正在使用它。
# 只处理本工具创建的缓存目录（16 位十六进制名称且含 cache.json 或 RenderHarness.csproj）：-CacheRoot 可能指向共享目录。
function Remove-ExpiredWpfRenderCache([string]$CacheRoot, [string]$CurrentWorkDir, [int]$RetentionDays) {
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    foreach ($dir in Get-ChildItem -LiteralPath $CacheRoot -Directory) {
        if ($dir.FullName -eq $CurrentWorkDir -or $dir.Name -notmatch '^[0-9a-f]{16}$') { continue }
        $stamp = Join-Path $dir.FullName 'cache.json'
        $hasStamp = Test-Path -LiteralPath $stamp
        if (-not $hasStamp -and -not (Test-Path -LiteralPath (Join-Path $dir.FullName 'RenderHarness.csproj'))) { continue }
        $lastUsed = if ($hasStamp) { (Get-Item -LiteralPath $stamp).LastWriteTime } else { $dir.LastWriteTime }
        if ($lastUsed -ge $cutoff) { continue }
        $lock = [Threading.Mutex]::new($false, "Local\wpf-render-$($dir.Name)")
        try {
            $acquired = try { $lock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $true }
            if ($acquired) {
                try { Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue }
                finally { $lock.ReleaseMutex() }
            }
        }
        finally { $lock.Dispose() }
    }
    Get-ChildItem -LiteralPath $CurrentWorkDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'render-*' -or $_.Name -like 'matrix-*' } |
        Where-Object { $_.LastWriteTime -lt $cutoff } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}
