# Test-tenant fixture setup

8 November 2026. This is the separate write/setup stage for the
[known-answer collection checks](KNOWN-ANSWER-CHECKS.md). The user confirmed that
the test tenant needs new groups and policies. All seven fixtures are now created
and retained for further tests. The two CA policies are disabled/report-only;
the compliance assignments target only the verified empty fixture groups.
Tenant/account identifiers and the preflight record stay in local private
evidence, outside the source tree.

## Current prerequisite result

The initial preflight confirmed the organisation/domain but found the original
Business Premium SKU `Suspended`; `INTUNE_A`, `INTUNE_SMBIZ` and
`AAD_PREMIUM` reported `Disabled`. The other listed SKU was also suspended.
The compliance-policy GET returned `403 Forbidden` / `UnknownError`. That fixed
code does not establish whether the failed request was caused by licensing,
permissions or another service prerequisite. The first role query failed; a
later direct directory-role membership read confirmed Global Administrator.

The user subsequently obtained a Business Premium (no Teams) trial. Graph
confirmed 25 enabled seats and Entra ID P1; Intune's portal confirmed account
status **Active**, Microsoft Intune MDM authority, 25 licences and zero enrolled
devices. Intune policy/filter creation succeeded in that portal. The original
CLI session's Intune 403 remains separate from the successfully tested reader
profile. No subscription or user-licence assignment was changed by the agent.

Existing app registrations were inspected. None had the reviewed combination of
a dedicated tenant-owned interactive public client and the three proposed
collector read scopes. A new single-tenant **Handoff Investigation Test Reader**
was then created without a secret/certificate or application permissions. The
user approved the three delegated read scopes for the selected administrator
only; that actual principal-scoped grant was read back and verified. Existing
Handoff assessment/execution registrations and operator roles were not changed.

