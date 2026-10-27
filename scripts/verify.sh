#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo 'XcodeGen is required. Install it with: brew install xcodegen' >&2
  exit 1
fi
if ! xcodebuild -version >/dev/null 2>&1; then
  echo 'A full Xcode installation is required. Set DEVELOPER_DIR to its Contents/Developer directory.' >&2
  exit 1
fi

swift test
xcodegen generate --spec project.yml
xcodebuild \
  -project LuckyAgent.xcodeproj \
  -scheme LuckyAgent \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "${LUCKYAGENT_DERIVED_DATA:-build/DerivedData}" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build-for-testing
