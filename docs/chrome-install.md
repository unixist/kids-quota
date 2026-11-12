# Install Kids Quota in Chrome

Kids Quota needs two components: the Mac companion installer and the Chrome
extension. The Mac service owns the allowances; the extension identifies the
active website and displays the time-limit page.

**Store release status:** v0.1.5 was submitted November 11, 2026 and is pending
Google review. The existing v0.1.4 extension remains available; it was verified
installable on November 8, 2026.
The listing is **unlisted**; open the
[direct store link](https://chromewebstore.google.com/detail/kcdaoppmbobecgoajneamoimiohmkipj)
instead of searching the store. Its ID is `kcdaoppmbobecgoajneamoimiohmkipj`.
Automatic publication after approval is selected. Until Google publishes
v0.1.5, existing Chrome profiles will still use the earlier blocked-page behavior.
Installing the companion DMG alone does not update the store extension.

The compatible companion installer is available as
[KidsQuota-0.1.5-Local.dmg](https://github.com/unixist/kids-quota/releases/download/v0.1.5/KidsQuota-0.1.5-Local.dmg)
in the [v0.1.5 prerelease](https://github.com/unixist/kids-quota/releases/tag/v0.1.5).
The v0.1.3 DMG supports the local unpacked
extension only; v0.1.4 first added store compatibility. Use v0.1.5 for the latest
companion fixes.

## Supervised Google accounts

Google blocks **Developer mode** and **Load unpacked** for supervised child
profiles. An administrator password for the Mac does not enable those Chrome
features. These profiles need the Chrome Web Store distribution.

Install the companion and browser extension separately:

1. Install **KidsQuota-0.1.5-Local.dmg** on the Mac. Run **Install Kids Quota.pkg**
   and authorize it with the parent's Mac administrator credentials. Upgrading
   preserves existing allowances and usage.
2. Open Kids Quota, unlock parent settings, and choose the Mac login to track if
   it is not already configured. Standard and administrator logins both work.
3. In Family Link, select the child and open **Controls → Google Chrome and Web →
   Advanced settings → Extensions**. Permit Web Store extension installation.
4. Open the [Kids Quota store listing](https://chromewebstore.google.com/detail/kcdaoppmbobecgoajneamoimiohmkipj)
   in that child's existing Chrome profile.
   Add the extension and complete Google's parental approval flow if prompted.
   Allow the requested website access so custom domains work.
5. Disable or remove any older unpacked Kids Quota extension from that same
   Chrome profile. Use one Kids Quota extension per profile.
6. Quit and reopen Chrome after a companion upgrade. Browse a configured website
   with Chrome in the foreground for one or two minutes, then check the Kids
   Quota toolbar popup or the Mac menu-bar hourglass. Balances display minutes.

Google's account settings and any school or organization policies still apply.
Store publication does not make an extension impossible to disable.

## Unmanaged Chrome profiles

The local development extension remains available for profiles that permit
Developer mode. In `chrome://extensions`, enable **Developer mode**, choose
**Load unpacked**, and select:

```text
/Library/Application Support/KidsQuota/BrowserExtensions/Chrome
```

In the folder picker, press **Command–Shift–G** to enter that path. Repeat for
each Chrome profile that needs coverage. Creating an unmanaged profile just for
testing does not enable tracking in a separate supervised profile, and Family
Link's Chrome restrictions do not apply in the unmanaged profile.

## If the balance does not change

- Confirm that the current Mac login is the one selected in Kids Quota.
- Open the Kids Quota Chrome popup. If it reports a connection problem, check
  that the companion installer matches the extension distribution and restart
  Chrome after upgrading.
- If the hourglass is missing, sign out of the Mac login and back in to start the
  activity agent.
- Keep the configured website selected and Chrome foreground while testing.
  Switching to the parent settings window pauses website charging.
- Website tracking requires an enabled extension with website permissions.
  The optional Network Extension is inactive in the local release.

See [Google's Family Link extension settings](https://support.google.com/families/answer/7087030?hl=en)
and the [Kids Quota privacy policy](privacy-policy.md).
