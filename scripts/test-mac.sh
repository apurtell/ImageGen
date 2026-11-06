#!/bin/bash
# Runs the unit tests on this Mac, hosted in the signed ImageGen app. Extra arguments go to
# xcodebuild (for example -only-testing:ImageGenMacTests/ResponseParserTests).
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$REPO_ROOT"

mkdir -p "$LOGS"
bundle="$LOGS/TestMac-$(date +%Y%m%d-%H%M%S).xcresult"
xcodebuild -project "$PROJECT" -scheme "$MAC_SCHEME" -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$MAC_DERIVED" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  -resultBundlePath "$bundle" "$@" test 2>&1 | tee "$LOGS/test-mac.log"
exit "${PIPESTATUS[0]}"
