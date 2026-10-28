# kids-quota

Weekly website and Mac app allowances shared across Chrome, Safari, and selected
apps, with independent balances for children using separate macOS login accounts.

**Status: local development release with a real installer.**
`dist/KidsQuota-0.1.2-Local.dmg` packages the app, root service, login agent,
browser adapters, and an **inactive** Network Extension for Apple Silicon and
Intel Macs running macOS 14 or later. It needs no Apple developer membership.
Website blocking requires manual browser setup; standalone-app network blocking
is disabled. Safari's unsigned-extension permission resets whenever Safari quits.
See [local installation](docs/local-install.md) for the exact steps and limits.

## How the pieces fit together

The **root quota service owns time and balances**. Chrome/Safari extensions and
a per-login Mac agent report what the child is using. The service combines those
observations, charges one foreground activity, and saves usage in SQLite. Browser
extensions block domains; the macOS network filter blocks selected apps' traffic.
The diagram includes the optional network filter; the local release keeps that
component inactive and labels native apps as tracking-only.

![Kids Quota architecture: child collectors, protected quota service, parent controls, read clients, and app network enforcement](docs/architecture.svg)

Browser rules arrive in replies to activity reports; the app filter polls for
rules. The arrows do not represent a broadcast service. The parent UI uses
administrator-authorized native IPC. Other clients use a separate, read-only HTTP
interface. See the [diagram and protocol map](docs/architecture.md#runtime-diagram)
or open the [full-size diagram](docs/architecture.svg).

A **service** groups websites and optional apps. A **quota** connects one child
to one service and gives it a weekly limit. For example, a child's Chrome,
Safari, and selected Chess.com app usage all draw from that child's Chess.com
quota. Their ChatGPT quota and a sibling's Chess.com quota are separate.

## Start reading the code

Follow the [code walkthrough](docs/code-guide.md) for complete browser, native
app, parent-edit, and reset flows. These are the main entry points:

| Location | Responsibility |
| --- | --- |
| [Core models](Sources/KidsQuotaCore/Models.swift) | Children, service groups, app bindings, quotas, defaults, and policy validation. |
| [QuotaEngine](Sources/KidsQuotaCore/QuotaEngine.swift) | Elapsed time, balance calculation, policy changes, and manual reset. Start here for accounting. |
| [QuotaStore](Sources/KidsQuotaCore/QuotaStore.swift) and [WeeklyCalendar](Sources/KidsQuotaCore/WeeklyCalendar.swift) | SQLite persistence and calendar-based weekly boundaries. |
| [ServiceController](Sources/KidsQuotaService/Controller.swift) | Connects reports to the engine; routes requests and authorizes changes. |
| [Transport](Sources/KidsQuotaService/Transport.swift), [Identity](Sources/KidsQuotaService/Identity.swift), and [Credentials](Sources/KidsQuotaService/Credentials.swift) | UNIX sockets/HTTP, authenticated process and account identities, and scoped read tokens. |
| [QuotaDaemon](Sources/QuotaDaemon/main.swift), [QuotaAgent](Sources/QuotaAgent/main.swift), and [QuotaBridge](Sources/QuotaBridge/main.swift) | Executable entry points for the root service, per-login collector, and Chrome native host. |
| [Child menu bar view](Sources/QuotaAgent/ChildStatusMenu.swift) and [child status models](Sources/KidsQuotaService/ChildStatus.swift) | Read-only remaining time for the current login; no parent credentials or child selector. |
| [Shared browser controller](extensions/shared/controller.js) and [browser core](extensions/shared/core.js) | Tab/focus reports, policy replies, stale-state recovery, and website blocking. |
| [ParentApp](macos/ParentApp/) | SwiftUI account setup, allowance cards, editors, administrator unlock, and reset controls. |
| [Safari handler](macos/SafariExtension/SafariWebExtensionHandler.swift) | Safari's native messaging connection to the daemon. |
| [Network filter](macos/NetworkFilter/FilterDataProvider.swift) and [FilterPolicy](macos/Shared/FilterPolicy.swift) | Per-child, signature-based app network decisions. |
| [Tests](Tests/) and [native tests](macos/Tests/) | Executable examples of accounting, authorization, browser behavior, and packaging. |

There are three build areas: [Package.swift](Package.swift) builds the Swift
libraries and command-line tools; [project.yml](project.yml) defines the Xcode app
and extension targets; [build-extensions.mjs](scripts/build-extensions.mjs)
generates both browser packages from shared JavaScript. Edit those sources rather
than generated browser files or only the generated Xcode project.

## Features

- Starts each linked child with **Chess.com: 6 hours/week** and **ChatGPT: 6
  hours/week**. Each service shares its balance between websites and selected apps.
- Adds custom domain groups, optional subdomains, and optional Mac apps. Choose
  an installed app with the standard picker; the service verifies its signature.
  App paths and names alone never grant a match.
- Counts the foreground website or app while the child's session is awake and
  unlocked, including passive viewing. Background use does not consume time.
- Blocks website navigation and replaces open matching tabs at exhaustion.
  The optional signed profile's Network Extension denies selected apps' network
  traffic for that child. The local release tracks app usage without blocking it.
  Neither profile prevents app launch or cached/offline use.
- Resets Monday at 00:00 by default in the saved timezone. Weekday/time/timezone
  are editable; schedule changes take effect after the current period. Handles
  DST, sleep, restarts, and clock rollback.
- Provides a parent-only **Reset this week** button. It restores the selected
  child's current-week balances, preserves their limits and next reset date, and
  records an audit event. Other children and earlier weeks are untouched.
- Gives each child a **Kids Quota hourglass in the Mac menu bar** showing their
  remaining time, weekly allowance, included domains, and next reset. The Chrome
  and Safari toolbar popups also show remaining time and domains. These views
  refresh while open and never expose settings, resets, or sibling balances.
- Exposes authenticated `http://127.0.0.1:48123/v1` JSON endpoints for widgets or
  local publishers. Revocable read tokens have explicit child grants. No client
  endpoint can post usage or set remaining balances.

After administrator unlock, the parent app opens to the child's remaining-time cards, with a child
picker when multiple accounts are linked, **Edit hours**, **Includes**, custom
services, and settings for protection, resets, and clients.
Service membership is shared; hours belong to the selected child. Website-only
services need no app selection. Presets do not guess app identities: use **Manage
included websites and apps → Choose app** to include the installed app.

## Install and set up

For this membership-free build, copy **KidsQuota-0.1.2-Local.dmg** to the new Mac.
It is the only file needed; the destination does not need Xcode, Node, Python,
the source repository, or a developer account.

1. While signed into the child's standard Mac account, mount the DMG and open
   **Install Kids Quota.pkg**. Enter the parent's administrator username and
   password when macOS Installer asks. It installs the app and background components. If
   macOS blocks this unnotarized installer, use **System Settings → Privacy &
   Security → Open Anyway** for that installer, then reopen it.
2. Open **Kids Quota** from Applications in the same login. Choose **Unlock parent
   settings** and enter the parent's administrator credentials in the macOS prompt.
3. Select the child's existing standard Mac login account and choose
   **Set up account**. Chess.com and ChatGPT are created automatically,
   each with six hours per week and a Monday reset. No token entry or terminal is needed.
4. In each child's Chrome account, open `chrome://extensions`, enable Developer
   mode, choose **Load unpacked**, and select
   `/Library/Application Support/KidsQuota/BrowserExtensions/Chrome`.
5. Safari is included for testing: enable **Allow unsigned extensions**, then
   enable Kids Quota and its website permissions. Safari clears the unsigned
   extension permission every time it quits. Native-app network filtering stays
   disabled; there is no filter approval step in this build.

The DMG includes **Start here.txt**, and the app's Protection settings show the
browser setup steps. Read [local installation](docs/local-install.md) before
relying on coverage. Unpacked/unsigned browser extensions can be disabled by a child.
You can also install and configure from the parent's login. There is no need to
enable the root account or switch away from the child's login.
Use Touch ID if macOS offers it in the authorization prompt; otherwise enter the
parent's administrator username and password. Touch ID availability depends on
macOS, the hardware, and the account; authorization from a different child's
login may still require the parent's password. See [Apple's Authorization Services](https://developer.apple.com/documentation/security/authorization-services).

## How children check their time

In the child's Mac login, click the **hourglass in the menu bar** to open Kids
Quota. It starts automatically with the login agent and works without opening
the parent settings app or a browser. Each service shows its remaining
time and weekly allowance, its covered domains, and when the allowance resets.
Multiple domains grouped into one service share the displayed balance.

Children can also click **Kids Quota in Chrome or Safari's toolbar**. Both views
refresh about every five seconds while open. If the service is unavailable, the
view shows that status instead of presenting an old balance as current. No
password or read-client token is needed; the service identifies the current Mac
login and returns only that child's assigned services. Changes and manual resets
still require the parent app and administrator authorization.

The installed parent executable is root-owned with mode `0755`, so any login can
open its locked screen but standard accounts cannot modify it. macOS Authorization
Services verifies the parent's administrator credentials. The root daemon checks
the parent app's identity and its temporary `com.kidsquota.manage` grant on every
native parent request. The GUI runs as the current login and never reads or stores
a persistent parent bearer token. Settings lock when you switch apps, close the
window, switch login sessions, choose Lock, or reach five minutes after unlocking.

The REST listener is **read-only**, even with an administrator bearer token.
Configuration and resets require the authenticated parent IPC connection. A copied
app or HTTP request from the child cannot change thresholds.

This local installer uses ad-hoc code signatures and pins the installed builds
in a root-protected trust manifest. This preserves process authentication without
an Apple-issued team identity. It does not enable Apple's restricted Network
Extension capabilities. The optional Developer ID release path remains available
for future signing and app network enforcement. See [deployment](docs/deployment.md).

## Build and test

Requires macOS 14+, full Xcode, Node 20+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
Uses system SQLite; no third-party Swift/JavaScript runtime dependencies.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
npm test
python3 -m unittest discover -s Tests/packaging
npm run build:extensions
xcodegen generate
xcodebuild -project KidsQuota.xcodeproj -scheme KidsQuotaMacTests \
  -destination 'platform=macOS' -derivedDataPath .build/xcode \
  CODE_SIGNING_ALLOWED=NO test
python3 scripts/smoke-service.py
```

The smoke test starts an unprivileged localhost service in a temporary directory,
checks HTTP authorization, rejected configuration writes, native-peer rejection, and crash recovery, then
stops it. It never installs a launch service or activates filtering.

See [macOS build details](docs/macos-build.md) and [signed deployment](docs/deployment.md).
Generated adapters are `extensions/build/chrome` and `extensions/build/safari`.

To rebuild the actual local DMG on the development Mac:

```sh
scripts/build-macos.sh --local
scripts/package.sh --local
```

The local build includes both `arm64` and `x86_64`, uses ad-hoc signatures, and
does not contact Apple's signing or notarization services. The installer runs
the root daemon with `--local-install`; this is distinct from `--development`.

To run a development daemon without installing anything:

```sh
swift build
BIN_DIR="$(swift build --show-bin-path)"
mkdir -p work/dev-data
"$BIN_DIR/kids-quota-service" --development \
  --data-dir "$PWD/work/dev-data" --socket /private/tmp/kids-quota-dev.sock
```

Development mode weakens native-peer verification and is for testing only.
Installed modes run as root with protected data. Local installation pins exact
ad-hoc-signed code; the Developer ID path validates the shared Apple team identity.

## Admin installation and removal resistance

The installer places the daemon, native hosts, app, and launch configuration in
administrator-controlled locations. A standard child cannot edit the ledger or
replace these files. If a collector disappears, known services block after their
freshness lease expires rather than continuing with unlimited time.

Unpacked Chrome or manually enabled Safari extensions remain removable/disableable.
Managed Chrome forced-install policy and Safari extension management can enforce
enablement; templates and requirements are in [deployment](docs/deployment.md).
This is a deployment choice, not a change to the quota architecture. Children
must use standard accounts.

## Key implementation choices

- **Domains come from the browser's active tab.** [DomainMatcher](Sources/KidsQuotaCore/DomainMatcher.swift)
  normalizes hostnames and checks label boundaries and public suffixes. It does not
  depend on IP addresses, DNS interception, or inspecting encrypted traffic.
- **The daemon measures elapsed time.** Collector messages report observations,
  not billable seconds. The foreground app and browser reports must agree, so a
  selected tab in a background browser does not consume time.
- **Native apps match by verified code identity and child UID.** Their network
  requests need not reveal which website they correspond to. The parent explicitly
  associates an app with a service; offline features remain usable.
- **Stable IDs preserve accounting.** Usage is keyed by child, quota, and week
  start. Account directory GUIDs are revalidated so reusing a numeric Mac UID does
  not inherit another child's allowance. Reset changes counters, not quota IDs.
- **Configuration and observation have different permissions.** Only an
  administrator-authorized parent connection can edit policy or reset usage.
  Collectors submit activity; scoped REST clients can only read.

## Validation and limits

- Automated suites cover calendar boundaries/DST, shared usage, persistence,
  child isolation, revocation, revisions, request parsing, domain matching, stale
  adapters, app-rule isolation, and native presentation. See [validation](docs/validation.md).
- The local DMG includes the Network Extension outside the activation directory
  and disables its UI control. Enabling it later requires the separately signed
  release and matching provisioning/entitlements. No services or protection have
  been installed on the development Mac as part of building the DMG.
- Run signed acceptance checks on each target macOS/browser version, including
  Safari's native socket sandbox exception, existing TCP/UDP flows, screen lock,
  wake, account switching, and the actual selected apps/helpers.
- Browser measurement is the foreground **top-level** website. Embedded services,
  other browsers, browser web-app wrappers, and unselected helpers may need added
  coverage. Unsupported attribution is surfaced as incomplete.
- A filter starting without the service has no initial rules; in-memory
  fail-closed behavior requires a previously received policy. Restart apps after
  initial filter activation to cover sockets opened before activation.
- One Mac only. DNS proxy enforcement, offline app denial, automatic app-signature
  catalogs, multi-Mac pooling, a widget, and a hosted publisher are follow-on work.
  The REST API supports independent read clients now.

## Reference

- [API behavior](docs/api.md) and [OpenAPI 3.1](api/openapi.yaml)
- [Install the local DMG](docs/local-install.md)
- [Code walkthrough and change guide](docs/code-guide.md)
- [Architecture diagram](docs/architecture.svg) and [editable Mermaid version](docs/architecture.mmd)
- [Architecture and acceptance criteria](docs/architecture.md)
- [Service UX and future catalog behavior](docs/service-setup-ux.md)
- [Example household policy](config/example-policy.json) (illustrative unpaired accounts)
- [Read-client example](examples/read_balances.py)
- [Third-party notices](THIRD_PARTY_NOTICES.md)
