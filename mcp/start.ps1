#requires -Version 7.0
# MCP 服务器启动器（Codex、Claude Code 等的 MCP 配置都指向这里）。
# 首次运行或源码变化后，把 mcp/WpfRenderMcp 编译到本机缓存目录；之后直接启动编译好的服务器。
# stdout 专用于 MCP 协议：编译输出全部转到 stderr；服务器用 Start-Process -NoNewWindow 直接继承 stdin / stdout 句柄，
# 不经过 PowerShell 管道，避免协议数据被转码或缓冲。
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $PSScriptRoot 'WpfRenderMcp'

# 源码哈希决定缓存目录，更新插件后自动重新编译。
$files = Get-ChildItem -LiteralPath $source -File -Recurse |
    Where-Object { $_.Extension -in '.cs', '.csproj' -and $_.FullName -notmatch '[\\/](bin|obj)[\\/]' } | Sort-Object FullName
$hashInput = ($files | ForEach-Object { $_.FullName.Substring($source.Length) + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }) -join "`n"
$hash = (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($hashInput))) -Algorithm SHA256).Hash.Substring(0, 16).ToLowerInvariant()
$cacheRoot = if ($env:WPF_RENDER_MCP_CACHE) { $env:WPF_RENDER_MCP_CACHE }
    elseif ($IsWindows) { Join-Path $env:LOCALAPPDATA 'wpf-offscreen-render\mcp' }
    else { Join-Path ([IO.Path]::GetTempPath()) 'wpf-offscreen-render-mcp' }
$outDir = Join-Path $cacheRoot $hash
$server = Join-Path $outDir 'WpfRenderMcp.dll'

if (-not (Test-Path -LiteralPath $server)) {
    # 多个代理会话同时启动时只编译一次。
    $mutex = [Threading.Mutex]::new($false, "Local\wpf-render-mcp-build-$hash")
    try {
        try { $null = $mutex.WaitOne([TimeSpan]::FromMinutes(10)) } catch [Threading.AbandonedMutexException] { }
        if (-not (Test-Path -LiteralPath $server)) {
            # 在缓存目录内的源码副本上编译，不在插件目录（可能只读或被多个版本共享）里写 obj / bin。
            $buildSource = Join-Path $cacheRoot "$hash-src"
            if (Test-Path -LiteralPath $buildSource) { Remove-Item -LiteralPath $buildSource -Recurse -Force }
            $null = New-Item -ItemType Directory -Path $buildSource -Force
            foreach ($file in $files) {
                $target = Join-Path $buildSource $file.FullName.Substring($source.Length + 1)
                $null = New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force
                Copy-Item -LiteralPath $file.FullName -Destination $target
            }
            [Console]::Error.WriteLine("wpf-offscreen-render：首次启动，正在编译 MCP 服务器到 $outDir …")
            & dotnet build (Join-Path $buildSource 'WpfRenderMcp.csproj') -c Release --nologo -o $outDir 2>&1 |
                ForEach-Object { [Console]::Error.WriteLine("$_") }
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $server)) {
                if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force -ErrorAction SilentlyContinue }
                [Console]::Error.WriteLine('wpf-offscreen-render：MCP 服务器编译失败，见上方输出（需要 .NET 8 或更高版本的 SDK）。')
                exit 1
            }
            Remove-Item -LiteralPath $buildSource -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    finally {
        try { $mutex.ReleaseMutex() } catch [ApplicationException] { }
        $mutex.Dispose()
    }
}

# Start-Process 拼接参数时不加引号，路径可能含空格（如用户目录），因此手动加引号。
$process = Start-Process -FilePath 'dotnet' -ArgumentList "`"$server`" --root `"$root`"" -NoNewWindow -PassThru -Wait
exit $process.ExitCode
