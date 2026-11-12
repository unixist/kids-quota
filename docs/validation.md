# Development release validation

Validated locally on Apple Silicon with Xcode 27.1. No protection was installed
or activated on the development Mac; no real child accounts were linked.

## v0.2.0 iPhone dashboard preparation

The November 11, 2026 local checks cover the opt-in Mac publisher, private relay,
iPhone dashboard, and small/medium/large widgets. These results describe local
builds and tests; they do not imply that Google Cloud or TestFlight is live.

The [earlier GitHub validation run for `04b7bcc`](https://github.com/unixist/kids-quota/actions/runs/43153294519)
passed both jobs. The simplicity/failure-state refinements below are validated
locally; their final GitHub run is recorded after publication.

| Suite | Result | Coverage |
| --- | --- | --- |
| Swift quota core and service | 158 passing tests | Existing accounting/authorization plus consistent phone snapshots, parent-only setup, protected credentials, connection changes, bounded HTTPS responses, cancellation, malformed ports, and rejection of missing or weakened administrator authorization rules |
| Native Mac models and parent session | 35 passing tests | Existing settings and child views plus private phone connection parsing, delivery-confirmed status, recovery actions, and canceled/racing status polls |
| iPhone shared models | 26 passing tests | Protocol validation, timestamps, freshness, weekly reset boundaries, per-Mac child identity, cache ordering, and HTTPS endpoint validation |
| iPhone app and widget state | 19 passing simulator tests | Late pairing/refresh replies, disconnect/reconnect, unavailable saved connections, valid-data fallback after cache failures, widget recovery states, and missing Mac reports |
| Packaging and QR utility | 41 passing tests | Installer regressions plus private QR output, unsafe paths, malformed input, and native QR decoding with synthetic credentials |

The Swift suite also passes with the process timezone set to UTC. The Safari
registration helper now explicitly owns its C argument buffers so older Swift
compilers can build it. Administrator-rule checks are deterministic; the live
empty-reference test on a clean Mac proves missing-rule denial. A successful
password/Touch ID unlock against the installed rule remains an interactive
acceptance check.

The relay's **50 Node tests pass** (`npm test --prefix cloud`). They cover
read/write/device isolation, payload limits,
validation, stale/concurrent storage updates, safe provisioning diagnostics, and
the deployment command sequence using a mock CLI, total request deadlines,
client cancellation, retry bounds, and fixed private-data-free failure diagnostics. Google Cloud IAM behavior and
an actual Cloud Run deployment still require live verification.

The final Mac components build for both Apple silicon and Intel, with macOS 14
as their minimum version. The local installer retains the inactive network
extension and does not request its activation. The v0.2.0 DMG contains a runnable
administrator-authorized PKG and phone setup instructions. Packaging verifies
its checksum; a read-only mount and package expansion inspect its contents
without installing it. The final DMG is 4,189,042 bytes with SHA-256
`063fd621344e4c20a42b215093547ab3fc2f13392dcc90545a9b86d0e5c76cdc`.
The isolated daemon HTTP/crash-recovery smoke test passes.

The iPhone simulator app and widget build successfully. The unsigned Release
archive contains app and widget version **0.2.0**, build **2**, for **iPhone,
iOS 17 or later**. The unsigned archive is not an installable phone release.
Signed archiving was attempted and stopped because Xcode has no Apple account
signed in and no matching provisioning profiles. No build was uploaded to
App Store Connect or TestFlight. Interactive visual review is also pending
access to the unlocked Mac.

Generated pairing credentials are held outside the checkout in private files.
Their endpoint remains a placeholder until cloud deployment. No real child
summary has been uploaded, no cloud resources have been created, and phone
sharing has not been enabled on an installed Mac during these checks.

## v0.1.3 automated baseline

| Suite | Result | Coverage |
| --- | --- | --- |
| Swift quota core | 60 passing tests | Domain boundaries/IDNA/public suffixes, policy validation, per-child shared usage, calendar/DST resets, clock changes, stale reports, persistence, reset audits and transaction rollback |
| Swift service and child view models | 65 passing tests | Authorization, child scopes, revisions, native roles, administrator proof from standard logins without a bearer, fail-closed authorization-right registration, read-only HTTP, scoped reset, account isolation, framing, local trust manifests, protected paths, real ad-hoc process signature pins, child-status privacy, observational reads, balance formatting, stale-view clearing, and a real local administrator-account binding with UID/GUID checks |
| Browser JavaScript | 30 passing tests | Chrome/Safari packaging, stable unpacked extension ID, focus reports, DNR matching, open-tab replacement, native disconnects/timeouts, persisted fail-closed rules, event ordering, same-week resets, permission failures, read-only popup refresh, domains/reset presentation and late-reply handling |
| Native Mac models and parent session | 21 passing tests | Filter UID isolation, stale rules, malformed policy, presentation, locked startup, any-login authorization proof, no saved parent bearer, pending system-prompt focus, app-switch relock/races, standard/administrator account selection, and local-mode refusal to activate the filter |
| Packaging | 21 passing tests | Root-owned app access, existing bootstrap token becoming root-only, child extension access, GUI-session activation, upgrade/trust rollback, local artifact metadata, DMG layout, signing-team validation, explicit notarization and codesign pipe handling |

**197 automated tests pass.** The OS authorization test creates an empty reference
and confirms it cannot grant access, without displaying a credential prompt. It can
skip when Authorization Services is unavailable in a sandbox/headless environment;
it passed in the local unsandboxed run. The filter model and browser tests use deterministic
fixtures/mocks; they do not substitute for running signed extensions inside macOS.

The real daemon also passes `scripts/smoke-service.py`: localhost HTTP requests,
Host/Origin rejection, bearer checks, administrator-only configuration/reset boundaries,
fixture-policy persistence, malformed framing, unauthorized native peers, a forced process crash,
and recovery of the stale socket and SQLite policy. Tokens are never logged.

`scripts/build-macos.sh --unsigned` compiles/stages all three CLI executables, the
parent app, Safari extension, and network system extension. Bundle resource checks
confirm that Safari contains its generated manifest/scripts and the daemon has
the bundled Public Suffix List. The earlier native layout was launched against
isolated demo data to inspect preset allowances and coverage labels. The current
account-only setup and cross-account administrator lock flow compile and pass
model/session tests; interactive authorization and Touch ID still need the local
acceptance run below.
No real accounts, browser permissions, or network-filter settings were changed.

`scripts/build-macos.sh --local` builds both `arm64` and `x86_64`, ad-hoc signs the
components with hardened runtime, removes restricted entitlements from the parent,
and moves the dormant filter outside its activation directory. The local trust
tests validate an actual running ad-hoc-signed fixture against accepted/rejected
code hashes. The login agent's bounded Safari discovery helper compiles but was
not executed here; installed child-session discovery still needs device validation.

Installer scripts passed shell syntax and plist checks. Generated MDM examples
passed plist/JSON validation. Unprivileged packaging fixtures checked clean upgrade
replacement and rollback, preserving usage files, `root:wheel 0755` policy for the
parent executable (openable but not editable by standard users) while retaining child extension access, and signed-DMG layout.
A real instructions-only preview DMG was created, checksum-verified and mounted
read-only to confirm it contains no runnable installer. Actual signed
installation, notarization, and MDM deployment have not been performed.

The actual **KidsQuota-0.1.3-Local.dmg** was created, checksum-verified, mounted
read-only, and unmounted after inspection. Its real PKG was expanded into scratch
files without installing it. PackageInfo declares root authorization, while the
setup app permits standard logins to open its locked window. The extracted
installer's read-only checks verified
all components' ad-hoc signatures, identifiers, hardened runtime, resource presence,
and Chrome key/ID. All six native binaries contain both `arm64` and `x86_64`.
The parent has `KidsQuotaLocalInstall=true` and no restricted entitlements; the
filter is outside its activation directory. The extracted trust helper produced
the expected five roles with both architecture hashes. The final local daemon
also passed the isolated live HTTP/crash-recovery smoke test above.

The child menu bar screen was opened with DEBUG-only fixture data and inspected
through its accessibility tree and rendered window. The browser popup was rendered
with an isolated mock status response, including multiple domains and reset time.
No real user balances, browser configuration, or installed services were touched.
The child-status tests decode real controller replies through the UI model and
verify that polling balances does not renew an activity heartbeat. Interactive
checking in an installed child's account remains part of acceptance below.

## v0.1.4 Chrome Web Store preparation

The store item `kcdaoppmbobecgoajneamoimiohmkipj` was submitted November 2, 2026.
The dashboard confirmed **Pending Review** and compliance review in progress.
Unlisted distribution and automatic publication after approval are selected.
Submission is not approval, publication, or a supervised-profile runtime test.
The companion installer authorizes that exact
ID alongside the existing unpacked extension ID. The
[v0.1.4 prerelease](https://github.com/unixist/kids-quota/releases/tag/v0.1.4)
contains the uploaded DMG and checksum file. GitHub reports 3,738,323 bytes and
SHA-256 `625462869970a8091f6499bc2aa6a835e78da17a5aaa3fdc45ed94380fe66812`
for the DMG.

The store package removes the local manifest key, includes icons, omits the
redundant Chrome `tabs` permission, and includes a local-data disclosure and
privacy-policy link. The listing screenshot renders the production popup with
explicitly labeled example balances; it does not show actual child usage or
prove native connectivity. Record current v0.1.4 test and package-inspection
results separately from the v0.1.3 baseline above.

Before relying on the store distribution, verify an upgrade and a fresh install
on a test Mac, inspect native-host registration for the exact store ID, and
exercise the published extension in an existing supervised Chrome profile.
Confirm Family Link installation approval, foreground timing, exhaustion,
already-open pages, reset, browser restart, and independent Mac-login balances.
The [reviewer procedure](chrome-web-store.md#reviewer-test-instructions) uses
`example.com` so website credentials are not required.

## Local runtime acceptance still required

The package has not been installed on a fresh second Mac in this task. On that Mac:

1. Stay signed in to the child's local account (test both standard and
   administrator accounts). Install the package using a
   parent administrator username and password in Installer, then open Kids Quota
   and unlock settings through the macOS authorization prompt. Link the child
   account and test editing hours and resetting usage. Confirm cancellation stays
   locked, switching apps or users and closing the window revoke access, and the
   session expires after five minutes. Verify root ownership and parent-only
   controls. Test Touch ID if macOS offers it; cross-account Touch ID is not
   guaranteed. A child who can authenticate as an administrator, including using
   Touch ID if macOS accepts it, can unlock settings with the current rule.
2. For supervised Google profiles, install the store extension after its
   approval and publication, using v0.1.4 or a later compatible companion.
   For unmanaged profiles, separately test the unpacked option. Run only one
   Kids Quota extension per profile. Verify new and already-open limited pages
   block. Test login, sleep, wake, and browser restart.
3. Check Safari discovery, website permissions, and native messaging with
   **Allow unsigned extensions** enabled. Confirm Safari loses that permission on
   quit; this limitation is expected and displayed in setup instructions.
4. Verify selected app time shares its quota but the app stays online at
   exhaustion, matching the deliberately disabled native filter. Confirm resets
   and independent read clients operate and do not affect sibling balances.
5. In each child's login, click the menu bar hourglass and browser toolbar popup.
   Verify that only that child's assigned services appear and their remaining
   time agrees with the parent dashboard. Test a parent reset, weekly reset,
   service interruption/recovery, and an unlinked account. The menu bar must
   appear again after login without requiring parent authorization.

## Signed runtime acceptance still required

1. Sign every component with one Developer ID team, install as administrator,
   and link two local macOS accounts, testing both standard and administrator accounts. Verify the child can open the locked
   app but cannot change settings without administrator authorization, read
   `admin.token`, or change the ledger/binaries,
   or load a user-level fake Chrome
   native host when the supplied management policy is applied.
2. Enable Chrome and Safari adapters, including site permissions. Verify both
   return live coverage and the signed Safari sandbox permits its native socket.
   Verify the Chrome host is launched by the expected signed Chrome parent.
3. Select the actual Chess.com and ChatGPT apps. Check foreground timing across
   website/app switches and moving/updating an app. Test any helper processes,
   browser-installed wrappers, and embedded web views explicitly.
4. Set a short allowance in a test child account. Confirm new navigations and
   existing tabs block, and selected native apps lose new **and existing** TCP,
   WebSocket, HTTP/2, and UDP/QUIC flows. The sibling and parent must stay unaffected.
5. Verify fast user switching, locking/unlocking, restart while locked, sleep/wake,
   daemon/adapter loss, restart, and weekly reset. Confirm no background or locked
   time is billed, and stale policies cannot reopen exhausted services.
   Confirm the administrator authorization prompt succeeds, cancellation stays
   locked, close/session switch revokes access, and **Reset this week** restores
   only the selected child without changing thresholds or the scheduled reset.
6. Test cold-start ordering and pre-activation sockets. The filter has no durable
   cache before its first valid policy. Restart limited apps after activation;
   do not treat missing coverage as successful enforcement.

The collector reads `CGSessionCopyCurrentDictionary()` for session state. Its
`CGSSessionScreenIsLocked` field is an implementation detail, not a documented
stable lock-state contract. Distributed lock notifications only trigger a fresh
read and cannot themselves pause billing. Lock-state behavior must be qualified
on each supported macOS version; a future stronger supported mechanism may need
additional OS integration. Apple's [session API documentation](https://developer.apple.com/documentation/coregraphics/cgsessioncopycurrentdictionary())
and [DTS discussion of lock-state guarantees](https://developer.apple.com/forums/thread/850327)
describe the distinction. This limitation does not affect calendar unit-test results.

An unmanaged Mac still allows extension disablement, another browser, and other
deliberate bypasses. Managed policies improve removal resistance. Network denial
does not prevent offline app use. See [deployment](deployment.md) for requirements.
