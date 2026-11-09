# Windows 一键启动: 本地代理 + 公网访问
# 公网优先使用 Tailscale Funnel(固定地址), 未配置时回退到 Cloudflare 快速隧道
# 用法: powershell -ExecutionPolicy Bypass -File .\start.ps1
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

if (-not (Test-Path .env)) {
    throw "缺少 .env, 请先复制 .env.example 为 .env 并填写 MIMO_API_KEY"
}

# 读取端口
$port = 8787
Get-Content .env -Encoding UTF8 | ForEach-Object {
    if ($_ -match '^\s*PORT\s*=\s*(\d+)') { $port = [int]$Matches[1] }
}

# PROXY_API_KEY 为空时本地随机生成并写入 .env
# 注意: 必须显式按 UTF-8 读写, 否则 Windows PowerShell 5.1 会按 ANSI 解码中文注释并破坏文件
$envText = Get-Content .env -Raw -Encoding UTF8
if ($envText -notmatch '(?m)^\s*PROXY_API_KEY\s*=\s*\S+') {
    $key = & python -c "import secrets; print(secrets.token_urlsafe(24))"
    if ($envText -match '(?m)^\s*PROXY_API_KEY\s*=.*$') {
        $envText = [regex]::Replace($envText, '(?m)^\s*PROXY_API_KEY\s*=.*$', "PROXY_API_KEY=$key")
    } else {
        $envText = $envText.TrimEnd() + "`nPROXY_API_KEY=$key`n"
    }
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot '.env'), $envText, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "已本地生成新的 PROXY_API_KEY 并写入 .env"
}

# 虚拟环境与依赖
$py = ".\.venv\Scripts\python.exe"
if (-not (Test-Path $py)) { python -m venv .venv }
& $py -m pip install -q -r requirements.txt

# 首次运行: 注册登录自启计划任务
if (-not (Get-ScheduledTask -TaskName "mimo-tts-proxy" -ErrorAction SilentlyContinue)) {
    try {
        $runner = Join-Path $PSScriptRoot "run-server.ps1"
        $action = New-ScheduledTaskAction -Execute "powershell.exe" `
            -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $runner + '"') `
            -WorkingDirectory $PSScriptRoot
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
            -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
        Register-ScheduledTask -TaskName "mimo-tts-proxy" -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force | Out-Null
        Write-Host "已注册登录自启计划任务: mimo-tts-proxy"
    } catch {
        Write-Warning "计划任务注册失败(不影响本次启动): $($_.Exception.Message)"
    }
}

# 启动本地服务: 优先使用计划任务(开机自启), 否则直接后台运行
$task = Get-ScheduledTask -TaskName "mimo-tts-proxy" -ErrorAction SilentlyContinue
if ($task) {
    if ($task.State -ne "Running") { Start-ScheduledTask -TaskName "mimo-tts-proxy" }
} else {
    Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique |
        ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }
    $srv = Start-Process -FilePath (Resolve-Path $py) -ArgumentList "-m","uvicorn","server:app","--host","127.0.0.1","--port",$port `
        -WorkingDirectory $PSScriptRoot -WindowStyle Hidden `
        -RedirectStandardOutput "server.log" -RedirectStandardError "server.err.log" -PassThru
    $srv.Id | Set-Content server.pid
}

$ready = $false
for ($i = 0; $i -lt 20; $i++) {
    try { Invoke-RestMethod "http://127.0.0.1:$port/health" -TimeoutSec 2 | Out-Null; $ready = $true; break } catch { Start-Sleep -Seconds 1 }
}
if (-not $ready) { throw "服务启动失败, 查看 server.log" }
Write-Host "本地服务已启动: http://127.0.0.1:$port"

# 公网地址: 优先 Tailscale Funnel
$tsExe = (Get-Command tailscale -ErrorAction SilentlyContinue).Source
if (-not $tsExe -and (Test-Path "C:\Program Files\Tailscale\tailscale.exe")) {
    $tsExe = "C:\Program Files\Tailscale\tailscale.exe"
}

$url = $null
$mode = $null
if ($tsExe) {
    $funnel = (& $tsExe funnel status 2>$null | Out-String)
    if ($funnel -match 'https://[a-z0-9.-]+\.ts\.net') {
        $url = $Matches[0]
        $mode = "Tailscale Funnel"
    }
}

# 回退: Cloudflare 快速隧道(地址每次启动都会变)
if (-not $url) {
    $cfExe = (Get-Command cloudflared -ErrorAction SilentlyContinue).Source
    if (-not $cfExe) {
        $fallback = "C:\Program Files (x86)\cloudflared\cloudflared.exe"
        if (Test-Path $fallback) { $cfExe = $fallback }
    }
    if ($cfExe) {
        # 只停掉本脚本上次启动的隧道, 避免误杀系统里其它 cloudflared 服务
        if (Test-Path cloudflared.pid) {
            $oldCf = Get-Content cloudflared.pid
            Stop-Process -Id $oldCf -Force -ErrorAction SilentlyContinue
        }
        $cf = Start-Process -FilePath $cfExe `
            -ArgumentList "tunnel","--url","http://127.0.0.1:$port" -WindowStyle Hidden `
            -RedirectStandardOutput "tunnel.out.log" -RedirectStandardError "tunnel.log" -PassThru
        $cf.Id | Set-Content cloudflared.pid
        for ($i = 0; $i -lt 40; $i++) {
            $txt = Get-Content tunnel.log -Raw -ErrorAction SilentlyContinue
            if ($txt -match 'https://[a-z0-9-]+\.trycloudflare\.com') { $url = $Matches[0]; $mode = "Cloudflare 快速隧道"; break }
            Start-Sleep -Seconds 1
        }
    }
}

$proxyKey = (Get-Content .env -Encoding UTF8 | Where-Object { $_ -match '^\s*PROXY_API_KEY\s*=' } | Select-Object -Last 1) -replace '^\s*PROXY_API_KEY\s*=\s*',''
Write-Host "=============================================="
Write-Host "公网方式:      $(if ($mode) { $mode } else { '未配置' })"
Write-Host "公网地址:      $(if ($url) { $url } else { '获取失败' })"
Write-Host "AnxReader URL: $(if ($url) { "$url/v1/audio/speech" })"
Write-Host "App API Key:   $proxyKey"
if ($mode -eq "Tailscale Funnel") { Write-Host "提示:          Funnel 地址固定, 重启后不变" }
Write-Host "=============================================="
