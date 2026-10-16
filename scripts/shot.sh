#!/bin/bash
# Captures a simulator screenshot to artifacts/<milestone>/<name>.png with a clean status bar.
set -euo pipefail
source "$(dirname "$0")/env.sh"

[ $# -eq 2 ] || { echo "usage: $0 <milestone> <name>" >&2; exit 2; }
require_sim
out="$REPO_ROOT/artifacts/$1/$2.png"
mkdir -p "$(dirname "$out")"
xcrun simctl status_bar "$SIM_UDID" override --time 9:41 --batteryState charged --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3 >/dev/null 2>&1 || true
xcrun simctl io "$SIM_UDID" screenshot "$out"
echo "$out"
