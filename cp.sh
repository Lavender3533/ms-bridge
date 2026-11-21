#!/usr/bin/env bash
# Open an SSH door into this ModelScope instance through cpolar (mainland China tunnel service).
# Usage: bash cp.sh <cpolar-authtoken>     (token: https://dashboard.cpolar.com/auth)
# Key-only login (password login disabled); sshd listens on 127.0.0.1 only.
set -u
DIR=/mnt/workspace/ms-bridge
STATE="$DIR/state"
CP="$DIR/cpolar/cpolar"
PORT_LOCAL=2222
PUBKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKVFfGNlsy9RMu4YAowwiWew/KuvDSPIiA09ApWs8ZTG Kangnaixi@Kangnaixi'
TOKEN="${1:-}"
mkdir -p "$STATE" "$DIR/cpolar"
pkill -f "bore_client.py" 2>/dev/null || true

echo "[1/3] sshd ..."
if ! command -v sshd >/dev/null 2>&1 && [ ! -x /usr/sbin/sshd ]; then
  echo "      installing openssh-server (about 1 minute) ..."
  export DEBIAN_FRONTEND=noninteractive
  sed -i -E 's#https?://[^/ ]+/(ubuntu|debian)#http://mirrors.aliyun.com/\1#' /etc/apt/sources.list 2>/dev/null
  timeout 180 apt-get update -qq >/dev/null 2>&1 || true
  timeout 300 apt-get install -y -qq openssh-server >/dev/null 2>&1 || { echo "FAILED: cannot install openssh-server"; exit 1; }
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
ClientAliveInterval 30
PidFile $STATE/sshd.pid
Subsystem sftp internal-sftp
EOF
mkdir -p /run/sshd
if ! (ss -ltn 2>/dev/null | grep -q "127.0.0.1:$PORT_LOCAL "); then
  "$SSHD" -f "$STATE/sshd_config" || { echo "FAILED: sshd did not start"; exit 1; }
fi

echo "[2/3] cpolar ..."
if [ ! -x "$CP" ]; then
  curl -fsSL -m 120 http://www.cpolar.com/static/downloads/releases/3.3.12/cpolar-stable-linux-amd64.zip -o /tmp/cpolar.zip \
    || { echo "FAILED: cannot download cpolar"; exit 1; }
  python3 -c "import zipfile;zipfile.ZipFile('/tmp/cpolar.zip').extractall('$DIR/cpolar')"
  chmod +x "$CP"
fi
if [ -n "$TOKEN" ]; then
  "$CP" authtoken "$TOKEN" >/dev/null || { echo "FAILED: authtoken rejected"; exit 1; }
fi
pkill -f "cpolar tcp $PORT_LOCAL" 2>/dev/null || true
sleep 1
nohup "$CP" tcp "$PORT_LOCAL" -log=stdout > "$STATE/cpolar.log" 2>&1 &
for _ in $(seq 1 40); do
  grep -o 'tcp://[^ "\]*' "$STATE/cpolar.log" | grep -qvE '127\.0\.0\.1|localhost' && break
  sleep 1
done

echo "[3/3] result:"
ADDR=$(grep -o 'tcp://[^ "\]*' "$STATE/cpolar.log" | grep -vE '127\.0\.0\.1|localhost' | tail -1)
if [ -n "$ADDR" ]; then
  nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || echo "no NVIDIA GPU visible"
  echo "ADDRESS: $ADDR"
  echo "OK - send the ADDRESS line to Claude. You can leave this terminal."
else
  echo "FAILED: cpolar did not report an address:"; grep -iE "tcp://|error|fail|auth" "$STATE/cpolar.log" | tail -8
  exit 1
fi
