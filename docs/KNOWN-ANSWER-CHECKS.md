# Windows baseline and known-answer Graph checks

8 November 2026. The public job is explicit group-reference investigation across
Conditional Access and Intune device-compliance policies. This record does not
resume the superseded retirement-first scope, deploy the wider app or diagnose
its assessment login.

**9 November transport update:** the collector now has streamed response limits,
per-request redirect/retry options and a shared cancellation deadline. Local
checks and a fresh delegated known-answer replay passed for the changed path.
The dated replay below supersedes the earlier hash for this narrow acceptance;
it does not establish real token refresh or all failure cases. See
[current transport controls and limits](TRANSPORT-CHECKS.md#collector-controls--9-november-2026).

## New-transport live replay — 9 November 2026

Committed source `84748980e12364ff7531db752f531aba66780c33` completed a
fresh process-scoped sign-in through the retained dedicated reader, with the
expected Test-Tenant administrator and exactly the three approved API scopes.
The run lasted 11:17:56–11:18:25 UTC on Windows / PowerShell 7.6.9 / SDK 2.38.1.
No registration, consent, policy, membership, licence or VM change was made.

| Live check | Result |
| --- | --- |
| Included group | PASS: exact three-reference set, CA states and compliance inclusion-filter ID/mode |
| Excluded group | PASS: exact three-reference set and CA states |
| Negative control | PASS: zero explicit references, complete visible sources, no evaluator issues |
| Request budget | PASS: one SDK invocation, both sources `request_limit`, no absence conclusion |
| Wrong tenant | PASS: security exception before collection |
| Ambient SDK request settings | PASS: identical before/after settings |

Each complete observation used four SDK invocations. Saved snapshots identify
`sdk_2.38.1_streamed_request_options_v1`, a 4 MiB per-response cap and the shared
120-second deadline. The saved raw snapshots and evaluated reference sets were
rechecked separately against the retained expected-answer record. This successful
HTTPS service path does not prove proxy variants, forced token refresh/claims
challenges, live denied-reader or multipage/partial-service scenarios, Ctrl+C or
clean-machine installation. The administrator profile is not minimum-role proof.

Tested source SHA-256:

- Collector: `61CA44C5E4B7F333DA6B2BC97ADA7C9072D4FF4F42F4F3942B6E3931E9420D5B`
- Transport helper: `49E55211220693E927CB977EE7E461E1FFCFF0659BA1F3F8F923094F27944F00`

Evidence is in the existing ignored private evidence directory under run
`transport-live-20261109T111756Z-a74b14e7`. Earlier snapshots/reports were not
overwritten. The dedicated process exited successfully and cleared its own
in-memory client/context without SDK logout, which would also delete the shared
authentication record. This is not Microsoft-side consent revocation; the
retained fixtures and reader grant remain available for the agreed next checks.

## Verified Windows baseline

Fetched `origin/codex/ai-tool-data-boundary` at
`bc97933b1bf3d09bd5a93b5664b042f2a693b2e4` (handoff documentation). Its history
contains `ec708397` (current scope), `57bbaa9b` (evaluator) and `b9b1442d`
(collector). Checked in the separate `codex/windows-investigation-checks-20261108`
worktree; the pre-existing Windows checkouts and installation files were preserved.
The modules and fixtures were unchanged for these baseline runs. The later
filter-contract correction and live replay are recorded below.

| Check | Windows result |
| --- | --- |
| Host | Windows 11 Pro, OS build 10.0.26300, x64; .NET 10.0.14 |
| PowerShell / Pester | 7.6.9 / 6.0.0 |
| Public tests, fresh process | 32 passed; zero failed, skipped or not run; 1.25 seconds |
| Combined PowerShell/public tests | 351 passed; zero failed, skipped or not run; 34.87 seconds |
| Fictional offline example | Two `include` references; `coverage = incomplete`; `canConcludeNoExplicitReferences = false` |
| Installed Graph authentication module | 2.38.1; import succeeded; no active context in the inspected process |
| Live collector acceptance at baseline | NOT RUN at that point; subsequent results below |

Commands were run from the source root:

```powershell
Import-Module Pester -RequiredVersion 6.0.0 -Force
Invoke-Pester -Path ./powershell/tests,./public-handoff/tests -CI
# Separate fresh process:
Import-Module Pester -RequiredVersion 6.0.0 -Force
Invoke-Pester -Path ./public-handoff/tests -CI
```

The example was also checked with assertions on the count, relations, coverage
and absence flag, with throwing Graph/context substitutes in that process. It
needed no Graph SDK or authentication. Pester initially could not create its
temporary HKCU registry key or inspect CIM inside the execution sandbox; the
successful runs used normal Windows access without changing the tests. The
combined suite emitted an existing `Get-MgSubscribedSku` authentication warning;
it is not licence evidence. The fresh public suite emitted no such warning.
These are local tests, not Microsoft service acceptance or clean-machine setup.

## Live continuation

The user obtained a Business Premium (no Teams) trial after the initial suspended
licence preflight. Graph confirmed 25 enabled seats and Entra ID P1; Intune's
portal confirmed **Active**, Microsoft Intune MDM authority, 25 licences and zero
enrolled devices. A direct role-membership read confirmed Global Administrator.
Seven [fixture objects](FIXTURE-SETUP.md) were created, with the groups empty and
CA policies disabled/report-only. Existing policies were preserved.

A separate single-tenant **Handoff Investigation Test Reader** was prepared
without credentials or application permissions. The user approved exactly
GroupMember.Read.All, Policy.Read.All and DeviceManagementConfiguration.Read.All
for the selected administrator only. The actual `Principal` consent grant was
read back; a fresh process-scoped delegated Global SDK session with those API
scopes and the expected tenant/client/account was verified. No setup write scope
was added to that profile. The successful read is evidence for this administrator
profile, not a proof of the minimum possible reader roles.
Post-login reconciliation found an additional tenant-wide grant for the same
three scopes on this new reader. That extra grant was removed; final readback
confirmed only the approved operator-specific grant remains.

The first live run of `bc97933b` matched the three/three/zero reference sets, but
**failed the filter check**: v1.0 assignments omitted ID/mode present in Intune's
saved policy. The baseline snapshots/results were preserved privately before
replay. Microsoft documents no properties on the
[v1.0 assignment target base](https://learn.microsoft.com/en-us/graph/api/resources/intune-shared-deviceandappmanagementassignmenttarget?view=graph-rest-1.0),
and the filter ID/mode on the
[beta target](https://learn.microsoft.com/en-us/graph/api/resources/intune-shared-deviceandappmanagementassignmenttarget?view=graph-rest-beta).

The local correction changes only compliance assignment reads to beta. Group,
CA and compliance-policy reads remain v1.0. Snapshot source is
`graph_v1_beta_delegated_policy_snapshot_v1` and `collection.apiVersions` records
each endpoint version. No permission was expanded and no v1.0 fallback was added.
The tested collector's SHA-256 is
`F539136F0E37115B86E2699CA0E756D8DEA9D521BB3FFFEA05C9095E29FFC405`;
the base Git revision remains `bc97933b` plus this local correction. Regression
tests reproduced the missing filter and guard beta pagination against a version
or policy change. All **354 combined tests passed**, including **35 public cases**,
with zero failures/skips, in 34.54 seconds.

The corrected live run completed on 8 November using PowerShell 7.6.9 and Graph
SDK 2.38.1. It compared exact reference sets, CA states and inclusion filter
ID/mode with the independently recorded expected configuration:

| Live case | Result |
| --- | --- |
| Included group | PASS: three inclusions; expected CA states and compliance filter ID/mode retained |
| Excluded group | PASS: three exclusions; exact policy/path set matched |
| Unreferenced group | PASS: zero explicit references; complete visible sources, no evaluator issues; absence flag true within this narrow claim |
| Request budget | PASS: one group request, policy sources marked `request_limit`, absence false |
| Wrong tenant preflight | PASS: security exception before collection |

Each full group observation used four SDK invocations, retained nine policy/
assignment items, and completed both sources within limits of ten pages per
collection, 100 retained items and 50 SDK invocations. Each collection fit on
one page per endpoint; **real multipage coverage was not proved**. SDK sessions
were disconnected afterwards. Raw snapshots, evaluated results, assignment IDs,
consent metadata, fixture cleanup journal and portal screenshots are retained
locally outside the source tree and ignored by Git. Fixtures and the approved
reader consent are retained for further tests; cleanup is pending.

Real denied-reader permissions, partial service/page failures, mid-read session
change, clean installation, minimum reader roles and transport acceptance remain
NOT RUN. The earlier CLI Intune 403 is not a denied-permission test of this
dedicated reader. Beta contracts can change; the public release is still gated
by the remaining transport and setup checks.

## Select and inspect the test profile

Use the authorised test tenant and retained fixtures; the separate
[fixture setup plan](FIXTURE-SETUP.md) records the exact objects, expected answers,
cleanup and resolved licensing preflight. Before connecting, record
the following in the operator's private evidence location, outside Git:

| Item | Required evidence | Current state |
| --- | --- | --- |
| Tenant and cloud | Explicit tenant GUID; Global commercial cloud | Organisation/domain confirmed privately |
| Public client | Tenant-owned, single-tenant interactive/native registration; client and service-principal IDs; appropriate redirect URIs for the tested SDK login | Created and verified; dedicated reader |
| Separation | Client differs from both wider-app assessment and automation registrations; no reused key/secret | Verified; new registration without credentials |
| Grants | Registration requests **and actual delegated service-principal consent grants**, including user/all-user scope and extra grants | Three approved read scopes, `Principal` grant for selected operator; no application grants |
| Operator | Intended account; active CA reader authority and Intune read authority; any PIM activation expiry, scope tags and scope groups | Global Administrator confirmed; reader session successfully collected fixtures |
| Licensing | Active Intune tenant licence and applicable Conditional Access entitlement | 25 enabled trial seats; Intune portal Active |
| Fixtures | Exact group/policy/assignment IDs and independently recorded expected references | Seven created; IDs and evidence recorded privately |

Inspect registrations, grants, licences and roles through the authorised portals;
do not add inventory API permissions to this collector just to inspect its setup.
The user authorised fixture creation and the precise reader consent. Reusing
wider-app registrations or changing subscriptions/billing was not part of it.

Candidate delegated API scopes for this test are:

| Collector GET | Candidate scope | Authority/verification |
| --- | --- | --- |
| `/v1.0/groups/{id}?$select=id,displayName,groupTypes,securityEnabled,mailEnabled,onPremisesSyncEnabled` | `GroupMember.Read.All` | Verify this exact property selection in the intended tenant; no membership endpoint is called |
| `/v1.0/identity/conditionalAccess/policies` | `Policy.Read.All` | Active supported CA reader authority; Security Reader is a documented read role |
| `/v1.0/deviceManagement/deviceCompliancePolicies` and `/beta/deviceManagement/deviceCompliancePolicies/{id}/assignments` | `DeviceManagementConfiguration.Read.All` | Active Intune tenant licence and operator read visibility over the fixtures |

The [group API](https://learn.microsoft.com/en-us/graph/api/group-get?view=graph-rest-1.0)
accepts group-read permissions; the [permission reference](https://learn.microsoft.com/graph/permissions-reference?view=graph-rest-1.0#groupmemberreadall)
describes `GroupMember.Read.All` as reading basic group properties and membership.
This is a read-only candidate for the selected properties, not a proved minimal
live profile. Do not substitute write permissions or broaden to `Directory.Read.All`
after a failure. Record the failure and review the specific property requirement.

[CA policy reads](https://learn.microsoft.com/en-us/graph/api/conditionalaccessroot-list-policies?view=graph-rest-1.0)
require `Policy.Read.All` and supported delegated operator authority.
[Compliance policies](https://learn.microsoft.com/en-us/graph/api/intune-deviceconfig-devicecompliancepolicy-list?view=graph-rest-1.0)
and [beta assignments](https://learn.microsoft.com/en-us/graph/api/intune-deviceconfig-devicecompliancepolicyassignment-list?view=graph-rest-beta)
document `DeviceManagementConfiguration.Read.All` and an active Intune tenant
licence. Review actual [Intune RBAC scopes](https://learn.microsoft.com/en-us/intune/fundamentals/role-based-access-control/overview)
and [read-role permissions](https://learn.microsoft.com/en-us/intune/fundamentals/role-based-access-control/ref-built-in-roles).
Successful reads by a scoped operator do not by themselves establish tenant-wide
visibility. The adapter's `complete` is collection completion for the visible
endpoint, not proof of RBAC coverage. Keep an independent visibility exception
until that coverage is established.

## Record the independent known answers first

In Entra, select the group's object ID, then inspect CA policy user/group
inclusions, exclusions, state and settings. In Intune, inspect device-compliance
policy properties and assignments, including target type, group ID, assignment
ID where available, filter ID and filter mode. Record portal capture times and
evidence references. If an assignment ID is not displayed, an independently
collected read/export can supplement the portal; it cannot replace checking
targeting independently of this evaluator.

Build an expected-reference table keyed by source, policy ID, relation and
source path, with assignment/filter details. Compare **sets of identities and
properties**, not just counts. Record an existing negative-control group with no
explicit references in these two sources. Note any broad targeting separately.
Do not create groups, enable/disable policies, alter assignments or remove grants
to manufacture cases in this read-only run. Missing cases stay NOT RUN until
separate fixture setup is agreed. Leave policy configuration unchanged throughout
collection; these sequential reads are not an atomic snapshot.

## Staged collection commands

The collection sequence was run successfully with the reviewed profile and
expected answers. For repetition, use a dedicated `pwsh -NoProfile` process. Set `$tenantId`,
`$clientId` and `$groupId` from that private test record. This is the reviewed
public client, not the SDK default client. Set `$operatorAccount` to the reviewed
operator's SDK account name as well. If Microsoft offers new consent or a
different tenant/account/profile, stop and review it before proceeding.

```powershell
Import-Module Microsoft.Graph.Authentication -RequiredVersion 2.38.1
$scopes = @('GroupMember.Read.All', 'Policy.Read.All',
    'DeviceManagementConfiguration.Read.All')
Connect-MgGraph -TenantId $tenantId -ClientId $clientId -Environment Global `
    -ContextScope Process -Scopes $scopes -NoWelcome

$ctx = Get-MgContext
if (-not $ctx -or $ctx.TenantId -ne $tenantId -or $ctx.ClientId -ne $clientId -or
    $ctx.AuthType -ne 'Delegated' -or $ctx.Environment -ne 'Global' -or
    $ctx.ContextScope -ne 'Process' -or $ctx.Account -ne $operatorAccount) {
    throw 'Unexpected test session'
}
if (@($scopes | Where-Object { $_ -notin $ctx.Scopes }).Count) {
    throw 'Required read scopes are absent'
}
```

Inspect `$ctx.Account` and `$ctx.Scopes` locally against the private profile and
actual grants, including any extra scopes. Continue only when they agree. The
SDK documents [custom public clients and process-scoped authentication](https://learn.microsoft.com/en-us/powershell/microsoftgraph/authentication-commands?view=graph-powershell-1.0).
Session scopes do not replace inspecting actual grants. Record unexpected
privilege rather than silently accepting it.

```powershell
Import-Module ./public-handoff/Handoff.Collection.psm1 -Force
Import-Module ./public-handoff/Handoff.Investigation.psm1 -Force
$snapshot = Get-HandoffPolicySnapshot -TenantId $tenantId -GroupId $groupId
$result = Get-HandoffGroupPolicyReference -TenantId $tenantId `
    -GroupId $groupId -Snapshot $snapshot
```

Keep the raw `$snapshot` and evaluated `$result` separate in the approved private
evidence location, together with source/SDK versions, UTC start/completion times,
limits, request/page/item counts, source and assignment statuses, fixed failure
codes, expected-answer comparison and portal references. No export command is
included until an evidence destination is selected. Do not commit tenant dumps,
tokens, cookies, private keys, auth codes or raw SDK error bodies. Run
`Disconnect-MgGraph` and close this dedicated process at the end; disconnect is
not Microsoft-side consent revocation.

## Acceptance matrix

The five live cases above have dated evidence. The matrix below also describes
remaining scenarios; do not promote those to PASS based on local mocks. Real
denials, empty endpoints, partial failures, mid-read changes and multipage reads
remain NOT RUN.

| Case | Expected result | How to stage without policy writes |
| --- | --- | --- |
| Selected identity | Exact tenant and group GUID; returned group properties match portal | Existing group |
| CA include/exclude | Both relations and exact source paths; state/settings preserved, including disabled/report-only policies | Existing independently documented policies; absent states stay NOT RUN |
| Compliance include/exclude/filter | Exact policy/assignment/group IDs; correct relation and unchanged filter ID/mode | Existing assignments; unsupported types produce issues, not clean absence |
| Broad targeting | All-user/all-device targets are context; no invented explicit group reference | Existing broad policies/assignments |
| Negative control | Zero explicit references only when visible sources and every assignment list complete, with no evaluator issues | Existing independently checked group; this does not mean no policy applies or safe deletion |
| Truly empty collection | A genuinely empty, authorised endpoint completes; denial must not resemble an empty list | Existing empty source if available; do not empty the tenant to test it |
| Denied group read | Throw; no investigation returned | Existing reviewed denied profile/account; do not revoke working grants |
| Denied CA/compliance read | Source `unavailable`, fixed `request_failed`; other known evidence survives; no absence conclusion | Existing limited profile/account; a smaller requested scope list alone is not proof of denial |
| Partial assignment/page failure | Completed evidence retained; failed assignment/source incomplete; no absence conclusion | Existing reproducible service/visibility failure if available; otherwise keep live row NOT RUN and use boundary mocks |
| Request budget | With `-MaxRequests 1`, exact group may resolve, then both policy sources are unavailable with `request_limit`; absence false | Extra bounded read on the same reviewed profile; an application-limit check, not a Graph-denial test |
| Tenant/session mismatch | Wrong tenant rejected before reads; visible mid-read binding change withholds the whole result | Foreign GUID for preflight; mid-read change remains boundary-mock evidence unless a controlled dedicated-process harness is prepared |
| Paging | Every returned page, including nested assignment pages, accounted for; no unsafe link followed | Existing paged data if available; do not invent live pagination coverage from a one-page response |

Public tests cover deterministic denied/partial/mismatch/unsafe-pagination cases
at the SDK boundary. An unavailable real-service failure scenario remains
unverified even when its mock passes. Scope tags, unsupported targeting and
configuration changes during the collection window require explicit exceptions.
No result here establishes effective access, affected population, policy
conflicts, inactivity or that a group is safe to delete.

## Remaining release gates

The [sixteen-case local transport probe](TRANSPORT-CHECKS.md) now verifies SDK
retry counts, per-request timeout, explicit cancellation, redirect/header
behaviour and large response allocation with a fictional credential. It also
demonstrates an HTTP buffer cap against content-length, chunked and compressed
responses. No tenant call was made in that work.

**Production transport acceptance remains open.** The collector still bounds
pages, retained items and SDK invocations, not HTTP attempts, response bytes or
overall duration. The probe reproduced redirects below the paging guards,
authentication retries outside `MaxRetry`, and response buffering before the
item limit. It did not apply a new transport policy to the collector. See the
report for the required combined change. Dedicated-process use reduces ambient
session interference; local context checks cannot exclude every unobservable
change-and-restore race.

Offline saved observations/notes and explicit refresh comparisons are now available
in [the evidence module](DEVELOPMENT.md#saved-investigations-notes-and-refresh-comparisons).
Their fictional/local tests are separate from the dated live collector evidence.
Offline [terminal summaries and HTML/JSON reports](DEVELOPMENT.md#readable-html-and-structured-json-exports)
are also implemented and locally checked; export replay of retained real evidence
is not a new Microsoft service read. Guided discovery, optional Axon, clean installation
and independent repository publication remain later slices under the
current release target (internal planning note).
