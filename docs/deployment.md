# Build and install

The repository has two installation profiles. The **local profile** requires no
Apple developer membership, bundles a stable unpacked Chrome extension, and keeps
the Network Extension inactive. The **Developer ID profile** enables the signed
distribution path and requires Apple signing/provisioning for the native filter.
Builds do not install anything or enable a network filter. Apple submissions occur
only with the explicit `--notarize` release option. Use a dedicated test Mac for the
first signed installation.

## Membership-free local DMG

```sh
scripts/build-macos.sh --local
scripts/package.sh --local
```

This builds universal Apple Silicon/Intel artifacts and creates the real
`dist/KidsQuota-0.1.0-Local.pkg` and `dist/KidsQuota-0.1.0-Local.dmg`. Only the DMG
needs to be copied to the new Mac. It contains **Install Kids Quota.pkg** and
**Start here.txt**. The package needs no development tools on the destination.
See [local installation](local-install.md) for Gatekeeper approval, child browser
setup, and Safari's permission-reset limitation.

Local code uses ad-hoc hardened-runtime signatures and exact build hashes rather
than an Apple Team ID. The root installer pins the service, agent, Chrome host,
parent app, and Safari handler in `local-trust.json`. The daemon runs with
`--local-install`, validates its own pin, and checks incoming clients' pins,
protected paths, roles, and OS account identities. The existing parent grant/token
checks remain. Neither a root daemon nor any client runs with `--development`.

The network filter is stored under the app's `Contents/Resources/DisabledExtensions`
and cannot be activated through the local UI. Native-app usage can still be
counted but cannot be blocked by this release. These limitations are displayed
in the parent interface. No Apple signing credentials or notarization submissions
are used by the local packaging path.

## Install from the disk image

For the separate Developer ID release, the parent opens `KidsQuota-<version>.dmg`, then double-clicks
**Install Kids Quota.pkg**. macOS Installer requests an administrator name and
password. No Terminal commands are needed. The image also contains a one-page
**Start here.txt** with the remaining setup steps.

Open **Kids Quota** from Applications in the parent's administrator account,
choose **Unlock parent settings**, then confirm the child's standard Mac account.
Each child starts with separate six-hour
weekly allowances for Chess.com and ChatGPT, resetting Monday. Select any companion
applications and finish the browser/filter approvals. The installer does not guess
application signers or publish/install a Chrome extension without a real release ID.

macOS requires approval for the Network Extension and Safari extension permissions;
an ordinary installer cannot silently grant them. Chrome also needs its published or
managed browser extension. These permissions remain necessary after the package
finishes. A file named `PREVIEW.dmg` is an instructions-only demonstration and
contains no application or installer.

## Compile and sign

Install full Xcode and Node.js. XcodeGen regenerates `KidsQuota.xcodeproj` from
`project.yml` when available; the generated project is also included. Build the
unsigned app, embedded extensions, and command-line tools with:

```sh
scripts/build-macos.sh --unsigned
```

These artifacts go into `dist/unsigned` and cannot pass the production installer.
For a signed release, configure the three app targets' capabilities and provisioning
in Xcode first, then set your actual values in the shell:

```sh
export TEAM_ID
export SIGN_IDENTITY
scripts/build-macos.sh
```

`TEAM_ID` is the Apple team identifier. `SIGN_IDENTITY` is the full
`Developer ID Application: …` certificate name in your Keychain. The script archives
the containing app and exports with Xcode's `developer-id` distribution method.
It does not request new provisioning profiles automatically. The macOS Network
Extension entitlement must be available for your team. See Apple's
[Network Extension deployment guidance](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment).

The command-line binaries are signed with hardened runtime and these identities:

| Component | Signing identifier |
| --- | --- |
| Machine service | `com.kidsquota.service` |
| Per-login activity collector | `com.kidsquota.agent` |
| Chrome native host | `com.kidsquota.bridge` |
| Parent app | `com.kidsquota.app` |
| Safari extension | `com.kidsquota.app.safari` |
| App network filter | `com.kidsquota.app.networkfilter` |

