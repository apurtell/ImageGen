#!/bin/bash
# Runs the built Debug macOS app with the given launch options, e.g.
#   scripts/run-mac.sh -UITestMockGemini 1 -SkipNotificationPrompt 1 -SeedDemoData 1
# Build first with scripts/build-mac.sh. Specifying RUN_MAC_BACKGROUND=1 launches in the background without activating the application (open -g).
set -euo pipefail
source "$(dirname "$0")/env.sh"

app="$MAC_DERIVED/Build/Products/Debug/ImageGen.app"
[ -d "$app" ] || { echo "error: $app not found; run scripts/build-mac.sh" >&2; exit 1; }
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"

# Terminate existing app instances to prevent concurrent container access and database store conflicts.
running() { pgrep -f "^$app/Contents/MacOS/" >/dev/null; }
if running; then
  osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do
    running || break
    sleep 0.2
  done
  if running; then
    echo "error: the running $bundle_id did not quit; quit it and try again" >&2
    exit 1
  fi
fi

# Launch via Launch Services (`open`) to configure window server session state.
# Retry to accommodate process termination delays from previous runs.
open_flags=()
[ "${RUN_MAC_BACKGROUND:-}" = "1" ] && open_flags=(-g)
for attempt in 1 2 3 4 5; do
  open ${open_flags[@]+"${open_flags[@]}"} "$app" --args "$@" && exit 0
  [ "$attempt" -lt 5 ] && sleep 1
done
echo "error: couldn't open $app" >&2
exit 1
