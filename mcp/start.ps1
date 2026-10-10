#requires -Version 7.0
# MCP 服务器启动器（Codex、Claude Code 等的 MCP 配置都指向这里）。
# 首次运行或源码变化后，把 mcp/WpfRenderMcp 编译到本机缓存目录；之后直接启动编译好的服务器。
# stdout 专用于 MCP 协议：编译输出全部转到 stderr；服务器用 Start-Process -NoNewWindow 直接继承 stdin / stdout 句柄，
# 不经过 PowerShell 管道，避免协议数据被转码或缓冲。
# -BuildOnly：只编译不启动。首次编译（含 NuGet 还原）可能超过客户端的 MCP 启动超时，可先手动运行一次预热。
param([switch]$BuildOnly)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $PSScriptRoot 'WpfRenderMcp'

# 源码哈希决定缓存目录，更新插件后自动重新编译。按统一为 LF 的文本内容与正斜杠相对路径计算：
# 不同机器的 git 换行设置不同，同版本插件也应得到相同哈希（离线机器可直接复用拷贝来的缓存）。
$files = Get-ChildItem -LiteralPath $source -File -Recurse |
    Where-Object { $_.Extension -in '.cs', '.csproj' -and $_.FullName -notmatch '[\\/](bin|obj)[\\/]' } | Sort-Object FullName
$hashInput = ($files | ForEach-Object {
        $text = [IO.File]::ReadAllText($_.FullName).Replace("`r`n", "`n")
        $_.FullName.Substring($source.Length).Replace('\', '/') + ':' +
            (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($text))) -Algorithm SHA256).Hash
    }) -join "`n"
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
            # 源码副本与输出都用一次性目录，成功后再改名为正式目录：客户端启动超时杀掉本进程时，
            # 遗留的编译进程不会与下一次启动的编译写同一目录，也不会留下半成品被当作可用的服务器。
            $buildId = [guid]::NewGuid().ToString('N').Substring(0, 8)
            $buildSource = Join-Path $cacheRoot "$hash-src-$buildId"
            $buildOut = Join-Path $cacheRoot "$hash-tmp-$buildId"
            $null = New-Item -ItemType Directory -Path $buildSource -Force
            foreach ($file in $files) {
                $target = Join-Path $buildSource $file.FullName.Substring($source.Length + 1)
                $null = New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force
                Copy-Item -LiteralPath $file.FullName -Destination $target
            }
            # dotnet 按当前目录查找 global.json：在源码副本目录（带空 global.json）中编译，不受用户项目锁定的 SDK 影响。
            [IO.File]::WriteAllText((Join-Path $buildSource 'global.json'), '{}', [Text.UTF8Encoding]::new($false))
            [Console]::Error.WriteLine("wpf-offscreen-render：首次启动，正在编译 MCP 服务器到 $outDir …")
            Push-Location -LiteralPath $buildSource
            try {
                & dotnet build (Join-Path $buildSource 'WpfRenderMcp.csproj') -c Release --nologo -o $buildOut 2>&1 |
                    ForEach-Object { [Console]::Error.WriteLine("$_") }
                $buildCode = $LASTEXITCODE
            }
            finally { Pop-Location }
            if ($buildCode -eq 0 -and (Test-Path -LiteralPath (Join-Path $buildOut 'WpfRenderMcp.dll'))) {
                if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force } # 缺少 dll 的残缺目录
                Move-Item -LiteralPath $buildOut -Destination $outDir
            }
            Remove-Item -LiteralPath $buildSource, $buildOut -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $server)) {
                [Console]::Error.WriteLine('wpf-offscreen-render：MCP 服务器编译失败，见上方输出（需要 .NET 8 或更高版本的 SDK）。')
                exit 1
            }
        }
        # 清理被中断的编译留下的一次性目录。
        Get-ChildItem -LiteralPath $cacheRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^[0-9a-f]{16}-(src|tmp)-[0-9a-f]{8}$' -and $_.LastWriteTime -lt (Get-Date).AddDays(-1) } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    finally {
        try { $mutex.ReleaseMutex() } catch [ApplicationException] { }
        $mutex.Dispose()
    }
}

if ($BuildOnly) { [Console]::Error.WriteLine("wpf-offscreen-render：MCP 服务器已就绪：$server"); exit 0 }

# Start-Process 拼接参数时不加引号，路径可能含空格（如用户目录），因此手动加引号。
# 不用 -Wait：它会等待全部子孙进程（渲染时 dotnet build 留下的 MSBuild 节点、编译服务器），服务器退出后启动器仍不退出。
$process = Start-Process -FilePath 'dotnet' -ArgumentList "`"$server`" --root `"$root`"" -NoNewWindow -PassThru
$null = $process.Handle # 先取得句柄，进程退出后才能读到 ExitCode
$process.WaitForExit()
exit $process.ExitCode
