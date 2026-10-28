# HTTP API

The v0.1 service implements a JSON REST API at `http://127.0.0.1:48123/v1`.
The [OpenAPI 3.1 contract](../api/openapi.yaml) describes its resources. Build and
install the daemon before connecting; checking out this repository does not start
a system service. The listener accepts loopback connections only.

One service owns policy, usage, and enforcement decisions for all children on the
Mac. Each child is paired with a separate macOS login account. Browser adapters
and foreground collectors use authenticated native IPC. Widgets and local
publishers use HTTP. The parent app sends these same HTTP-shaped requests through
a root-authenticated UNIX socket, avoiding an impostor localhost listener.
The HTTP listener is read-only. Administrative operations below document the
shared request schema used by the native parent connection; sending them over HTTP
returns `403 administrator_required`, even with the administrator token. Each native
parent request must also carry an Authorization Services external form granting
`system.privilege.admin`, and the kernel peer UID must be an administrator.
There is no HTTP endpoint for submitting usage, setting balances, or claiming a
child's OS identity.

The built-in child menu bar view needs no HTTP token. It runs in the verified
login agent and sends `{"op":"childStatus"}` over the native socket. The service
uses the kernel peer UID to return only that child's assigned service balances;
extra fields, including a requested child ID, are rejected. This is a read-only
operation and gives no access to parent configuration. External clients still
use the scoped bearer-authenticated HTTP API documented below.

## Resources

- **Service:** a named group of domains and verified Mac applications. Membership
  changes affect all children assigned that service.
- **Child:** a stable ID and display name. Ordinary read clients do not receive
  account UIDs or GeneratedUIDs.
- **Quota:** one child's weekly allowance for one service. Website and selected
  application share this allowance, independent of other children's usage.
- **Balance:** current usage, remaining time, calendar period, and protection
  coverage, including elapsed usage observed by the service.

New children receive six-hour quotas for the Chess.com and ChatGPT presets.
Parents can change allowances, add services for other domains or apps, and assign
different quotas per child. Allowances are integer seconds from `0` through
`604800000`. The ledger key is `(childId, quotaId, periodStart)`; changing a
limit, name, or membership preserves usage.

## Endpoints

| Method and path | Purpose | Required scope |
| --- | --- | --- |
| `GET /v1/children` | List granted children | `children:read` |
| `GET /v1/services` | List visible services | `services:read` |
| `GET /v1/children/{childId}/quotas` | Read allowances | `quotas:read` |
| `GET /v1/children/{childId}/balances` | Read balances | `balances:read` |
| `POST /v1/services` | Create a domain/app group | `policy:write` |
| `PATCH /v1/services/{serviceId}` | Edit a group | `policy:write` |
| `POST /v1/children/{childId}/quotas` | Assign an allowance | `policy:write` |
| `PATCH /v1/children/{childId}/quotas/{quotaId}` | Change an allowance | `policy:write` |
| `GET /v1/admin/state` | Read policy, client grants, and filter status | `policy:write` |
| `POST /v1/admin/children` | Verify and pair a macOS account | `policy:write` |
| `POST /v1/admin/children/{childId}/reset` | Restore this child's current-week balances | `policy:write` |
| `POST /v1/admin/applications` | Verify a selected app's signature | `policy:write` |
| `PUT /v1/admin/settings` | Change the shared reset schedule | `policy:write` |
| `POST /v1/admin/clients` | Issue a child-scoped read credential | `policy:write` |
| `DELETE /v1/admin/clients/{clientId}` | Revoke a read credential | `policy:write` |

Every `policy:write` operation requires the administrator credential **and** the
OS-authorized native parent connection. No HTTP header can supply that trust.
Administrative routes require both factors, including reading admin state. Read grant creation
cannot confer administrative authority. v0.1 exposes no child, service, or quota
deletion endpoints.

## Authentication and client grants

Every request requires `Authorization: Bearer <token>`, including local requests.
Initial setup creates a protected administrator bootstrap credential. The parent
app uses it to issue read grants for explicitly selected children. Read tokens
support `children:read`, `services:read`, `quotas:read`, and `balances:read`.
Store tokens in Keychain or another protected store; never put them in a URL,
public webpage, or log.

For example, the unlocked parent app sends this to `POST /v1/admin/clients`
through its authenticated native connection:

```json
{
  "name": "Alice's widget",
  "scopes": ["balances:read"],
  "childIds": ["alice"]
}
```

The response contains `id`, the one-time plaintext `token`, and the public
`client` grant. Only digests are stored in the client database. Admin state lists
grants without plaintext tokens or digests. Revocation is immediate and persisted;
the protected administrator cannot be revoked through this route. Issuing and
revoking grants do **not** use or change the policy revision.

