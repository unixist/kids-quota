# Service setup UX

**Implemented:** native child/service selection, website-only groups, custom domains,
app selection with signature verification, per-child hours, shared membership editing,
and coverage display. The first release uses **Choose app** for optional native apps.
Automatic discovery, future-app inclusion, the trusted preset catalog, and catalog
update flows below are follow-on design, not implemented behavior. Signed enforcement
still requires on-device acceptance testing.

## Organize around the service

The parent adds **Chess.com**, not a domain rule and an application rule. That
service contains its websites and optional apps, while each child has one weekly
allowance for the service. Chess.com and ChatGPT are starter presets; custom
website-only services use the same model.

The everyday row shows the service name, remaining weekly time, and **Edit hours**.
A small **Includes** detail explains the website/app coverage. Paths, signing
identifiers, and helper-process rules stay in diagnostics.

## Add a service

1. Select the child, then choose **Add service**.
2. Select a preset such as **Chess.com** or **ChatGPT**, or **Custom website**.
3. Set the weekly allowance, initially six hours for the starter presets.
4. Review **Includes** and choose **Add to [child]**.

A selection toggle in the preset picker means “include this in the draft to add.”
It has no effect until saving. Do not use that control as an immediate on/off
switch for an existing limit: the current API has no enabled/disabled quota field.
Editing or reselecting a service preserves its quota ID and accumulated usage.
If pausing limits is added later, it must be a separate explicit action that
preserves already-used time.

## Preset contents

For Chess.com, **Includes** presents:

- **Website:** chess.com and its subdomains.
- **Mac app:** a friendly app name and its detection/verification state.
- **Include compatible Mac apps, now or when installed:** an explicit choice,
  enabled by default for a preset with an accompanying app.

Native setup discovers candidate apps and verifies their exact supported signing
identity against a trusted preset definition before selecting them automatically.
A filename or vendor name alone is not sufficient. No real Chess.com or ChatGPT
application identifiers have been supplied by this design.

When a supported app is absent, the website can still be ready. Keep the parent's
future-app choice visible, and include a later installation only if it satisfies
the already-approved matching requirement. Do not describe an absent app as blocked.
When an app is present but cannot be verified or attributed, show **Choose app…**
or **Review app**, retain working website coverage, and explain the app gap.

The picker shows familiar app icons and names. Selecting an app causes native
verification; it does not accept raw signer strings from the user or generic API.
An application path helps locate the selected app but is not its identity. Renaming
or moving a matching signed app must not create a new allowance or bypass the rule.
Compatible updates keep working; identity changes require review.

## Three coverage states

| Label | Meaning and next action |
| --- | --- |
| **Website + app ready** | Required browser permissions and verified app filtering are working. |
| **Website ready · app not installed** | The website is covered; optionally include a compatible app if installed later. |
| **Needs setup** | A required permission, verified binding, or filter is missing; expand for the specific fix. |

For a deliberately website-only service, use **Website ready**. These are coverage
labels, separate from **Available** or **Weekly limit reached**. At exhaustion, app
coverage means internet access is blocked; cached/offline features can still work.

## Custom websites and unusual apps

**Custom website** asks for a website address, friendly name, and weekly hours.
Parse a pasted URL and show the hostname that will be included before saving.
Subdomain inclusion is a simple checkbox; **Add another website** is optional.
An optional **Add an app…** action reveals the app picker. A parent who wants only
a website never has to choose an app or handle technical identifiers.

A browser-installed web app may share its executable or signer with other sites.
It needs a verified site-specific binding. If that is unavailable, report app
coverage as unsupported and keep the browser website rule; never attach all of
Chrome or Safari to Chess.com or ChatGPT.

## Shared definitions and child-specific limits

**Edit hours** changes only the selected child's allowance. **Edit included websites
and apps** changes the shared service definition and shows the affected children
before saving. A child needing different included sites gets a separate service
definition, without overlapping selectors in that child's policy.

When adding an already-configured preset for another child, reuse its existing
**Includes** settings and show those settings read-only in the quick-add flow.
Route membership changes to **Manage service**, where the parent sees the children
affected. Do not let an apparently child-specific app checkbox silently change a
sibling's protection. The interactive concept illustrates first-time setup.

Preset definitions are versioned. A catalog update may suggest new domains or
signing requirements, but must show the proposed membership changes for parent
approval before broadening an existing rule. Compatible app releases satisfying
the stored requirement do not need repeated approval. Existing balances survive
all membership and catalog updates.

## Deliberate tradeoffs

- Presets minimize setup, but app coverage must remain visible when a match cannot
  be verified. A selected preset is not proof of complete protection.
- Automatic inclusion of later apps closes an easy gap, but only within explicitly
  approved identity requirements; unfamiliar apps need review.
- Sharing service definitions avoids configuring the same app for every child,
  while per-child allowances keep the main control simple and independent.

These UX choices refine native setup and preset handling. They do not add a public
API for supplying signing identities, invent a limit toggle, or change the
accounting authority described in [the architecture](architecture.md).
