# Phone dashboard protocol (version 1)

The Mac remains authoritative for usage and enforcement. Phone access is read-only.
Each Mac publishes an outbound HTTPS snapshot every 300 seconds; the relay retains
only the latest snapshot per Mac in a private Google Cloud Storage bucket. Each
parent has a separate revocable read credential and each Mac its own write credential.
No browser history, account UID, app paths, or signing identities leave the Mac.

All dates are RFC 3339 UTC strings. All durations are nonnegative integer seconds.
IDs are restricted to ASCII letters, digits, underscores, and hyphens (1–100 chars).
Requests use `Authorization: Bearer <token>`. Credentials never belong in HTTP URLs
or logs. Non-local relay URLs must use HTTPS. No cross-origin browser API is enabled.
Uploads are limited to 128 KiB, with at most 20 children per Mac, 50 allowances per
child, and 50 domains per allowance. A deployment supports up to 20 Macs and
20 parent read credentials. Phone responses are bounded to 4 MiB. Display names
are trimmed, nonempty, at most 100 characters, and contain no control characters.
Upload capture timestamps may include milliseconds. Used time may exceed a lowered
allowance; remaining time is always `max(0, limitSeconds - usedSeconds)`.

## Endpoints

- `GET /healthz`: public liveness, no private data.
- `PUT /v1/devices/{deviceId}/snapshot`: that device's write credential only.
- `GET /v1/family`: a family read credential only; no quota mutation endpoints.

Snapshot body:

```json
{
  "schemaVersion": 1,
  "deviceId": "mac-1",
  "deviceName": "Kids Mac",
  "capturedAt": "2026-11-12T02:00:00Z",
  "resetTimeZone": "America/Chicago",
  "children": [{
    "id": "child-local-id", "name": "Alex",
    "balances": [{
      "quotaId": "quota-id", "serviceId": "service-id", "serviceName": "Chess.com",
      "domains": ["chess.com"],
      "limitSeconds": 21600, "usedSeconds": 3600, "remainingSeconds": 18000,
      "periodStart": "2026-11-09T06:00:00Z", "periodEnd": "2026-11-16T06:00:00Z",
      "quotaState": "available", "coverage": "complete", "blockingReason": "available"
    }]
  }]
}
```

`blockingReason` is optional: `available`, `exhausted`, or `collector_unavailable`.
`quotaState` is `available` or `exhausted`; `coverage` is `complete` or `incomplete`.
The relay validates snapshots, rejects an older capturedAt than the stored snapshot,
and adds its own `receivedAt`. An identical retry is safe. Never silently filter a
bad child out and publish a partial snapshot as though it were complete.

Family response:

```json
{
  "schemaVersion": 1, "familyName": "Our family", "servedAt": "2026-11-12T02:01:00Z",
  "devices": [{
    "deviceId": "mac-1", "deviceName": "Kids Mac", "receivedAt": "2026-11-12T02:00:01Z",
    "snapshot": { "schemaVersion": 1, "deviceId": "mac-1", "deviceName": "Kids Mac", "capturedAt": "2026-11-12T02:00:00Z", "resetTimeZone": "America/Chicago", "children": [] }
  }]
}
```

A device that has not reported is included with `receivedAt: null, snapshot: null`.
Children are keyed by `(deviceId, child.id)`; do not merge independent Mac ledgers.
Mark data older than 15 minutes stale, preserve its last known balance, and never
simulate a live countdown or infer a weekly reset without a new Mac snapshot.
WidgetKit refresh is best effort (request 15 minutes); opening the app refreshes.

## Pairing documents

Mac connection JSON: `schemaVersion: 1`, `endpoint` (HTTPS origin), `deviceId`,
`deviceName`, `writeToken`. Configure only through the authorized parent app;
save credentials with root-only permissions. Disconnection removes the local token.

iPhone connection JSON: `schemaVersion: 1`, `endpoint` (HTTPS origin),
`familyName`, `readToken`. Accept JSON paste/file import and optionally a QR code
containing `kidsquota://pair?data=<base64url-encoded JSON>`. These are secrets;
never commit pairing documents or display their plaintext in diagnostic output.
Store credentials in shared Keychain for app/widget and cached summaries in the
App Group. Clearing the phone connection removes both. A token grants no Mac
administrator access. The relay configuration stores SHA-256 token digests only.
