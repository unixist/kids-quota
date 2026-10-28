#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
VERSION="${VERSION:-0.1.1}"
MODE=signed; NOTARIZE=0
PACKAGE=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --preview) [[ "$MODE" == signed ]] || { echo 'Choose only one image mode.' >&2; exit 2; }; MODE=preview; shift ;;
    --local) [[ "$MODE" == signed ]] || { echo 'Choose only one image mode.' >&2; exit 2; }; MODE=local; shift ;;
    --package) PACKAGE="${2:?Missing package path}"; shift 2 ;;
    --notarize) NOTARIZE=1; shift ;;
    *) echo 'Usage: create-dmg.sh [--local] [--package PKG] [--notarize] | --preview' >&2; exit 2 ;;
  esac
done
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Version must be major.minor.patch.' >&2; exit 2; }
if [[ "$MODE" == preview ]]; then
  [[ "$NOTARIZE" == 0 && -z "$PACKAGE" ]] || { echo 'A preview cannot contain an installer or be notarized.' >&2; exit 2; }
elif [[ "$MODE" == local ]]; then
  [[ "$NOTARIZE" == 0 ]] || { echo 'Local disk images cannot be notarized without Developer ID signing.' >&2; exit 2; }
  PACKAGE="${PACKAGE:-$REPO_ROOT/dist/KidsQuota-$VERSION-Local.pkg}"
  [[ -f "$PACKAGE" ]] || { echo 'Build a local installer with scripts/package.sh --local first.' >&2; exit 1; }
else
  : "${TEAM_ID:?Set the actual Apple developer team ID}"
  : "${SIGN_IDENTITY:?Set the full Developer ID Application certificate name}"
  [[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ && "$SIGN_IDENTITY" == 'Developer ID Application:'* ]] || { echo 'Invalid signing team or application identity.' >&2; exit 2; }
  PACKAGE="${PACKAGE:-$REPO_ROOT/dist/KidsQuota-$VERSION.pkg}"
  [[ -f "$PACKAGE" ]] || { echo 'Build a signed installer with scripts/package.sh first.' >&2; exit 1; }
  SIGNATURE="$(/usr/sbin/pkgutil --check-signature "$PACKAGE")"
  /usr/bin/grep -E -q "Developer ID Installer: .*\($TEAM_ID\)" <<< "$SIGNATURE" || { echo 'Installer is not signed by the requested Developer ID team.' >&2; exit 1; }
  if [[ "$NOTARIZE" == 1 ]]; then
    : "${NOTARY_PROFILE:?Set a configured notarytool Keychain profile}"
    /usr/bin/xcrun notarytool submit "$PACKAGE" --keychain-profile "$NOTARY_PROFILE" --wait
    /usr/bin/xcrun stapler staple "$PACKAGE"
    /usr/bin/xcrun stapler validate "$PACKAGE"
  fi
fi
mkdir -p "$REPO_ROOT/.build" "$REPO_ROOT/dist"
STAGE="$(/usr/bin/mktemp -d "$REPO_ROOT/.build/dmg.XXXXXX")"
trap '/bin/rm -rf "$STAGE"' EXIT
if [[ "$MODE" == preview ]]; then
  cat > "$STAGE/Start here - PREVIEW.txt" <<'PREVIEW'
KIDS QUOTA — INSTALLATION PREVIEW

This image is a preview of the installation instructions only.
It contains no application or installer and cannot enable protection.

A signed release will contain:
  Install Kids Quota.pkg
  Start here.txt

The release workflow is to open the installer, approve the normal macOS
administrator prompt, then open Kids Quota from Applications in the parent's
administrator account. Select the child's standard Mac account. Chess.com and
ChatGPT each start with six hours per week, resetting Monday.

macOS requires separate approval for the app network filter and Safari extension.
Chrome also needs the published or managed Kids Quota browser extension.

A real release requires the developer's Apple signing/provisioning credentials.
PREVIEW
  OUTPUT="$REPO_ROOT/dist/KidsQuota-$VERSION-PREVIEW.dmg"
  VOLUME='Kids Quota Preview'
elif [[ "$MODE" == local ]]; then
  /usr/bin/ditto "$PACKAGE" "$STAGE/Install Kids Quota.pkg"
  cat > "$STAGE/Start here.txt" <<'LOCAL'
KIDS QUOTA — LOCAL EDITION

This is a real installer for macOS 14 or later, including Apple silicon and Intel.
No Apple developer membership, Xcode, Node.js, or Terminal commands are needed.
It is not Apple-notarized. App network blocking is intentionally disabled.

1. Open “Install Kids Quota.pkg” and follow Installer's administrator prompt.
   If macOS blocks it because the developer cannot be verified, try opening it
   once, then use System Settings → Privacy & Security → Open Anyway and confirm
   only this installer. No global Gatekeeper or SIP changes are needed.

2. Open Kids Quota from Applications in the parent's administrator account.
   Unlock parent settings and select the child's standard Mac login. Chess.com
   and ChatGPT each start with six hours per week, resetting Monday. Repeat
   “Add another child” for other accounts. The background service stays running
   when the parent window is closed. Settings and resets require parent unlock.

3. In EACH child's Chrome, open chrome://extensions, turn on Developer mode,
   choose “Load unpacked”, press Command-Shift-G in the folder picker, and enter:
   /Library/Application Support/KidsQuota/BrowserExtensions/Chrome
   Select that folder. This browser extension is included in the installation;
   there is no Chrome Web Store download. The child can still disable/remove it.

