# Development release validation

Validated locally on Apple Silicon with Xcode 27.1. No protection was installed
or activated on the development Mac; no real child accounts were linked.

## Automated checks

| Suite | Result | Coverage |
| --- | --- | --- |
| Swift quota core | 47 passing tests | Domain boundaries/IDNA/public suffixes, policy validation, per-child shared usage, calendar/DST resets, clock changes, stale reports, persistence and rollback |
| Swift service | 32 passing tests | Authorization, child scopes, revocation, revisions, verified setup, native roles, profile switching, account GUID reuse, filter isolation, unhealthy collectors, bootstrap recovery, HTTP/native framing |
| Browser JavaScript | 19 passing tests | Chrome/Safari packaging, focus reports, DNR matching, open-tab replacement, native disconnects/timeouts, persisted fail-closed rules, event ordering and permission failures |
| Native Mac models | 7 passing tests | Filter UID isolation, stale rules, audit-token UID layout, malformed policy, presentation, generated entitlements |

**105 automated tests pass.** The filter model and browser tests use deterministic
fixtures/mocks; they do not substitute for running signed extensions inside macOS.

The real daemon also passes `scripts/smoke-service.py`: localhost HTTP requests,
Host/Origin rejection, bearer checks, custom-service persistence, stale revision
rejection, malformed framing, unauthorized native peers, a forced process crash,
and recovery of the stale socket and SQLite policy. Tokens are never logged.

`scripts/build-macos.sh --unsigned` compiles/stages all three CLI executables, the
parent app, Safari extension, and network system extension. Bundle resource checks
confirm that Safari contains its generated manifest/scripts and the daemon has
the bundled Public Suffix List. The native app was launched against isolated demo
data and its child sidebar, preset allowances, and coverage labels were inspected.
No real accounts, browser permissions, or network-filter settings were changed.

Installer scripts passed shell syntax and plist checks. Generated MDM examples
passed plist/JSON validation. An unprivileged transaction harness checked clean
upgrade replacement and rollback, including preserving usage files. Actual signed
installation, notarization, and MDM deployment have not been performed.

## Signed runtime acceptance still required

1. Sign every component with one Developer ID team, install as administrator,
   and link two **standard** macOS accounts. Verify the child cannot read
   `admin.token`, change the ledger/binaries, or load a user-level fake Chrome
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
