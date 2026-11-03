#!/usr/bin/env bash
# No-backdoor gate: fails if tracking/crash/ads SDKs, unexpected network hosts,
# or unpinned/remote binary dependencies appear in the source tree.
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0
SRC="App Packages project.yml"

# 1. Known telemetry / crash / ads SDKs.
if grep -rniE 'firebase|crashlytics|sentry|mixpanel|amplitude|posthog|segment\.(io|com)|appsflyer|adjust\.com|branch\.io|datadog|bugsnag|newrelic|admob|GoogleMobileAds|facebook' $SRC --exclude-dir=.build -I 2>/dev/null; then
  echo "❌ audit: tracking/analytics SDK reference found"; fail=1
fi

# 2. Every hard-coded http(s) host must be on the allowlist (docs/network-allowlist.txt).
hosts=$(grep -rhoE 'https?://[A-Za-z0-9.-]+' App Packages --include='*.swift' 2>/dev/null | sed -E 's#https?://##' | sort -u || true)
for h in $hosts; do
  grep -qxF "$h" docs/network-allowlist.txt || { echo "❌ audit: host not in allowlist: $h"; fail=1; }
done

# 3. Remote packages must be pinned by exact revision.
if grep -nE '^\s+(from|branch|minorVersion|majorVersion):' project.yml; then
  echo "❌ audit: remote package not pinned by exact revision"; fail=1
fi

[ $fail -eq 0 ] && echo "✅ audit passed" || exit 1
