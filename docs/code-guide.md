# Reading the code

Kids Quota has one authority for time: the root quota service. The browser
extensions and login agent report what is in use. The service chooses one
foreground activity, charges its quota, and returns enforcement decisions.
The parent app edits policy; it does not keep a second ledger.

Start with the [README](../README.md) for the architecture diagram and build
commands. This guide follows the implementation. [Architecture](architecture.md)
contains the wider design rationale; [validation](validation.md) distinguishes
automated checks from the signed runtime tests still required.

The [local installer profile](local-install.md) keeps the network filter inactive.
Its root daemon uses [LocalInstallTrust.swift](../Sources/KidsQuotaService/LocalInstallTrust.swift)
to authenticate pinned ad-hoc builds at protected paths instead of requiring an
Apple Team ID. The full filter flow below describes the optional signed profile.

## A useful reading order

| Read | What to look for |
| --- | --- |
| [Models.swift](../Sources/KidsQuotaCore/Models.swift) | `Child`, `ServiceDefinition`, `Quota`, `Policy.starter()`, and `Policy.validate()` define the vocabulary and defaults. |
| [QuotaEngine.swift](../Sources/KidsQuotaCore/QuotaEngine.swift) | `reportActivity`, `tick`, `balances`, and `resetUsage` define how seconds become balances. |
| [Controller.swift](../Sources/KidsQuotaService/Controller.swift) | `native` receives observations, `reconcile` selects foreground ownership, and `handle` implements resource operations. |
| [QuotaDaemon/main.swift](../Sources/QuotaDaemon/main.swift) | The entry point starts the service, listeners, one-second accounting timer, and shutdown handling. |
| [extensions/shared/controller.js](../extensions/shared/controller.js) | The browser observes tabs, exchanges state for policy, and applies navigation rules. |
| [ParentStore.swift](../macos/ParentApp/ParentStore.swift) | The parent app unlocks, loads data, sends authorized changes, and clears its state when locked. |

Then follow the specific path below that interests you. You do not need to start
with socket parsing or installation scripts to understand quota accounting.

## Three build areas

| Area | Source of truth | Produces |
| --- | --- | --- |
| Swift Package Manager | [Package.swift](../Package.swift), `Sources/`, `Tests/` | `KidsQuotaCore`, `KidsQuotaService`, and the service, login-agent, and Chrome-bridge executables. Uses system SQLite. |
| Xcode | [project.yml](../project.yml), `macos/` | The SwiftUI parent app, its embedded Safari extension, the network system extension, and native tests. XcodeGen regenerates the checked-in project. |
| Browser JavaScript | [extensions/shared/](../extensions/shared/), [build-extensions.mjs](../scripts/build-extensions.mjs) | Chrome and Safari packages in `extensions/build/`, including manifests and bundled background scripts. |

Edit shared JavaScript and regenerate the packages; do not make a change only in
the generated browser output. Similarly, change `project.yml` when adding Xcode
targets or changing their source/entitlement configuration. The native app has
small API presentation types in [macos/ParentApp/Models.swift](../macos/ParentApp/Models.swift);
the authoritative policy types live in `KidsQuotaCore`.

[build-macos.sh](../scripts/build-macos.sh) coordinates all three build areas.
[install.sh](../scripts/install.sh) installs verified artifacts and launchd jobs.
[package.sh](../scripts/package.sh) and [create-dmg.sh](../scripts/create-dmg.sh)
wrap the release for installation. Build commands do not install protection.

## The data model

| Type | Meaning |
| --- | --- |
| `Child` | Stable application ID and display name, bound to a standard macOS account's directory GUID and current numeric UID. |
| `ServiceDefinition` | A named group of domains and optional application-binding IDs, such as Chess.com. Shared across the household. |
| `ApplicationBinding` | A selected app's verified signing identity and designated code requirement. A filename alone is insufficient. |
| `Quota` | One child's weekly allowance for one service. Its stable ID identifies ledger rows. |
| `Policy` | All children, service groups, bindings, quotas, reset schedule, and a revision used to reject stale edits. |
| `Balance` | A computed view of limit, usage, remaining time, current period, quota state, and coverage. |

For example, a child's Chess.com quota is 21,600 seconds. Chrome usage on
`chess.com`, Safari usage there, and foreground use of a selected Chess app all
resolve to that same quota. A sibling has a different quota and ledger rows. The
child's ChatGPT quota is also separate. Updating a shared service's domains/apps
affects everyone assigned that service; editing hours affects the chosen quota.

`Policy.starter()` creates the two website service definitions. The
`POST /v1/admin/children` handler verifies the selected account and creates the
child's two six-hour quota assignments. Companion apps are selected and verified
separately; the starter policy does not contain guessed app signatures.

## Follow one browser session

