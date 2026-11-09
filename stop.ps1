# 停止本地代理与 Cloudflare 隧道(Tailscale Funnel 配置保留, 需要时用 tailscale funnel reset 关闭)
Set-Location $PSScriptRoot

# 先停计划任务, 避免被自动拉起
$task = Get-ScheduledTask -TaskName "mimo-tts-proxy" -ErrorAction SilentlyContinue
if ($task) { Stop-ScheduledTask -TaskName "mimo-tts-proxy" -ErrorAction SilentlyContinue }

foreach ($f in @("server.pid", "cloudflared.pid")) {
    if (Test-Path $f) {
        $procId = Get-Content $f
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
        Remove-Item $f -ErrorAction SilentlyContinue
    }
}

$port = 8787
if (Test-Path .env) {
    Get-Content .env -Encoding UTF8 | ForEach-Object { if ($_ -match '^\s*PORT\s*=\s*(\d+)') { $port = [int]$Matches[1] } }
}
Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty OwningProcess -Unique |
    ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }

Write-Host "已停止本地服务与隧道"
