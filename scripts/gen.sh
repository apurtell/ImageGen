#!/bin/bash
# Generates ImageGen.xcodeproj from project.yml.
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$REPO_ROOT"
xcodegen generate --spec project.yml
