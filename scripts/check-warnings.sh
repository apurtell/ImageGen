#!/bin/bash
# Clean builds of both apps into their own derived data and logs; fails on any warning from ImageGen/ and Platforms/ sources.
set -uo pipefail
source "$(dirname "$0")/env.sh"
cd "$REPO_ROOT"

require_sim
mkdir -p "$LOGS"
ios_log="$LOGS/warnings.log"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
  -destination "id=$SIM_UDID" -derivedDataPath "$REPO_ROOT/build/DerivedData-warnings" \
  clean build > "$ios_log" 2>&1
status=$?
if [ "$status" -ne 0 ]; then
  echo "check-warnings: iOS build failed (see $ios_log)"; exit "$status"
fi
mac_log="$LOGS/warnings-mac.log"
xcodebuild -project "$PROJECT" -scheme "$MAC_SCHEME" -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$REPO_ROOT/build/DerivedData-warnings-mac" \
  CODE_SIGNING_ALLOWED=NO clean build > "$mac_log" 2>&1
status=$?
if [ "$status" -ne 0 ]; then
  echo "check-warnings: macOS build failed (see $mac_log)"; exit "$status"
fi
warnings="$(grep -hE '/(ImageGen|Platforms)/.*: warning:' "$ios_log" "$mac_log" | sort -u)"
if [ -n "$warnings" ]; then
  echo "$warnings"
  echo "check-warnings: $(echo "$warnings" | wc -l | tr -d ' ') warning(s) in ImageGen/ and Platforms/"
  exit 1
fi
echo "check-warnings: 0 warnings in ImageGen/ and Platforms/, iOS and macOS"
