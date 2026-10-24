# Architecture proposal

This document describes intended behavior, not an implemented system.

## Initial supported services

- **Chess.com:** `chess.com` and subdomains, plus the selected Chess.com Mac app,
  share a six-hour weekly allowance.
- **ChatGPT:** `chatgpt.com` and subdomains, plus the selected ChatGPT Mac app,
  share a separate six-hour weekly allowance.

Chrome and Safari extensions enforce website quotas. A macOS Network Extension
content filter cuts off network access for the selected apps at exhaustion. The
apps may remain open and their cached or offline features may continue working.
App termination, launch prevention, and Endpoint Security are outside this scope.
DNS filtering is optional and is not required for the initial enforcement design.

## Why domain identity belongs in the browser

An extension can read a permitted tab's URL and extract its hostname before any
DNS-to-IP mapping matters. HTTPS does not hide the URL from the browser itself.
The quota is associated with the top-level site being viewed, not every analytics,
advertising, or media host contacted by that page.

Chrome supports tab access, declarative request blocking, and communication with
a native host. Safari Web Extensions provide their own native messaging bridge.
Use shared extension logic where compatible, with platform-specific adapters and
capability checks. Do not assume complete Chrome/Safari API parity.

Sources: [Chrome permissions](https://developer.chrome.com/docs/extensions/develop/concepts/declare-permissions),
[Chrome request rules](https://developer.chrome.com/docs/extensions/reference/api/declarativeNetRequest),
[Chrome native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging),
[Safari native messaging](https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension).

## Components and authority

- **Swift macOS app:** parent settings, weekly hours, domain/app groups, reset day and
  timezone, remaining time, and explicit temporary overrides. Keep the main view
  simple: one row per service with used/remaining time and blocking state, a clear
  hours editor, and one shared reset setting. Show incomplete setup plainly.
- **Quota service:** the single owner of balances for a macOS user. A per-user
  background agent is sufficient for an initial prototype; privileged service
  design and deployment policy are separate work for stronger tamper resistance.
- **SQLite store:** validated policies and durable usage indexed by user, stable
  quota ID, and calendar-period start. Do not store page contents or full URL history.
- **Browser adapters:** report the selected top-level hostname and focus changes,
  receive remaining time and deadlines, and apply blocking. A Chrome native host
  and Safari native app-extension bridge both connect to the same service.
- **Native app monitor:** observes the frontmost application and resolves its
  verified identity to an explicit application binding. Reports activity to the
  same quota service; a running background process does not imply use.
- **Application network filter:** a Network Extension content filter applies an
  exhausted group's policy to traffic from its selected apps and explicitly bound
  helper processes. It handles new flows and existing connections, independently
  of whether an app is foreground, background, already running, or newly launched.
  It does not prevent launch or stop offline app features.

Browser/native messages must be versioned, bounded, and restricted to the intended
extension identities. Do not expose an unauthenticated localhost control server.
Policy updates require parent authorization in the intended product, not merely
a browser message. A parent PIN alone is not an OS-level security boundary.

## Shared website and application quotas

A quota is a stable group ID with one allowance and one usage ledger per user and
calendar period. Group membership can include both domains and application IDs.
Members never receive separate copies of the allowance.

The `chesscom` group has six hours per week shared by `chess.com` and subdomains
in Chrome/Safari, and the explicitly selected installed Chess.com app.
Two hours in Chrome plus one in Safari plus two in the native app use five hours,
leaving one hour. Exhaustion and the Monday reset apply to the entire group.
The separate `chatgpt` group applies the same model to `chatgpt.com` and the selected
ChatGPT Mac app, with its own six-hour allowance and balance. Using or exhausting one
service does not change the other service's balance or access.

Policy `applicationIds` reference logical IDs in `applicationBindings`; those IDs
are internal references, not claimed bundle identifiers. The example's
`chesscom-macos` and `chatgpt-macos` bindings have `status: needs-selection` and
`identity: null` because the actual apps have not been inspected. A production
policy may retain those drafts, but must surface incomplete app coverage and
cannot claim to restrict the app
until binding and enforcement setup succeed. Missing identities never match all apps.

During setup, the parent selects the installed app. Record and verify its signing
identity, including a suitable code-signing requirement and signing identifier;
do not rely on the display name, filename, installation path, or PID as identity.
Resolve legitimate helper processes as part of a tested app-specific binding;
never allow a broad vendor identity to capture unrelated apps or shared processes.
Updates that satisfy the stored identity preserve the binding and usage; identity
changes require review rather than silently losing coverage. Reject unresolved
application ID references, duplicate verified identities under different bindings,
and overlapping app membership across quota groups.

Associate apps with services explicitly. An app making a request to `chess.com`
does not establish that all its foreground time is Chess.com use. Selecting an
app means its entire foreground use counts, including its offline features.
General browsers must use the domain adapter rather than whole-app membership.
Safari web apps and Chrome-installed web apps may share executable identities with
their browser or other sites; require a distinct, verifiable site/app registration
or report unsupported coverage. Never bind all browser processes to either service.

Sources: [Foreground application](https://developer.apple.com/documentation/appkit/nsworkspace/frontmostapplication),
[Code Signing Services](https://developer.apple.com/documentation/security/code-signing-services).

## Domain matching

Parse URLs using a URL parser, canonicalize hostname case, trailing dot, and IDNA,
and compare DNS labels rather than arbitrary substrings.

For an entry `chess.com` with `includeSubdomains: true`, match the normalized
hostname when it equals `chess.com` or ends with `.chess.com`. Apply the same
label-boundary rule to `chatgpt.com`.

- Matches: `chess.com`, `www.chess.com`, and other subdomains.
- Does not match: `notchess.com`, `chess.com.attacker.example`.
- Additional aliases require an explicit service-specific policy entry. Do not
  include all of `openai.com` or shared authentication/CDN domains in ChatGPT's
  website quota merely because the service contacts them.
- Reject IP literals, schemes, paths, empty names, public-suffix-only entries such
  as `com` or `co.uk`, and overlapping rules that would make quota attribution ambiguous.
- Support explicit related-domain groups; do not infer site ownership from IPs.

Blocking a site's navigation should not globally block a shared CDN just because
that site uses it. Third-party embeds, alternate domains, installed web apps, and
picture-in-picture need a defined policy before claiming coverage.

## What counts as time

While the macOS session is unlocked and awake, resolve the foreground activity to
either the selected top-level tab in the frontmost supported browser or a bound
standalone application. Use OS foreground/session state to arbitrate across apps,
browsers, and windows; a tab's `active` flag alone is insufficient.

Passive foreground viewing counts. A lack of keyboard or mouse activity must not
stop the clock for a video. Background tabs and background audio do not count in
the initial scope. This is a stated policy limitation, not an inference that the
child has stopped consuming the content. An abandoned foreground page or paused
video still consumes time. Picture-in-picture and background playback are not
covered by this foreground-only measurement.

The native service owns elapsed-time accounting using a monotonic clock. Browser
navigation and focus events update the current activity, with bounded heartbeats
for liveness. Do not depend on a Manifest V3 worker's `setInterval` remaining alive.
Resolve the actual current tab on startup, wake, reconnection, and focus changes.
Also reconcile the current foreground application on those transitions. Do not
infer that an old tab or application stayed active through a long unobserved interval.

Charge at most one foreground activity per user at a time. Persist short increments
transactionally and settle on transitions. Identify duplicate/out-of-order events
with session IDs and sequence numbers. Target a small documented overshoot bound
and measure it under suspension and disconnects before promising timing precision.
For a browser-to-app transition within the same quota group, settle the previous
activity and continue the same balance. Deduplicate simultaneous reports from web
and native adapters. A browser left open behind the app cannot charge a second
interval, and background network requests do not create usage intervals.

## Weekly reset

The default boundary is Monday 00:00 in the policy's named IANA timezone. Select the
timezone during setup, then store it explicitly. The example uses America/Chicago.

Compute the most recent and next calendar boundary, not an elapsed 604,800-second
timer. Weeks spanning daylight-saving transitions are not always 168 hours.
Use half-open periods `[start, nextStart)` and split a usage interval at a boundary.
Define non-existent local midnight as the next valid instant and repeated midnight
as its first occurrence, with tests for the supported calendar implementation.

Recompute the current period on startup, wake, policy checks, and quota queries.
A reset must work even when the Mac was asleep at the boundary. New periods begin
with fresh allowance; old usage can remain for local summaries. Old-period blocking
rules must be reconciled before browsing is allowed or denied in the new period.

Reset-schedule changes should take effect at the next existing boundary. Keep the
current period intact so repeatedly changing the weekday cannot mint new hours.
Allowance edits apply to the current period without discarding already-used time.
Lowering an allowance below time used blocks immediately. Changing device timezone
does not change a policy's saved timezone. Domain, application membership, and
display-name edits preserve the quota's stable ID and usage; deleting and recreating a quota is an explicit
parent-authorized policy change.

Clock rollback must not revive an older balance. Persist period transitions and
detect discontinuities. Large forward clock changes can still grant a new period
without a trusted time source; stronger resistance requires deployment controls or
a separately designed trusted-time policy.

## Exhaustion and recovery

When remaining time reaches zero, the extension should:

1. Apply domain-based rules for new navigations and relevant requests.
2. Navigate already-open matching tabs to its own local exhaustion page, stopping
   already-loaded content and buffered playback.
3. Show the quota name and next reset time without exposing sensitive URL details.
4. Reconcile rules after reset, extension startup, reconnection, and policy changes.

Request filtering alone does not remove already-rendered content. Verify cached
pages, browser back/forward restoration, service workers, and existing media.
Safari's supported blocking APIs and timing must be verified on the chosen minimum
macOS/Safari versions in the first vertical slice.

Proposed service-unavailable behavior: existing exhausted rules remain, and known
restricted domains get a temporary unavailable page after a short grace interval.
Unrestricted browsing remains available. This requires the extension to be running;
it cannot guarantee enforcement if the extension is removed or disabled.

The same exhausted quota decision must reach the application's Network Extension
content filter. Match flows using verified source-app identity and tested helper
attribution; do not try to discover every API or CDN domain used by the native app.
This app-specific denial applies to its network traffic regardless of the target
IP, hostname visibility, or whether the app uses its own DNS implementation. No
TLS decryption is part of the design.

At exhaustion, reevaluate tracked existing flows as well as deny new ones. An app
may already have an active game connection, streaming response, WebSocket, or
other long-lived session. Verify TCP and UDP/QUIC behavior and bound the time until
further traffic is blocked; a rule applying only to newly opened connections is
insufficient. Validate helper/source-app attribution and report coverage gaps.
Confirm that the chosen flow-verdict strategy retains control of ongoing flows
before claiming that already-established connections are covered.
Buffered responses or locally stored content can remain visible after network
traffic stops; the filter does not erase content or stop offline computation.

On reset or an authorized allowance increase, reconcile the app filter and browser
rules against the same current quota state. Fresh app connections should work
again; apps may need to retry connections that were denied. Preserve exhausted
app rules across service restarts and report filter disconnection or disablement
as incomplete enforcement. Do not advertise app launch or offline-use blocking.

Sources: [Network source-app identity](https://developer.apple.com/documentation/networkextension/nefilterflow/sourceappaudittoken),
[Content filter provider](https://developer.apple.com/documentation/networkextension/nefilterdataprovider).

## Network Extension scope and optional DNS filtering

DNS filtering can refuse selected hostnames, but a lookup is not a measure of viewing
time. Cached DNS, established connections, and buffered or cached pages mean that
denying later lookups cannot immediately revoke all use. Apple's DNS proxy handles
port-53 DNS flows; an application's own DNS-over-HTTPS is not automatically an
ordinary DNS flow.

Network Extension is the primary native-app enforcement layer. Domain metadata
remains conditional: Apple's `NEFilterSocketFlow.remoteHostname` is populated
for create-by-name APIs, and `NEFilterBrowserFlow` is WebKit-specific. Do not claim
that a packet or socket filter always knows every Chrome request's domain. Native
app rules use app identity; browser rules use the extensions' known page domains.

macOS 26 URL filtering is worth a later feasibility check, but Apple's coverage is
WebKit and URLSession by default, with participation required from other stacks.
It also does not supply active-tab time accounting. Network extensions introduce
signing, entitlement, installation, and system-extension deployment work.

Sources: [DNS proxy](https://developer.apple.com/documentation/networkextension/nednsproxyprovider),
[Socket hostname](https://developer.apple.com/documentation/networkextension/nefiltersocketflow/remotehostname),
[Browser flow](https://developer.apple.com/documentation/networkextension/nefilterbrowserflow),
[URL filters](https://developer.apple.com/documentation/networkextension/url-filters),
[Deployment](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment).

## Child-account enforcement

Reliable deployment requires enabled extensions, website permissions, coverage of
all allowed browser profiles, and an explicit private-browsing policy. Switching
to an unsupported browser or disabling an extension can bypass a basic prototype.
A standard child account is useful but does not by itself prevent extension removal.
Evaluate browser management/MDM and application restrictions separately for Chrome
and Safari. A child with administrator control can defeat ordinary local controls.

Native Screen Time APIs should not be assumed to provide a cross-browser macOS
quota engine. Apple's native ScreenTime framework concerns an app's own web usage;
DeviceActivity platform availability is not equivalent to unrestricted native
macOS enforcement across browsers.

Sources: [ScreenTime](https://developer.apple.com/documentation/screentime),
[DeviceActivity](https://developer.apple.com/documentation/deviceactivity).

## Acceptance checks for implementation

- Correct exact/subdomain boundaries, IDNA, suffix validation, aliases, and overlap rejection.
- Shared balance when switching between Chrome and Safari, profiles, windows, and tabs.
- Chess.com six-hour balance shared across Chrome, Safari, and its bound standalone app.
- ChatGPT six-hour balance shared across Chrome, Safari, and its bound standalone app.
- Each service exhausts and recovers independently; unrelated apps and sites remain accessible.
- Browser/app overlap charges once; running background apps do not consume foreground time.
- Verified app identity survives renaming and compatible updates; unresolved bindings show incomplete coverage.
- Shared browser executables do not accidentally match all sites as one standalone app.
- Exhaustion blocks browser access and the selected app's new and existing network flows.
- Test long-lived game/streaming connections, TCP, UDP/QUIC, and app helper attribution.
- Reset, allowance increases, wake, and restarts reconcile browser and app network rules.
- Cached/offline app use and app launches remain possible and are clearly described.
- No double charging; passive video counts; lock/sleep and excluded background use pause.
- Exhaustion stops an open page as well as fresh navigation; cached content is covered.
- Monday/custom-day boundaries, DST changes, wake after reset, and intervals across midnight.
- Crash/restart durability, duplicate messages, worker suspension, and service disconnects.
- Policy changes preserve usage; rollback does not restore already-spent allowance.
- Explicit observed behavior for private browsing, disabled extensions, and unsupported browsers.
