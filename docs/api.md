# HTTP API proposal

**Status:** draft contract, not a running server. The machine-readable contract is
[OpenAPI 3.1](../api/openapi.yaml). Nothing is listening on the proposed address yet.

## Service and clients

One protected service on the Mac owns policy, usage, and enforcement decisions.
Browser/native collectors, the parent app, widgets, and other clients use that
same authority. Each child has a separate macOS login account paired during
parent-authorized native setup. HTTP callers cannot claim an OS identity or pair
accounts by passing a child ID.

The initial HTTP endpoint is proposed as `http://127.0.0.1:48123/v1`. Bind only to
loopback; a localhost connection still requires authentication because other local
users and processes may connect. This API does not imply a cloud account, remote
access, or cross-device balance synchronization.

## Resources

- **Service:** a named group of domains and verified application bindings, such as
  Chess.com or ChatGPT. Parents can add other services/domains. Membership is shared
  by children assigned that service; changing it affects all those assignments.
- **Child:** a stable ID and display name. Native setup privately maintains the
  macOS account binding; it is not returned to ordinary API clients.
- **Quota:** a child's assignment to a service and its weekly allowance in seconds.
  Each child/service pair has at most one quota. Both initial services default to
  21,600 seconds (six hours) when assigned; limits remain editable per child.
- **Balance:** the computed current-period view of one quota. It includes live
  elapsed usage, rather than waiting for the next database checkpoint.

The ledger key is `(childId, quotaId, periodStart)`. IDs, membership edits, and name
changes must not accidentally create fresh time. Two children using the same app
or website have independent balances and enforcement decisions.

## Endpoints

| Method and path | Purpose | Required scope |
| --- | --- | --- |
| `GET /v1/children` | List only granted children | `children:read` |
| `GET /v1/services` | List service definitions visible to the client | `services:read` |
| `GET /v1/children/{childId}/quotas` | Read assigned allowances | `quotas:read` |
| `GET /v1/children/{childId}/balances` | Read current remaining time and status | `balances:read` |
| `POST /v1/services` | Create a domain/app group | `policy:write` |
| `PATCH /v1/services/{serviceId}` | Edit a group without resetting its quotas | `policy:write` |
| `POST /v1/children/{childId}/quotas` | Assign a service and allowance | `policy:write` |
| `PATCH /v1/children/{childId}/quotas/{quotaId}` | Change the allowance, preserving usage | `policy:write` |

Initial child creation, OS-account pairing, application verification, API-client
pairing, and the household reset setting remain parent-app operations. A future
version can expose more administrative operations without changing these resources.
There is no public endpoint for setting balances, resetting usage, or submitting
usage. Trusted collectors use authenticated native IPC; a publisher or widget
cannot mint time or charge a sibling by sending arbitrary events.

## Authentication and authorization

Use revocable opaque bearer tokens in `Authorization: Bearer <token>`, issued by
parent-approved client pairing. Store tokens in Keychain or another protected
credential store. Never embed a parent token in a public web page, query string,
sample configuration, or log.

Every token has explicit scopes and an allowlist of child IDs. A widget can have
`balances:read` for one child; a local publisher can read selected children. Only
parent-authorized administrative clients receive `policy:write`. Scope checks and
child authorization happen on every request. `policy:write` is household-admin
authority issued only to a parent client with all-child grants, since shared service
edits can affect every child. Read grants can be narrower. An unauthorized child/resource ID
returns `404`, without revealing whether it exists. List responses are filtered;
service definitions for ordinary clients are limited to their granted children's
assignments. Parent policy administrators may read the entire catalog when also
granted `services:read`.

Reject unexpected `Host` and browser `Origin` values, disable cross-origin browser
access by default, enforce request/body limits, and rate-limit abusive clients.
Read-only access does not authorize publishing a child's data publicly. No network
configuration or credentials are changed by this specification.

## Balance responses and updates

Responses use JSON, integer seconds, UTC RFC 3339 timestamps, and
`Cache-Control: no-store`. `periodStart` and `periodEnd` are computed from the
household's saved weekday/timezone, including daylight-saving changes. Intervals
are half-open: `[periodStart, periodEnd)`.

`quotaState` is `available` or `exhausted`; `coverage` is separately `complete` or
`incomplete`. A positive balance does not mean all enforcement components are
working. Usage may exceed a lowered limit; remaining time is clamped to zero.
Unknown identities, unpaired accounts, or unavailable enforcement report incomplete
coverage rather than inventing a fully protected state.

Clients poll for snapshots, show the response's `asOf` time, and mark old or failed
reads as stale. They must not show an old balance as current after the Mac sleeps
or becomes unreachable. Widgets can use their platform's permitted refresh cadence;
the daemon, not client polling, drives blocking and weekly resets.

All successful reads return `policyRevision`. Writes require
`expectedPolicyRevision`; a stale revision returns `409` without modifying policy.
Writes increment that revision transactionally. A successful response returns the
new revision and resource; callers re-read before retrying an ambiguous result.
Creating a duplicate child/service assignment returns `409`. Invalid domains,
overlapping membership for a child's quotas, unknown application binding IDs, or
invalid allowances return `422`. Stored draft app bindings must show incomplete
coverage and cannot be activated by an HTTP client supplying a made-up identity.

Other errors use a stable JSON envelope: `400` malformed request, `401` missing or
invalid credentials, `403` missing scope, `404` absent or unauthorized resource,
`429` rate limited, and `503` service temporarily unavailable. Errors must not
include tokens, OS-account identifiers, or unrelated children's details.

## Website publisher and remote clients

A local publisher can read approved balance summaries from this API and send only
the parent-selected fields to an explicitly chosen website destination. Publication
is a separate, opt-in client action; the quota service does not publish anything.
A hosted website cannot call the Mac's loopback address to obtain its balances.

Remote access, if added later, needs an authenticated TLS gateway or a separately
paired synchronization service. Opening the daemon on all interfaces or putting a
bearer token in browser JavaScript is not the planned transport. Initial clients
can be implemented in any language that supports HTTP and JSON; they do not need
to link against the Swift app or directly open its database.