4. Safari uses the bundled native Safari extension. In EACH child's Safari,
   open Settings → Advanced and enable “Show features for web developers”.
   In Settings → Developer, enable “Allow unsigned extensions” (administrator
   authentication may be requested). Enable Kids Quota under Settings → Extensions
   and allow website access. Safari resets the unsigned-extension setting when
   it quits: re-enable it after every Safari restart. This is temporary developer
   installation, not dependable removal-resistant Safari protection.

5. Children can click the Kids Quota hourglass in the Mac menu bar to see their
   remaining time, weekly allowances, included websites, and next reset. It
   starts automatically and needs no parent password. The browser toolbar popup
   also shows remaining time. These views cannot change limits or reset usage.

6. Check coverage in Kids Quota. Sign out and back in, or restart, if an account
   helper is unavailable. Test a short website allowance in each browser.
   After an upgrade, quit and reopen Kids Quota, Chrome, and Safari to use the
   updated components. Re-enable Safari's unsigned-extension permission.

Known limits: selected native-app usage can be counted, but reaching a quota
does NOT cut off a native app's network access in this edition. The Network
Extension is retained as an inactive resource for a future signed release; the
app cannot enable it here. Offline app use is not blocked. Other browsers and
disabled extensions are not protected. Browser permissions are per login account.

“Reset this week” restores only the selected child's current-week time, preserving
weekly limits and the scheduled reset. Scoped read-only HTTP clients remain usable.

All application components are locally ad-hoc signed. The administrator installer
pins their exact code identities in protected storage; ordinary child accounts
cannot edit the service, identity pins, policy, or balances. Never give a child
administrator privileges. This local build is not a managed deployment.
LOCAL
  OUTPUT="$REPO_ROOT/dist/KidsQuota-$VERSION-Local.dmg"
  VOLUME='Kids Quota Local'
else
  /usr/bin/ditto "$PACKAGE" "$STAGE/Install Kids Quota.pkg"
  cat > "$STAGE/Start here.txt" <<'WELCOME'
KIDS QUOTA

1. Double-click “Install Kids Quota.pkg”.
   Follow Installer and enter an administrator name and password when macOS asks.
   No Terminal commands are needed.

2. Open “Kids Quota” in Applications from the parent's administrator account.
   Unlock parent settings with macOS administrator authorization, then choose
   the child's standard Mac account. Chess.com and ChatGPT each start
   with six hours per week, resetting Monday. You can change hours and reset
   settings in the app, add other websites, and select companion applications.

3. Finish protection setup in the app.
   Approve the macOS app network filter when prompted. Enable the Safari
   extension and its website permissions in each child's account. These macOS
   permission prompts are separate from installation and cannot be skipped.

“Reset this week” restores only the selected child's current-week time. It does
not change the weekly limits or next reset day, and requires unlocked parent access.

The parent app is available only to administrators. The protected background
service and browser helpers work in the children's standard accounts.
Children can click the Kids Quota hourglass in the Mac menu bar, or the browser
toolbar button, to see their own remaining time and next reset without a password.
These views are read-only; settings and resets remain restricted to the parent.

The installer starts helpers in existing login sessions where possible. If the
app reports an unavailable account helper, sign out and back in or restart the Mac.
Restart any limited apps after first enabling the network filter.

Chrome requires the published or managed Kids Quota extension supplied with this
release. Installing this package alone does not install Chrome's extension.
WELCOME
  if [[ -n "${CHROME_INSTALL_URL:-}" ]]; then
    [[ "$CHROME_INSTALL_URL" == https://* && "$CHROME_INSTALL_URL" != *$'\n'* && "$CHROME_INSTALL_URL" != *$'\r'* ]] || { echo 'CHROME_INSTALL_URL must be a single HTTPS URL.' >&2; exit 2; }
    printf '\nChrome extension: %s\n' "$CHROME_INSTALL_URL" >> "$STAGE/Start here.txt"
  fi
  OUTPUT="$REPO_ROOT/dist/KidsQuota-$VERSION.dmg"
  VOLUME='Kids Quota'
fi
/usr/bin/hdiutil create -volname "$VOLUME" -srcfolder "$STAGE" -format UDZO -ov "$OUTPUT"
/usr/bin/hdiutil verify "$OUTPUT"
if [[ "$MODE" == signed ]]; then
  /usr/bin/codesign --force --timestamp --identifier com.kidsquota.diskimage --sign "$SIGN_IDENTITY" "$OUTPUT"
  /usr/bin/codesign --verify --strict --test-requirement "=anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_ID\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists" "$OUTPUT"
  if [[ "$NOTARIZE" == 1 ]]; then
    /usr/bin/xcrun notarytool submit "$OUTPUT" --keychain-profile "$NOTARY_PROFILE" --wait
    /usr/bin/xcrun stapler staple "$OUTPUT"
    /usr/bin/xcrun stapler validate "$OUTPUT"
    echo "Signed and notarized disk image: $OUTPUT"
  else echo "Signed disk image (not yet notarized): $OUTPUT"; fi
elif [[ "$MODE" == local ]]; then echo "Local disk image with runnable installer: $OUTPUT"
else echo "Instructions-only preview, with no runnable installer: $OUTPUT"; fi
