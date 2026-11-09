BeforeAll {
    Import-Module "$PSScriptRoot/../Handoff.Evidence.psm1" -Force
    Import-Module "$PSScriptRoot/../Handoff.Report.psm1" -Force
    $script:tenant = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    $script:group = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
    function New-ReportSnapshot {
        $snapshot = Get-Content "$PSScriptRoot/../examples/group-policy-snapshot.json" -Raw | ConvertFrom-Json -AsHashtable -DateKind String
        $snapshot.compliance.status = 'complete'
        return $snapshot
    }
}

Describe 'Offline reports from selected saved observations' {
    BeforeEach {
        $script:ids = @{TenantId=$tenant;GroupId=$group}
        $script:path = Join-Path $TestDrive ([guid]::NewGuid().ToString('D'))
        $script:snapshot = New-ReportSnapshot
        $script:first = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        $script:output = Join-Path $TestDrive ([guid]::NewGuid().ToString('D'))
    }
    It 'builds a scoped report with recorded identities, original settings and concrete follow-up checks' {
        $report = Get-HandoffInvestigationReport -Path $path @ids -ObservationId $first.id
        $report.reportType | Should -Be 'group_policy_investigation_v1'
        $report.observationId | Should -Be $first.id
        $report.groupId | Should -Be $group
        $report.group.displayName | Should -Be 'Support team'
        $report.references.Count | Should -Be 2
        $report.policyEvidence.Count | Should -Be 2
        $report.claim | Should -Be 'explicit_group_references_only'
        $report.manualChecks.code | Should -Contain 'reader_visibility_not_attested'
        $report.manualChecks.code | Should -Contain 'population_and_runtime_not_assessed'
        $report.manualChecks.code | Should -Contain 'other_workloads_not_checked'
        foreach ($check in $report.manualChecks) {
            $check.attempted | Should -Not -BeNullOrEmpty
            $check.unknown | Should -Not -BeNullOrEmpty
            $check.consequence | Should -Not -BeNullOrEmpty
            $check.verify | Should -Not -BeNullOrEmpty
        }
    }
    It 'keeps coverage gaps and retained references visible rather than claiming absence' {
        $snapshot.compliance.status = 'partial'
        $snapshot.compliance.failureCode = 'deadline_exceeded'
        $later = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        $report = Get-HandoffInvestigationReport -Path $path @ids -ObservationId $later.id
        $report.coverage | Should -Be 'incomplete'
        $report.references.Count | Should -Be 2
        $report.summary | Should -Match 'coverage is incomplete'
        $report.canConcludeNoExplicitReferences | Should -BeFalse
        $report.sources[1].failureCode | Should -Be 'deadline_exceeded'
        $report.manualChecks.code | Should -Contain 'source_incomplete'
    }
    It 'handles a complete zero-reference observation without inventing a blank reference' {
        $snapshot.conditionalAccess.policies = @()
        $snapshot.compliance.policies = @()
        $later = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        $report = Get-HandoffInvestigationReport -Path $path @ids -ObservationId $later.id
        $report.references.Count | Should -Be 0
        $report.policyEvidence.Count | Should -Be 0
        $report.summary | Should -Match 'two visible policy sources'
        $report.summary | Should -Match 'does not establish safe deletion'
    }
    It 'renders an honest empty-reference HTML section' {
        $snapshot.conditionalAccess.policies = @()
        $snapshot.compliance.policies = @()
        $later = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        $file = Export-HandoffInvestigationReport -Path $path @ids -ObservationId $later.id -OutFile ($output+'.html') -Format Html
        $html = Get-Content -LiteralPath $file.FullName -Raw
        $html | Should -Match 'No explicit group references observed in the two visible policy sources'
        $html | Should -Not -Match 'class="reference"|<bdi></bdi>'
    }
    It 'exports only attached notes and selected evidence, not other history or unrelated policies' {
        $null = Add-HandoffInvestigationNote -Path $path @ids -ObservationId $first.id -Text 'Earlier-only private note'
        $snapshot.conditionalAccess.policies[0].displayName = 'Current policy name'
        $snapshot.conditionalAccess.policies += @{id='eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';displayName='Unrelated tenant policy';conditions=@{users=@{includeGroups=@('ffffffff-ffff-ffff-ffff-ffffffffffff')}}}
        $later = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        $null = Add-HandoffInvestigationNote -Path $path @ids -ObservationId $later.id -Text 'Selected observation note'
        $report = Get-HandoffInvestigationReport -Path $path @ids -ObservationId $later.id
        $json = $report | ConvertTo-Json -Depth 80
        $report.notes.Count | Should -Be 1
        $report.notes[0].text | Should -Be 'Selected observation note'
        $json | Should -Not -Match 'Earlier-only private note|Unrelated tenant policy|Require MFA for support'
        $report.policyEvidence.Count | Should -Be 2
    }
    It 'retains unsupported targeting evidence and provides filter-definition checks' {
        $snapshot.compliance.policies[0].assignments[0].target.deviceAndAppManagementAssignmentFilterId = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'
        $snapshot.compliance.policies[0].assignments[0].target.deviceAndAppManagementAssignmentFilterType = 'include'
        $snapshot.compliance.policies += @{id='ffffffff-ffff-ffff-ffff-ffffffffffff';displayName='Unknown targeting';assignmentsStatus='complete';assignments=@(@{id='opaque';target=@{'@odata.type'='#microsoft.graph.futureTarget'}})}
        $later = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        $report = Get-HandoffInvestigationReport -Path $path @ids -ObservationId $later.id
        $report.manualChecks.code | Should -Contain 'filter_definition_not_collected'
        $report.issues.code | Should -Contain 'unsupported_assignment_target'
        $report.policyEvidence.Count | Should -Be 3
        $report.coverage | Should -Be 'incomplete'
        $file = Export-HandoffInvestigationReport -Path $path @ids -ObservationId $later.id -OutFile ($output+'.html') -Format Html
        $html = Get-Content -LiteralPath $file.FullName -Raw
        $html | Should -Match 'Policy ID <code>ffffffff-ffff-ffff-ffff-ffffffffffff</code>'
        $html | Should -Match 'href="#policy-3"'
    }
    It 'preserves broad targeting as context rather than computing effective group impact' {
        $snapshot.conditionalAccess.policies[0].conditions.users.includeUsers = @('All')
        $snapshot.compliance.policies += @{id='eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';displayName='Broad device policy';assignmentsStatus='complete';assignments=@(@{id='all';target=@{'@odata.type'='#microsoft.graph.allDevicesAssignmentTarget'}})}
        $later = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        $report = Get-HandoffInvestigationReport -Path $path @ids -ObservationId $later.id
        $report.context.Count | Should -Be 2
        $report.references.Count | Should -Be 2
        $report.policyEvidence.Count | Should -Be 3
        $file = Export-HandoffInvestigationReport -Path $path @ids -ObservationId $later.id -OutFile ($output+'.html') -Format Html
        $html = Get-Content -LiteralPath $file.FullName -Raw
        $html | Should -Match 'Configured all-devices assignment target|Additional Conditional Access targeting'
    }
    It 'adds an explicit comparison with both coverage states and cautious difference wording' {
        $snapshot.collectedAt = '2026-11-09T12:00:00Z'
        $snapshot.compliance.status = 'partial'
        $snapshot.compliance.policies = @()
        $later = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        $report = Get-HandoffInvestigationReport -Path $path @ids -ObservationId $later.id -CompareWithObservationId $first.id
        $report.comparison.notObservedLater.Count | Should -Be 1
        $report.comparison.coverageBefore | Should -Be 'complete_for_explicit_references'
        $report.comparison.coverageAfter | Should -Be 'incomplete'
        $report.comparison.verification | Should -Match 'not proof of creation, deletion'
    }
    It 'publishes structured JSON without wrapping it in the private journal envelope' {
        $file = Export-HandoffInvestigationReport -Path $path @ids -ObservationId $first.id -OutFile ($output+'.json') -Format Json
        $report = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable -DateKind String
        $report.schemaVersion | Should -Be 1
        $report.reportType | Should -Be 'group_policy_investigation_v1'
        $report.references.Count | Should -Be 2
        $report.Contains('content') | Should -BeFalse
        $report.Contains('snapshot') | Should -BeFalse
    }
    It 'escapes hostile names, states, filters, notes and raw JSON as text in HTML' {
        $attack = '</style></title><img src="https://example.invalid/leak" onerror="alert(1)"><script>alert(2)</script>'
        $snapshot.group.displayName = $attack
        $snapshot.conditionalAccess.policies[0].displayName = $attack
        $snapshot.conditionalAccess.policies[0].state = $attack
        $snapshot.compliance.policies[0].assignments[0].id = $attack
        $snapshot.compliance.policies[0].assignments[0].target.deviceAndAppManagementAssignmentFilterId = $attack
        $later = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        $null = Add-HandoffInvestigationNote -Path $path @ids -ObservationId $later.id -Text $attack
        $file = Export-HandoffInvestigationReport -Path $path @ids -ObservationId $later.id -OutFile ($output+'.html') -Format Html
        $html = Get-Content -LiteralPath $file.FullName -Raw
        $html | Should -Not -Match '<script\b|<img\b|<link\b|<iframe\b|<base\b'
        $html | Should -Match '&lt;script&gt;alert\(2\)&lt;/script&gt;'
        [regex]::Matches($html, '<style>').Count | Should -Be 1
        [regex]::Matches($html, '</title>').Count | Should -Be 1
    }
    It 'generates semantic self-contained HTML with a matching CSS hash and no external assets' {
        $file = Export-HandoffInvestigationReport -Path $path @ids -ObservationId $first.id -OutFile ($output+'.html') -Format Html
        $html = Get-Content -LiteralPath $file.FullName -Raw
        $html | Should -Match '<!DOCTYPE html>|<html lang="en">'
        [regex]::Matches($html, '<h1>').Count | Should -Be 1
        $html | Should -Match '<main>|<caption id="source-caption">|scope="col"|scope="row"'
        $html | Should -Match 'default-src &#39;none&#39;|default-src ''none'''
        $html | Should -Not -Match 'src=|@import|url\(|<script\b|unsafe-inline|<form\b'
        $css = [regex]::Match($html, '(?s)<style>(.*?)</style>').Groups[1].Value
        $css | Should -Not -Match '\r'
        $hash = [Convert]::ToBase64String([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($css)))
        $html.Contains("'sha256-$hash'") | Should -BeTrue
        $css | Should -Match '@media print|:focus-visible|overflow-wrap:anywhere'
        foreach ($link in [regex]::Matches($html, 'href="#(policy-\d+)"')) { $html.Contains('id="'+$link.Groups[1].Value+'"') | Should -BeTrue }
    }
    It 'exports unknown page counts and absent group names honestly' {
        $snapshot.Remove('group')
        $later = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        $file = Export-HandoffInvestigationReport -Path $path @ids -ObservationId $later.id -OutFile ($output+'.html') -Format Html
        $html = Get-Content -LiteralPath $file.FullName -Raw
        $html | Should -Match 'Selected group|Not recorded'
    }
    It 'labels missing names, Conditional Access states and compliance assignment IDs as unrecorded' {
        $snapshot.group.displayName = '  '
        $snapshot.conditionalAccess.policies[0].Remove('displayName')
        $snapshot.conditionalAccess.policies[0].Remove('state')
        $snapshot.compliance.policies[0].assignments[0].Remove('id')
        $later = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        $file = Export-HandoffInvestigationReport -Path $path @ids -ObservationId $later.id -OutFile ($output+'.html') -Format Html
        $html = Get-Content -LiteralPath $file.FullName -Raw
        $html | Should -Match '<bdi>Selected group</bdi>|<bdi>Policy name not recorded</bdi>'
        $html | Should -Match '<dt>Policy state</dt><dd>Not recorded</dd>'
        $html | Should -Match '<dt>Assignment ID</dt><dd>Not recorded</dd>'
    }
    It 'distinguishes collected false and null flags from properties that were never collected' {
        $snapshot.group.mailEnabled = $false
        $snapshot.group.onPremisesSyncEnabled = $null
        $snapshot.group.groupTypes = @()
        $later = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        $file = Export-HandoffInvestigationReport -Path $path @ids -ObservationId $later.id -OutFile ($output+'.html') -Format Html
        $html = Get-Content -LiteralPath $file.FullName -Raw
        $html | Should -Match '<dt>Mail enabled</dt><dd>false</dd>'
        $html | Should -Match '<dt>Directory sync enabled</dt><dd>Null returned</dd>'
        $html | Should -Match '<dt>Group types</dt><dd>\[\]</dd>'
        $html | Should -Match '<dt>Security enabled</dt><dd>Not collected</dd>'
    }
    It 'refuses to overwrite a destination or publish a misleading file extension' {
        $existing = $output+'.html'
        'Preserve existing export' | Set-Content -LiteralPath $existing
        { Export-HandoffInvestigationReport -Path $path @ids -ObservationId $first.id -OutFile $existing -Format Html } | Should -Throw '*already exists*'
        (Get-Content -LiteralPath $existing -Raw).Trim() | Should -Be 'Preserve existing export'
        { Export-HandoffInvestigationReport -Path $path @ids -ObservationId $first.id -OutFile ($output+'.html') -Format Json } | Should -Throw '*matching*'
    }
    It 'rejects output inside the journal or its descendants and leaves journal files unchanged' {
        $before = @(Get-ChildItem -LiteralPath $path -Filter '*.json' | Get-FileHash | ForEach-Object Hash | Sort-Object)
        $child = New-Item -ItemType Directory -Path (Join-Path $path 'exports')
        foreach ($destination in @((Join-Path $path 'report.json'),(Join-Path $child.FullName 'report.html'))) {
            $format = $(if ($destination.EndsWith('.json')) { 'Json' } else { 'Html' })
            { Export-HandoffInvestigationReport -Path $path @ids -ObservationId $first.id -OutFile $destination -Format $format } | Should -Throw '*outside*'
        }
        $after = @(Get-ChildItem -LiteralPath $path -Filter '*.json' | Get-FileHash | ForEach-Object Hash | Sort-Object)
        @(Compare-Object $before $after).Count | Should -Be 0
        (Get-HandoffInvestigation -Path $path @ids).observations.Count | Should -Be 1
    }
    It 'rejects foreign scope or missing observations before publishing any file' {
        { Export-HandoffInvestigationReport -Path $path -TenantId ([guid]::NewGuid()) -GroupId $group -ObservationId $first.id -OutFile ($output+'.json') -Format Json } | Should -Throw
        { Export-HandoffInvestigationReport -Path $path @ids -ObservationId ([guid]::NewGuid()) -OutFile ($output+'.json') -Format Json } | Should -Throw
        Test-Path -LiteralPath ($output+'.json') | Should -BeFalse
    }
    It 'rejects corrupt evidence before publishing a report' {
        '{' | Set-Content -LiteralPath (Join-Path $path ('observation-'+$first.id+'.json'))
        { Export-HandoffInvestigationReport -Path $path @ids -ObservationId $first.id -OutFile ($output+'.html') -Format Html } | Should -Throw
        Test-Path -LiteralPath ($output+'.html') | Should -BeFalse
    }
    It 'requires an existing output directory and rejects non-filesystem providers' {
        { Export-HandoffInvestigationReport -Path $path @ids -ObservationId $first.id -OutFile (Join-Path $output 'report.html') -Format Html } | Should -Throw
        { Export-HandoffInvestigationReport -Path $path @ids -ObservationId $first.id -OutFile 'Env:Report.html' -Format Html } | Should -Throw
        Test-Path -LiteralPath $output | Should -BeFalse
    }
    It 'does not publish truncated output when the export size limit fails' {
        try {
            & (Get-Module Handoff.Report) { $script:MaxExportBytes = 100 }
            { Export-HandoffInvestigationReport -Path $path @ids -ObservationId $first.id -OutFile ($output+'.json') -Format Json } | Should -Throw '*export limit*'
        } finally { & (Get-Module Handoff.Report) { $script:MaxExportBytes = 32MB } }
        Test-Path -LiteralPath ($output+'.json') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '.handoff-export-*.tmp' -Force).Count | Should -Be 0
    }
}
