# Kids Quota on your iPhone

The iPhone app and Home Screen widget show each child's latest reported time left,
weekly use, and tracking status. Both parents can see the same family dashboard.
The Mac continues to measure time and enforce quotas; the phone is read-only.

The connection is deliberately simple: each Mac replaces its latest report every
five minutes. There is no queue of missed updates to repair. Phones keep the last
known report when a refresh fails and show when it was captured.

## Set up the family connection

1. Deploy the private relay once using the [cloud setup guide](phone-cloud.md).
   Keep its generated connection files private. Give each Mac its own Mac file
   and each parent their own iPhone file.
2. Install the v0.2.0 Mac companion on each child's computer. Open **Parent
   settings**, authenticate as a Mac administrator, and open **Phone dashboard**.
3. Import that computer's Mac connection file, then choose **Connect and share
   balances**. This explicitly enables sharing of the children's display names,
   configured services, allowances, usage totals, time left, and tracking status.
   The screen first shows **Connecting**. It changes to **Sharing** after an
   update actually reaches the dashboard. **Last sent** updates automatically;
   there is no separate status-refresh step.
4. Install the iPhone app using the [iPhone installation guide](../ios/README.md).
   Open **Connect your family** and scan your private iPhone QR code. File import
   and paste are under **Other ways**. Use a different parent's code on the other phone so
   either connection can later be revoked independently.
5. Open the app once and confirm the children and balances appear. A computer
   without a report is shown as waiting, rather than as having a full allowance.

The iPhone app is a separate installation from the Mac DMG. TestFlight distribution
requires the app to be signed and uploaded under the family's Apple Developer
account; building the source alone does not make it appear in TestFlight.

## Add the widget

Touch and hold the iPhone Home Screen, choose **Edit → Add Widget**, and search for
**Kids Quota**. The medium widget is a good fit for two children with Chess.com and
ChatGPT allowances. A larger widget shows more children. A small widget focuses
on one child. Touch and hold a widget and choose **Edit Widget** to select a child.
Tap the widget to open the full dashboard and see all configured services.

Each child's allowance remains separate. A child with accounts on two Macs
appears under each computer; this version does not pool or enforce one shared
allowance across multiple Macs.

## Understand the update label

The Mac sends a summary about every five minutes while awake and connected. The
app checks for a new report when opened and supports pull-to-refresh. The widget
requests a refresh about every fifteen minutes, but iOS chooses when it actually
runs. A widget is not a live countdown and cannot guarantee five-minute freshness.

- **Updated:** the time the Mac captured the displayed balances.
- **Last known / old report:** the report is more than fifteen minutes old, or its
  allowance period has ended. The displayed balance is preserved until the Mac
  reports again; the phone does not invent a reset or deduct unobserved usage.
- **Tracking paused:** the Mac's activity monitor is unavailable. This differs
  from reaching the weekly limit, even if the website is temporarily blocked.
- **Weekly limit reached:** the Mac reported no remaining allowance.
- **Check tracking:** coverage is incomplete; inspect setup on that Mac.

A sleeping Mac cannot send fresh reports. Internet or cloud outages do not stop
the Mac's local quota enforcement. When connectivity returns, its next successful
upload replaces the older summary.

## When something needs attention

The balance and its age remain visible whenever a valid report is available.
Connection trouble does not turn a positive allowance into "weekly limit reached."

| What you see | What to do |
| --- | --- |
| **Can't refresh balances** | Check the iPhone's internet connection and try again. Keep reading the last-known report and its age. |
| **Reconnect this iPhone** | Use a new iPhone connection code from parent setup. Repeated refreshes cannot repair a rejected code. |
| **Saved connection unavailable** | Unlock the iPhone and reopen Kids Quota. A temporarily unreadable saved connection is not treated as a new, unpaired phone. |
| **No saved Mac report** | Open Phone dashboard in that Mac's parent settings and check sharing. A report can also disappear after the cloud retention period; this does not reset the Mac's quota. |
| **Last known / old report** | Wake the Mac and check its internet connection. The phone cannot know whether the Mac is asleep or disconnected, so it does not guess. |
| **Can't save balances** | The new balances are still shown. Try again; if it persists, install the latest app. Until storage works, widgets or offline views may have an older report. |
| **Tracking paused / Check tracking on Mac** | Check the browser extension and activity monitor on that Mac. This is separate from a phone-sync problem or an exhausted allowance. |

The Mac's sharing screen supplies one recovery action for its current problem:
**Try again**, **Reconnect**, or **Check setup**. Its server address and connection
replacement controls stay under **Connection details**. A failed connection to
the local Mac service is labeled separately from failure to reach the dashboard.

## Disconnect or replace a device

**Stop sharing** in the Mac's Phone dashboard stops uploads and removes its local
device credential. The previous cloud report remains until removed or expired.
**Disconnect this iPhone** removes that phone's saved connection and cached
balances. It does not revoke a copied connection code; revoke or replace its
reader entry using the cloud setup guide if a credential was shared or lost.

Never put connection documents in GitHub, a public website, logs, or screenshots.
They grant access to private family summaries. Use AirDrop or another private
transfer between your own devices. See the [privacy policy](privacy-policy.md)
for the exact fields shared and where they are stored.
