#!/usr/bin/env bash
# Open an SSH door into this ModelScope instance through the public bore.pub relay.
# Key-only login (password login disabled); sshd listens on 127.0.0.1 only.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
PORT_LOCAL=2222
PORT_PUBLIC=47219
PUBKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKVFfGNlsy9RMu4YAowwiWew/KuvDSPIiA09ApWs8ZTG Kangnaixi@Kangnaixi'
STATE="$DIR/state"
mkdir -p "$STATE"

echo "[1/3] sshd ..."
if ! command -v sshd >/dev/null 2>&1 && [ ! -x /usr/sbin/sshd ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || true
  if ! apt-get install -y -qq openssh-server >/dev/null 2>&1; then
    sed -i -E 's#https?://[^/ ]+/(ubuntu|debian)#http://mirrors.aliyun.com/\1#' /etc/apt/sources.list 2>/dev/null
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq openssh-server >/dev/null 2>&1 || { echo "FAILED: cannot install openssh-server"; exit 1; }
  fi
fi
SSHD="$(command -v sshd || echo /usr/sbin/sshd)"

[ -f "$STATE/host_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -f "$STATE/host_ed25519"
echo "$PUBKEY" > "$STATE/authorized_keys"
chmod 700 "$STATE"; chmod 600 "$STATE/authorized_keys" "$STATE/host_ed25519"
cat > "$STATE/sshd_config" <<EOF
Port $PORT_LOCAL
ListenAddress 127.0.0.1
HostKey $STATE/host_ed25519
AuthorizedKeysFile $STATE/authorized_keys
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
StrictModes no
UsePAM no
PidFile $STATE/sshd.pid
Subsystem sftp internal-sftp
EOF
mkdir -p /run/sshd
if [ -f "$STATE/sshd.pid" ] && kill -0 "$(cat "$STATE/sshd.pid")" 2>/dev/null; then
  kill "$(cat "$STATE/sshd.pid")"; sleep 1
fi
"$SSHD" -f "$STATE/sshd_config" || { echo "FAILED: sshd did not start"; exit 1; }

echo "[2/3] tunnel ..."
pkill -f "bore_client.py $PORT_LOCAL" 2>/dev/null
nohup python3 "$DIR/bore_client.py" "$PORT_LOCAL" "$PORT_PUBLIC" > "$STATE/tunnel.log" 2>&1 &
for _ in $(seq 1 30); do
  grep -q "TUNNEL READY" "$STATE/tunnel.log" && break
  sleep 1
done

echo "[3/3] result:"
if grep -q "TUNNEL READY" "$STATE/tunnel.log"; then
  nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || echo "no NVIDIA GPU visible"
  echo "OK - tunnel is up. You can leave this terminal; the connection keeps running in the background."
else
  echo "FAILED: tunnel did not come up:"; tail -5 "$STATE/tunnel.log"
  exit 1
fi
