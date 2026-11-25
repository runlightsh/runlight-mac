#!/bin/sh
# Everything that must pass before a commit: no dashes, the project generates, it builds, tests pass.
set -eu
cd "$(dirname "$0")/.."
scripts/check-dashes.sh
xcodegen generate --quiet
xcodebuild test \
  -project Runlight.xcodeproj \
  -scheme Runlight \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -quiet
echo "All checks passed."
