# 在当前 PowerShell 进程中编译 ImageTools.cs（只编译一次）。由 compare-snapshots.ps1 与 render.ps1 点引用。
# System.Drawing.Common 在新版 .NET 中依赖若干内部程序集，按实际加载位置传给 Add-Type，避免按名称引用失败。
if (-not ('WpfOffscreenRender.ImageTools' -as [type])) {
    Add-Type -AssemblyName System.Drawing.Common
    $drawing = [System.Drawing.Bitmap].Assembly
    $references = @($drawing.Location) + @($drawing.GetReferencedAssemblies() | ForEach-Object {
            try { [Reflection.Assembly]::Load($_).Location } catch { }
        }) | Where-Object { $_ } | Select-Object -Unique
    Add-Type -Path (Join-Path $PSScriptRoot 'ImageTools.cs') -ReferencedAssemblies $references
}
