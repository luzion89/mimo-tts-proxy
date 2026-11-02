# Windows 一键启动: 本地代理 + Cloudflare 公网隧道
# 用法: powershell -ExecutionPolicy Bypass -File .\start.ps1
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

if (-not (Test-Path .env)) {
    throw "缺少 .env, 请先复制 .env.example 为 .env 并填写 MIMO_API_KEY"
}

# 读取端口
$port = 8787
Get-Content .env | ForEach-Object {
    if ($_ -match '^\s*PORT\s*=\s*(\d+)') { $port = [int]$Matches[1] }
}

# PROXY_API_KEY 为空时本地随机生成并写入 .env
$envText = Get-Content .env -Raw
if ($envText -notmatch '(?m)^\s*PROXY_API_KEY\s*=\s*\S+') {
    $key = & python -c "import secrets; print(secrets.token_urlsafe(24))"
    if ($envText -match '(?m)^\s*PROXY_API_KEY\s*=.*$') {
        $envText = [regex]::Replace($envText, '(?m)^\s*PROXY_API_KEY\s*=.*$', "PROXY_API_KEY=$key")
    } else {
        $envText = $envText.TrimEnd() + "`nPROXY_API_KEY=$key`n"
    }
    Set-Content .env $envText -NoNewline
    Write-Host "已本地生成新的 PROXY_API_KEY 并写入 .env"
}

# 虚拟环境与依赖
$py = ".\.venv\Scripts\python.exe"
if (-not (Test-Path $py)) { python -m venv .venv }
& $py -m pip install -q -r requirements.txt

# 停掉占用端口的旧 uvicorn
Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty OwningProcess -Unique |
    ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }

$srv = Start-Process -FilePath (Resolve-Path $py) -ArgumentList "-m","uvicorn","server:app","--host","127.0.0.1","--port",$port `
    -WorkingDirectory $PSScriptRoot -WindowStyle Hidden `
    -RedirectStandardOutput "server.log" -RedirectStandardError "server.err.log" -PassThru
$srv.Id | Set-Content server.pid
Start-Sleep -Seconds 3

try { Invoke-RestMethod "http://127.0.0.1:$port/health" -TimeoutSec 10 | Out-Null }
catch { throw "服务启动失败, 查看 server.err.log" }
Write-Host "本地服务已启动: http://127.0.0.1:$port"

# 定位 cloudflared
$cfExe = (Get-Command cloudflared -ErrorAction SilentlyContinue).Source
if (-not $cfExe) {
    $fallback = "C:\Program Files (x86)\cloudflared\cloudflared.exe"
    if (Test-Path $fallback) { $cfExe = $fallback }
}
if (-not $cfExe) {
    Write-Warning "未找到 cloudflared, 仅本地可用。安装: winget install Cloudflare.cloudflared"
} else {
    # 停掉旧隧道
    Get-Process cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $cf = Start-Process -FilePath $cfExe `
        -ArgumentList "tunnel","--url","http://127.0.0.1:$port" -WindowStyle Hidden `
        -RedirectStandardOutput "tunnel.out.log" -RedirectStandardError "tunnel.log" -PassThru
    $cf.Id | Set-Content cloudflared.pid
}

$url = $null
if ($cfExe) {
    for ($i = 0; $i -lt 40; $i++) {
        $txt = Get-Content tunnel.log -Raw -ErrorAction SilentlyContinue
        if ($txt -match 'https://[a-z0-9-]+\.trycloudflare\.com') { $url = $Matches[0]; break }
        Start-Sleep -Seconds 1
    }
}

$proxyKey = (Get-Content .env | Where-Object { $_ -match '^\s*PROXY_API_KEY\s*=' } | Select-Object -Last 1) -replace '^\s*PROXY_API_KEY\s*=\s*',''
Write-Host "=============================================="
Write-Host "公网地址:      $(if ($url) { $url } else { '获取失败, 查看 tunnel.log' })"
Write-Host "AnxReader URL: $(if ($url) { "$url/v1/audio/speech" })"
Write-Host "App API Key:   $proxyKey"
Write-Host "=============================================="
