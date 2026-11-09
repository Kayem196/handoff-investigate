# Handoff investigation core — development slices

A standalone PowerShell evaluator and read-only collector for **explicit group references** in
Conditional Access and Intune device-compliance policy evidence. This is the
first building block of the public release target (internal planning note),
not an installable public release. Bounded known-answer reads passed in the
authorised test tenant; wider failure, transport and installation acceptance is
still outstanding.

**Installing:** see [INSTALL.md](../INSTALL.md) for the supported versions, module
installation, the dedicated reader registration and a first investigation. Build
a package with `./tools/Build-HandoffPackage.ps1 -OutDirectory <new folder>`.
Then check it in a fresh `pwsh -NoProfile` with
`./tests/package/Test-HandoffPackage.ps1 -PackageRoot <that folder>`. That smoke
test verifies checksums, an import limited to the package, that the Graph SDK is
not loaded, that the collector compiles its helper, and that the offline
commands and example work.

Importing this module needs no SDK, authentication, network, AI, server or database.
The evaluator exposes `Get-HandoffGroupPolicyReference`; a separate collection module
exposes `Get-HandoffPolicySnapshot`. Development is staged here
until the independent public repository is prepared.

## Try the fictional example

From this directory in PowerShell 7:

```powershell
Import-Module ./Handoff.Investigation.psm1 -Force
$snapshot = Get-Content ./examples/group-policy-snapshot.json -Raw | ConvertFrom-Json -AsHashtable
$result = Get-HandoffGroupPolicyReference `
    -TenantId aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa `
    -GroupId bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb `
    -Snapshot $snapshot
$result | ConvertTo-Json -Depth 12
```

Expected: two explicit inclusion references and `coverage: incomplete`, because
compliance collection in the example is declared partial. Known findings survive
without suggesting that collection finished. No Microsoft call is made.

## Input and output contract

Input is an `IDictionary` snapshot (for example JSON read with `-AsHashtable`):
version 1, tenant GUID, explicit UTC/offset collection timestamp, and two sources
named `conditionalAccess` and `compliance`. Each source contains collection
`status` and an array of `policies`. Compliance policies additionally contain
`assignmentsStatus` and an array of `assignments`. Raw policy/target properties
follow the documented Microsoft Graph shapes below.

Only the literal `complete` status permits a completeness conclusion. Missing,
partial or unavailable sources, malformed policies/lists, duplicate policy IDs,
unread assignment lists and unsupported target types produce issues. Snapshot
metadata is structural input, not authenticated proof of a Microsoft collection;
the collection module establishes its own session binding and paging metadata.
Manually supplied snapshots are not authenticated by the evaluator.

Output identifies the exact group/policy IDs, include/exclude relation, source
property path, policy state where supplied, assignment ID and assignment filter.
Disabled/report-only policies remain references. Broad or other CA targeting and
supported all-device/all-licensed-user compliance assignments are context, not
invented explicit references to the selected group.

`canConcludeNoExplicitReferences` applies **only** to the two supplied collections
and supported reference shapes. It never means no policy applies, no other
workload uses the group, no member has access, or deletion is safe. Filters are
preserved, not evaluated. No population count, group inheritance, effective access,
policy conflict resolution or lockout prediction is implemented in this slice.
Original policy settings/evidence remain in the input snapshot; the output is an
index of references, not a replacement for that evidence.

## Verification

```powershell
Invoke-Pester -Path ./tests -CI
```

Tests use Pester 6.0.0, matching the parent repository's PowerShell CI. On
8 November 2026, Windows 11 / PowerShell 7.6.9 initially passed all 32 public tests
and 351 combined tests. After the live filter-contract correction, all 354
combined tests passed, including 35 public cases. The offline example matched its
known answer. Earlier macOS validation used PowerShell 7.6.5. These offline tests
use SDK-boundary mocks. Five separate live cases passed with Graph SDK 2.38.1;
this is not clean-install or complete Microsoft acceptance. See the
[Windows baseline and staged known-answer checks](KNOWN-ANSWER-CHECKS.md) for
the exact source revision, test profile requirements and outstanding live cases.

## Saved investigations, notes and refresh comparisons

`Handoff.Evidence.psm1` is offline and needs no Graph SDK, login, server or AI.
It requires PowerShell **7.5+** (tested on Windows with **7.6.9**). Try the
fictional example with a new private directory outside any repository or sync folder:

```powershell
$folder = Join-Path $env:LOCALAPPDATA ('Handoff/Investigations/example-' + [guid]::NewGuid())
$diff = ./examples/saved-investigation.ps1 -Path $folder
$diff | Select-Object summary, coverageBefore, coverageAfter, verification
$diff.policyChanges | Select-Object source, policyId, changedFields
```

For your own already-collected snapshot, import the evidence module and explicitly
select its tenant/group and a private directory. No command below starts a login,
collects Graph data or changes the tenant:

```powershell
Import-Module ./Handoff.Evidence.psm1
$ids = @{TenantId=$tenantId; GroupId=$groupId}
$first = Save-HandoffInvestigationObservation -Path $folder @ids -Snapshot $snapshot
Add-HandoffInvestigationNote -Path $folder @ids -ObservationId $first.id `
    -Text 'Confirm the policy owner and remaining source coverage before changes.'
$saved = Get-HandoffInvestigation -Path $folder @ids

# Refresh is explicit: collect a new snapshot separately using the reviewed reader.
# Supply that $newSnapshot here; saving never performs a hidden live read.
$later = Save-HandoffInvestigationObservation -Path $folder @ids -Snapshot $newSnapshot
$diff = Compare-HandoffInvestigationObservation -Path $folder @ids `
    -EarlierObservationId $first.id -LaterObservationId $later.id