1. [The extension controller](../extensions/shared/controller.js) listens for
   selected-tab, URL, and window-focus changes. It also refreshes about every five
   seconds while running; alarms and page lifecycle messages help recover from
   browser-worker suspension. [core.js](../extensions/shared/core.js) produces a
   hostname, focus flag, session ID, and sequence number. It sends neither a full
   URL history nor a claimed number of seconds spent.
2. Chrome sends that state over native messaging to
   [QuotaBridge/main.swift](../Sources/QuotaBridge/main.swift). Safari sends it to
   [SafariWebExtensionHandler.swift](../macos/SafariExtension/SafariWebExtensionHandler.swift).
   Both forward a `browser` request to `/var/run/kids-quota.sock` and return its
   policy reply. Chrome's browser-to-host port is long-lived; the UNIX socket
   exchange is one request/reply per connection.
3. Independently, [QuotaAgent/main.swift](../Sources/QuotaAgent/main.swift) reports
   the frontmost process and session state every second and on relevant app,
   sleep, and session events. The daemon needs this evidence as well as the tab
   report: a selected tab in a background browser must not consume time.
4. [ServiceController.reconcile](../Sources/KidsQuotaService/Controller.swift)
   verifies the current console child and fresh reports, chooses the active
   browser session, and resolves the hostname to an assigned service.
   [DomainMatcher.swift](../Sources/KidsQuotaCore/DomainMatcher.swift) uses
   canonical hostnames, label boundaries, and the bundled Public Suffix List.
5. `QuotaEngine.reportActivity` settles the previous activity and establishes the
   new one. `tick` measures elapsed time using a monotonic clock, splits intervals
   across calendar boundaries, and persists usage. Only one activity is charged
   on this Mac at a time. Passive foreground viewing counts; background tabs do not.
6. Each browser-state request receives the latest domain rules and remaining
   balances. At exhaustion, the extension updates declarative navigation rules
   and replaces already-open matching tabs with its local blocked page. It does
   not wait for another DNS lookup. Changes reach the browser through these
   exchanges; the daemon does not broadcast unsolicited browser updates.

## Follow a standalone app session

The login agent reports the frontmost PID. When that process is not a recognized
browser, the controller checks it against the designated requirements of selected
apps using [NativeIdentity.processMatches](../Sources/KidsQuotaService/Identity.swift).
A match resolves to the same service/quota used by its website. App network
requests themselves do not create usage intervals.

[FilterDataProvider.swift](../macos/NetworkFilter/FilterDataProvider.swift) polls
the daemon's `filterRules` operation every second. Each rule contains the child's
UID, the app's code requirement, service ID, and blocked state.
[FilterPolicy.swift](../macos/Shared/FilterPolicy.swift) applies those rules to a
flow's authenticated source identity. This prevents one child's exhaustion from
blocking the same installed app for a sibling or parent.

The provider keeps monitored sockets under filtering and reevaluates tracked
flows on policy refresh, so the implementation targets both new and existing
connections. Actual TCP/UDP behavior and helper attribution still require signed
on-device acceptance tests. This is app network denial: it does not stop launch,
offline play, cached content, or local computation. There is no DNS proxy in this
implementation, and no native-app domain guessing or TLS decryption.

## Follow a parent change or reset

1. [KidsQuotaApp.swift](../macos/ParentApp/KidsQuotaApp.swift) opens a locked
   [ParentAccessGate](../macos/ParentApp/ParentAccessView.swift).
   [ParentAuthorization.swift](../macos/ParentApp/ParentAuthorization.swift)
   obtains a macOS administrator authorization grant. `ParentStore` reads its
   credential and contacts the daemon only after unlock.
2. [Editors.swift](../macos/ParentApp/Editors.swift) handles account setup, hours,
   and included websites/apps. [HouseholdView.swift](../macos/ParentApp/HouseholdView.swift)
   shows balances, polls while open, and captures the selected child and policy
   revision before showing the reset confirmation.
3. `ParentStore` sends an HTTP-shaped `parentHTTP` JSON envelope through
   [DaemonSocket.swift](../macos/Shared/DaemonSocket.swift), including a bearer
   token and the authorization external form. This uses authenticated UNIX IPC,
   not the public HTTP listener. The client checks that the server belongs to root.
4. [PeerVerifier](../Sources/KidsQuotaService/Transport.swift) verifies the native
   process's UID and signed role. The service's separate
   [ParentAuthorization validator](../Sources/KidsQuotaService/ParentAuthorization.swift)
   checks administrator membership and the granted right. The controller also
   checks token scope and the expected policy revision.
5. Ordinary edits call `QuotaEngine.replacePolicy`, preserving stable usage IDs.
   **Reset this week** calls `resetUsage`: settle observed usage, zero only the
   selected child's current-period counters, append a private audit record, and
   advance policy revision atomically. Limits, scheduled reset, prior periods,
   and siblings remain unchanged. Adapters obtain the new state on subsequent
   exchanges.

