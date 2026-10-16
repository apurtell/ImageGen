#!/bin/bash
# Toolchain checks (IMPLEMENTATION_PLAN.md section 1.1). Exits 0 only when everything is ready.
source "$(dirname "$0")/env.sh"

fail=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n        fix: %s\n' "$1" "$2"; fail=1; }

echo "ImageGen doctor"

if [ -z "${DEVELOPER_DIR:-}" ]; then
  bad "Xcode 26 or later not found (looked at \$IMAGEGEN_XCODE, /Applications/Xcode.app, ~/Downloads/Xcode.app)" \
      "install Xcode 26+, or set IMAGEGEN_XCODE to its .app path"
else
  ok "$(xcodebuild -version | tr '\n' ' ')at $DEVELOPER_DIR"
  if xcodebuild -license check >/dev/null 2>&1; then ok "Xcode license accepted"
  else bad "Xcode license not accepted" "sudo xcodebuild -license accept"; fi
  if xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then ok "first launch done"
  else bad "Xcode first launch not done" "xcodebuild -runFirstLaunch"; fi
  runtime="$(xcrun simctl list runtimes 2>/dev/null | grep -E '^iOS (2[6-9]|[3-9][0-9])\.' | grep -v unavailable | tail -1)"
  if [ -n "$runtime" ]; then ok "simulator runtime: $runtime"
  else bad "no iOS 26+ simulator runtime" "xcodebuild -downloadPlatform iOS"; fi
fi

if command -v xcodegen >/dev/null 2>&1; then
  xv="$(xcodegen --version | awk '{print $2}')"
  if python3 -c 'import sys; v=tuple(int(x) for x in sys.argv[1].split(".")); sys.exit(0 if v >= (2,46,0) else 1)' "$xv"; then
    ok "XcodeGen $xv"
  else bad "XcodeGen $xv is older than 2.46.0" "brew upgrade xcodegen"; fi
else
  bad "XcodeGen not installed" "brew install xcodegen"
fi

if command -v python3 >/dev/null 2>&1; then ok "$(python3 --version)"
else bad "python3 not found" "install Python 3.9+"; fi

if [ "$fail" -ne 0 ]; then echo "doctor: FAILED"; exit 1; fi
echo "doctor: all checks passed"
