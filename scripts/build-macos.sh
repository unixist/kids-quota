#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$REPO_ROOT/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$REPO_ROOT/.build/swift-module-cache"
MODE=signed
case "${1:-}" in --unsigned) MODE=unsigned; shift ;; --local) MODE=local; shift ;; esac
[[ $# == 0 ]] || { echo 'Usage: scripts/build-macos.sh [--unsigned | --local]' >&2; exit 2; }
for tool in swift xcodebuild node; do command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }; done
if [[ "$MODE" == signed ]]; then
  : "${TEAM_ID:?Set your Apple developer team ID}"
  : "${SIGN_IDENTITY:?Set the full Developer ID Application certificate name}"
  [[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ && "$SIGN_IDENTITY" == 'Developer ID Application:'* ]] || { echo 'Invalid signing team or identity.' >&2; exit 2; }
fi
node scripts/build-extensions.mjs
if command -v xcodegen >/dev/null; then xcodegen generate; fi
[[ -d KidsQuota.xcodeproj ]] || { echo 'Install XcodeGen and run xcodegen generate.' >&2; exit 1; }
SWIFT_FLAGS=(--configuration release --disable-sandbox)
if [[ "$MODE" == local ]]; then SWIFT_FLAGS+=(--arch arm64 --arch x86_64); fi
swift build "${SWIFT_FLAGS[@]}"
BIN_PATH="$(swift build --show-bin-path "${SWIFT_FLAGS[@]}")"
ARTIFACTS="$REPO_ROOT/dist/$MODE"
mkdir -p "$ARTIFACTS/bin"
for component in service agent bridge; do
  /usr/bin/install -m 0755 "$BIN_PATH/kids-quota-$component" "$ARTIFACTS/bin/kids-quota-$component"
  if [[ "$MODE" == signed ]]; then
    /usr/bin/codesign --force --timestamp --options runtime --identifier "com.kidsquota.$component" --sign "$SIGN_IDENTITY" "$ARTIFACTS/bin/kids-quota-$component"
  elif [[ "$MODE" == local ]]; then
    /usr/bin/codesign --force --options runtime --identifier "com.kidsquota.$component" --sign - "$ARTIFACTS/bin/kids-quota-$component"
  fi
done
[[ -d "$BIN_PATH/kids-quota_KidsQuotaCore.bundle" ]] || { echo 'Missing SwiftPM domain-validation resource bundle.' >&2; exit 1; }
/usr/bin/ditto "$BIN_PATH/kids-quota_KidsQuotaCore.bundle" "$ARTIFACTS/bin/kids-quota_KidsQuotaCore.bundle"
if [[ "$MODE" == unsigned || "$MODE" == local ]]; then
  XCODE_FLAGS=(CODE_SIGNING_ALLOWED=NO)
  if [[ "$MODE" == local ]]; then XCODE_FLAGS+=("ARCHS=arm64 x86_64" ONLY_ACTIVE_ARCH=NO); fi
  xcodebuild -project KidsQuota.xcodeproj -scheme KidsQuota -configuration Release \
    -derivedDataPath "$REPO_ROOT/.build/xcode-$MODE" "${XCODE_FLAGS[@]}" build
  # A new build must not retain an older active extension bundle or stale files.
  /bin/rm -rf "$ARTIFACTS/Kids Quota.app"
  /usr/bin/ditto "$REPO_ROOT/.build/xcode-$MODE/Build/Products/Release/Kids Quota.app" "$ARTIFACTS/Kids Quota.app"
  if [[ "$MODE" == local ]]; then
    LOCAL_APP="$ARTIFACTS/Kids Quota.app"
    FILTER="$LOCAL_APP/Contents/Library/SystemExtensions/com.kidsquota.app.networkfilter.systemextension"
    DISABLED="$LOCAL_APP/Contents/Resources/DisabledExtensions"
    /bin/mkdir -p "$DISABLED"
    # Keep the implementation in the deliverable, outside macOS's activation path.
    /bin/mv "$FILTER" "$DISABLED/"
    /bin/rmdir "$LOCAL_APP/Contents/Library/SystemExtensions"
    /usr/libexec/PlistBuddy -c 'Add :KidsQuotaLocalInstall bool true' "$LOCAL_APP/Contents/Info.plist"
    /usr/bin/codesign --force --options runtime --identifier com.kidsquota.app.networkfilter --sign - "$DISABLED/com.kidsquota.app.networkfilter.systemextension"
    /usr/bin/codesign --force --options runtime --identifier com.kidsquota.app.safari --entitlements "$REPO_ROOT/macos/SafariExtension/SafariExtension.entitlements" --sign - "$LOCAL_APP/Contents/PlugIns/KidsQuotaSafari.appex"
    # Deliberately grant no restricted Network Extension entitlements to this GUI.
    /usr/bin/codesign --force --options runtime --identifier com.kidsquota.app --sign - "$LOCAL_APP"
    /usr/bin/codesign --verify --deep --strict "$LOCAL_APP"
    /bin/mkdir -p "$ARTIFACTS/browser"
    /bin/rm -rf "$ARTIFACTS/browser/chrome"
    /usr/bin/ditto "$REPO_ROOT/extensions/build/chrome" "$ARTIFACTS/browser/chrome"
    node --input-type=module - "$REPO_ROOT" "$ARTIFACTS" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';
const [root, artifacts] = process.argv.slice(2);
const chromeExtensionId = fs.readFileSync(path.join(root,'extensions/build/chrome-extension-id.txt'),'utf8').trim();
if (!/^[a-p]{32}$/.test(chromeExtensionId)) throw new Error('Missing stable Chrome extension ID');
fs.writeFileSync(path.join(artifacts,'local-release.json'),JSON.stringify({schemaVersion:1,chromeExtensionId,networkFilterEnabled:false},null,2)+'\n');
NODE
    for binary in "$ARTIFACTS/bin/kids-quota-service" "$ARTIFACTS/bin/kids-quota-agent" "$ARTIFACTS/bin/kids-quota-bridge" "$LOCAL_APP/Contents/MacOS/Kids Quota" "$LOCAL_APP/Contents/PlugIns/KidsQuotaSafari.appex/Contents/MacOS/KidsQuotaSafari" "$DISABLED/com.kidsquota.app.networkfilter.systemextension/Contents/MacOS/com.kidsquota.app.networkfilter"; do
      # Xcode 27's lipo accepts one architecture per verification reliably.
      for architecture in arm64 x86_64; do /usr/bin/lipo "$binary" -verify_arch "$architecture"; done
    done
    "$REPO_ROOT/scripts/install.sh" --check --local --artifacts "$ARTIFACTS"
    echo 'Universal local artifacts staged in dist/local. No Apple membership is required; app network blocking is disabled.'
  else
    echo 'Unsigned compilation artifacts staged in dist/unsigned. The installer intentionally refuses these.'
  fi
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
