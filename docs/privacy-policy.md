# Kids Quota Privacy Policy

Last updated: November 11, 2026.

Kids Quota helps a parent or Mac administrator set weekly website allowances.
This policy describes the Kids Quota Chrome extension and its required macOS
companion app and background service, and the optional iPhone dashboard introduced
in the v0.2.0 source, maintained in the
[unixist/kids-quota project](https://github.com/unixist/kids-quota).

## Website activity processed on your Mac

The extension reads browser tab URLs to identify website domains and to replace
restricted pages with the time-limit screen. It checks which browser window and
tab are active. It does not read page text, forms, messages, passwords, cookies,
screenshots, audio, or keystrokes.

While a normal HTTP or HTTPS website is active, the extension sends its hostname
(for example, `chess.com`), a focus flag, a temporary extension-session identifier,
a message sequence number, and a tab identifier to the Kids Quota native helper
on the same Mac. Hostnames may include sites that have no configured allowance;
the local service uses the hostname to decide whether an allowance applies.
The extension removes the URL's path, query, and fragment before making this
report. It does not send full URLs to the native helper or keep a full-URL
browsing-history log.

The companion service combines these reports with the local login agent's
foreground application, session, sleep, and lock observations to measure active
use. It records aggregate usage for each configured child, service, and weekly
period. It does not store a chronological list of visited websites. Browser
activity reports and current foreground observations are kept in process memory
for activity matching and freshness checks.

## Settings and storage

The extension stores the last received service names, configured domains,
remaining balances, reset times, and blocking policy in Chrome's local extension
storage. This lets it restore known restrictions while reconnecting to the Mac
service. It does not use Chrome's sync storage.

The companion app stores the display name chosen for each child, local macOS
account identifiers, configured domains, selected application identities and
paths, allowances, reset schedules, aggregate usage, and manual-reset audit
records on the Mac. These files are under
`/Library/Application Support/KidsQuota`; operating-system file permissions
restrict the native database and credential files. This version does not add its
own database encryption.

The extension does not request your Google account, email address, or password.
Parent settings use macOS's administrator authorization prompt. The extension
does not receive the administrator password or the parent's authorization grant.

## How the information is used and shared

Information is used to calculate and display allowances, apply configured
website restrictions, restore the extension's current policy, and let the parent
manage the installation. The child can view the balances for the current Mac
login. An authorized administrator can view and manage the configured accounts
and allowances on that Mac.

Kids Quota has no developer-operated analytics or cloud collection endpoint. The
extension and companion software do not send usage records, domains, or child
profiles to the project maintainer. There are no advertising or tracking SDKs,
and the software does not sell data or use it for advertising, creditworthiness,
or lending decisions. All executable extension code is included in its package.

A parent can separately authorize other local programs to read selected child
names, services, allowances, and balances through a scoped, read-only API on
`127.0.0.1`. Those programs may use or publish the information as the parent
directs. The Chrome extension does not use this HTTP API. A separate client's
data handling is controlled by that client and its operator, and is not automatic
sharing by the Chrome extension. The parent can revoke these read credentials
in the companion app.

## Optional iPhone dashboard

Phone synchronization is off until an administrator configures it in the Mac
app. When enabled, the Mac sends quota summaries to the parent's configured HTTPS
relay approximately every five minutes. Summaries contain the chosen Mac and
child display names, opaque record IDs, assigned service names and configured
domains, weekly allowance and usage totals, remaining time, reset boundaries and
timezone, and tracking status. They exclude macOS account identifiers, application
paths or signing identities, full URLs, page content, and a history of visited sites.

The supplied relay runs in the parent's Google Cloud project and stores the latest
summary per Mac in a private Cloud Storage bucket. The endpoint authenticates each
Mac's write credential and each parent's separate read credential. The bucket is
not public. The relay does not grant phones permission to change Mac quotas or
settings. Google processes hosting requests under its own terms and privacy
practices; ordinary infrastructure logs can include request times, IP addresses,
and HTTP status, but the relay does not log authorization headers or summary bodies.

The iPhone app and widget save their connection credential in shared Keychain and
cache the latest summary in their shared App Group. A widget may show an older
summary when the Mac is asleep, a connection fails, or iOS delays refresh; it labels
when the Mac last reported. Disconnecting a phone clears its local credential and
cached summary. It does not delete the relay's copy or revoke a credential copied
to another device; the project owner can revoke that credential in relay configuration.
Disconnecting a Mac stops future uploads and removes its local write credential.
The project owner controls deletion and retention of cloud copies. The cloud
deployment guide documents the configured bucket retention behavior.

Chrome, the Chrome Web Store, GitHub, and websites you visit have their own
privacy practices. Visiting the project's support pages or submitting a GitHub
issue shares that request or issue with GitHub. Information you put in a public
issue is public; do not include a child's private information, activity records,
passwords, or tokens.

## Retention and removal

Current activity observations remain in memory until replaced, cleared, or the
service exits; they are not written to an activity-history table. The saved
extension policy remains in Chrome's local extension storage until replaced or
that extension's data is removed. Removing the Chrome extension removes its
extension storage but does not delete the companion app's native database.

Native settings, aggregate usage from earlier weeks, and manual-reset audit
records have no automatic expiry in this version. Weekly rollover starts a new
allowance period; it does not erase earlier records. **Reset this week** changes
the current counters and records a reset event; it is not a data-deletion command.
Upgrading the Mac app preserves existing data.

The Mac administrator controls the local installation and can remove its native
data when uninstalling. This version has no built-in per-child deletion screen.
For removal guidance, use the project's support link below. The maintainer
cannot remotely retrieve or delete data stored only on your Mac. Copies in your
backups or in separately authorized clients must be removed separately.

## Questions and changes

Ask general privacy or removal questions through
[Kids Quota support](https://github.com/unixist/kids-quota/issues).
Changes to this policy will be published here with an updated date. Changes to
what the software processes will also require an updated software release.
