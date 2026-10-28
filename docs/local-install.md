# Install the local release

Copy **KidsQuota-0.1.2-Local.dmg** to the destination Mac. This is a real installer,
not the earlier instructions-only `PREVIEW.dmg`. The package contains everything
needed to install Kids Quota; the new Mac does not need the repository, Xcode,
Node.js, Python, or an Apple developer membership.

Requires macOS 14 or later on Apple Silicon or Intel, an administrator account
for the parent, and a separate **standard** local account for each child. Chrome
and Safari themselves are not installed by this package.

## Parent setup

1. From the child's standard Mac login, open the DMG and double-click
   **Install Kids Quota.pkg**.
2. If macOS blocks the installer because its developer cannot be verified, open
   **System Settings → Privacy & Security**, find the blocked installer, and
   choose **Open Anyway**. Reopen it and follow the normal Installer prompts.
   Approve this specific package; no global Gatekeeper or SIP change is needed.
3. Enter the parent's administrator username and password when Installer requests them.
4. Open **Kids Quota** from Applications in the same login.
   If macOS separately blocks this app, use the same **Open Anyway** flow for
   Kids Quota. Choose **Unlock parent settings** and enter the parent's
   administrator credentials in the macOS prompt.
5. Choose the child's standard local account and click **Set up account**.
   Chess.com and ChatGPT each start at **six hours per week**, resetting Monday
   at midnight in the saved timezone. Add additional children later if needed.

You may also use the parent's login, but switching accounts is not required.
The Mac's root account does not need to be enabled. The app locks when you switch
apps, close the window, switch login sessions, choose Lock, or reach five minutes
after unlocking. The parent password is entered only in macOS's authorization UI.
Use Touch ID if that prompt offers it. Otherwise enter the parent's administrator
username and password. Cross-account Touch ID is not guaranteed: Apple associates
fingerprints with individual accounts and controls which authentication methods
are available. See [Authorization Services](https://developer.apple.com/documentation/security/authorization-services)
and [Touch ID on Mac](https://support.apple.com/guide/mac-help/use-touch-id-mchl16fbf90a/mac).

The root service starts automatically. The installer also starts activity agents
in existing GUI sessions where possible; otherwise sign out and back in or restart.
The parent app need not stay open for quotas to run.
Each installed login agent registers the bundled Safari extension for discovery
without opening the parent settings app or enabling the extension.

Apple documents the per-app approval flow in
[Safely open apps on your Mac](https://support.apple.com/102445).

## How children see their remaining time

Click the **Kids Quota hourglass in the Mac menu bar** while signed into the
child's account. It appears automatically with the login agent. It shows the
current child's remaining time, weekly allowances, included domains, and next
reset, and refreshes every five seconds while open. No parent password or browser
is needed. If the hourglass is missing after installation, sign out and back in.

The **Kids Quota browser toolbar button** in Chrome or Safari also shows the
remaining balances and next reset. Multiple domains in one service share one
balance. These screens are read-only; children cannot change limits, reset usage,
or switch to a sibling's balances. An unlinked login shows that parent setup is
needed. If the service cannot be reached, balances are hidden until it reconnects.

## Chrome setup in each child's account

1. Sign into the child's macOS account and open Chrome.
2. Visit `chrome://extensions` and enable **Developer mode**.
3. Click **Load unpacked**. In the folder picker, press **Command–Shift–G** and enter:

   ```text
   /Library/Application Support/KidsQuota/BrowserExtensions/Chrome
   ```

4. Select that folder. Allow the extension to access all websites so future
   custom services can work. Repeat for every Chrome profile the child uses.
5. Open Chess.com or ChatGPT and check the Kids Quota popup. The parent dashboard
   should show usage changing while the website is foreground and the Mac unlocked.

The installer registers the machine-wide native messaging host. The included
public manifest key gives the unpacked extension the same ID on both computers;
no extension-ID copying or terminal command is needed on the destination Mac.
The browser files are root-owned, but Chrome still lets a child disable/remove an
unpacked extension. This local build does not implement managed forced installation.

## Safari setup and its limitation

For Safari 17 or later, in each child's account:

1. Open **Safari → Settings → Advanced** and enable **Show features for web developers**.
2. In **Settings → Developer**, enable **Allow unsigned extensions**.
3. In **Settings → Extensions**, enable **Kids Quota** and allow it on all websites.

**Safari resets “Allow unsigned extensions” whenever it quits.** The setting must
be enabled again after restarting Safari. This makes the included unsigned Safari
extension unsuitable for unattended enforcement across browser restarts. Chrome
does not have this particular unsigned-Safari restriction. Apple documents the
behavior in [Running your Safari web extension](https://developer.apple.com/documentation/safariservices/running-your-safari-web-extension).

## What works and what remains inactive

| Component | Local release behavior |
| --- | --- |
| Quota service and SQLite ledger | Tracks weekly time, stores independent child balances, and resets on schedule. |
| Parent app | Launches locked from any login; a parent's administrator credentials authorize setup, hours, custom domains/apps, manual reset, and read-client tokens. |
| Child menu bar view | Current login's remaining time, weekly allowances, covered domains, and next reset; read-only and automatically started. |
| Chrome extension | Website measurement and blocking after manual installation and website permission. |
| Safari extension | Website measurement and blocking while enabled; unsigned permission resets on quit. |
| Selected native apps | Foreground usage can share the website's allowance, but the native app is **not blocked** at exhaustion. |
| Network Extension | Included as a dormant component; no activation or network interception. |
| HTTP read clients | Scoped local REST reads remain available. |

The native filter bundle is retained under
`Kids Quota.app/Contents/Resources/DisabledExtensions`, outside the system-extension
activation directory. The local parent app has no restricted network-extension
entitlements, its activation method refuses local mode, and the local daemon does
not accept a filter peer. A later signed build can restore this optional feature.

## Access controls and updates

The installer requires administrator authorization. It installs root-owned app
and service files, gives the parent executable mode `0755`, and stores the protected
ledger and credentials under `/Library/Application Support/KidsQuota`. A standard
account can launch the locked app but cannot change its installed files.
The daemon validates the parent app and its temporary `com.kidsquota.manage` grant
for every native parent request. The GUI never reads or saves a persistent parent
bearer token; configuration and resets require macOS administrator authorization.
HTTP remains read-only and uses separate scoped tokens for integrations.

The local build uses **ad-hoc signatures**, which verify code integrity but do not
identify an Apple-approved publisher. During installation, the installer records
the exact native components' code hashes in root-protected `local-trust.json`.
The daemon validates its own executable and incoming native clients against these
pins and their protected paths. It does not use the relaxed development-mode
basename checks. Upgrades replace the binaries and pins together and preserve
existing policy and usage data.
After upgrading, quit and reopen Kids Quota, Chrome, and Safari so their processes
use the newly pinned binaries. Re-enable Safari's unsigned-extension permission.

For a first check, use a short allowance in a test child account and verify that
both an already-open page and a new navigation block. Native-app access should
remain available because its blocking layer is deliberately disabled. A build
and package inspection do not establish real browser enforcement on every Mac.
