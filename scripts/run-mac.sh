#!/bin/bash
# Runs the built macOS app binary with the given launch options, e.g.
#   scripts/run-mac.sh -UITestMockGemini 1 -SkipNotificationPrompt 1 -SeedDemoData 1
# Build first with scripts/build-mac.sh.
set -euo pipefail
source "$(dirname "$0")/env.sh"

app="$MAC_DERIVED/Build/Products/Debug/ImageGen.app/Contents/MacOS/ImageGen"
[ -x "$app" ] || { echo "error: $app not found; run scripts/build-mac.sh" >&2; exit 1; }
exec "$app" "$@"
