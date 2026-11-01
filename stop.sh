#!/bin/bash
cd "$(dirname "$0")"
[ -f server.pid ] && kill "$(cat server.pid)" 2>/dev/null
[ -f cloudflared.pid ] && kill "$(cat cloudflared.pid)" 2>/dev/null
rm -f server.pid cloudflared.pid
echo "已停止"
