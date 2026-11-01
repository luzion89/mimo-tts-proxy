#!/bin/bash
# 一键启动: 本地代理 + Cloudflare 公网隧道
cd "$(dirname "$0")"

[ -f .env ] || { echo "缺少 .env, 请先复制 .env.example 为 .env 并填写 MIMO_API_KEY"; exit 1; }
PORT=$(grep -E '^PORT=' .env | tail -1 | cut -d= -f2)
PORT=${PORT:-8787}

# 代理访问密钥为空时, 在本地随机生成并写入 .env (可随时手动修改)
if ! grep -qE '^PROXY_API_KEY=.+' .env; then
  KEY=$(python3 -c "import secrets; print(secrets.token_urlsafe(24))")
  if grep -qE '^PROXY_API_KEY=' .env; then
    sed -i '' "s|^PROXY_API_KEY=.*|PROXY_API_KEY=$KEY|" .env
  else
    echo "PROXY_API_KEY=$KEY" >> .env
  fi
  echo "已本地生成新的 PROXY_API_KEY 并写入 .env"
fi

[ -d .venv ] || python3 -m venv .venv
source .venv/bin/activate
pip install -q -r requirements.txt

pkill -f "uvicorn server:app" 2>/dev/null
nohup uvicorn server:app --host 127.0.0.1 --port "$PORT" >> server.log 2>&1 &
echo $! > server.pid
sleep 2
curl -sf "http://127.0.0.1:$PORT/health" >/dev/null || { echo "服务启动失败, 查看 server.log"; exit 1; }
echo "本地服务已启动: http://127.0.0.1:$PORT"

pkill -f "cloudflared tunnel --url" 2>/dev/null
nohup cloudflared tunnel --url "http://127.0.0.1:$PORT" >> tunnel.log 2>&1 &
echo $! > cloudflared.pid

URL=""
for i in $(seq 1 30); do
  URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' tunnel.log | head -1)
  [ -n "$URL" ] && break
  sleep 1
done

PROXY_KEY=$(grep -E '^PROXY_API_KEY=' .env | cut -d= -f2)
echo "=============================================="
echo "公网地址:      ${URL:-获取失败, 查看 tunnel.log}"
echo "AnxReader URL: ${URL:+$URL/v1/audio/speech}"
echo "App API Key:   $PROXY_KEY (即 .env 中的 PROXY_API_KEY)"
echo "=============================================="
