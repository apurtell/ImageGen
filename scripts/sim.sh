#!/bin/bash
# Manages the dedicated simulator: ensure | udid | boot | reset | erase
set -euo pipefail
source "$(dirname "$0")/env.sh"

newest_runtime() {
  xcrun simctl list runtimes -j | python3 -c '
import json, sys
rs = [r for r in json.load(sys.stdin)["runtimes"]
      if r.get("platform") == "iOS" and r.get("isAvailable") and int(r["version"].split(".")[0]) >= 26]
rs.sort(key=lambda r: tuple(int(x) for x in r["version"].split(".")))
print(rs[-1]["identifier"] if rs else "")'
}

device_type_for() {
  # Prefers iPhone 17 Pro; falls back to the newest iPhone Pro the runtime supports.
  xcrun simctl list runtimes -j | python3 -c '
import json, sys
rid = sys.argv[1]
r = next(r for r in json.load(sys.stdin)["runtimes"] if r["identifier"] == rid)
types = [t for t in r.get("supportedDeviceTypes", []) if t.get("productFamily") == "iPhone"]
names = [t["name"] for t in types]
if "iPhone 17 Pro" in names:
    print(next(t["identifier"] for t in types if t["name"] == "iPhone 17 Pro"))
else:
    pros = [t for t in types if t["name"].endswith(" Pro")]
    print((pros or types)[-1]["identifier"])' "$1"
}

boot() {
  local udid="$1"
  state="$(xcrun simctl list devices -j | python3 -c '
import json, sys
for ds in json.load(sys.stdin)["devices"].values():
    for d in ds:
        if d["udid"] == sys.argv[1]: print(d["state"])' "$udid")"
  if [ "$state" != "Booted" ]; then xcrun simctl boot "$udid"; fi
  xcrun simctl bootstatus "$udid" -b >/dev/null
  open -a Simulator --args -CurrentDeviceUDID "$udid" || true
}

cmd="${1:-ensure}"
case "$cmd" in
  ensure)
    udid="$(sim_udid)"
    if [ -z "$udid" ]; then
      runtime="$(newest_runtime)"
      [ -n "$runtime" ] || { echo "error: no iOS 26+ runtime; run xcodebuild -downloadPlatform iOS" >&2; exit 1; }
      dtype="$(device_type_for "$runtime")"
      udid="$(xcrun simctl create "$SIM_NAME" "$dtype" "$runtime")"
      echo "created $SIM_NAME ($dtype, $runtime): $udid"
    fi
    boot "$udid"
    echo "$udid"
    ;;
  udid)  require_sim; echo "$SIM_UDID" ;;
  boot)  require_sim; boot "$SIM_UDID" ;;
  reset) require_sim; xcrun simctl uninstall "$SIM_UDID" "$BUNDLE_ID" || true ;;
  erase) require_sim; xcrun simctl shutdown "$SIM_UDID" || true; xcrun simctl erase "$SIM_UDID" ;;
  *) echo "usage: $0 ensure|udid|boot|reset|erase" >&2; exit 2 ;;
esac