$diff.summary
$diff.policyChanges | Select-Object source, policyId, changedFields
```

The first save creates an identity-bound investigation manifest. Each observation
and note is a separate uniquely named record; refresh and new notes never replace
earlier files. Raw snapshot JSON and its versioned evaluation are retained together,
with separate saved/collection times. Reopening verifies checksums, identities,
note links and the recorded evaluation against its supported evaluator version.
Unsupported versions or corrupt/foreign records stop the read; nothing is silently
repaired. Missing references are **not observed later**, not certified deletions.
Diffs show both coverage states, changed reference details and differing fields
of policies referenced by the selected group. Dictionary key order is ignored;
array order and case-sensitive values remain observed differences, not a semantic
policy-equivalence or impact calculation. Collection status is not a policy-setting
change. A partial refresh never becomes proof of safe deletion.

Storage uses complete, flushed same-directory staging files and non-overwriting
rename, plus an exclusive writer handle. A competing writer fails safely; retry
after that writer finishes. Reads see published records only. The persistent
`.handoff-write.lock` file is not itself a stale lock after process exit. Stranded
`.handoff-staging-*.tmp` files after interruption are not observations; inspect them
manually, preserving published history. Power-loss durability, hostile local writers,
network filesystems and cloud-sync conflicts are not accepted by the local tests.

Records are capped at **16 MiB**, investigations at **64 MiB / 1,000 JSON records**,
and notes at **16,000 characters**. Exceeding a limit fails rather than truncates
evidence; a failed first save can leave an empty, valid investigation manifest.
Files are **plaintext**, inherit the chosen directory's permissions and are not
automatically uploaded. Keep tenant evidence outside Git and sync folders. Never
paste credentials into snapshots or notes: the snapshot top-level-field check is
not a general secret scrubber. Checksums detect accidental alteration, not malicious
rewriting by someone who can also recompute them; this is not signed audit evidence.

Verification on 9 November: **27 evidence tests** and **388 combined PowerShell
tests** passed on Windows, with zero failures/skips. The fictional example saved
two observations and a note, reopened in a fresh process without the SDK and left
published file hashes unchanged. A separate offline replay of the retained 8/9
November live snapshots preserved their three/three reference sets, reported no
reference/configuration changes and left the original private files unchanged.
That replay made no new tenant call and is not clean-machine or power-loss proof.

## Readable HTML and structured JSON exports

`Handoff.Report.psm1` reads the verified saved evidence above; it never logs in or
refreshes a tenant. Get a terminal summary with `Get-HandoffInvestigationReport`,
or explicitly export a selected observation. Notes from other observations are
not included. An earlier observation is included only when you select a comparison.

```powershell
Import-Module ./Handoff.Report.psm1
$report = Get-HandoffInvestigationReport -Path $folder @ids -ObservationId $later.id `
    -CompareWithObservationId $first.id
$report.summary

$exports = Join-Path $env:LOCALAPPDATA ('Handoff/Exports/' + [guid]::NewGuid())
$null = New-Item -ItemType Directory -Path $exports
Export-HandoffInvestigationReport -Path $folder @ids -ObservationId $later.id `
    -CompareWithObservationId $first.id -OutFile (Join-Path $exports 'group.html') -Format Html
