#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
command -v xcodegen >/dev/null || { echo 'Install XcodeGen first (brew install xcodegen).' >&2; exit 1; }
cd "$repo/ios"
xcodegen generate --spec project.yml
xcodebuild -project KidsQuotaPhone.xcodeproj -scheme KidsQuotaPhone \
  -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$repo/dist/ios-simulator" CODE_SIGNING_ALLOWED=NO build "$@"
