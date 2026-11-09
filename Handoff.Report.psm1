#Requires -Version 7.5
# Offline presentation of verified saved observations. No SDK or external resources.
Import-Module (Join-Path $PSScriptRoot 'Handoff.Evidence.psm1') -Scope Local
$script:MaxExportBytes = 32MB

function Get-HandoffInvestigationReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][guid]$TenantId,
        [Parameter(Mandatory)][guid]$GroupId,
        [Parameter(Mandatory)][guid]$ObservationId,
        [guid]$CompareWithObservationId = [guid]::Empty
    )
    $saved = Get-HandoffInvestigation -Path $Path -TenantId $TenantId -GroupId $GroupId
    $selected = @($saved.observations | Where-Object id -CEQ $ObservationId.ToString())
    if ($selected.Count -ne 1) { throw 'Choose an observation in this investigation.' }
    $observation = $selected[0]
    $evaluation = $observation.evaluation
    $sources = foreach ($name in @('conditionalAccess','compliance')) {
        $source = $observation.snapshot[$name]
        $status = $(if ($source.status -in @('complete','partial','unavailable')) { [string]$source.status } else { 'unavailable' })
        [ordered]@{source=$name;status=$status;pagesRead=$source.pagesRead;failureCode=$source.failureCode}
    }
    $policies = [Collections.Generic.List[object]]::new()
    foreach ($source in @('conditionalAccess','compliance')) {
        $wanted = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($item in @($evaluation.references) + @($evaluation.issues) + @($evaluation.context)) {
            if ($item.source -ceq $source -and $item.policyId) { $null = $wanted.Add([string]$item.policyId) }
        }
        foreach ($policy in $observation.snapshot[$source].policies) {
            $id = [guid]::Empty
            if ([guid]::TryParse([string]$policy.id, [ref]$id) -and $wanted.Contains($id.ToString())) {
                $policies.Add([ordered]@{evidenceId='policy-' + ($policies.Count + 1);source=$source;policyId=$id.ToString();configuration=$policy})
            }
        }
    }
    $references = @(foreach ($reference in $evaluation.references) {
        $evidence = @($policies | Where-Object { $_.source -ceq $reference.source -and $_.policyId -ceq $reference.policyId })
        $row = [ordered]@{}
        foreach ($key in $reference.Keys) { $row[$key] = $reference[$key] }
        $row.evidenceId = $(if ($evidence.Count) { $evidence[0].evidenceId } else { $null })
        $row
    })
    $checks = [Collections.Generic.List[object]]::new()
    foreach ($issue in $evaluation.issues) {
        $where = $(if ($issue.source -ceq 'conditionalAccess') { 'Entra admin center: Conditional Access policies' } else { 'Intune admin center: device compliance policies and assignments' })
        $family = $(if ($issue.source -ceq 'conditionalAccess') { 'Conditional Access' } else { 'Intune compliance' })
        $checks.Add([ordered]@{code=$issue.code;source=$issue.source;policyId=$issue.policyId
            title='Resolve the recorded evidence gap'
            attempted='Read and evaluate the visible ' + $family + ' policy evidence.'
            unknown='This observation has issue ' + $issue.code + '; complete supported targeting is not established.'
            consequence='Do not treat missing references as confirmed absence.'
            verify=$where + '. Locate the recorded policy ID if present, inspect its targeting and the reader permissions, and repeat the supported read after resolving the gap.'})
    }
    if (@($evaluation.references | Where-Object { $_.filter.id -or $_.filter.type }).Count) {
        $checks.Add([ordered]@{code='filter_definition_not_collected';title='Check assignment filter definitions'
            attempted='Retained filter IDs and modes from compliance assignments.'
            unknown='Filter rules and matching device populations were not collected.'
            consequence='A configured group assignment is not proof that a device matches its filter.'
            verify='In Intune, open Filters and locate each recorded filter ID. Compare its rule, include/exclude mode and workload support with the original policy assignment.'})
    }
    $checks.Add([ordered]@{code='reader_visibility_not_attested';title='Confirm the reader can see the intended scope'
        attempted='Read the two supported policy sources through the selected reader.'
        unknown='A completed visible endpoint is not an independent tenant-wide RBAC coverage attestation.'
        consequence='Hidden policies or Intune scope restrictions may limit the answer.'
        verify='Have an authorised administrator compare the visible inventory with the intended scope, and check Entra roles, Intune RBAC scope tags/groups and active licensing. Do not silently add permissions.'})
    $checks.Add([ordered]@{code='population_and_runtime_not_assessed';title='Verify population and runtime applicability'
        attempted='Matched explicit group IDs in configured policy targeting.'
        unknown='Membership, nesting, dynamic rules, synchronisation, policy combinations and runtime access were not evaluated.'
        consequence='Reference counts are not counts of affected people or devices, and are not lockout predictions.'
        verify='Inspect the selected group membership and source of authority in Entra. With the authorised operator, check relevant Conditional Access evaluation/sign-in evidence and Intune assignment/device evidence before planning a change.'})
    $checks.Add([ordered]@{code='other_workloads_not_checked';title='Check purpose, owners and other workloads'
        attempted='Investigated Conditional Access and Intune device-compliance references only.'
        unknown='Configuration profiles, apps, MAM, Teams/SharePoint, roles, third-party services and business purpose are outside this observation.'
        consequence='No reference in these two sources does not mean unused, unnecessary or safe to delete.'
        verify='Ask the group owner to confirm purpose and dependencies. Review the relevant workload portals and change/recovery requirements separately; do not delete or change the group from this report alone.'})
    $comparison = $null
    if ($CompareWithObservationId -ne [guid]::Empty) {
        $comparison = Compare-HandoffInvestigationObservation -Path $Path -TenantId $TenantId -GroupId $GroupId -EarlierObservationId $CompareWithObservationId -LaterObservationId $ObservationId
    }
    $summary = $(if ($evaluation.coverage -ne 'complete_for_explicit_references') {
        '{0} explicit references observed; coverage is incomplete. Missing references cannot establish absence.' -f $evaluation.references.Count
    } elseif ($evaluation.references.Count -eq 0) {
        'No explicit group references observed in the two visible policy sources. This does not establish safe deletion.'
    } else {
        '{0} explicit group references observed in the two visible policy sources. Population and runtime access are not assessed.' -f $evaluation.references.Count
    })
    return [ordered]@{
        schemaVersion=1;reportType='group_policy_investigation_v1';generatedAt=[datetimeoffset]::UtcNow.ToString('o')
        investigationId=$saved.investigationId;tenantId=$saved.tenantId;groupId=$saved.groupId
        observationId=$observation.id;collectedAt=$evaluation.collectedAt;savedAt=$observation.savedAt;evaluator=$observation.evaluator
        group=$observation.snapshot.group;claim=$evaluation.claim;coverage=$evaluation.coverage
        summary=$summary;canConcludeNoExplicitReferences=$evaluation.canConcludeNoExplicitReferences
        sources=@($sources);references=@($references);issues=@($evaluation.issues);context=@($evaluation.context)
        manualChecks=$checks.ToArray();policyEvidence=$policies.ToArray();collection=$observation.snapshot.collection
        notes=@($saved.notes | Where-Object observationId -CEQ $observation.id | ForEach-Object { [ordered]@{id=$_.id;savedAt=$_.savedAt;text=$_.text} })
        comparison=$comparison
        disclosure='Private tenant evidence and unverified notes. Contains the selected observation, its attached notes and policies matched to referenced or flagged IDs, plus an optional explicit comparison. Invalid or missing IDs may prevent evidence matching. Not a full raw snapshot, current live state, signed audit record or deletion approval. Review before sharing.'
    }
}

