#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

./build.sh

# Replace any running instance so changes take effect.
pkill -x UsageBar 2>/dev/null || true
sleep 0.3

# Exec the binary directly instead of `open`. `open` goes through
# LaunchServices, which on recent macOS rejects ad-hoc-signed apps with
# "may be damaged or incomplete". Direct exec only has to satisfy AMFI,
# which accepts ad-hoc signatures.
#
# nohup + disown so the app survives this shell exiting; output is suppressed
# because the app doesn't print and WKWebView is noisy.
nohup ./UsageBar.app/Contents/MacOS/UsageBar >/dev/null 2>&1 &
disown

echo "Launched UsageBar — look for the menu bar item next to the clock."
