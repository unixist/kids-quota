# Kids Quota for iPhone

The iPhone app shows the latest quota summary reported by each Mac. The Home
Screen widget supports small, medium, and large sizes, and can show the family
overview or a selected child. Parents get separate read credentials; the phone
cannot change an allowance or reset usage.

## Connect a phone

1. Install the app using your signed development build or TestFlight.
2. Choose **Connect your family**. Scan the private iPhone QR code, import the
   iPhone connection JSON file, or paste that file's contents.
3. The app verifies the connection before saving it. Do this separately on each
   parent's iPhone with their own read credential.
4. Touch and hold the Home Screen, then choose **Edit → Add Widget → Kids Quota**.
   Touch and hold the installed widget and choose **Edit Widget** to select one
   child. An empty child selection shows the family overview.

The app displays sample data only when **See a sample** is selected, or when run
with the development launch argument `--demo`. Sample data is never uploaded,
cached for a real widget, or mixed into a connected family.

## Reading the display

- The large number is the last reported **time left**, with used time and the
  weekly allowance below it. Progress bars represent the fraction used.
- **Tracking paused** is separate from **Weekly limit reached**. A missing Mac
  monitor can pause website access while the allowance remains positive.
- Data over 15 minutes old, or crossing the reported reset boundary without a
  new Mac report, is labeled **Last known**. The app never invents a countdown or
  grants a new week from cached data.
- Macs upload about every five minutes while awake. WidgetKit is asked to fetch
  every fifteen minutes, but iOS controls actual refresh timing. Open or pull to
  refresh the app for a fresh relay read; this does not wake a sleeping Mac.
- Small widgets show one child's first two services; medium shows two children;
  large shows four. Extra children/services are indicated and visible in the app.
- The same child's login on two Macs remains two independent ledgers, labeled
  with the Mac name. This release does not pool or enforce a shared allowance
  across computers.

## Build and test

Requires Xcode with an iOS 17+ SDK and XcodeGen. The separate iOS project does not
change the existing macOS project.

```sh
scripts/build-ios.sh
cd ios/QuotaKit
swift test
```

The generated project is `ios/KidsQuotaPhone.xcodeproj`. The app scheme is
`KidsQuotaPhone`, and its test action runs five asynchronous pairing/refresh
regressions. The pure `QuotaKit` Swift package has twenty-one tests for validation,
staleness, reset boundaries, identity, timestamps, and cache ordering.
CI also runs the five app-state tests on an available iPhone simulator using the
newest installed iOS runtime (17 or later).

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project ios/KidsQuotaPhone.xcodeproj -scheme KidsQuotaPhone \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath dist/ios-simulator CODE_SIGNING_ALLOWED=NO test
```

`project.yml` is the source of truth; run `xcodegen generate --spec project.yml`
from `ios` after changing it. App version is 0.2.0, build 1. The icon is original
vector drawing code in `generate-icon.swift`, rendered to an opaque 1024px PNG.

## Signing and TestFlight

Select your Apple Developer team for both the application and widget targets.
Default identifiers are:

| Purpose | Identifier |
| --- | --- |
| iPhone app | `com.unixist.kidsquota.mobile` |
| Widget extension | `com.unixist.kidsquota.mobile.widget` |
| Shared App Group | `group.com.unixist.kidsquota.mobile` |
| Shared Keychain suffix | `com.unixist.kidsquota.mobile.shared` |

The App Group must be enabled for both targets. Shared Keychain access uses the
team's application identifier prefix. `KQ_BUNDLE_PREFIX`, `KQ_APP_GROUP`, and
`KQ_KEYCHAIN_SUFFIX` can be overridden in project settings for another team.
Do not embed connection codes or credentials in build settings or the bundle.

Archive for **Any iOS Device**, validate in Organizer, and upload to App Store
Connect. Create the App Store Connect app record with the same bundle ID first.
After processing, add both parents as internal testers where eligible, or use
external TestFlight testing (which can require Apple's beta review). An unsigned
simulator build is not installable on a physical iPhone.

The simulator build intentionally does not sign or upload anything. Distribution
requires valid signing credentials, profiles, an App Store Connect record, and
the account's current agreements. Root project release documentation records
what was actually built or uploaded.

## Code map

- `QuotaKit`: Foundation-only protocol decoding, validation, formatting,
  identity, staleness transitions, and preservation of newer Mac reports.
- `Shared/FamilyClient.swift`: bounded HTTPS reads and explicit rejection of
  redirects, so read credentials are never forwarded to a different address.
- `Shared/PhoneStorage.swift`: shared Keychain connection and App Group cache.
  Cache files are tied to the connection fingerprint, protected after first
  unlock, and updated through file coordination across app/widget processes.
- `App/FamilyStore.swift`: connection and refresh state with request generations
  preventing late replies from restoring a disconnected or replaced family.
- `App/FamilyDashboard.swift`: family cards, progress, and connection settings.
- `App/PairingView.swift`: JSON/file/QR setup; camera frames are not saved.
- `Widget/KidsQuotaWidget.swift`: child selection, timeline fetches, and cached
  freshness/reset transitions. No background location, push, or live activity.

Connection tokens stay in this phone's Keychain and do not migrate through an
unencrypted export. **Disconnect this iPhone** removes its credential and cache;
cloud-side revocation is handled by the deployment's parent credential controls.
Cached balances can remain visible after a network or authorization error and are
clearly last known; cloud revocation prevents further reads, not remote erasure
of data already received by a phone.

## Beta description and review notes

Kids Quota gives parents a read-only view of their children's weekly website and
app allowances. See remaining time for each child and service, and add a small,
medium, or large Home Screen widget. Reports identify the Mac that supplied them
and show when they were last updated; a sleeping or disconnected Mac can leave
the displayed balance out of date. This iPhone app does not change limits or
enforce restrictions.

Reviewers can choose **See a sample** before connecting; this displays isolated
sample data without an account or server. Real balances require a configured
Kids Quota Mac and private relay, plus a parent's read-only connection code.
Supply a separate test-family connection through the private review channel
when testing the actual relay or widgets. Test pairing, refresh, disconnect,
offline/stale indicators, and widget child selection. These notes prepare a beta
submission; they do not mean a build has been uploaded or approved.

## Privacy data summary for release preparation

The app receives child display names, computer names and identifiers, configured
service names and domains, weekly allowances, usage totals, remaining balances,
tracking state, and report/reset timestamps from the family's private relay over
HTTPS. It caches those summaries in the shared App Group for the app and widget.
It does not receive browsing history, complete page URLs, page contents, typed
text, or location. There are no advertising or analytics SDKs.

The connection credential is kept in the shared Keychain. The optional camera
scanner reads a pairing QR code locally; camera frames are neither saved nor
uploaded. Disconnect removes this phone's saved connection and quota cache.
Relay storage and retention are controlled by the family's deployment. Review
the deployed service and its access/logging settings when completing Apple's
privacy answers and publishing a privacy policy.
