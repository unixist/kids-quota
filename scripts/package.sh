#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
: "${TEAM_ID:?Set the actual Apple developer team ID}"
: "${INSTALLER_IDENTITY:?Set the full Developer ID Installer certificate name}"
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ && "$INSTALLER_IDENTITY" == 'Developer ID Installer:'* ]] || { echo 'Invalid signing team or installer identity.' >&2; exit 2; }
CHROME_EXTENSION_ID="${CHROME_EXTENSION_ID:-}"
[[ -z "$CHROME_EXTENSION_ID" || "$CHROME_EXTENSION_ID" =~ ^[a-p]{32}$ ]] || { echo 'Invalid Chrome extension ID.' >&2; exit 2; }
VERSION="${VERSION:-0.1.0}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Version must be major.minor.patch.' >&2; exit 2; }
"$REPO_ROOT/scripts/install.sh" --check --artifacts "$REPO_ROOT/dist/signed" --team-id "$TEAM_ID"
STAGE="$(/usr/bin/mktemp -d "$REPO_ROOT/.build/package.XXXXXX")"
trap '/bin/rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/scripts" "$REPO_ROOT/dist"
/usr/bin/ditto "$REPO_ROOT/dist/signed" "$STAGE/scripts/artifacts"
/usr/bin/install -m 0755 "$REPO_ROOT/scripts/install.sh" "$STAGE/scripts/install.sh"
cat > "$STAGE/scripts/postinstall" <<POSTINSTALL
#!/bin/bash
set -euo pipefail
[[ "\${3:-/}" == / ]] || { echo 'Kids Quota must be installed on the running startup volume.' >&2; exit 1; }
PACKAGE_SCRIPTS="\$(cd "\$(dirname "\$0")" && pwd)"
exec "\$PACKAGE_SCRIPTS/install.sh" --artifacts "\$PACKAGE_SCRIPTS/artifacts" --team-id "$TEAM_ID" ${CHROME_EXTENSION_ID:+--chrome-extension-id "$CHROME_EXTENSION_ID"}
POSTINSTALL
chmod 0755 "$STAGE/scripts/postinstall"
# The same installer is used for direct and packaged deployment. All artifacts
# are signed/checked before the root postinstall makes changes.
/usr/bin/pkgbuild --nopayload --scripts "$STAGE/scripts" --identifier com.kidsquota.installer \
  --version "$VERSION" --sign "$INSTALLER_IDENTITY" "$REPO_ROOT/dist/KidsQuota-$VERSION.pkg"
/usr/sbin/pkgutil --check-signature "$REPO_ROOT/dist/KidsQuota-$VERSION.pkg"
echo 'Signed installer created. Notarization/stapling remains a distribution step; no Apple submission was performed.'
