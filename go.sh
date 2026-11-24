#!/usr/bin/env bash
# 一键：纯 Python SSH 服务端 + cpolar 隧道。以后每次开机：bash /mnt/workspace/go.sh
set -u
D=/mnt/workspace/ms-bridge; S=$D/state; CP=$D/cpolar/cpolar; mkdir -p $S $D/cpolar
echo "[1/3] 安装 asyncssh ..."
python3 -c "import asyncssh" 2>/dev/null || pip install -q asyncssh 2>/dev/null || pip install -q -i https://mirrors.aliyun.com/pypi/simple asyncssh || { echo "失败：装不上 asyncssh"; exit 1; }
cat > $D/pysshd.py <<'PY'
# 纯 Python SSH 服务端（asyncssh）：只认指定公钥；支持 exec / shell / sftp / scp
import asyncio, asyncssh, os, sys
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 2222
STATE = "/mnt/workspace/ms-bridge/state"
os.makedirs(STATE, exist_ok=True)
HK = os.path.join(STATE, "py_host_key")
if not os.path.exists(HK):
    asyncssh.generate_private_key("ssh-ed25519").write_private_key(HK)
AK = os.path.join(STATE, "authorized_keys")
with open(AK, "w") as f:
    f.write("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKVFfGNlsy9RMu4YAowwiWew/KuvDSPIiA09ApWs8ZTG Kangnaixi@Kangnaixi\n")

async def handle(process):
    cmd = process.command or "bash -i"
    p = await asyncio.create_subprocess_shell(
        cmd, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE, cwd="/mnt/workspace", start_new_session=True)
    await process.redirect(stdin=p.stdin, stdout=p.stdout, stderr=p.stderr)
    process.exit(await p.wait())

async def main():
    await asyncssh.listen("127.0.0.1", PORT, server_host_keys=[HK], authorized_client_keys=AK,
                          process_factory=handle, encoding=None, sftp_factory=True, allow_scp=True)
    print("PYSSHD READY", PORT, flush=True)
    await asyncio.Future()

asyncio.run(main())
PY
pkill -f pysshd.py 2>/dev/null; sleep 1
(setsid nohup python3 $D/pysshd.py 2222 > $S/pysshd.log 2>&1 &)
for i in $(seq 1 20); do grep -q READY $S/pysshd.log && break; sleep 1; done
grep -q READY $S/pysshd.log || { echo "失败：SSH 服务没起来"; cat $S/pysshd.log; exit 1; }
echo "[2/3] cpolar ..."
if [ ! -x $CP ]; then
  curl -fsSL -m 120 http://www.cpolar.com/static/downloads/releases/3.3.12/cpolar-stable-linux-amd64.zip -o /tmp/cpolar.zip || { echo "失败：cpolar 下载不了"; exit 1; }
  python3 -c "import zipfile;zipfile.ZipFile('/tmp/cpolar.zip').extractall('$D/cpolar')"; chmod +x $CP
fi
$CP authtoken "${1:?缺 cpolar 令牌}" >/dev/null
pkill -f cpolar-keepalive 2>/dev/null; pkill -f "cpolar tcp 2222" 2>/dev/null; sleep 1; : > $S/cpolar.log
setsid nohup bash -c "exec -a cpolar-keepalive bash -c 'while true; do $CP tcp 2222 -log=stdout >> $S/cpolar.log 2>&1; sleep 5; done'" >/dev/null 2>&1 </dev/null &
for i in $(seq 1 40); do grep -o 'tcp://[^ "\]*' $S/cpolar.log | grep -qvE '127\.0\.0\.1|localhost' && break; sleep 1; done
echo "[3/3] 结果："
A=$(grep -o 'tcp://[^ "\]*' $S/cpolar.log | grep -vE '127\.0\.0\.1|localhost' | tail -1)
[ -n "$A" ] && echo "ADDRESS: $A" || { echo "失败：隧道没起来"; tail -5 $S/cpolar.log; }
