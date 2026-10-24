#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$REPO_ROOT/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$REPO_ROOT/.build/swift-module-cache"
MODE=signed
if [[ "${1:-}" == --unsigned ]]; then MODE=unsigned; shift; fi
[[ $# == 0 ]] || { echo 'Usage: scripts/build-macos.sh [--unsigned]' >&2; exit 2; }
for tool in swift xcodebuild node; do command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }; done
if [[ "$MODE" == signed ]]; then
  : "${TEAM_ID:?Set your Apple developer team ID}"
  : "${SIGN_IDENTITY:?Set the full Developer ID Application certificate name}"
  [[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ && "$SIGN_IDENTITY" == 'Developer ID Application:'* ]] || { echo 'Invalid signing team or identity.' >&2; exit 2; }
fi
node scripts/build-extensions.mjs
if command -v xcodegen >/dev/null; then xcodegen generate; fi
[[ -d KidsQuota.xcodeproj ]] || { echo 'Install XcodeGen and run xcodegen generate.' >&2; exit 1; }
swift build --configuration release --disable-sandbox
BIN_PATH="$(swift build --configuration release --show-bin-path --disable-sandbox)"
ARTIFACTS="$REPO_ROOT/dist/$MODE"
mkdir -p "$ARTIFACTS/bin"
for component in service agent bridge; do
  /usr/bin/install -m 0755 "$BIN_PATH/kids-quota-$component" "$ARTIFACTS/bin/kids-quota-$component"
  if [[ "$MODE" == signed ]]; then
    /usr/bin/codesign --force --timestamp --options runtime --identifier "com.kidsquota.$component" --sign "$SIGN_IDENTITY" "$ARTIFACTS/bin/kids-quota-$component"
  fi
done
[[ -d "$BIN_PATH/kids-quota_KidsQuotaCore.bundle" ]] || { echo 'Missing SwiftPM domain-validation resource bundle.' >&2; exit 1; }
/usr/bin/ditto "$BIN_PATH/kids-quota_KidsQuotaCore.bundle" "$ARTIFACTS/bin/kids-quota_KidsQuotaCore.bundle"
if [[ "$MODE" == unsigned ]]; then
  xcodebuild -project KidsQuota.xcodeproj -scheme KidsQuota -configuration Release \
    -derivedDataPath "$REPO_ROOT/.build/xcode-release" CODE_SIGNING_ALLOWED=NO build
  /usr/bin/ditto "$REPO_ROOT/.build/xcode-release/Build/Products/Release/Kids Quota.app" "$ARTIFACTS/Kids Quota.app"
  echo 'Unsigned compilation artifacts staged in dist/unsigned. The installer intentionally refuses these.'
else
  ARCHIVE="$REPO_ROOT/.build/KidsQuota.xcarchive"
  OPTIONS="$REPO_ROOT/.build/ExportOptions.plist"
  /bin/rm -f "$OPTIONS"
  /usr/bin/plutil -create xml1 "$OPTIONS"
  /usr/bin/plutil -insert method -string developer-id "$OPTIONS"
  /usr/bin/plutil -insert teamID -string "$TEAM_ID" "$OPTIONS"
  /usr/bin/plutil -insert signingStyle -string automatic "$OPTIONS"
  /usr/bin/plutil -insert signingCertificate -string "$SIGN_IDENTITY" "$OPTIONS"
  # Provisioning profiles must already be available. This does not change the
  # developer account, grant capabilities, or upload anything to Apple.
  xcodebuild -project KidsQuota.xcodeproj -scheme KidsQuota -configuration Release \
    -archivePath "$ARCHIVE" DEVELOPMENT_TEAM="$TEAM_ID" archive
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$ARTIFACTS" -exportOptionsPlist "$OPTIONS"
  "$REPO_ROOT/scripts/install.sh" --check --artifacts "$ARTIFACTS" --team-id "$TEAM_ID"
  echo 'Developer ID artifacts staged in dist/signed. Notarize the distribution before external deployment.'
fi