Recheck the trial and operator authority before future setup or collection.
The seven objects and their cleanup IDs are recorded privately; the bounded
live results are summarised in the [collection checkpoint](KNOWN-ANSWER-CHECKS.md#live-continuation).
Microsoft documents an [Intune subscription and Entra ID P1/P2 for Conditional Access](https://learn.microsoft.com/en-us/intune/device-security/compliance/create-policy#requirements).

## Objects to create

Use one unique run prefix, `Handoff-KA-<UTC date>-<8 hex characters>`. Put the same
marker in every object's description: `Temporary group-policy reference fixture;
keep groups empty; remove using this run's recorded IDs.` Record returned object
IDs immediately in a private manifest. Names are labels, not identifiers.

| Object suffix | Exact configuration |
| --- | --- |
| `Included` | Assigned-membership security group; `securityEnabled = true`, `mailEnabled = false`, `groupTypes = []`; not role assignable; no members or nested groups |
| `Excluded` | Same empty security-group configuration |
| `Unreferenced` | Same empty configuration; no fixture policy refers to this group |
| `CA-Disabled` | Include only `Included`; exclude only `Excluded`; all resources, all client app types; require MFA; state `disabled`; no other targeting or controls |
| `CA-ReportOnly` | Same targeting and MFA control; state `enabledForReportingButNotEnforced` |
| `Windows-Filter` | Managed-device assignment filter for Windows 10 and later; rule `(device.model -eq "<run prefix>")` |
| `Windows-Compliance` | Standard Windows 10 and later compliance policy (`#microsoft.graph.windows10CompliancePolicy`); require password; other configurable compliance checks not configured; no custom compliance script |

The portal created a new compliance policy with exactly these reviewed assignments:

| Assignment | Target and filter |
| --- | --- |
| Include | `#microsoft.graph.groupAssignmentTarget`, group ID of `Included`; filter ID of `Windows-Filter`, filter mode `include` |
| Exclude | `#microsoft.graph.exclusionGroupAssignmentTarget`, group ID of `Excluded`; no assignment filter |

Use the default mark-noncompliant action only; no email, remote lock, retire or
other added actions. Do not assign All users or All devices. Keep all three
groups empty throughout the investigation; the filter is a test datum, not a
guarantee that a device can never match. Verify the group memberships again
before assigning the compliance policy.

Both CA policies must remain non-enforcing. Microsoft documents
[report-only evaluation without enforcement](https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-conditional-access-report-only).
This fixture uses MFA and empty groups; it does not require a compliant device
as a CA grant control. No enabled-policy or real-user/device enforcement test is
part of this setup.

Create the filter through the supported Intune portal workflow, confirm Windows
compliance supports it in the selected tenant, and record its ID/rule separately.
The collector preserves filter ID and mode; it does not collect/evaluate the
filter rule. See Microsoft's [filter workflow](https://learn.microsoft.com/en-us/intune/fundamentals/filters/overview)
and [supported workloads](https://learn.microsoft.com/en-us/intune/fundamentals/filters/ref-supported-workloads).
Record any unavailable fixture as NOT CREATED rather than silently omitting it
from a successful test result.

## Setup authority and order

Use the authorised administrative setup session. Keep its write authority out of
the investigation reader registration. If using Graph rather than portals, the
documented delegated setup permissions are `Group.ReadWrite.All` for
[groups](https://learn.microsoft.com/en-us/graph/api/group-post-groups?view=graph-rest-1.0),
`Policy.Read.All` plus `Policy.ReadWrite.ConditionalAccess` and supported operator
authority for [CA policies](https://learn.microsoft.com/en-us/graph/api/conditionalaccessroot-post-policies?view=graph-rest-1.0),
and `DeviceManagementConfiguration.ReadWrite.All` for the
[Windows compliance policy](https://learn.microsoft.com/en-us/graph/api/intune-deviceconfig-windows10compliancepolicy-create?view=graph-rest-1.0)
and its [assign action](https://learn.microsoft.com/en-us/graph/api/intune-deviceconfig-devicecompliancepolicy-assign?view=graph-rest-1.0).
Do not silently add these scopes to an existing Handoff registration.

1. Confirm the exact tenant, active licences and setup operator authority.
2. Create the three groups and record their IDs. Independently verify zero members.
3. Create the filter and record its ID; prepare a new compliance policy in its
   creation wizard. Do not select or edit an existing policy.
4. Create the two CA policies with the states and exact group IDs above. Read
   back each policy and verify its state before continuing.
5. Recheck empty membership, create the new compliance policy with only the two
   fixture-group assignments, record its ID and read back all assignments. If
   using Graph's assign action instead, that operation must never
   target a pre-existing policy, because it can replace that policy's assignments.
6. Inspect the objects independently in Entra/Intune and finish the expected-answer
   table using the actual IDs, states, settings, assignments and filter metadata.
7. Select/create the dedicated interactive reader profile with the three reviewed
   read scopes, inspect actual consent grants and verify delegated reader authority.
   Reconnect in a separate process for collection; no setup/write session is a
   substitute for validating the collector's intended public-client profile.

Keep a private manifest containing tenant ID, operator, run marker, creation UTC,
each object's type/ID/name, assignment IDs, filter ID/rule and each operation's
confirmed outcome. If a write times out or returns an ambiguous result, stop and
reconcile that exact operation before retrying; do not create duplicates blindly.
No fixture-provisioning or deletion helper is included in the public collector.

## Expected answers before collection

These counts are the **fixture contribution**, not a claim about the tenant's
other policies. Compare the actual ID/property sets, then investigate extras.

| Selected group | Expected fixture references |
| --- | --- |
| `Included` | Three inclusions: both CA policies at `conditions.users.includeGroups`, preserving their different states; the compliance assignment at `assignments.target.groupId`, preserving its assignment ID and filter ID/mode |
| `Excluded` | Three exclusions: both CA policies at `conditions.users.excludeGroups`; the compliance exclusion at `assignments.target.groupId` |
| `Unreferenced` | Zero explicit fixture references; no fixture assignment/filter points to it |

A local synthetic self-check against the unchanged evaluator confirmed these
three/three/zero reference counts, relations and retained inclusion-filter ID.
It made no Graph calls and does not establish that live fixtures exist.

For the negative control, `canConcludeNoExplicitReferences` is true only when
all collected visible policies/assignments complete and the evaluator finds no
issues or other explicit references. Broad targeting remains context; unknown
target types or incomplete evidence prevent the absence conclusion. This setup
does not prove membership effects, filter applicability, enforcement or safety
to delete a group.

The live replay passed the three reference cases, request-budget exhaustion and
wrong-tenant preflight. The initial v1.0 filter omission and its correction are
recorded separately; do not discard the failed baseline.

This seven-object fixture does not manufacture tenant-wide empty sources, broad
enforcing assignments, HTTP failures, pagination or denied authority. Those
acceptance rows retain their separate live/mocked/NOT RUN status.

## Cleanup

Leave fixtures available for the agreed investigation; record cleanup as pending.
When removal is requested, use only the exact IDs in this run's manifest:

1. Confirm tenant and ownership marker; check that no fixture group gained members
   and no unrelated object adopted these groups or the filter. Stop on drift.
2. Remove the two fixture CA policies and the fixture compliance policy; verify
   removal of its assignments. Do not clear assignments on any other policy.
3. Remove the fixture filter after verifying it has no remaining references.
4. Remove the three empty groups. Never bulk-delete by a display-name prefix.
5. Record every confirmed deletion or unresolved object. Reader-app consent and
   app removal are a separate decision; preserve it if further tests are planned.

Subscription/billing changes, existing policy changes, VM deployment and wider-app
assessment login are outside this fixture setup.
