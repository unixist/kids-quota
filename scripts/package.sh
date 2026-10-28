#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PKG_ONLY=0; NOTARIZE=0; MODE=signed
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pkg-only) PKG_ONLY=1; shift ;;
    --local) MODE=local; shift ;;
    --notarize) NOTARIZE=1; shift ;;
    *) echo 'Usage: package.sh [--local] [--pkg-only] [--notarize]' >&2; exit 2 ;;
  esac
done
if [[ "$MODE" == signed ]]; then
  : "${TEAM_ID:?Set the actual Apple developer team ID}"
  : "${INSTALLER_IDENTITY:?Set the full Developer ID Installer certificate name}"
  [[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ && "$INSTALLER_IDENTITY" == 'Developer ID Installer:'* ]] || { echo 'Invalid signing team or installer identity.' >&2; exit 2; }
  if [[ "$PKG_ONLY" == 0 ]]; then : "${SIGN_IDENTITY:?Set the Developer ID Application identity to sign the disk image}"; fi
  if [[ "$NOTARIZE" == 1 ]]; then : "${NOTARY_PROFILE:?Set a configured notarytool Keychain profile}"; fi
else
  [[ "$NOTARIZE" == 0 ]] || { echo 'A local release cannot be notarized without Developer ID signing.' >&2; exit 2; }
fi
CHROME_EXTENSION_ID="${CHROME_EXTENSION_ID:-}"
[[ -z "$CHROME_EXTENSION_ID" || "$CHROME_EXTENSION_ID" =~ ^[a-p]{32}$ ]] || { echo 'Invalid Chrome extension ID.' >&2; exit 2; }
VERSION="${VERSION:-0.1.1}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Version must be major.minor.patch.' >&2; exit 2; }
INSTALL_ARGS=(--artifacts "$REPO_ROOT/dist/$MODE")
SUFFIX=''
if [[ "$MODE" == local ]]; then INSTALL_ARGS+=(--local); SUFFIX='-Local'
else INSTALL_ARGS+=(--team-id "$TEAM_ID"); fi
if [[ -n "$CHROME_EXTENSION_ID" ]]; then INSTALL_ARGS+=(--chrome-extension-id "$CHROME_EXTENSION_ID"); fi
"$REPO_ROOT/scripts/install.sh" --check "${INSTALL_ARGS[@]}"
mkdir -p "$REPO_ROOT/.build" "$REPO_ROOT/dist"
STAGE="$(/usr/bin/mktemp -d "$REPO_ROOT/.build/package.XXXXXX")"
trap '/bin/rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/scripts" "$REPO_ROOT/dist"
/usr/bin/ditto "$REPO_ROOT/dist/$MODE" "$STAGE/scripts/artifacts"
/usr/bin/install -m 0755 "$REPO_ROOT/scripts/install.sh" "$STAGE/scripts/install.sh"
/usr/bin/install -m 0755 "$REPO_ROOT/scripts/create-local-trust.sh" "$STAGE/scripts/create-local-trust.sh"
if [[ "$MODE" == local ]]; then INSTALL_MODE='--local'
else INSTALL_MODE="--team-id $TEAM_ID"; fi
cat > "$STAGE/scripts/postinstall" <<POSTINSTALL
#!/bin/bash
set -euo pipefail
[[ "\${3:-/}" == / ]] || { echo 'Kids Quota must be installed on the running startup volume.' >&2; exit 1; }
PACKAGE_SCRIPTS="\$(cd "\$(dirname "\$0")" && pwd)"
exec "\$PACKAGE_SCRIPTS/install.sh" --artifacts "\$PACKAGE_SCRIPTS/artifacts" $INSTALL_MODE ${CHROME_EXTENSION_ID:+--chrome-extension-id "$CHROME_EXTENSION_ID"}
POSTINSTALL
chmod 0755 "$STAGE/scripts/postinstall"
# The same installer is used for direct and packaged deployment. All artifacts
# are signed/checked before the root postinstall makes changes.
PACKAGE_ARGS=(--nopayload --scripts "$STAGE/scripts" --identifier com.kidsquota.installer --version "$VERSION")
if [[ "$MODE" == signed ]]; then PACKAGE_ARGS+=(--sign "$INSTALLER_IDENTITY"); fi
/usr/bin/pkgbuild "${PACKAGE_ARGS[@]}" "$REPO_ROOT/dist/KidsQuota-$VERSION$SUFFIX.pkg"
if [[ "$MODE" == signed ]]; then /usr/sbin/pkgutil --check-signature "$REPO_ROOT/dist/KidsQuota-$VERSION.pkg"; fi
if [[ "$PKG_ONLY" == 0 ]]; then
  if [[ "$MODE" == local ]]; then "$REPO_ROOT/scripts/create-dmg.sh" --local
  elif [[ "$NOTARIZE" == 1 ]]; then "$REPO_ROOT/scripts/create-dmg.sh" --notarize
  else "$REPO_ROOT/scripts/create-dmg.sh"; fi
elif [[ "$NOTARIZE" == 1 ]]; then
  /usr/bin/xcrun notarytool submit "$REPO_ROOT/dist/KidsQuota-$VERSION.pkg" --keychain-profile "$NOTARY_PROFILE" --wait
  /usr/bin/xcrun stapler staple "$REPO_ROOT/dist/KidsQuota-$VERSION.pkg"
  /usr/bin/xcrun stapler validate "$REPO_ROOT/dist/KidsQuota-$VERSION.pkg"
elif [[ "$MODE" == local ]]; then echo "Local installer created: $REPO_ROOT/dist/KidsQuota-$VERSION-Local.pkg"
else echo 'Signed installer created. Notarization/stapling remains a distribution step; no Apple submission was performed.'; fi