function ConvertTo-HandoffReportHtml {
    param([System.Collections.IDictionary]$Report)
    function Encode($Text) { [Net.WebUtility]::HtmlEncode([string]$Text) }
    function Label($Source) { if ($Source -ceq 'conditionalAccess') { 'Conditional Access' } else { 'Intune compliance' } }
    $css = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'report/report.css')).Replace("`r`n", "`n").Replace("`r", "`n")
    $styleHash = [Convert]::ToBase64String([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($css)))
    $name = $(if (-not [string]::IsNullOrWhiteSpace([string]$Report.group.displayName)) { [string]$Report.group.displayName } else { 'Selected group' })
    $status = $(if ($Report.coverage -ceq 'complete_for_explicit_references') { 'Complete for explicit references only' } else { 'Incomplete evidence' })
    $groupProperties = foreach ($field in @(
        @('groupTypes','Group types'), @('securityEnabled','Security enabled'),
        @('mailEnabled','Mail enabled'), @('onPremisesSyncEnabled','Directory sync enabled')
    )) {
        $value = 'Not collected'
        if ($Report.group -is [System.Collections.IDictionary] -and $Report.group.Contains($field[0])) {
            $value = $(if ($null -eq $Report.group[$field[0]]) { 'Null returned' } else { ConvertTo-Json -InputObject $Report.group[$field[0]] -Compress -Depth 64 -WarningAction Stop -ErrorAction Stop })
        }
        '<dt>' + $field[1] + '</dt><dd>' + (Encode $value) + '</dd>'
    }
    $sourceRows = foreach ($source in $Report.sources) {
        $pages = $(if ($null -eq $source.pagesRead) { 'Not recorded' } else { [string]$source.pagesRead })
        $failure = $(if ($source.failureCode) { [string]$source.failureCode } else { 'None recorded' })
        '<tr><th scope="row">' + (Label $source.source) + '</th><td>' + (Encode $source.status) + '</td><td>' + (Encode $pages) + '</td><td>' + (Encode $failure) + '</td></tr>'
    }
    $referenceRows = foreach ($reference in $Report.references) {
        $policyName = $(if (-not [string]::IsNullOrWhiteSpace([string]$reference.policyName)) { [string]$reference.policyName } else { 'Policy name not recorded' })
        $state = $(if ($reference.policyState) { [string]$reference.policyState } elseif ($reference.source -ceq 'conditionalAccess') { 'Not recorded' } else { 'Not supplied by this policy family' })
        $filter = $(if ($reference.filter.id -or $reference.filter.type) { '{0} / {1}' -f $reference.filter.id,$reference.filter.type } else { 'No filter ID/mode recorded' })
        $assignment = $(if ($reference.assignmentId) { [string]$reference.assignmentId } elseif ($reference.source -ceq 'compliance') { 'Not recorded' } else { 'Not applicable' })
        $link = $(if ($reference.evidenceId) { '<a href="#' + (Encode $reference.evidenceId) + '">Inspect recorded settings</a>' } else { '<p>Original policy details are not available in this report.</p>' })
        @"
<li><article class="reference"><h3><bdi>$(Encode $policyName)</bdi></h3>
<p class="relation">$(Label $reference.source): $(Encode $reference.relation) reference</p>
<dl><div><dt>Policy ID</dt><dd>$(Encode $reference.policyId)</dd></div><div><dt>Policy state</dt><dd>$(Encode $state)</dd></div>
<div><dt>Source path</dt><dd>$(Encode $reference.sourcePath)</dd></div><div><dt>Assignment ID</dt><dd>$(Encode $assignment)</dd></div>
<div><dt>Assignment filter ID / mode</dt><dd>$(Encode $filter)</dd></div></dl>$link</article></li>
"@
    }
    $references = $(if ($Report.references.Count) { '<ul class="references" role="list">' + ($referenceRows -join '') + '</ul>' } else { '<p>' + (Encode $Report.summary) + '</p>' })
    $manual = foreach ($check in $Report.manualChecks) {
        $target = ''
        if ($check.policyId) {
            $matched = @($Report.policyEvidence | Where-Object { $_.source -ceq $check.source -and $_.policyId -ceq $check.policyId })
            $target = '<p>Policy ID <code>' + (Encode $check.policyId) + '</code>.'
            if ($matched.Count) { $target += ' <a href="#' + (Encode $matched[0].evidenceId) + '">Inspect recorded settings</a>' }
            $target += '</p>'
        }
        '<li><h3>' + (Encode $check.title) + '</h3>' + $target + '<dl><dt>Attempted</dt><dd>' + (Encode $check.attempted) + '</dd><dt>Not established</dt><dd>' + (Encode $check.unknown) + '</dd><dt>Why it matters</dt><dd>' + (Encode $check.consequence) + '</dd><dt>Verify manually</dt><dd>' + (Encode $check.verify) + '</dd></dl></li>'
    }
    $contexts = foreach ($item in $Report.context) {
        $kind = switch -CaseSensitive ($item.kind) {
            'other_conditional_access_targeting' { 'Additional Conditional Access targeting, not evaluated for this group' }
            '#microsoft.graph.allDevicesAssignmentTarget' { 'Configured all-devices assignment target' }
            '#microsoft.graph.allLicensedUsersAssignmentTarget' { 'Configured all-licensed-users assignment target' }
            default { 'Additional targeting context; inspect the original settings' }
        }
        $matched = @($Report.policyEvidence | Where-Object { $_.source -ceq $item.source -and $_.policyId -ceq $item.policyId })
        $link = $(if ($matched.Count) { ' <a href="#' + (Encode $matched[0].evidenceId) + '">Inspect recorded settings</a>' } else { '' })
        '<li>' + (Encode $kind) + '. ' + (Label $item.source) + ' policy ID <code>' + (Encode $item.policyId) + '</code>.' + $link + '</li>'
    }
    $context = $(if ($Report.context.Count) { '<ul>' + ($contexts -join '') + '</ul><p>These targeting forms are context, not calculated group impact.</p>' } else { '<p>No additional targeting context was recorded. This is not proof that other targeting is absent.</p>' })
    $notes = foreach ($note in $Report.notes) { '<li><p class="note-text">' + (Encode $note.text) + '</p><p class="muted">Note saved ' + (Encode $note.savedAt) + '</p></li>' }
    $noteContent = $(if ($Report.notes.Count) { '<ul class="notes">' + ($notes -join '') + '</ul>' } else { '<p>No notes are attached to this observation.</p>' })
    $evidence = foreach ($policy in $Report.policyEvidence) {
        $json = ConvertTo-Json -InputObject $policy.configuration -Depth 64 -WarningAction Stop -ErrorAction Stop
        $policyName = $(if (-not [string]::IsNullOrWhiteSpace([string]$policy.configuration.displayName)) { [string]$policy.configuration.displayName } else { 'Policy name not recorded' })
        '<article id="' + (Encode $policy.evidenceId) + '" class="evidence"><h3>' + (Label $policy.source) + ': <bdi>' + (Encode $policyName) + '</bdi></h3><p>Policy ID ' + (Encode $policy.policyId) + '</p><details open><summary>Original recorded configuration</summary><pre><code>' + (Encode $json) + '</code></pre></details></article>'
    }
    $comparison = ''
    if ($Report.comparison) {
        $changes = $Report.comparison | ConvertTo-Json -Depth 64 -WarningAction Stop -ErrorAction Stop
        $fields = foreach ($change in $Report.comparison.policyChanges) {
            '<li>' + (Label $change.source) + ' policy <code>' + (Encode $change.policyId) + '</code>: differing recorded fields ' + (Encode ($change.changedFields -join ', ')) + '.</li>'
        }
        $fieldList = $(if ($Report.comparison.policyChanges.Count) { '<ul>' + ($fields -join '') + '</ul>' } else { '<p>No differences in matched referenced-policy configuration were observed.</p>' })
        $comparison = '<section id="comparison"><h2>Compared with an earlier observation</h2><p>' + (Encode $Report.comparison.summary) + '</p><p>Earlier collection: ' + (Encode $Report.comparison.earlierCollectedAt) + '. Earlier coverage: ' + (Encode $Report.comparison.coverageBefore) + '.</p>' + $fieldList + '<p>' + (Encode $Report.comparison.verification) + '</p><details open><summary>Recorded comparison details</summary><pre><code>' + (Encode $changes) + '</code></pre></details></section>'
    }
    $metadata = $(if ($Report.collection) { $Report.collection | ConvertTo-Json -Depth 64 -WarningAction Stop -ErrorAction Stop } else { 'Collection provenance was not supplied with this observation.' })
    return @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'sha256-$styleHash'; base-uri 'none'; form-action 'none'">
