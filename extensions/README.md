# Browser adapters

Run `npm run build:extensions` at the repository root. The dependency-free builder
creates `extensions/build/chrome` and `extensions/build/safari` from shared sources.
Run `npm test` for the pure-policy and browser-controller tests.

## Browser setup for the local DMG

The local installer includes the browser files and native hosts. It does not
silently enable extensions. Complete these steps in **each child's macOS login**.
The Network Extension is included but inactive in this build; native app usage
can consume time, but native apps retain network access after exhaustion.

### Chrome

1. Open `chrome://extensions` and enable **Developer mode**.
2. Choose **Load unpacked**.
3. Select `/Library/Application Support/KidsQuota/BrowserExtensions/Chrome`.
4. Allow Kids Quota to access its requested websites. Enable it for every browser
   profile the child uses; incognito access is a separate browser setting.

The installed folder remains in place after ejecting the DMG. The public manifest
key in [chrome-public-key.json](chrome-public-key.json) gives this local build a
stable extension ID on every Mac and installation path. The builder writes that
ID to `extensions/build/chrome-extension-id.txt`; the local installer registers
the native host for that exact ID. This file contains only a public key, not a
private signing key. A future Chrome Web Store release must use the store's real
key/ID and keep the host registration consistent.

### Safari

The containing Kids Quota app includes a native Safari extension. A temporary
raw JavaScript extension cannot replace it because Kids Quota uses native messaging.

1. In Safari **Settings → Advanced**, enable **Show features for web developers**.
2. In **Settings → Developer**, enable **Allow unsigned extensions**. Safari may
   request administrator authentication.
3. In **Settings → Extensions**, enable Kids Quota and grant website access.
4. If Safari has multiple profiles, enable it in each relevant profile as well.

**Safari resets “Allow unsigned extensions” every time it quits.** Repeat that
step after each restart. This local Safari adapter is suitable for testing and
does not provide persistent removal-resistant protection. The parent app shows
missing coverage when the adapter stops reporting.

Apple documents these steps in [Running your Safari web extension](https://developer.apple.com/documentation/safariservices/running-your-safari-web-extension).

## Development and signed deployment

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