All must use the same team. The installer validates Developer ID signatures,
identifiers, hardened runtime, and presence of the bundled Public Suffix List.
An unsigned build proves compilation only. It does not prove that approved
entitlements, Safari's runtime transport, app attribution, or live filtering work.
See the signed validation cases in [macOS build notes](macos-build.md).

## Direct administrator installation (development/deployment)

After setting `CHROME_EXTENSION_ID` to the real published or managed release's ID:

```sh
sudo scripts/install.sh --artifacts "$PWD/dist/signed" \
  --team-id "$TEAM_ID" --chrome-extension-id "$CHROME_EXTENSION_ID"
```

Omit the Chrome option for a Safari-only installation. Re-running with the correct
ID creates or updates Chrome's machine-wide native host registration. It does not
install the Chrome extension itself. A locally loaded unpacked extension is useful
for development but can be disabled or removed by the child.

The installer copies root-owned binaries and their SwiftPM resource bundle to
`/Library/Application Support/KidsQuota/bin`, copies `Kids Quota.app` to
`/Applications`, installs a root LaunchDaemon and an Aqua LaunchAgent, initializes
the database, then starts the daemon. Standard users cannot modify these installed
files. Only the parent app's main executable is `root:admin`, mode `0750`, with
its ACL removed: standard accounts cannot read, copy, or run that installed binary.
The containing bundle, embedded Safari/filter extensions, and their resources stay
traversable and executable for the child and OS extension host. The service and
native helpers remain `root:wheel`, mode `0755`. The installer verifies signatures
after setting these permissions; it does not weaken native/API authorization.

The data directory grants others traversal only so child accounts can run
the agent and native host. Its database and credential registry are root-only;
`admin.token` is `root:admin`, mode `0640`. Never distribute that token to children,
widgets, websites, or extensions. The parent app reads its credential only after
administrator unlock; credentials entered in Settings are saved in the parent's
Keychain. Issue scoped read-only clients from Settings for integrations.

The installer discovers local accounts and starts the collector only in GUI
sessions that launchd confirms exist, including existing child sessions. It never
opens the parent app or runs a GUI collector as root. Accounts without a current GUI
session load it at next login. If a session cannot load the agent, sign out and back
in or restart the Mac. Open Kids Quota as the parent, bind the children's standard accounts, set service allowances,
and select any companion apps. Use Settings → Protection to request app-filter
activation and approve the system prompts. Enable Safari's extension and its
website permissions in each child's account, and install the Chrome extension.
Restart limited apps after activating the filter to include existing connections.
The service listens only on `127.0.0.1:48123` and uses `/var/run/kids-quota.sock`
for authenticated native clients.

## Build the signed disk image

The package wraps the same verified installer. In addition to `TEAM_ID` and
`SIGN_IDENTITY` used for the application build, set `INSTALLER_IDENTITY` to your
full `Developer ID Installer: …` certificate name:

```sh
export TEAM_ID SIGN_IDENTITY INSTALLER_IDENTITY CHROME_EXTENSION_ID
scripts/package.sh
```

This creates `dist/KidsQuota-0.1.0.pkg` and a signed `dist/KidsQuota-0.1.0.dmg`.
The DMG contains the package named **Install Kids Quota.pkg** and **Start here.txt**.
Set `CHROME_INSTALL_URL` to your actual HTTPS extension installation link to add it
to the instructions. Set `VERSION=major.minor.patch` for another release.
Use `scripts/package.sh --pkg-only` for MDM deployments that need only a package.
An existing signed package can be wrapped with
`scripts/create-dmg.sh --package /absolute/path/to/release.pkg`.

The installer is a script-based package that runs only on the startup volume; its
receipt does not enumerate installed payload files. Existing policy/usage data
is retained by the installer. Normal packaging signs both artifacts but does not
notarize them.
Updates stage clean app and binary directories, verify their signatures, and keep
the previous artifacts until service startup succeeds. A trapped installation
failure restores the prior artifacts and restarts the prior service registration.
Power loss or a forced kill during replacement still requires administrator recovery;
the script leaves private staging directories available in that case.
For distribution, explicitly request notarization using your configured Apple
notarytool Keychain profile:

