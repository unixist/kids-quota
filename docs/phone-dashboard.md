# Kids Quota on your iPhone

The iPhone app and Home Screen widget show each child's latest reported time left,
weekly use, and tracking status. Both parents can see the same family dashboard.
The Mac continues to measure time and enforce quotas; the phone is read-only.

## Set up the family connection

1. Deploy the private relay once using the [cloud setup guide](phone-cloud.md).
   Keep its generated connection files private. Give each Mac its own Mac file
   and each parent their own iPhone file.
2. Install the v0.2.0 Mac companion on each child's computer. Open **Parent
   settings**, authenticate as a Mac administrator, and open **Phone dashboard**.
3. Import that computer's Mac connection file, then choose **Connect and share
   balances**. This explicitly enables sharing of the children's display names,
   configured services, allowances, usage totals, time left, and tracking status.
   Check that **Last sent** appears. Use **Send update now** after setup if needed.
4. Install the iPhone app using the [iPhone installation guide](../ios/README.md).
   Open **Connect your family** and scan, import, or paste your private iPhone
   connection document. Use a different parent's document on the other phone so
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

## Disconnect or replace a device

**Disconnect** in the Mac's Phone dashboard stops uploads and removes its local
device credential. The previous cloud report remains until removed or expired.
**Disconnect this iPhone** removes that phone's saved connection and cached
balances. It does not revoke a copied connection code; revoke or replace its
reader entry using the cloud setup guide if a credential was shared or lost.

Never put connection documents in GitHub, a public website, logs, or screenshots.
They grant access to private family summaries. Use AirDrop or another private
transfer between your own devices. See the [privacy policy](privacy-policy.md)
for the exact fields shared and where they are stored.
