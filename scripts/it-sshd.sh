#!/usr/bin/env bash
# Local, unprivileged sshd + throwaway herdr session for integration tests.
#   scripts/it-sshd.sh start|stop|env
# Everything lives in build/it/ — keys are generated fresh, nothing touches ~/.ssh.
set -euo pipefail
cd "$(dirname "$0")/.."
D="$PWD/build/it"; PORT="${LASSO_IT_PORT:-2222}"; SESSION=lasso-it
case "${1:-start}" in
start)
  mkdir -p "$D"
  [ -f "$D/host_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -f "$D/host_ed25519"
  [ -f "$D/client_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -f "$D/client_ed25519"
  cp "$D/client_ed25519.pub" "$D/authorized_keys"; chmod 600 "$D/authorized_keys"
  cat > "$D/sshd_config" <<CFG
Port $PORT
ListenAddress 127.0.0.1
HostKey $D/host_ed25519
PidFile $D/sshd.pid
AuthorizedKeysFile $D/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
AllowStreamLocalForwarding yes
AllowUsers $(whoami)
CFG
  [ -f "$D/sshd.pid" ] && kill -0 "$(cat "$D/sshd.pid")" 2>/dev/null || /usr/sbin/sshd -f "$D/sshd_config" -E "$D/sshd.log"
  pgrep -f "herdr --session $SESSION server" >/dev/null || (nohup herdr --session $SESSION server >"$D/herdr.log" 2>&1 &)
  for _ in $(seq 50); do [ -S "$HOME/.config/herdr/sessions/$SESSION/herdr.sock" ] && break; sleep 0.1; done
  echo "sshd :$PORT + herdr session $SESSION up";;
stop)
  [ -f "$D/sshd.pid" ] && kill "$(cat "$D/sshd.pid")" 2>/dev/null || true
  herdr session stop $SESSION >/dev/null 2>&1 || true; echo stopped;;
env)
  echo "LASSO_IT_HOST=127.0.0.1 LASSO_IT_PORT=$PORT LASSO_IT_USER=$(whoami) LASSO_IT_KEY=$D/client_ed25519 LASSO_IT_HOSTKEY=$D/host_ed25519.pub LASSO_IT_SOCK=$HOME/.config/herdr/sessions/$SESSION/herdr.sock$( [ -S "$HOME/.local/state/herdr-core/default/default.sock" ] && echo " LASSO_IT_CORE=1")";;
esac