The GUI stays an ordinary user process. The installed main executable is
restricted to administrators; the daemon independently enforces authorization.
Locking, closing, or changing the active login session clears the UI's grant and
credential state. A late asynchronous reply cannot restore an old unlocked session.

## Persistence and time boundaries

[QuotaStore.swift](../Sources/KidsQuotaCore/QuotaStore.swift) owns SQLite access.
The production database is `quota.sqlite` in
`/Library/Application Support/KidsQuota`:

| Table or file | Contents |
| --- | --- |
| SQLite `metadata` | Encoded policy and the furthest accepted calendar-period start (`periodFloor`). |
| SQLite `usage` | Fractional seconds keyed by `(child_id, quota_id, period_start)`. |
| SQLite `reset_events` | Manual reset time, trusted administrator UID, child, period, prior total usage, and revision. |
| `clients.json` | API token digests, scopes, and explicit child grants, managed by [Credentials.swift](../Sources/KidsQuotaService/Credentials.swift). |
| `admin.token` | Protected bootstrap credential used by the parent app. It is not a read-client credential. |

Browser/foreground observations are transient memory state. The ledger stores
usage totals rather than visited pages. SQLite uses WAL and full synchronization;
related counter/period changes and manual resets use transactions.

[WeeklyCalendar.swift](../Sources/KidsQuotaCore/WeeklyCalendar.swift) computes
boundaries in the saved timezone. A week spanning daylight-saving changes need
not contain 168 hours. A new period gets a fresh allowance without erasing the old
rows. Schedule changes wait until the current boundary; clock rollback cannot
select an earlier period and revive its allowance. A restart restores the ledger
but does not bill downtime without new activity observations.

## Read clients and unavailable components

Widgets or a local website publisher use authenticated GET requests to
`http://127.0.0.1:48123/v1`. [read_balances.py](../examples/read_balances.py) is a
minimal example; [api.md](api.md) and [openapi.yaml](../api/openapi.yaml) describe
the contract. Tokens restrict both operations and children. Browser-page origins
are rejected, so a future publisher should read locally and publish only chosen
summaries rather than embedding the token in a public page. HTTP cannot modify
policy or reset usage, even with the parent bearer token.

Freshness and quota state are separate. A positive balance does not prove all
protection is working. Stale or unhealthy login-agent reports stop accounting and
cause known services to block. Browser policies become unavailable after the
15-second contact window; saved restrictions are revalidated on startup. The app
filter also blocks known app rules when its policy becomes stale, but its cache
is only in memory: before its first policy, it has no rules to enforce. See
[validation.md](validation.md) for these limits and screen-lock qualification.

## Where to change behavior

| Change | Start here |
| --- | --- |
| Presets or default weekly hours | `Policy.starter()`, `Quota` initializer in core `Models.swift`, and the child-creation handler in `Controller.swift`; keep onboarding copy consistent. |
| Domain matching or overlap rejection | `DomainMatcher.swift` and `Policy.validate()`. |
| Which foreground activity is charged | `ServiceController.reconcile()`; keep elapsed accounting in `QuotaEngine`. |
| Weekly boundaries or manual reset semantics | `WeeklyCalendar.swift`, `QuotaEngine.swift`, and `QuotaStore.swift`. |
| Browser blocking or recovery | Shared browser `core.js` and `controller.js`, then regenerate both packages. |
| Native flow decisions | `FilterDataProvider.swift` and `FilterPolicy.swift`; preserve per-UID matching. |
| Parent UI | `HouseholdView.swift`, `Editors.swift`, `SettingsView.swift`, and `ParentStore.swift`. |
| A new read-only client/resource | `Credentials.swift`, `Controller.swift`, and `api/openapi.yaml`; preserve child grants. |
| Installation or release packaging | `scripts/install.sh`, `scripts/package.sh`, `scripts/create-dmg.sh`, and [deployment.md](deployment.md). |

## Tests to read alongside the implementation

- [Core tests](../Tests/KidsQuotaCoreTests/) demonstrate domain boundaries,
  shared balances, DST, clock changes, persistence, and reset rollback.
- [Service tests](../Tests/KidsQuotaServiceTests/) cover authenticated roles,
  read-only HTTP, account isolation, foreground arbitration, and scoped resets.
- [Browser tests](../Tests/browser/) simulate tabs/native messaging, stale policy,
  already-open page blocking, reconnection, and same-week parent resets.
- [Native tests](../macos/Tests/) cover filter identity decisions and parent
  unlock/lock races without prompting for real credentials.
- [Packaging tests](../Tests/packaging/) exercise staged installation and DMG
  assembly with mocked privileged/system operations.

Run the relevant commands in the [README](../README.md). The isolated
[service smoke test](../scripts/smoke-service.py) also starts the real executable
against temporary data, verifies HTTP/native boundaries and crash recovery, and
stops it. Unit tests and an unsigned build do not replace the signed acceptance
checks for real browser permissions, system extensions, and app attribution.
