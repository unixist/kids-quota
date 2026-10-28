# Development release validation

Validated locally on Apple Silicon with Xcode 27.1. No protection was installed
or activated on the development Mac; no real child accounts were linked.

## Automated checks

| Suite | Result | Coverage |
| --- | --- | --- |
| Swift quota core | 60 passing tests | Domain boundaries/IDNA/public suffixes, policy validation, per-child shared usage, calendar/DST resets, clock changes, stale reports, persistence, reset audits and transaction rollback |
| Swift service and child view models | 58 passing tests | Authorization, child scopes, revisions, native roles, administrator proof, read-only HTTP, scoped reset, account isolation, framing, local trust manifests, protected paths, real ad-hoc process signature pins, child-status privacy, observational reads, balance formatting and stale-view clearing |
| Browser JavaScript | 30 passing tests | Chrome/Safari packaging, stable unpacked extension ID, focus reports, DNR matching, open-tab replacement, native disconnects/timeouts, persisted fail-closed rules, event ordering, same-week resets, permission failures, read-only popup refresh, domains/reset presentation and late-reply handling |
| Native Mac models and parent session | 15 passing tests | Filter UID isolation, stale rules, malformed policy, presentation, locked startup, authorization proof, relock/races, and local-mode refusal to activate the filter |
| Packaging | 20 passing tests | Parent-only executable access, child extension access, GUI-session activation, upgrade/trust rollback, local artifact metadata, DMG layout, signing-team validation, explicit notarization and codesign pipe handling |

**183 automated tests pass.** The OS authorization test creates an empty reference
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
account-only setup and administrator lock flow compile and pass model/session
tests; interactive authorization still needs the signed acceptance run below.
No real accounts, browser permissions, or network-filter settings were changed.

`scripts/build-macos.sh --local` builds both `arm64` and `x86_64`, ad-hoc signs the
components with hardened runtime, removes restricted entitlements from the parent,
and moves the dormant filter outside its activation directory. The local trust
tests validate an actual running ad-hoc-signed fixture against accepted/rejected
code hashes. The login agent's bounded Safari discovery helper compiles but was
not executed here; installed child-session discovery still needs device validation.

Installer scripts passed shell syntax and plist checks. Generated MDM examples
passed plist/JSON validation. Unprivileged packaging fixtures checked clean upgrade
replacement and rollback, preserving usage files, `root:admin 0750` policy for the
parent executable while retaining child extension access, and signed-DMG layout.
A real instructions-only preview DMG was created, checksum-verified and mounted
read-only to confirm it contains no runnable installer. Actual signed
installation, notarization, and MDM deployment have not been performed.

The actual **KidsQuota-0.1.1-Local.dmg** was created, checksum-verified, mounted
read-only, and unmounted after inspection. Its real PKG was expanded into scratch
files without installing it. The extracted installer's read-only checks verified
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

## Local runtime acceptance still required

The package has not been installed on a fresh second Mac in this task. On that Mac:

1. Approve the local package, install as administrator, unlock the parent app,
   and link a standard account. Verify root ownership and parent-only controls.
2. Load the Chrome package in each child profile and verify new and already-open
   limited pages block. Test login, sleep, wake, and browser restart.
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
   and link two **standard** macOS accounts. Verify the child cannot read
   or execute the parent main binary, read `admin.token`, change the ledger/binaries,
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