Scope and child checks run on every request. Unauthorized child IDs return
`404`. Ordinary clients see only granted children and their assigned services;
administrators can read the entire catalog. Responses use `Cache-Control: no-store`
and do not enable CORS. Any `Origin` header, or a `Host` other than
`127.0.0.1:48123` or `localhost:48123`, is rejected. A custom daemon port changes
the accepted Host. JSON bodies are limited to 65,536 bytes; each credential is
limited to 60 requests per one-second window.

## Policy writes and verified setup

Policy mutations require the latest `expectedPolicyRevision`. A stale revision
returns `409`; successful changes increment the revision. Array fields replace
previous arrays; omitted PATCH fields remain unchanged. JSON bodies must use
`Content-Type: application/json`, and unknown top-level fields are rejected.

Child setup accepts a display name and the selected account's `generatedUid`.
The daemon resolves the current account itself. The optional numeric `uid` is a
consistency check. Native requests revalidate GeneratedUID/UID bindings with a
short cache, detecting deleted or replaced accounts.

App setup accepts the selected `.app` path. The daemon inspects its signature and
returns a verified binding; clients cannot supply a signer, designated
requirement, or ready status. Add that binding's ID to a service's
`applicationIds`. A new binding returns `201`; an already-known signing identity
returns the existing binding with `200`. Selection uses a path; enforcement uses
the verified identity.

Service writes accept website addresses and canonicalize them. Responses contain
lowercase ASCII/IDNA hostnames and explicit `includeSubdomains`. IP addresses,
public suffixes, unknown app IDs, and overlapping memberships for the same child
are rejected. A service needs at least one domain or app. A duplicate child/service
assignment returns `409`; invalid policy returns `422`.

The reset setting contains `weekday`, `localTime` (`HH:mm`), and IANA
`timeZone`. A changed schedule takes effect at the existing period's end. The
returned policy contains `pendingReset` until then, preventing an immediate
allowance reset caused by changing the reset day.

## Parent-authorized manual reset

`POST /v1/admin/children/{childId}/reset` accepts only
`{"expectedPolicyRevision": <current revision>}`. It requires the same signed
parent role, administrator UID, OS authorization, and bearer credential as other
configuration changes. Read tokens, browser/native collectors, and all HTTP callers
cannot invoke it.

The service settles observed elapsed time, atomically resets only that child's
current-period counters, increments the policy revision, and records the actor UID,
time, child, period, and previous usage in its private audit table. It preserves
weekly limits, the next scheduled reset, other children, and prior periods. Live
tracking resumes from the reset instant. The response contains `policyRevision`
and `balances` (a BalanceSnapshot). Stale/repeated revisions return `409`.

## Balances and protection status

Snapshots contain `asOf`, `policyRevision`, `childId`, and `items`.
Each item contains `quotaId`, `serviceId`, `periodStart`, `periodEnd`,
`limitSeconds`, `usedSeconds`, `remainingSeconds`, `quotaState`, and `coverage`.
Timestamps are UTC RFC 3339. Periods are half-open `[periodStart, periodEnd)`,
computed from the saved timezone, including daylight-saving changes. Fractional
observed usage is rounded up for display; remaining time is clamped to zero.

`quotaState` is `available` or `exhausted`. `coverage` is independently
`complete` or `incomplete`. It uses current account verification and recent
collector/browser/filter reports; a positive balance does not prove protection is
working. Coverage is operational status, not proof software cannot be disabled.
Native app enforcement blocks networking and does not remove cached offline
features. Website usage follows the active tab's top-level hostname; background
media and third-party frames are not separately attributed.

Clients should display `asOf` and mark failed or old snapshots as stale.
Polling does not grant time or drive enforcement; the daemon remains authoritative
while widgets are closed.

Errors use `{"error":{"code":"...","message":"..."}}`: `400` malformed request,
`401` invalid credential, `403` missing permission, administrator authorization, or invalid host/origin,
`404` missing or unauthorized resource, `409` conflict, `422` invalid policy,
`429` rate limit, and `503` unavailable storage. Re-read before retrying an
ambiguous policy write.

## Publishers and remote clients

A local publisher can read approved summaries and send selected fields to a
chosen website. Publication is a separate client action; this service publishes
nothing. A hosted website cannot read the Mac's loopback API directly. Remote
access or cross-device synchronization would require a separately authenticated
transport; v0.1 has neither. Local clients can use any language supporting HTTP
and JSON without opening the database or linking Swift code.
