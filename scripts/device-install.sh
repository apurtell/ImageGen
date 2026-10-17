#!/bin/bash
# Builds, installs and launches on a connected iPhone (IMPLEMENTATION_PLAN.md M10).
#   scripts/device-install.sh [--release] [--no-launch]
# DEVICE_UDID selects the phone (its hardware UDID, 00008…-…). Without it, the script picks the one
# reachable iPhone, or lists them and stops when there are several. Signing needs DEVELOPMENT_TEAM in
# Config/Local.xcconfig and the device registered once (the first Run from Xcode, or -allowProvisioningUpdates).
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$REPO_ROOT"

config=Debug; launch=1
for arg in "$@"; do
  case "$arg" in
    --release) config=Release ;;
    --no-launch) launch=0 ;;
    *) echo "usage: $0 [--release] [--no-launch]" >&2; exit 2 ;;
  esac
done

if [ -z "${DEVICE_UDID:-}" ]; then
  # Reachable iPhones only: a paired phone that isn't connected has no transport type.
  phones="$(xcrun devicectl list devices --json-output - 2>/dev/null | python3 -I -c '
import json, sys
for x in json.load(sys.stdin)["result"]["devices"]:
    hw, conn, dev = x["hardwareProperties"], x.get("connectionProperties", {}), x["deviceProperties"]
    if hw.get("platform") == "iOS" and conn.get("transportType"):
        print(hw["udid"], dev.get("name", "?"), dev.get("developerModeStatus", "?"), sep="\t")
')"
  count="$(printf '%s' "$phones" | grep -c . || true)"
  if [ "$count" -eq 0 ]; then
    echo "device-install: no reachable iPhone (connect it, unlock it and trust this Mac)" >&2; exit 1
  elif [ "$count" -gt 1 ]; then
    echo "device-install: several iPhones are reachable; set DEVICE_UDID to one of:" >&2
    printf '%s\n' "$phones" >&2; exit 1
  fi
  DEVICE_UDID="$(printf '%s' "$phones" | cut -f1)"
  mode="$(printf '%s' "$phones" | cut -f3)"
  if [ "$mode" = "disabled" ]; then
    echo "device-install: Developer Mode is off on $(printf '%s' "$phones" | cut -f2)." >&2
    echo "  On the iPhone: Settings › Privacy & Security › Developer Mode › On, restart, confirm." >&2
    exit 1
  fi
fi
echo "device-install: $config build for $DEVICE_UDID"

mkdir -p "$LOGS"
set +e
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$config" \
  -destination "platform=iOS,id=$DEVICE_UDID" -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build > "$LOGS/device-build.log" 2>&1
status=$?
set -e
grep -E '^\*\* |error:' "$LOGS/device-build.log" | tail -20
[ "$status" -eq 0 ] || { echo "device-install: build failed; see build/logs/device-build.log" >&2; exit 1; }

xcrun devicectl device install app --device "$DEVICE_UDID" "$DERIVED/Build/Products/$config-iphoneos/ImageGen.app"
if [ "$launch" -eq 1 ]; then
  xcrun devicectl device process launch --device "$DEVICE_UDID" "$BUNDLE_ID"
fi
