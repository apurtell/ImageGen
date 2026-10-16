# Sourced by every script. Picks the Xcode, names the simulator and sets the shared paths.
# shellcheck shell=bash

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

_imagegen_xcode_ok() {
  # $1: an Xcode.app path. True when it exists and reports version 26 or later.
  [ -d "$1/Contents/Developer" ] || return 1
  local v
  v="$(DEVELOPER_DIR="$1/Contents/Developer" xcodebuild -version 2>/dev/null | awk '/^Xcode /{print $2; exit}')"
  [ -n "$v" ] && [ "${v%%.*}" -ge 26 ]
}

if [ -z "${IMAGEGEN_DEVELOPER_DIR_PICKED:-}" ]; then
  for candidate in "${IMAGEGEN_XCODE:-}" /Applications/Xcode.app "$HOME/Downloads/Xcode.app"; do
    [ -n "$candidate" ] || continue
    if _imagegen_xcode_ok "$candidate"; then
      export DEVELOPER_DIR="$candidate/Contents/Developer"
      export IMAGEGEN_DEVELOPER_DIR_PICKED=1
      break
    fi
  done
fi

# IMAGEGEN_SIM (a simulator name or UDID) overrides the dedicated simulator, e.g. one already booted.
export SIM_NAME="${IMAGEGEN_SIM:-ImageGen-Sim}"
export BUNDLE_ID="com.andrewpurtell.imagegen"
export DERIVED="$REPO_ROOT/build/DerivedData"
export LOGS="$REPO_ROOT/build/logs"
export PROJECT="$REPO_ROOT/ImageGen.xcodeproj"
export SCHEME="ImageGen"

# Prints the UDID of the dedicated simulator, or nothing when it doesn't exist.
sim_udid() {
  xcrun simctl list devices -j 2>/dev/null | python3 -c '
import json, sys
name = sys.argv[1]
for runtime, devices in json.load(sys.stdin)["devices"].items():
    for d in devices:
        if name in (d["name"], d["udid"]) and d.get("isAvailable", True):
            print(d["udid"]); sys.exit(0)
' "$SIM_NAME"
}

# Exits with a message unless the dedicated simulator exists; sets SIM_UDID.
require_sim() {
  SIM_UDID="$(sim_udid)"
  if [ -z "$SIM_UDID" ]; then
    echo "error: simulator $SIM_NAME not found; run scripts/sim.sh ensure" >&2
    exit 1
  fi
  export SIM_UDID
}
