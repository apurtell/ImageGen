#!/bin/bash
# Builds for the dedicated simulator (default) or, with --release, the Release configuration.
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$REPO_ROOT"

config=Debug; log=build.log
for arg in "$@"; do
  case "$arg" in
    --release) config=Release; log=build-release.log ;;
    *) echo "usage: $0 [--release]" >&2; exit 2 ;;
  esac
done

require_sim
mkdir -p "$LOGS"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$config" \
  -destination "id=$SIM_UDID" -derivedDataPath "$DERIVED" build 2>&1 | tee "$LOGS/$log"
exit "${PIPESTATUS[0]}"
