#!/bin/bash
# Runs the unit tests on the dedicated simulator. Extra arguments go to xcodebuild
# (for example -only-testing:ImageGenTests/ResponseParserTests).
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$REPO_ROOT"

require_sim
mkdir -p "$LOGS"
bundle="$LOGS/Test-$(date +%Y%m%d-%H%M%S).xcresult"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
  -destination "id=$SIM_UDID" -derivedDataPath "$DERIVED" \
  -resultBundlePath "$bundle" "$@" test 2>&1 | tee "$LOGS/test.log"
exit "${PIPESTATUS[0]}"
