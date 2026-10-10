# 业务项目授权记录（由 hooks/verify-on-stop.ps1 与 scripts/trust-project.ps1 点引用）。
# Stop hook 会执行 wpf-render.json 中的 build 命令并运行业务程序集，因此只对用户显式授权的配置生效。
# 授权保存在仓库之外，并绑定配置文件内容的哈希：配置被修改（例如 build 命令变化）后需要重新授权。

function Get-TrustStorePath {
    if ($env:WPF_RENDER_TRUST_FILE) { return $env:WPF_RENDER_TRUST_FILE }
    $base = if ($IsWindows) { $env:LOCALAPPDATA } else { Join-Path $HOME '.local/share' }
    Join-Path $base 'wpf-offscreen-render/trusted-projects.json'
}

function Get-ConfigIdentity([string]$ConfigPath) {
    $full = (Resolve-Path -LiteralPath $ConfigPath).Path
    [pscustomobject]@{
        Config = $full.Replace('\', '/')
        Sha256 = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
    }
}

function Read-TrustStore {
    $path = Get-TrustStorePath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try { @((Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).projects | Where-Object { $_ }) } catch { @() }
}

function Write-TrustStore($Projects) {
    $path = Get-TrustStorePath
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
    $json = [ordered]@{ projects = @($Projects) } | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText($path, $json, [Text.UTF8Encoding]::new($false))
}

# 返回 trusted / changed（授权后配置被修改） / untrusted。
function Get-ProjectTrust([string]$ConfigPath) {
    $identity = Get-ConfigIdentity $ConfigPath
    $entry = Read-TrustStore | Where-Object { $_.config -ieq $identity.Config } | Select-Object -First 1
    if (-not $entry) { 'untrusted' } elseif ($entry.sha256 -eq $identity.Sha256) { 'trusted' } else { 'changed' }
}
