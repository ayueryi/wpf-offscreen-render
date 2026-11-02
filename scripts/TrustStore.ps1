# 业务项目授权记录（由 hooks/verify-on-stop.ps1 与 scripts/trust-project.ps1 点引用）。
# Stop hook 会执行 wpf-render.json 中的 build 命令并运行业务程序集，因此只对用户显式授权的配置生效。
# 授权保存在仓库之外，并绑定配置文件内容的哈希：配置被修改（例如 build 命令变化）后需要重新授权。

function Get-TrustStorePath {
    if ($env:AGENT_RENDER_TRUST_FILE) { return $env:AGENT_RENDER_TRUST_FILE }
    if ($env:WPF_RENDER_TRUST_FILE) { return $env:WPF_RENDER_TRUST_FILE }
    $base = if ($IsWindows) { $env:LOCALAPPDATA } else { Join-Path $HOME '.local/share' }
    Join-Path $base 'agent-render/trusted-projects.json'
}

function Get-ConfigIdentity([string]$ConfigPath) {
    $full = (Resolve-Path -LiteralPath $ConfigPath).ProviderPath
    [pscustomobject]@{
        Config = $full.Replace('\', '/')
        Sha256 = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
    }
}

# 业务配置文件名：优先 agent-render.json，兼容旧的 wpf-render.json（授权按配置路径记录，两者各自独立）。
$script:ConfigFileNames = @('agent-render.json', 'wpf-render.json')

function Find-ConfigFile([string]$Directory) {
    foreach ($name in $script:ConfigFileNames) {
        $candidate = Join-Path $Directory $name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $null
}

# 插件改名前的授权库位置。默认位置的新库不存在时一次性迁入（记录绑定配置内容哈希，迁移不放宽授权）。
function Move-LegacyTrustStore([string]$NewPath) {
    if ($env:AGENT_RENDER_TRUST_FILE -or $env:WPF_RENDER_TRUST_FILE) { return }
    $legacy = Join-Path (Split-Path -Parent (Split-Path -Parent $NewPath)) 'wpf-offscreen-render/trusted-projects.json'
    if ((Test-Path -LiteralPath $NewPath) -or -not (Test-Path -LiteralPath $legacy)) { return }
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $NewPath) -Force
    Copy-Item -LiteralPath $legacy -Destination $NewPath
}

function Read-TrustStore {
    $path = Get-TrustStorePath
    Move-LegacyTrustStore $path
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
