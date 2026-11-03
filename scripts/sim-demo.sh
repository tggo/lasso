#!/usr/bin/env bash
# Boots the simulator, installs a Debug build and launches it against the local
# integration sshd + herdr (scripts/it-sshd.sh), with demo workspaces/agents.
set -euo pipefail
cd "$(dirname "$0")/.."
DEV="${SIM:-iPhone 17 Pro}"
./scripts/it-sshd.sh start >/dev/null
eval "$(./scripts/it-sshd.sh env)"
S="$LASSO_IT_SOCK"
q() { printf '%s\n' "$1" | nc -U -w2 "$S"; }
if ! q '{"id":"s","method":"session.snapshot","params":{}}' | grep -q '"label":"api"'; then
  for ws in api web; do
    p=$(q "{\"id\":\"c\",\"method\":\"workspace.create\",\"params\":{\"label\":\"$ws\",\"cwd\":\"$PWD\"}}" | sed -E 's/.*"root_pane":\{"pane_id":"([^"]+)".*/\1/')
    st=$([ $ws = api ] && echo blocked || echo working)
    q "{\"id\":\"r\",\"method\":\"pane.report_agent\",\"params\":{\"pane_id\":\"$p\",\"source\":\"demo\",\"agent\":\"claude\",\"state\":\"$st\"}}" >/dev/null
    q "{\"id\":\"t\",\"method\":\"pane.send_input\",\"params\":{\"pane_id\":\"$p\",\"text\":\"echo hello from $ws\",\"keys\":[\"enter\"]}}" >/dev/null
  done
fi
xcrun simctl boot "$DEV" 2>/dev/null || true
open -a Simulator
xcodebuild -project Lasso.xcodeproj -scheme Lasso -configuration Debug -destination "platform=iOS Simulator,name=$DEV" \
  -derivedDataPath build/sim -quiet build
xcrun simctl install "$DEV" build/sim/Build/Products/Debug-iphonesimulator/Lasso.app
xcrun simctl terminate "$DEV" dev.lasso.Lasso 2>/dev/null || true
SIMCTL_CHILD_LASSO_SEED_KEY="$LASSO_IT_KEY" \
SIMCTL_CHILD_LASSO_SEED_HOST="$LASSO_IT_HOST:$LASSO_IT_PORT:$LASSO_IT_USER:$S" \
  xcrun simctl launch "$DEV" dev.lasso.Lasso
