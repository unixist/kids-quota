# Architecture proposal

This document describes intended behavior, not an implemented system.

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

- **Swift macOS app:** parent settings, weekly hours, domain groups, reset day and
  timezone, remaining time, and explicit temporary overrides.
- **Quota service:** the single owner of balances for a macOS user. A per-user
  background agent is sufficient for an initial prototype; privileged service
  design and deployment policy are separate work for stronger tamper resistance.
- **SQLite store:** validated policies and durable usage indexed by user, stable
  quota ID, and calendar-period start. Do not store page contents or full URL history.
- **Browser adapters:** report the selected top-level hostname and focus changes,
  receive remaining time and deadlines, and apply blocking. A Chrome native host
  and Safari native app-extension bridge both connect to the same service.

Browser/native messages must be versioned, bounded, and restricted to the intended
extension identities. Do not expose an unauthenticated localhost control server.
Policy updates require parent authorization in the intended product, not merely
a browser message. A parent PIN alone is not an OS-level security boundary.

## Domain matching

Parse URLs using a URL parser, canonicalize hostname case, trailing dot, and IDNA,
and compare DNS labels rather than arbitrary substrings.

For an entry `youtube.com` with `includeSubdomains: true`, match the normalized
hostname when it equals `youtube.com` or ends with `.youtube.com`.

- Matches: `youtube.com`, `www.youtube.com`, `m.youtube.com`.
- Does not match: `notyoutube.com`, `youtube.com.attacker.example`.
- `youtu.be` is a separate domain and must be listed explicitly in the same group.
- Reject IP literals, schemes, paths, empty names, public-suffix-only entries such
  as `com` or `co.uk`, and overlapping rules that would make quota attribution ambiguous.
- Support explicit related-domain groups; do not infer site ownership from IPs.

Blocking a site's navigation should not globally block a shared CDN just because
that site uses it. Third-party embeds, alternate domains, installed web apps, and
picture-in-picture need a defined policy before claiming coverage.

## What counts as time

Default to the selected top-level tab in the frontmost supported browser while the
macOS session is unlocked and awake. Use OS foreground/session state to arbitrate
across browsers and windows; a tab's `active` flag alone is insufficient.

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
Do not infer that an old tab stayed active through a long unobserved interval.

Charge at most one foreground activity per user at a time. Persist short increments
transactionally and settle on transitions. Identify duplicate/out-of-order events
with session IDs and sequence numbers. Target a small documented overshoot bound
and measure it under suspension and disconnects before promising timing precision.

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
does not change a policy's saved timezone. Domain and display-name edits preserve
the quota's stable ID and usage; deleting and recreating a quota is an explicit
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

## Why DNS and Network Extension are secondary layers

DNS filtering can refuse selected hostnames, but a lookup is not a measure of viewing
time. Cached DNS, established connections, and buffered or cached pages mean that
denying later lookups cannot immediately revoke all use. Apple's DNS proxy handles
port-53 DNS flows; an application's own DNS-over-HTTPS is not automatically an
ordinary DNS flow.

Network Extension content filters can add network-level enforcement, but domain
metadata is conditional. Apple's `NEFilterSocketFlow.remoteHostname` is populated
for create-by-name APIs, and `NEFilterBrowserFlow` is WebKit-specific. Do not claim
that a packet or socket filter always knows every Chrome request's domain.

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
- No double charging; passive video counts; lock/sleep and excluded background use pause.
- Exhaustion stops an open page as well as fresh navigation; cached content is covered.
- Monday/custom-day boundaries, DST changes, wake after reset, and intervals across midnight.
- Crash/restart durability, duplicate messages, worker suspension, and service disconnects.
- Policy changes preserve usage; rollback does not restore already-spent allowance.
- Explicit observed behavior for private browsing, disabled extensions, and unsupported browsers.