Export-HandoffInvestigationReport -Path $folder @ids -ObservationId $later.id `
    -CompareWithObservationId $first.id -OutFile (Join-Path $exports 'group.json') -Format Json
```

For fictional data without SDK/authentication, run this from `public-handoff/`:

```powershell
$destination = Join-Path $env:LOCALAPPDATA ('Handoff/ReportExamples/' + [guid]::NewGuid())
$files = ./examples/export-investigation.ps1 -OutDirectory $destination
$files # Includes the main HTML/JSON and a separate incomplete-observation HTML.
```

The HTML is self-contained: system fonts, one hash-authorised inline stylesheet,
no JavaScript, no external resources or telemetry. Names, notes and original JSON
settings are HTML-encoded, never treated as markup. It includes identity and
recorded group flags, source outcomes, reference paths, state/filter details,
matched policy configurations, targeting context, attached notes and concrete
manual checks. `false`, `null` and **Not collected** remain distinct. Coverage
limits come before findings; zero visible references never becomes a deletion
recommendation. Comparisons retain both coverage states and cautious observed-
difference wording. Native disclosures work without scripts. Print styles were
checked in Edge; expand evidence sections before printing in other browsers that
omit collapsed details.

Exports are **plaintext and not redacted**: identifiers, policy definitions
(including other assignments/targeting within matched policies), notes and optional
earlier comparison settings may be sensitive. They include policies matched to
reference/issue/context IDs, not a complete raw snapshot. Missing/invalid IDs can
prevent matching; use the original saved snapshot to investigate those gaps.
Review recipients and content before sharing. JSON uses report schema version 1
(`group_policy_investigation_v1`); it is a report, not a journal import format or
signed audit evidence. Neither format represents current live state.

Choose an existing ordinary output directory **outside** the journal and its
descendants. Destinations must match `.html`/`.json` and must not already exist;
there is no overwrite option. Publication uses a flushed temporary file and a
non-overwriting same-directory rename, capped at **32 MiB** per export. Existing
records remain untouched and exports inherit their destination permissions.

Verification on 9 November: **20 report tests / 408 combined PowerShell tests**
passed with zero failures/skips. **31 local Edge 157 browser checks** passed for
complete, incomplete and hostile-text reports: desktop, 390/320 px layouts, native
keyboard disclosure, print-style emulation, matching CSP and no HTTP(S) page
requests. The test-owned browser was stopped. A separate offline export of retained
real evidence preserved three references, attached notes and original file hashes;
it made no new tenant call. Screen-reader usability, other browser engines, actual
printer pagination and clean-machine setup remain unverified. See
[repeatable browser checks](../tests/browser/README.md).

## Guided group discovery and selection

`Handoff.Console.psm1` adds `Start-HandoffGroupInvestigation`. It uses an
already connected, process-scoped reader. It never signs in, changes consent or
modifies the tenant. Before any read, it checks the exact tenant, reviewed
client, account and approved read scopes. If any of these differ, or extra API
scopes are present, it stops.

```powershell
Import-Module ./Handoff.Console.psm1
Start-HandoffGroupInvestigation -TenantId $tenantId -ClientId $clientId `
    -Account $operatorAccount -OutDirectory (Join-Path $privateParent 'new-investigation') `
    -NameContains 'support'
```

1. Type `READ` to list up to 200 visible groups (`Get-HandoffGroupCatalog`:
   `id`, name, type and flag properties only; 10 pages, 50 SDK invocations,
   4 MiB per response, shared deadline). Owners, membership, activity and
   policy references are **not collected** for the picker. They are not zero.
2. Optionally filter the retained rows locally by literal name text. Choose a
   displayed number. Groups with the same name are distinguished by ID. Other
   input is rejected, not executed. Empty input or `Q` cancels.
3. Type `READ` again to collect only that group's Conditional Access/compliance
   snapshot. Evidence and HTML/JSON reports go into a **new** directory, which is
   created exclusively, so another run's output is never overwritten.

Tenant-provided names are escaped before terminal display, including ANSI and
bidirectional control characters. A partial or unavailable catalog is labelled as
such. A local no-match is not proof that a group is absent. If report export fails,
the saved evidence remains. The catalog is a bounded visible list, not a tenant
inventory. It is not reference-ranked and never suggests deletion. It uses the
existing `GroupMember.Read.All` delegated scope; no permission was added.

