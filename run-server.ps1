# 由计划任务在用户登录时调用: 释放端口后启动 uvicorn, 并保持任务运行
Set-Location $PSScriptRoot

$diag = Join-Path $PSScriptRoot "task-diag.log"
function Log($msg) { Add-Content -Path $diag -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" }

$py = ".\.venv\Scripts\python.exe"
if (-not (Test-Path $py)) {
    Log "缺少 .venv, 退出"
    throw "缺少 .venv, 请先运行 start.ps1"
}

$port = 8787
if (Test-Path .env) {
    Get-Content .env -Encoding UTF8 | ForEach-Object { if ($_ -match '^\s*PORT\s*=\s*(\d+)') { $port = [int]$Matches[1] } }
}
Log "wrapper start, port=$port"

# 结束占用端口的旧实例
$pids = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty OwningProcess -Unique
foreach ($procId in $pids) {
    try {
        Stop-Process -Id $procId -Force -ErrorAction Stop
        Log "killed old process $procId"
    } catch {
        Log "kill $procId failed: $($_.Exception.Message)"
    }
}

# 等待端口释放
for ($i = 0; $i -lt 40; $i++) {
    if (-not (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)) { break }
    Start-Sleep -Milliseconds 250
}
Start-Sleep -Seconds 1

Log "starting uvicorn"
$proc = Start-Process -FilePath $py `
    -ArgumentList "-m","uvicorn","server:app","--host","127.0.0.1","--port",$port `
    -WorkingDirectory $PSScriptRoot -WindowStyle Hidden `
    -RedirectStandardOutput "server-task.log" -RedirectStandardError "server-task.err.log" -PassThru
Log "uvicorn pid $($proc.Id)"
$proc.WaitForExit()
Log "uvicorn exited code $($proc.ExitCode)"
