#!/bin/bash
# Opt-in live API smoke test (IMPLEMENTATION_PLAN.md section 2.5). Never echoes the key.
#   TEST_RUNNER_GEMINI_API_KEY="$GEMINI_API_KEY" scripts/live-smoke.sh
set -uo pipefail
source "$(dirname "$0")/env.sh"

if [ -z "${TEST_RUNNER_GEMINI_API_KEY:-}" ] && [ -z "${GEMINI_API_KEY:-}" ]; then
  echo "live-smoke: skipped (no GEMINI_API_KEY)"
  exit 0
fi
# xcodebuild forwards TEST_RUNNER_-prefixed variables to the test runner without the prefix.
export TEST_RUNNER_GEMINI_API_KEY="${TEST_RUNNER_GEMINI_API_KEY:-$GEMINI_API_KEY}"
exec "$(dirname "$0")/test.sh" -only-testing:ImageGenTests/LiveSmokeTests