<meta name="referrer" content="no-referrer"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>$(Encode $name) — Handoff group investigation</title><style>$css</style></head>
<body><header><p class="wordmark">Handoff</p><p>Saved group investigation</p></header>
<nav aria-label="Report sections"><a href="#coverage">Coverage</a><a href="#references">References</a><a href="#verify">Manual checks</a><a href="#notes">Notes</a><a href="#evidence">Evidence</a></nav>
<main><h1><bdi>$(Encode $name)</bdi></h1><p class="lead">$(Encode $Report.summary)</p>
<dl class="identity"><div><dt>Tenant ID</dt><dd>$(Encode $Report.tenantId)</dd></div><div><dt>Group ID</dt><dd>$(Encode $Report.groupId)</dd></div>
<div><dt>Collected</dt><dd>$(Encode $Report.collectedAt)</dd></div><div><dt>Observation ID</dt><dd>$(Encode $Report.observationId)</dd></div></dl>
<details class="group-properties"><summary>Observed group properties</summary><dl>$($groupProperties -join '')</dl><p>These are recorded flags, not membership counts or an independent source-of-authority verification.</p></details>
<section id="coverage"><h2>Coverage and boundaries</h2><p class="coverage">$(Encode $status)</p>
<p>Only explicit group references in visible Conditional Access and Intune device-compliance evidence were evaluated. Membership, effective access, policy conflicts and safety to delete were not assessed.</p>
<div class="table-wrap" role="region" tabindex="0" aria-labelledby="source-caption"><table><caption id="source-caption">Recorded policy source outcomes</caption><thead><tr><th scope="col">Source</th><th scope="col">Read status</th><th scope="col">Pages</th><th scope="col">Failure code</th></tr></thead><tbody>$($sourceRows -join '')</tbody></table></div>
<h3>Other targeting context</h3>$context</section>
<section id="references"><h2>Observed group references</h2>$references</section>
<section id="verify"><h2>Manual checks before any change</h2><p>These follow-ups are not completed findings or approval to change a tenant.</p><ul class="checks">$($manual -join '')</ul></section>
$comparison
<section id="notes"><h2>Notes attached to this observation</h2><p>Unverified annotations, not independently collected findings. Later notes may postdate the collection.</p>$noteContent</section>
<section id="evidence"><h2>Recorded evidence</h2><p>Only policy definitions matched to referenced or flagged IDs are included. Invalid or missing IDs may prevent matching; inspect the saved raw snapshot for these gaps. This is not a full raw snapshot. Expand disclosure sections before printing in browsers that omit collapsed details.</p>$($evidence -join '')
<h3>Collection provenance</h3><pre><code>$(Encode $metadata)</code></pre></section>
</main><footer><p>$(Encode $Report.disclosure)</p><p>Saved $(Encode $Report.savedAt). Exported $(Encode $Report.generatedAt). Evaluator $(Encode $Report.evaluator).</p></footer></body></html>
"@
}

