# Build the native macOS app

The repository includes a SwiftUI parent app, Safari Web Extension native wrapper,
and a Network Extension content filter. The app supports macOS 14 or later.
The UI uses the same REST handlers through a root-authenticated Unix socket.
Read clients can use `http://127.0.0.1:48123/v1`. The privileged parent bearer is
never sent to an unverified loopback TCP listener.

For the current membership-free installer, use `scripts/build-macos.sh --local`
followed by `scripts/package.sh --local`. This builds universal ad-hoc-signed
components, installs exact code-hash trust pins, and keeps the Network Extension
inactive. The parent app omits restricted network-extension entitlements in this
profile. See [local setup](local-install.md) for manual browser setup and Safari's
unsigned-permission reset behavior. The Developer ID steps below describe the
separate optional full-filter release.

## Build and unit tests

Install Xcode and XcodeGen, then, from the repository root:

```sh
npm run build:extensions
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project KidsQuota.xcodeproj -scheme KidsQuota -configuration Debug \
  -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project KidsQuota.xcodeproj -scheme KidsQuotaMacTests -destination 'platform=macOS' \
  -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO test
```

An unsigned build checks the source, resources, and bundle structure. It **does not
activate a filter or install browser protection**. Xcode's SwiftUI compiler plugins
must be allowed to launch; an outer sandbox can otherwise produce misleading
“external macro implementation type could not be found” errors.

`project.yml` is the project source. Generate the Xcode project after rebuilding
browser resources. The full-profile `Kids Quota.app` embeds both extensions. The Safari manifest and
scripts are copied directly into its extension's Resources directory.

## Developer ID signing and enabling the optional filter

For independent distribution, sign the app and system extension with your Apple
Developer ID team, provision the Network Extension capability, use the supplied
`content-filter-provider-systemextension` entitlement, enable the hardened runtime,
and notarize the release. Sign the daemon/native host/login agent with the **same
team** so the daemon's IPC peer verification can authenticate the extensions.
Do not replace that verification with executable-name checks in production.

