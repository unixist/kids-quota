# Install Kids Quota in Chrome

Kids Quota needs two components: the Mac companion installer and the Chrome
extension. The Mac service owns the allowances; the extension identifies the
active website and displays the time-limit page.

**Store release status:** the Chrome Web Store submission is being prepared.
There is no published store installation link yet. The v0.1.3 DMG supports the
local unpacked extension only. Do not expect that installer to connect to a
future store extension without updating it.

## Supervised Google accounts

Google blocks **Developer mode** and **Load unpacked** for supervised child
profiles. An administrator password for the Mac does not enable those Chrome
features. These profiles need the Chrome Web Store distribution.

When the store release and compatible companion installer are available:

1. Install the compatible Kids Quota DMG on the Mac. Run **Install Kids Quota.pkg**
   and authorize it with the parent's Mac administrator credentials. Upgrading
   preserves existing allowances and usage.
2. Open Kids Quota, unlock parent settings, and choose the Mac login to track if
   it is not already configured. Standard and administrator logins both work.
3. In Family Link, select the child and open **Controls → Google Chrome and Web →
   Advanced settings → Extensions**. Permit Web Store extension installation.
4. Open the Kids Quota store listing in that child's existing Chrome profile.
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