function Export-HandoffInvestigationReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][guid]$TenantId,
        [Parameter(Mandatory)][guid]$GroupId,
        [Parameter(Mandatory)][guid]$ObservationId,
        [Parameter(Mandatory)][string]$OutFile,
        [Parameter(Mandatory)][ValidateSet('Html','Json')][string]$Format,
        [guid]$CompareWithObservationId = [guid]::Empty
    )
    $provider = $null
    $drive = $null
    $destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile, [ref]$provider, [ref]$drive)
    if ($provider.Name -cne 'FileSystem' -or [IO.Path]::GetExtension($destination) -ine ('.' + $Format.ToLowerInvariant())) { throw 'Choose a filesystem output with the matching .html or .json extension.' }
    if (Test-Path -LiteralPath $destination) { throw 'Export destination already exists; choose a new filename.' }
    $parent = Get-Item -LiteralPath ([IO.Path]::GetDirectoryName($destination)) -Force -ErrorAction Stop
    if (-not $parent.PSIsContainer -or ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Choose an ordinary existing output directory.' }
    # Exported JSON must never become an unrelated journal record on the next reopen.
    $source = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $comparison = $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal })
    $sourceDirectory = [IO.Path]::TrimEndingDirectorySeparator($source.FullName)
    if ($parent.FullName.Equals($sourceDirectory, $comparison) -or $parent.FullName.StartsWith(($sourceDirectory + [IO.Path]::DirectorySeparatorChar), $comparison)) { throw 'Keep exports outside the investigation directory.' }
    $report = Get-HandoffInvestigationReport -Path $Path -TenantId $TenantId -GroupId $GroupId -ObservationId $ObservationId -CompareWithObservationId $CompareWithObservationId
    $text = $(if ($Format -ieq 'Html') { ConvertTo-HandoffReportHtml $report } else { ConvertTo-Json -InputObject $report -Depth 80 -WarningAction Stop -ErrorAction Stop })
    $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($text)
    if ($bytes.Length -gt $script:MaxExportBytes) { throw 'Report exceeds the 32 MiB export limit; no file was published.' }
    $temporary = Join-Path $parent.FullName ('.handoff-export-' + [guid]::NewGuid().ToString('D') + '.tmp')
    $created = $false
    try {
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $created = $true
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        [IO.File]::Move($temporary, $destination)
    } finally { if ($created -and [IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
    return Get-Item -LiteralPath $destination
}

Export-ModuleMember -Function Get-HandoffInvestigationReport,Export-HandoffInvestigationReport