The generated project intentionally has no personal team ID. Configure your team
and provisioning profiles in Xcode. Apple Development and App Store entitlement
values differ from Developer ID distribution; consult Apple's [Network Extension
provider deployment](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment)
and [export guidance](https://developer.apple.com/forums/tags/systemextensions).
The release packaging and Apple provisioning credentials are not supplied here.

Install the signed containing app in `/Applications`, and install the daemon and
login agent using the repository's administrator installation steps. Open Kids
Quota in an administrator's account. The app starts locked, without reading tokens
or loading household configuration. **Unlock parent settings** requests
`system.privilege.admin` using macOS Authorization Services; the app itself stays at
ordinary user privilege. The daemon verifies both the peer's administrator membership
and the external authorization form on every parent request. The initial token is
read only after authorization, from
`/Library/Application Support/KidsQuota/admin.token`, readable only by root and
administrators. A manually entered token is validated before saving to the parent's
Keychain. For local UI smoke tests, a Debug build can use `KIDS_QUOTA_DATA_DIR` for the
development `admin.token`, plus `KIDS_QUOTA_DEVELOPMENT=1` and `KIDS_QUOTA_SOCKET`
for the development daemon socket. This explicit Debug-only mode verifies the
server is owned by the current UID instead of root. Release builds ignore these
socket overrides and require a root peer. Never use production credentials in
development mode.

In Settings → Protection, **Enable app network filter** requests macOS approval
and saves `NEFilterManager` configuration. This is an explicit user action, not a
build step. Follow macOS's System Settings prompts and restart if requested.
After enabling protection or adding a new child, restart limited apps so pre-existing
connections are captured. Enable the Safari extension in Safari settings for each
child and grant website permission. Install Chrome's generated extension and its
native messaging host using the browser setup instructions.

## Parent workflow

1. Unlock parent settings, then choose one standard macOS username on the first-run
   screen. Its account display name is used automatically. The picker excludes
   administrator accounts and stores the verified account's GeneratedUID.
2. Chess.com and ChatGPT are added with six hours per week each. The main screen
   shows this child's allowances directly. **Add service** adds custom websites;
   Settings → **Add another child** adds another login later. A child selector appears
   when more than one child is configured. Presets are website-only until an app is
   explicitly selected and verified.
3. Expand **Includes → Manage included websites and apps** to select an app using
   the macOS app picker. The daemon verifies its code signature. No guessed vendor
   signer or filename match is treated as verified. This screen names all children
   affected by the shared service definition. Moving a signed app does not change
   its identity; a different signer requires review.
4. Use **Edit hours** to change one child's allowance without clearing consumed
   time. **Reset this week** confirms the selected child's name and clears that
   child's consumed time across all their services. It preserves weekly allowances,
   the scheduled reset, and other children's balances. Reset schedule changes take
   effect after the current week.
5. Settings → API clients creates revocable, read-only tokens restricted to selected
   children. Copy a new token when displayed; it is not retrievable afterward.

**Lock**, closing the main window, quitting, or switching login sessions destroys
the app's authorization reference and clears the in-memory token and configuration.
A late service response cannot repopulate the locked screen. Standard logins see
only a parent-only locked screen and cannot start an unlock. macOS selects the
available authentication method and may honor its own valid authorization cache;
the app does not collect a password or launch an elevated GUI. Read-only HTTP
clients remain independent from this parent authorization session.

A compatible preset signer catalog, automatic app discovery, and automatic adoption
of future installed apps are not included. A browser/PWA launcher shared with other
sites must not be attached to a service. Website-only and app-only service definitions
are supported by the API; the quick-add UI begins with a website, and Manage service
can retain an app while removing its websites.

## IPC and the macOS filter sandbox

The data provider is a macOS **system extension** distributed with Developer ID,
not an iOS Filter Data Provider app extension. Apple's DTS [clarifies the sandbox
model](https://developer.apple.com/forums/thread/133761): the blanket no-network,
no-IPC restriction described in older generic filter documentation applies to iOS.
This project does not opt the macOS system extension into App Sandbox. It exchanges
bounded JSON with the root daemon through `/var/run/kids-quota.sock` using authenticated
peer identity. No browsing payload or content is sent; the filter only asks for UID,
code-signing requirements, exhaustion state, and revision. The socket client also
requires the server's kernel peer UID to be root.

Safari's native app extension **is** sandboxed. It currently uses a temporary file
access exception for `/var/run/kids-quota.sock` (including the canonical `/private`
path) plus the network-client entitlement. Test this entitlement with the signed
Safari host on supported macOS releases. A compiler success is not proof that Safari's
runtime sandbox permits the connection. If release entitlement review or the host
sandbox rejects it, replace this transport with a properly entitled XPC Mach service;
do not weaken daemon authentication or broaden file access. This is not represented
as an App Store-approved distribution design.

## Enforcement and release validation

The filter authenticates an app's `sourceAppAuditToken`, selects rules by the child's
UID, and checks its designated code-signing requirement. It authenticates and caches matches for current rules when
a flow opens, preserving its identity if the origin process exits. It retains data callbacks
for monitored child sockets and polls policy each second. New exhausted flows are
dropped. Existing tracked flows are updated with a drop verdict at exhaustion,
including TCP and UDP sockets delivered by the OS. Callback decisions also recheck
policy, so a connection is not permanently allowed at its first packet. The filter
does not inspect HTTPS plaintext or derive domain names from IP addresses.

After 15 seconds without valid policy, previously configured app identities are
blocked for monitored children. Previously fetched exhausted rules remain in force.
An initial startup with no rules cannot identify protected apps; the daemon must
report missing/incomplete coverage. Failed attribution is reported as a coverage gap,
not silently claimed as protection. Unknown apps and parent accounts are unaffected.

Before calling a release protected, test signed installation on a dedicated Mac:

- Each child is charged only for their account, including fast user switching.
- The selected app and its helper processes are attributed to the correct signed app.
- New and already-open TCP, WebSocket, HTTP/2, and UDP/QUIC traffic stops after quota
  exhaustion. Include long-lived streams and repeated resets/reconnects.
- Moving/updating an app with its approved identity retains the rule; a changed signer
  requires review. Shared browser launchers never block unrelated sites.
- Browser permissions/native host, Safari socket entitlement, daemon restart,
  stale policy, filter restart, and reboot produce accurate coverage states.
- Run throughput/memory checks with monitored long-lived flows; provider callbacks
  currently retain a small peek window for prompt policy checks.

Existing connections predating filter activation, unavailable audit attribution,
OS-exempt traffic, relays/helpers with unrelated identities, and unsupported browser
launchers require explicit testing and review. Network blocking cannot disable cached
offline app features or prevent process launch. Strong anti-removal depends on managed
browser policies/MDM; standard child logins protect installed root-owned service files
but do not make a developer-loaded browser extension non-removable.