```sh
export NOTARY_PROFILE
scripts/package.sh --notarize
```

This uploads the package to Apple, waits, staples and validates its ticket, then
does the same for the enclosing signed disk image. The script stops on a failed
submission or staple validation. Confirm the returned results and test the installed
release; signing alone is not approval or proof of enforcement. See Apple's
[notarization guidance](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

Without signing credentials, `scripts/create-dmg.sh --preview` makes
`dist/KidsQuota-0.1.0-PREVIEW.dmg` containing instructions only. It cannot install
or enable protection. Packaging unit tests use temporary fixtures and mock signing,
launchd, and disk-image utilities:

```sh
python3 -B -m unittest discover -s Tests/packaging -v
```

## Managed browser installation

Generate deployment examples with your actual identities:

```sh
python3 deployment/render-policies.py --team-id "$TEAM_ID" \
  --chrome-extension-id "$CHROME_EXTENSION_ID" --output dist/mdm
```

The generator validates identity formats and writes files without installing them.
The default update URL is the Chrome Web Store. A private release must supply an
actual HTTPS update-manifest URL with `--chrome-update-url` and publish matching
signed extension updates. Import these files through an MDM service that supports
the indicated payloads; review existing policy before merging them.

- `chrome-force-install.mobileconfig` uses `ExtensionInstallForcelist` in the
  `com.google.Chrome` preference domain. Chrome prevents removal through its UI.
  On macOS, force installation outside the Web Store needs MDM, MCX, or Chrome
  Enterprise Core enrollment. This policy does not cover Incognito. Consider
  managed Incognito/guest restrictions and approved browser restrictions for the
  child fleet; these affect the managed scope, potentially including parents.
  Google's documentation describes removal protection as best effort, including
  external modification and developer-tool limitations.
  [Chromium policy definition](https://raw.githubusercontent.com/chromium/chromium/main/components/policy/resources/templates/policy_definitions/Extensions/ExtensionInstallForcelist.yaml).
  The profile also sets `NativeMessagingUserLevelHosts=false`, so a child cannot
  replace the machine native host with a host manifest in their own profile.
  This applies to all native hosts within the managed scope.
  [Chromium native-host policy](https://raw.githubusercontent.com/chromium/chromium/main/components/policy/resources/templates/policy_definitions/NativeMessaging/NativeMessagingUserLevelHosts.yaml).
- `safari-always-on.json` is a declarative configuration delivered on the user
  channel of supervised macOS 15+ devices. It requires the installed host app, uses the composed
  extension ID plus real team, enables normal and private browsing, and grants
  website access for future custom domains. Connect it to an MDM activation
  declaration; it is not a manually installable configuration profile. macOS 14
  supports this app but requires manual Safari extension setup and has weaker
  anti-removal behavior.
  [Apple's Safari extension schema](https://raw.githubusercontent.com/apple/device-management/release/declarative/declarations/configurations/safari.extensions.settings.yaml).
- `system-extension-approval.mobileconfig` approves only this app's filter, rather
  than every extension signed by the team. It requires eligible user-approved
  device MDM enrollment and still needs the containing app to request activation.
  Add `--non-removable` for macOS 15+ devices with SIP enabled to emit
  `NonRemovableSystemExtensions`; plan how an administrator will remove that
  profile for maintenance. This does not itself configure the content filter.
  [Apple's System Extensions schema](https://raw.githubusercontent.com/apple/device-management/release/mdm/profiles/com.apple.system-extension-policy.yaml).

These templates strengthen deployment without changing quota accounting. They do
not make this release child-proof. A standard account can still disrupt its own
unmanaged login agent or browser, use an unsupported browser or remote service,
and use cached offline app features. Missing collectors or extension connectivity
must be treated as incomplete protection in the dashboard. Managed login items,
app allowlisting, removal-resistant enrollment, and live tamper testing are separate
deployment work before claiming robust enforcement. The network filter blocks
network flows of the selected signed apps; it does not stop those apps from launching
or disable offline features.
