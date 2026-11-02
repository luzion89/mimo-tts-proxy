# 停止本地代理与 Cloudflare 隧道
Set-Location $PSScriptRoot

foreach ($f in @("server.pid", "cloudflared.pid")) {
    if (Test-Path $f) {
        $procId = Get-Content $f
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
        Remove-Item $f -ErrorAction SilentlyContinue
    }
}

$port = 8787
if (Test-Path .env) {
    Get-Content .env | ForEach-Object { if ($_ -match '^\s*PORT\s*=\s*(\d+)') { $port = [int]$Matches[1] } }
}
Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty OwningProcess -Unique |
    ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }

Get-Process cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Write-Host "已停止本地服务与隧道"
