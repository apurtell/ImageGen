#!/bin/bash
# Installs the Debug build on the dedicated simulator and launches it with the given launch options.
set -euo pipefail
source "$(dirname "$0")/env.sh"

require_sim
app="$DERIVED/Build/Products/Debug-iphonesimulator/ImageGen.app"
[ -d "$app" ] || { echo "error: $app not found; run scripts/build.sh" >&2; exit 1; }
xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$SIM_UDID" "$app"
sleep 1
# --terminate-running-process: never just foreground a process an install left running.
xcrun simctl launch --terminate-running-process "$SIM_UDID" "$BUNDLE_ID" "$@"
