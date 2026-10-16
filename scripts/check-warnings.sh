#!/bin/bash
# Clean build into its own derived data and log; fails on any warning from ImageGen/ sources.
set -uo pipefail
source "$(dirname "$0")/env.sh"
cd "$REPO_ROOT"

require_sim
mkdir -p "$LOGS"
log="$LOGS/warnings.log"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
  -destination "id=$SIM_UDID" -derivedDataPath "$REPO_ROOT/build/DerivedData-warnings" \
  clean build > "$log" 2>&1
status=$?
if [ "$status" -ne 0 ]; then
  echo "check-warnings: build failed (see $log)"; exit "$status"
fi
warnings="$(grep -E '/ImageGen/.*: warning:' "$log" | sort -u)"
if [ -n "$warnings" ]; then
  echo "$warnings"
  echo "check-warnings: $(echo "$warnings" | wc -l | tr -d ' ') warning(s) in ImageGen/"
  exit 1
fi
echo "check-warnings: 0 warnings in ImageGen/"
