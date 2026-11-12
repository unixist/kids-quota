# Chrome Web Store submission

This file contains release notes for the publisher, ready-to-paste listing text,
permission explanations, and reviewer instructions.

**Current status: v0.1.5 submitted November 11, 2026; pending Google review.**
The existing v0.1.4 store extension remains available; it was verified installable
on November 8, 2026. Unlisted distribution and automatic publication after approval
are selected for the update. Submission is not approval or publication.
The store ID remains `kcdaoppmbobecgoajneamoimiohmkipj`; use the
[direct store URL](https://chromewebstore.google.com/detail/kcdaoppmbobecgoajneamoimiohmkipj),
because the unlisted extension does not appear in store searches. The compatible
v0.1.5 companion DMG is published in the
[v0.1.5 prerelease](https://github.com/unixist/kids-quota/releases/tag/v0.1.5).
Installing that DMG does not replace the extension in a Chrome Web Store profile.

## Prepared artifacts

Run `npm run package:chrome-store` to create
`dist/KidsQuota-Chrome-0.1.5.zip` and its SHA-256 file. The ZIP omits the local
manifest key so Google can assign the store ID; local builds retain the existing
key. The icon is `dist/chrome-store/icons/icon128.png`.

`node scripts/preview-chrome-store.mjs` creates a local preview in
`work/chrome-store-preview` using the production popup with labeled example
balances. Serve that directory on localhost and capture it at 1280 × 800.
The prepared screenshot is
`dist/chrome-store-artwork/remaining-time-1280x800.jpg`.

The real store ID is recorded in `extensions/chrome-store.json`. After building
the updated companion, package it with
`VERSION=0.1.5 scripts/package.sh --local`; the script reads that ID by default.
An explicit equivalent is
`CHROME_STORE_EXTENSION_ID=kcdaoppmbobecgoajneamoimiohmkipj VERSION=0.1.5 scripts/package.sh --local`.
The installer accepts the exact local and store IDs together; existing local
extension installations continue to work. Do not run both extensions in one
Chrome profile. The v0.1.5 app's setup links direct families to the store
installation guide, which distinguishes pending approval from availability.

## Release prerequisites

The Chrome Web Store assigns its own extension ID. The native messaging host
installed by Kids Quota must explicitly allow that ID. **The published v0.1.3
local DMG registers the unpacked extension's ID and is not the store companion
installer.** Store compatibility was added in v0.1.4 and is retained in
v0.1.5. Use the v0.1.5 companion for this update and test it with the store build.
Do not point reviewers or families to v0.1.3 as though it supports the store ID.

The published companion prerelease is
`https://github.com/unixist/kids-quota/releases/tag/v0.1.5`, with direct asset URL
`https://github.com/unixist/kids-quota/releases/download/v0.1.5/KidsQuota-0.1.5-Local.dmg`.
The DMG and checksum file are uploaded. The DMG is 3,771,686 bytes with SHA-256
`8dd8772815bddc507123a44fe25d0ff8d7912e5919e50f706ecd8e935a7b5d08`.
The submitted `KidsQuota-Chrome-0.1.5.zip` is 15,312 bytes with SHA-256
`bd97c46674df4b4035966edd3cb5764bb4c287ec970fb63a06fa2efb48eb0023`.
Upload verification does not establish supervised-profile runtime behavior.

Publish [the privacy policy](privacy-policy.md) to the public repository before
using its URL in the dashboard. The expected public URL is
`https://github.com/unixist/kids-quota/blob/main/docs/privacy-policy.md`.
Verify that this URL loads without signing in after pushing the file.

The store needs a 128 × 128 icon and at least one 1280 × 800 screenshot. Use
screenshots of the actual extension UI with clearly fictional demonstration
data; do not use a child's real usage, names, or browsing activity. Identify demo
data as such. Include the popup's balance view and the time-limit page, and
prominently state the companion-app requirement.

Unlisted distribution makes the listing installable through its direct URL
without including it in store discovery. It still receives Google's review.
Neither an upload nor a submitted review is an approval. A supervised Chrome
profile must still permit installation from the Chrome Web Store; publishing
does not bypass Family Link or an organization's policy.

## Store fields

| Field | Value |
| --- | --- |
| Name | Kids Quota |
| Summary | Weekly website time allowances and remaining balances. Requires the Kids Quota companion app for macOS. |
| Language | English |
| Category | Productivity (or Workflow & Planning if the current dashboard uses subcategories) |
| Homepage | `https://github.com/unixist/kids-quota` |
| Support | `https://github.com/unixist/kids-quota/issues` |
| Privacy policy | `https://github.com/unixist/kids-quota/blob/main/docs/privacy-policy.md` |
| Store ID | `kcdaoppmbobecgoajneamoimiohmkipj` |
| Direct store URL | `https://chromewebstore.google.com/detail/kcdaoppmbobecgoajneamoimiohmkipj` |
| Visibility | Unlisted |
| Review status | v0.1.5 submitted November 11, 2026; pending review |
| Publication | Automatic after approval |
| Mature content | No |
| Remote code | No |

## Detailed description

Kids Quota gives families weekly website allowances and a clear view of how much
time remains. This Chrome extension works with the Kids Quota companion app on
macOS 14 or later. The companion app must be installed and configured before the
extension can measure or restrict website use.

Parents choose a Mac login to manage, set weekly allowances, and group domains
under a service. Initial setup includes Chess.com and ChatGPT at six hours each
per week, with a Monday reset. Parents can change those limits, choose another
reset schedule, and add other domains in the companion app.

The extension measures the selected website while Chrome is in the foreground
and the Mac session is awake and unlocked. Background tabs do not consume their
own allowance. Click the Kids Quota toolbar button to see remaining time and the
next reset. When a configured allowance is exhausted, Kids Quota redirects
matching pages to its time-limit screen and replaces matching pages already
open in Chrome.

Different children use separate macOS login accounts for independent balances.
Chrome profiles within the same Mac login share that login's allowance. Where a
parent has linked a native Mac app to the same service, its foreground usage can
also consume that service's allowance. The current local companion release
tracks selected native apps but does not block their network or offline use.

Website activity stays on the Mac. The extension reads tab URLs, sends only the
active website's hostname and activity state to the local companion service,
and receives balances and blocking rules. It does not read page content,
messages, forms, or keystrokes, and does not send activity to a developer cloud
service. All-site permission allows parents to add custom domain rules in the
companion app and allows restrictions to apply to already-open pages.

Installation requires an administrator to install the companion Mac app and
configure the selected login. The current companion installer is an unnotarized
local build, so macOS may ask you to approve it under Privacy & Security. Follow
the release-specific installation guide in the project repository. Install the
Chrome extension in each Chrome profile that needs coverage and allow its
website access. A supervised Google account may require parental permission to
install extensions from the Chrome Web Store.

This extension does not replace Family Link or configure Google's account
supervision. Its installation does not make it removal-proof. Other browsers,
profiles without the extension, and native-app access need their own controls.
If the companion service disconnects, previously configured domains may remain
blocked until it reconnects. Parent settings and allowance changes are available
in the Mac app, not the browser popup.

Download and setup: https://github.com/unixist/kids-quota
Support: https://github.com/unixist/kids-quota/issues

## Privacy practices fields

### Single purpose

Measure and enforce parent-configured weekly website allowances on a Mac, and
show the current Mac user's remaining time, using the installed Kids Quota
companion service.

### Permission explanations

| Permission | Justification |
| --- | --- |
| `storage` | Saves the last received allowance policy locally so the extension can restore configured restrictions while reconnecting after a browser or background-worker restart. It uses `storage.local`, not sync storage. |
| `nativeMessaging` | Exchanges current website hostnames/activity state and allowance policies with the required `com.kidsquota.bridge` native helper on the same Mac. The local service owns the clock, per-user balances, and parent settings. No remote server receives these native messages. |
| `alarms` | Periodically reconnects and refreshes policy after browser background suspension, so balances, resets, and blocking do not rely solely on a continuously running JavaScript timer. |
| `declarativeNetRequestWithHostAccess` | Redirects top-level pages and frames for configured exhausted domains to the packaged Kids Quota time-limit page. Rules come from the locally configured allowance policy and can be removed when time becomes available. |
| `http://*/*` and `https://*/*` | Parents can configure arbitrary website domains in the Mac app. Host access lets the extension identify the active HTTP(S) tab, redirect configured exhausted domains, and replace already-open matching pages. Content scripts observe focus and visibility changes to refresh activity; they do not read page contents. Broad access is used for the current custom-domain feature, not a planned feature. |

The Chrome store build omits the separate `tabs` permission: the existing
HTTP(S) host permissions supply URL access for the websites it handles. Safari
build permissions are outside this store submission.

### Remote code declaration

No. All executable JavaScript and CSS are packaged with the extension. The native
helper is installed separately by the Mac administrator. Native replies are
validated JSON data containing domain rules, balances, and reset times; they are
not executable code. The extension does not fetch or evaluate remote scripts.

### Data handling disclosure

Disclose **Web history** and **User activity** even though processing stays on
the Mac: the extension accesses HTTP(S) tab URLs, reduces them to hostnames for
native reporting, and reports foreground activity. Do not select "no user data"
or claim that only configured sites are observed.

The full product also handles child display names and local Mac account
identifiers in its companion app. If the dashboard asks about product-wide data
handling, disclose **Personally identifiable information** for those local
records. The Chrome extension itself does not receive child names, Mac account
IDs, Google account details, or administrator credentials. Its session and tab
identifiers are transient activity-routing values. Review the dashboard's exact
category wording when completing this section; keep its declarations consistent
with the published privacy policy and the actual package.

Data is used for the allowance feature. It is not sold, used for advertising, or
used for creditworthiness or lending. A parent may authorize separate local
read clients; those grants and their consequences are explained in the policy.
Do not state that native data is encrypted by Kids Quota or automatically deleted
after each week. Native storage is protected by operating-system permissions
and old aggregate periods remain in the database.

## v0.1.5 review notes

This update distinguishes a disconnected Mac activity monitor from an exhausted
allowance. A fresh positive balance displays the real time remaining and explains
that tracking is paused. Known restricted domains remain blocked until trusted
monitoring reconnects. A fresh zero balance still displays “weekly limit reached.”
The extension never grants or resets time itself.

Recovery fixes cover delayed replies, policy-save failures, and old blocking rules.
The return button stays unavailable until Chrome successfully removes the old
rules. Reset times use the saved timezone, with an explicit UTC fallback when an
older browser lacks that timezone. Permissions, privacy declarations, and local
data handling are unchanged; no remote code was added.

## Reviewer test instructions

The instructions below reference the uploaded v0.1.5 companion asset. Its native
host authorizes `chrome-extension://kcdaoppmbobecgoajneamoimiohmkipj/`. Do not
substitute v0.1.3, which does not authorize that store ID.
No Kids Quota cloud account, subscription, Google login, or test credentials are
required to test the allowance features. Website accounts are unnecessary for
the custom-domain test below.

1. Use macOS 14 or later on Apple Silicon or Intel. Download the store-compatible
   [KidsQuota-0.1.5-Local.dmg](https://github.com/unixist/kids-quota/releases/download/v0.1.5/KidsQuota-0.1.5-Local.dmg).
   Mount it and run **Install Kids Quota.pkg**. Enter credentials for an
   administrator on the test Mac when macOS Installer requests them. This local
   build is unnotarized; macOS may require approval in **System Settings →
   Privacy & Security → Open Anyway** for the package or app.
2. Open **Kids Quota** in Applications. Choose **Unlock parent settings** and
   authenticate with a Mac administrator. Select a disposable test Mac login
   through **Set up account**; standard and administrator logins are both
   supported. The current login may be selected. The default services appear
   with six hours per week each.
3. In Chrome under that selected Mac login, install the submitted store
   extension and allow its website access. Do not load the local unpacked
   extension in parallel. Pin Kids Quota and open its popup. It should display
   balances for the configured Mac login. If the menu-bar hourglass is missing,
   sign out of the test Mac login and back in to start the login agent.
4. To avoid website login requirements, unlock the companion app and use
   **Add a service**. Choose **Custom website**, name it `Review example`, set
   its website to `example.com`, and set the allowance to `0.02` hours. Save.
   This is approximately 72 seconds. No native app needs to be selected.
5. Open `https://example.com` in Chrome. Keep that tab selected, Chrome in the
   foreground, and the Mac unlocked for about 90 seconds. Do not keep the parent
   settings window foreground while testing; website charging pauses when
   Chrome is no longer the active application. The active page should change
   to the Kids Quota time-limit screen when its allowance runs out.
6. Try opening `https://example.com` in another tab: it should also reach the
   time-limit screen. Unconfigured websites should remain accessible. The
   toolbar popup should show no time left for `Review example`.
7. Unlock parent settings, choose the same test login, and use **Reset this
   week**. This resets all current-week service balances for that selected
   login, so use a disposable account. Return to Chrome and choose **Return to
   website** on the time-limit page after the extension receives the fresh
   policy. The site should reopen and start using the restored allowance.
8. Verify background behavior with a positive allowance: switch to another
   application or another unconfigured tab for a minute. The configured
   website's balance should stop decreasing. Balances display whole minutes
   and refresh about every five seconds; they are not a seconds countdown.
9. For account isolation, switch to a Mac login that has not been configured.
   Its extension popup should ask for account setup rather than display the
   configured login's balances. No parent settings can be changed from the
   browser popup.

The optional Network Extension is inactive in this companion release. No
network-filter approval is needed for these browser tests. Native app blocking
and prevention of offline use are not claimed. Parent **Check coverage** can
remain present if another supported browser is absent or native app filtering
is inactive; test the Chrome behavior directly.

## Source and policy references

The implementation is in `extensions/shared/controller.js`,
`extensions/shared/core.js`, `Sources/QuotaBridge/main.swift`,
`Sources/QuotaAgent/main.swift`, `Sources/KidsQuotaService/Controller.swift`, and
`Sources/KidsQuotaCore/QuotaStore.swift`.

Google describes [listing fields and image requirements](https://developer.chrome.com/docs/webstore/cws-dashboard-listing),
[privacy declarations](https://developer.chrome.com/docs/webstore/cws-dashboard-privacy),
[local-data privacy requirements](https://developer.chrome.com/docs/webstore/program-policies/user-data-faq),
and [unlisted distribution and review](https://developer.chrome.com/docs/webstore/cws-dashboard-distribution).
