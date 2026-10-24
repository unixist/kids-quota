# Browser adapters

Run `npm run build:extensions` at the repository root. The dependency-free builder
creates `extensions/build/chrome` and `extensions/build/safari` from shared sources.
Run `npm test` for the pure-policy and browser-controller tests.

Chrome development: load `extensions/build/chrome` using **Load unpacked** in
`chrome://extensions`, then register the bundled native host using the install
instructions. An unpacked extension can be disabled by its user. Managed deployment
and stable extension IDs are separate from developer loading.

Safari resources are consumed by the native Safari Web Extension target. Enable
that extension and grant website access in Safari settings. Safari uses native
request/reply messages; Chrome uses a persistent native-messaging port. Both send
to `com.kidsquota.bridge`. They do not contact the REST API or carry parent tokens.

## Wire protocol

Adapters send `browserState` with `browser`, `sessionId`, increasing `sequence`,
selected `hostname` or null, `focused`, and `tabId` or null. The native side must
authenticate the connecting OS user, arbitrate the actual foreground OS session,
and return only that user's policy. Browser reports never include elapsed seconds.

Replies have `type: policy`, `revision`, `requestSequence` (echoed when available),
`configured`, `coverage`, and `rules`. Each rule has `serviceId`, optional `name`,
`domains: [{hostname, includeSubdomains}]`, `blocked`, `remainingSeconds`, and an
ISO-8601 `resetAt`. Temporary errors should return `type: error`, not an empty
policy. Valid explicit policy changes can clear old rules.

## Behavior and limits

- Tab, URL, window focus, page lifecycle, native replies, and recovery alarms all
  trigger reconciliation. Five-second heartbeats improve freshness but are not the
  authoritative clock. The native service must stop accepting stale activity.
- After 15 seconds without a valid native reply, all previously configured domains
  are blocked until reconciliation succeeds. Unconfigured sites are unaffected.
- Exhaustion installs declarative top-level/iframe navigation redirects and
  replaces existing matching tabs, stopping already-loaded page content. No
  screenshots, page contents, keystrokes, or full-URL history are stored.
- Usage follows the selected top-level HTTP(S) hostname while its browser window
  is in front. Embedded third-party frames and background media do not receive
  their own usage attribution. Other browsers and profiles without the extension
  require separate deployment controls.
- Returning after reset opens the service's first configured hostname rather than
  restoring a possibly sensitive deep link.
- Dynamic rule errors are surfaced as incomplete protection. Website permissions,
  browser-specific DNR compatibility, private windows, and extension enablement
  need on-device testing. These unit tests do not establish anti-tamper protection.
- Chrome native-port lifetime and Safari background-page suspension differ. Full
  signed/native integration tests must exercise idle video, window switching,
  browser restart, cached pages, and native-service interruption.

Sources: [Chrome service-worker lifecycle](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle),
[Safari content blocking](https://developer.apple.com/documentation/safariservices/blocking-content-with-your-safari-web-extension),
[Safari native messaging](https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension).