Verification on 9 November: **35 catalog/guide tests**, **443 combined PowerShell
tests** and **30 local collector integration checks** passed. The integration
checks include catalog pagination, redirect, size and deadline cases, plus a
synthetic end-to-end guided catalog → read → save → export run through the real
SDK pipeline with a fictional token.

Live acceptance passed on 9 November (source `eaaba01e`), using a fresh delegated
sign-in through the retained test reader. The catalog read made one SDK call and
returned 14 visible groups, status complete. All three fixture groups appeared,
with exact IDs and names. In the guided flow, the operator selected the
`Included` fixture. Its saved observation matched the expected three-reference
set and retained the compliance filter ID/mode. Coverage was complete for
explicit references, and HTML/JSON reports were published. No tenant
configuration, consent or registration changed. Raw evidence stays in the
private evidence area, outside Git. Still unverified: a multipage catalog in
real data, large tenants, limited-scope (non-Global Administrator) readers, and
clean-machine setup.

## Optional Axon explanations

`Invoke-HandoffAxonExplanation` asks an AI model one question about one saved
observation. Everything else in Handoff works without it. It has no tools: it
cannot read more data, run commands or change the tenant. It only explains what
was recorded.

```powershell
$ask = @{ Path=$folder; TenantId=$tenantId; GroupId=$groupId; ObservationId=$observationId
          Question='Which policies reference this group, and what is still unknown?' }
Invoke-HandoffAxonExplanation @ask -PreviewOnly          # exact text and destination; nothing sent
$key = Read-Host 'Anthropic API key' -AsSecureString
Invoke-HandoffAxonExplanation @ask -ApiKey $key          # Anthropic, default model claude-opus-5-5
Invoke-HandoffAxonExplanation @ask -Provider OpenAI -Model '<model>' -ApiKey $key
Invoke-HandoffAxonExplanation @ask -Provider AzureOpenAI -AzureEndpoint 'https://<resource>.openai.azure.com' `
    -Deployment '<deployment>' -ApiKey $key
