#!/bin/bash
# Builds the macOS app (scheme ImageGenMac) with real signing so the Keychain works.
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$REPO_ROOT"

config=Debug; log=build-mac.log
for arg in "$@"; do
  case "$arg" in
    --release) config=Release; log=build-mac-release.log ;;
    *) echo "usage: $0 [--release]" >&2; exit 2 ;;
  esac
done

mkdir -p "$LOGS"
xcodebuild -project "$PROJECT" -scheme "$MAC_SCHEME" -configuration "$config" \
  -destination 'platform=macOS' -derivedDataPath "$MAC_DERIVED" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build 2>&1 | tee "$LOGS/$log"
exit "${PIPESTATUS[0]}"
