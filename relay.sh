#!/usr/bin/env bash
# 一句话启动信箱：curl -fsSL .../relay.sh | bash -s <魔搭令牌>
T="${1:?缺魔搭令牌}"
pkill -f cpolar-keepalive 2>/dev/null; pkill -f "cpolar tcp" 2>/dev/null; pkill -f relay_agent.py 2>/dev/null
mkdir -p /workspace && cd /workspace
git config --global --add safe.directory '*'; git config --global http.version HTTP/1.1
for i in $(seq 1 10); do
G=$(python3 - "$T" <<'PY'
import json,sys,urllib.request
r=urllib.request.Request("https://www.modelscope.cn/api/v1/login",data=json.dumps({"AccessToken":sys.argv[1]}).encode(),headers={"Content-Type":"application/json"})
d=json.load(urllib.request.urlopen(r,timeout=30))["Data"];print(f"https://oauth2:{d['AccessToken']}@www.modelscope.cn/datasets/{d['Username']}/relay.git")
PY
) 2>/dev/null && break; echo "登录魔搭重试 $i"; sleep 3; done
[ -n "${G:-}" ] || { echo "失败：魔搭登录不了"; exit 1; }
curl -fsSL -m 60 -o /workspace/relay_agent.py https://fastly.jsdelivr.net/gh/Lavender3533/ms-bridge@56b13a9/relay_agent.py || { echo "失败：下载 agent"; exit 1; }
rm -rf /workspace/relay; : > /workspace/relay_agent.log
for i in 1 2 3 4 5 6; do timeout 90 git clone -q --depth 1 "$G" /workspace/relay && break; echo "拉取重试 $i"; rm -rf /workspace/relay; sleep 2; done
[ -d /workspace/relay/.git ] || { echo "失败：信箱拉不下来"; exit 1; }
pkill -f relay-keepalive 2>/dev/null
setsid nohup bash -c "exec -a relay-keepalive bash -c 'while true; do python3 /workspace/relay_agent.py $T >> /workspace/relay_agent.log 2>&1; echo restart >> /workspace/relay_agent.log; sleep 5; done'" >/dev/null 2>&1 </dev/null &
for i in $(seq 1 60); do grep -q "relay agent up" /workspace/relay_agent.log && { echo "成功：已连上，终端可以关了"; exit 0; }; sleep 2; done
echo "还没连上，但它会在后台一直自动重试，你可以关掉终端了"; tail -2 /workspace/relay_agent.log