```

**What is shared, and only after you type `SHARE` for that request:**
- an allow-listed copy of the scoped report: coverage, sources, references,
  issues, context and manual checks, plus the matched policies' name, state,
  conditions, controls and assignment targets
- your question

The tenant ID is never sent. Notes are sent only with `-IncludeNotes`. Before
asking for confirmation, it shows the destination, model, byte count and
SHA-256 of the payload. Payloads are capped at 256 KiB. The API key is passed as
a SecureString and used only in the request header. It never appears in the
payload or the output. You pay your provider's usage costs, and their data terms
apply.

**Treatment of tenant data:** it goes inside a delimited evidence block, and an
attempted closing tag is escaped. The system prompt says that block is data, not
instructions. It also forbids deletion-safety claims, impact predictions and
invented evidence. That reduces prompt-injection risk but cannot eliminate it,
so always check answers against the report.

**Transport and failures:** redirects are refused and requests time out. Each
failure becomes a fixed code (`provider_auth_failed`, `provider_rate_limited`,
`provider_redirect_rejected`, `provider_unreachable`, `provider_output_limit`,
`provider_quota_exhausted` (an OpenAI account without API credit) and similar) without echoing provider response bodies. An answer the provider cut
short is returned with `truncated = true`. OpenAI and Azure requests use
`max_completion_tokens` (4,000), because current models reject `max_tokens` and
reasoning tokens count against the budget. Answers are returned, not saved. There is no fallback
provider.

Verification on 9 November: 18 Axon tests passed, using mocked provider calls
plus one real HTTP check against a loopback listener for redirects and JSON.

**Live Anthropic acceptance passed on 9 November** (source `8f857784`, model
`claude-opus-5-5`), using the fictional example only. No tenant data was sent.
The 3,990-byte payload excluded the tenant ID and notes. The operator confirmed
with `SHARE` and supplied the key through hidden input. The answer listed the two
references correctly. It put the incomplete compliance coverage first, separated
configured targeting from membership and applicability, and refused a deletion
verdict. It also pointed to the manual checks. A random invalid key returned HTTP
401, mapped to `provider_auth_failed` with no echoed provider text. The saved
results contain no key material.

OpenAI live check, 9 November, with fictional data and model `gpt-5`:
- A random invalid key returned HTTP 401, mapped to `provider_auth_failed`.
- The operator's real key was accepted, and the request was sent after `SHARE`,
  but OpenAI returned HTTP 429 instead of an answer. That is consistent with an
  account that has no API credit.
- That outcome led to the new `provider_quota_exhausted` code.
- **After credit was added, the rerun passed** (source `f3261da8`, `gpt-5`,
  `max_completion_tokens`). The invalid key again mapped to
  `provider_auth_failed`. The real answer was complete (not truncated). It
  listed both references, put the incomplete compliance source first and
  declined a deletion verdict. It also pointed to the manual checks. The results
  contain no key material.

Azure OpenAI is implemented from Microsoft's documented API
(`api-version=2024-10-21`) but has **not been tested** against a real
deployment. Treat it as experimental. Azure OpenAI also remains unverified live, as is behaviour with real tenant evidence or hostile policy names against a
live model. Axon can't yet start guided reads, and consent is
per request, not stored per investigation.

## Read-only collection module

### Transport controls (9 November 2026)

Live collection requires the already imported **Microsoft.Graph.Authentication
2.38.1** module and its normal Global-cloud HTTP pipeline in a dedicated
`pwsh -NoProfile` process. Other versions and nonstandard cloud endpoints fail
closed. The evaluator still needs no SDK. Collection lazily compiles the included
`Handoff.Transport.cs` with PowerShell's `Add-Type`; no package or separate build
tool is required. Environments that prohibit `Add-Type` are not supported yet.

The collector now sends through the SDK's existing authenticated HTTP client,
using public per-request Kiota options to disable redirects and ordinary retries.
It neither extracts tokens nor changes shared request settings, middleware,
HTTP buffer limits or client ownership. The SDK can still retry authentication
once; `MaxRequests` remains a count of SDK-client invocations, not HTTP attempts.

- `-MaxResponseBytes` defaults to **4 MiB** per decompressed response (range
  1 KiB–16 MiB). Streaming reads reject oversized bodies before JSON conversion,
  including chunked/compressed bodies. This is not a whole-process memory cap;
  bounded JSON still allocates strings and objects.
- `-TimeoutSeconds` defaults to **120** (range 1–600), shared across all reads,
  including SDK authentication and response streaming. JSON conversion is
  bounded by response size/depth and checked before/after, not preempted mid-parse.
  Synchronous SDK client initialisation is also checked afterwards; this is not
  a hard real-time CPU/process termination guarantee.
- `-CancellationToken` accepts a .NET cancellation token. Caller cancellation
  returns no investigation. Ctrl+C responsiveness has not been accepted separately.
- `response_limit`, `redirect_rejected` and `deadline_exceeded` are fixed failure
  codes. A failed current page is discarded; completed earlier pages survive as
  partial evidence. A group-read failure returns no investigation. No raw SDK
  error or response body is included in failures.

Local collector integration checks exercise the pinned SDK pipeline, not just
boundary mocks. See [transport checks](TRANSPORT-CHECKS.md#collector-controls--9-november-2026).
On 9 November, 25 collector integration checks, 361 combined PowerShell tests
(42 public), and the original sixteen SDK observation checks passed on Windows.
The new path also passed six [live replay checks](KNOWN-ANSWER-CHECKS.md#new-transport-live-replay--9-november-2026)
with a fresh delegated sign-in and the retained fixtures. Real token refresh,
denied-reader and multipage/partial-service cases, TLS/proxy variants, Ctrl+C and
clean-machine setup remain separate gates; this is not public-release approval.

`Handoff.Collection.psm1` uses an existing delegated Graph session. Importing it
does not connect, grant consent, change permissions, extract tokens or import the
wider application. Live include/exclude/filter and negative-control cases, a
request-budget check and wrong-tenant preflight passed using a separate
tenant-owned public client and the approved three read scopes. Keep development
use in the authorised test tenant with independently known policy fixtures.

After importing Microsoft.Graph.Authentication and connecting through the
reviewed tenant-owned client, the intended collection sequence is:

```powershell
Import-Module ./Handoff.Collection.psm1 -Force
$snapshot = Get-HandoffPolicySnapshot -TenantId $tenantId -GroupId $groupId
$result = Get-HandoffGroupPolicyReference -TenantId $tenantId -GroupId $groupId -Snapshot $snapshot
```

`$tenantId` and `$groupId` are the explicitly selected tenant and group GUIDs.
This command resolves that exact group; it does not search ambiguous names or
collect membership/population counts. It GETs Conditional Access policies,
device-compliance policies and each valid compliance policy's assignments. It
retains original settings and adds assignment collection status. Snapshot time
is the start of the collection window; completion time is separate. These are
sequential reads, not an atomic snapshot.

Group, CA and compliance-policy reads use Graph v1.0. Compliance **assignment**
reads use Graph beta because the v1.0 contract omits assignment-filter ID/mode;
the first live v1.0 run reproduced that loss. Snapshot source is now
`graph_v1_beta_delegated_policy_snapshot_v1`, with an explicit `collection.apiVersions`
map. Older v1.0-only evidence retains its original source. The
[beta assignment contract](https://learn.microsoft.com/en-us/graph/api/intune-deviceconfig-devicecompliancepolicyassignment-list?view=graph-rest-beta)
is subject to more frequent change. There is no silent v1.0 fallback that could
discard filters. Filter definitions/applicability are still not evaluated.

The adapter checks the visible SDK session's tenant, client, account, auth type,
environment, scope list and context scope before/after requests and before
returning. A visible binding change withholds the entire result. This is local
SDK-context validation, not a new signed-identity proof, continuous permission
attestation or protection against an unobserved change-and-restore of ambient
SDK context. Use a dedicated process/session for an investigation. Only Global
commercial-cloud delegated sessions are accepted in this slice.

Defaults cap pages per collection at 100, total retained policy/assignment items
at 10,000 and SDK request invocations at 1,000. Lower these with `-MaxPages`,
`-MaxItems` and `-MaxRequests`. These are application collection bounds; SDK
internal authentication retries remain SDK behaviour. The per-response byte cap
and shared cancellation deadline above apply independently of these item/page
limits and are reapplied on each request, including after an SDK client reset.
The [original local transport probe](TRANSPORT-CHECKS.md) records the unsafe SDK
defaults separately from the newer collector controls.

Pagination accepts only HTTPS graph.microsoft.com URLs on port 443, without
credentials or fragments, and the exact original resource path. Foreign paths,
cyclic links, malformed pages and exhausted limits cannot become successful empty
collections. Known completed pages survive later failures, while assignment
failures propagate incomplete status to compliance. Group resolution or a session
binding failure returns no investigation. SDK request errors become fixed failure
codes without their raw causes/bodies. No automatic retry or mutation is added
by Handoff. Output persistence is not implemented yet.

The live profile used delegated GroupMember.Read.All, Policy.Read.All and
DeviceManagementConfiguration.Read.All, an active licensed tenant and a Global
Administrator operator. This establishes that profile's reads, not a minimum
reader-role configuration or scoped-operator visibility. Supplying scopes alone
does not prove authority. Clean setup, dependency distribution and the consent
wizard remain subsequent work.

Guided discovery and Axon are pending. Saved evidence/notes, explicit refresh
comparisons and HTML/JSON exports are available above; guided discovery/refresh
is not built yet.
No tenant-changing endpoint is exposed by either module.

## Source contracts

- [Policy reads](https://learn.microsoft.com/en-us/graph/api/conditionalaccessroot-list-policies?view=graph-rest-1.0), [compliance policies](https://learn.microsoft.com/en-us/graph/api/intune-deviceconfig-devicecompliancepolicy-list?view=graph-rest-1.0) and [beta compliance assignments](https://learn.microsoft.com/en-us/graph/api/intune-deviceconfig-devicecompliancepolicyassignment-list?view=graph-rest-beta).
- [Selected group](https://learn.microsoft.com/en-us/graph/api/group-get?view=graph-rest-1.0), [paging](https://learn.microsoft.com/en-us/graph/paging), [SDK context](https://learn.microsoft.com/en-us/powershell/module/microsoft.graph.authentication/get-mgcontext?view=graph-powershell-1.0) and [SDK request method](https://learn.microsoft.com/en-us/powershell/module/microsoft.graph.authentication/invoke-mggraphrequest?view=graph-powershell-1.0).

- [Conditional Access users/groups](https://learn.microsoft.com/en-us/graph/api/resources/conditionalaccessusers?view=graph-rest-1.0): explicit includeGroups/excludeGroups are GUID collections.
- [Compliance group targets](https://learn.microsoft.com/en-us/graph/api/resources/intune-shared-groupassignmenttarget?view=graph-rest-beta) and [exclusion targets](https://learn.microsoft.com/en-us/graph/api/resources/intune-shared-exclusiongroupassignmenttarget?view=graph-rest-beta): distinguish the target type and match groupId, not display name.

The existing repository licence applies; this directory introduces no separate
licence or published package.
