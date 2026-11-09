BeforeAll {
    Import-Module "$PSScriptRoot/../Handoff.Evidence.psm1" -Force
    $script:tenant = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    $script:group = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
    function New-EvidenceSnapshot {
        $snapshot = Get-Content "$PSScriptRoot/../examples/group-policy-snapshot.json" -Raw | ConvertFrom-Json -AsHashtable -DateKind String
        $snapshot.groupId = $group
        $snapshot.compliance.status = 'complete'
        $snapshot.conditionalAccess.policies[0].grantControls = @{operator='OR';builtInControls=@('mfa')}
        return $snapshot
    }
    function Rewrite-TestRecord($File, $Change) {
        $envelope = Get-Content -LiteralPath $File -Raw | ConvertFrom-Json -AsHashtable -DateKind String
        $record = $envelope.content | ConvertFrom-Json -AsHashtable -DateKind String
        & $Change $record
        $envelope.content = $record | ConvertTo-Json -Compress -Depth 64
        $envelope.sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($envelope.content)))
        $envelope | ConvertTo-Json -Compress -Depth 4 | Set-Content -LiteralPath $File -Encoding utf8
    }
}

Describe 'Local append-only investigation evidence' {
    BeforeEach {
        $script:path = Join-Path $TestDrive ([guid]::NewGuid().ToString('D'))
        $script:ids = @{TenantId=$tenant;GroupId=$group}
        $script:snapshot = New-EvidenceSnapshot
    }
    It 'saves raw evidence and its evaluated result, then reopens it without the SDK' {
        $first = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        $saved = Get-HandoffInvestigation -Path $path @ids
        $saved.observations.Count | Should -Be 1
        $saved.observations[0].id | Should -Be $first.id
        $saved.observations[0].evaluation.references.Count | Should -Be 2
        $saved.observations[0].snapshot.conditionalAccess.policies[0].grantControls.builtInControls | Should -Contain 'mfa'
        $saved.notes.Count | Should -Be 0
    }
    It 'normalizes supplied JSON-compatible types before evaluating and saving' {
        $snapshot.conditionalAccess.policies[0] = [pscustomobject]$snapshot.conditionalAccess.policies[0]
        $first = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        $snapshot.conditionalAccess.policies[0].displayName = 'Changed only in caller memory'
        $saved = Get-HandoffInvestigation -Path $path @ids
        $saved.observations[0].evaluation.references.Count | Should -Be 2
        $saved.observations[0].snapshot.conditionalAccess.policies[0].displayName | Should -Be 'Require MFA for support'
        $first.snapshot.conditionalAccess.policies[0].displayName | Should -Be 'Require MFA for support'
    }
    It 'appends refresh observations and notes without rewriting earlier files' {
        $first = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        $file = Join-Path $path ('observation-' + $first.id + '.json')
        $hash = (Get-FileHash -LiteralPath $file).Hash
        $note = Add-HandoffInvestigationNote -Path $path @ids -ObservationId $first.id -Text 'Check the policy owner before changing targeting.'
        $noteFile = Join-Path $path ('note-' + $note.id + '.json')
        $noteHash = (Get-FileHash -LiteralPath $noteFile).Hash
        $snapshot.collectedAt = '2026-11-09T12:00:00Z'
        $snapshot.conditionalAccess.policies[0].state = 'disabled'
        $second = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        $saved = Get-HandoffInvestigation -Path $path @ids
        $saved.observations.Count | Should -Be 2
        $saved.notes.Count | Should -Be 1
        $saved.notes[0].observationId | Should -Be $first.id
        $saved.notes[0].text | Should -Match 'policy owner'
        $second.id | Should -Not -Be $first.id
        (Get-FileHash -LiteralPath $file).Hash | Should -Be $hash
        (Get-FileHash -LiteralPath $noteFile).Hash | Should -Be $noteHash
    }
    It 'rejects a foreign tenant, group or supplied snapshot without appending' {
        $null = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        { Get-HandoffInvestigation -Path $path -TenantId 'ffffffff-ffff-ffff-ffff-ffffffffffff' -GroupId $group } | Should -Throw
        { Get-HandoffInvestigation -Path $path -TenantId $tenant -GroupId 'ffffffff-ffff-ffff-ffff-ffffffffffff' } | Should -Throw
        $snapshot.groupId = 'ffffffff-ffff-ffff-ffff-ffffffffffff'
        { Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot } | Should -Throw
        (Get-HandoffInvestigation -Path $path @ids).observations.Count | Should -Be 1
    }
    It 'rejects arbitrary authentication/session fields before creating a directory' {
        $snapshot.accessToken = 'fictional-do-not-store'
        { Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot } | Should -Throw
        Test-Path -LiteralPath $path | Should -BeFalse
    }
    It 'requires an empty new directory and does not overwrite unrelated files' {
        $null = New-Item -ItemType Directory -Path $path
        'preserve me' | Set-Content -LiteralPath (Join-Path $path 'existing.txt')
        { Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot } | Should -Throw
        (Get-Content -LiteralPath (Join-Path $path 'existing.txt') -Raw).Trim() | Should -Be 'preserve me'
    }
    It 'rejects a missing observation, blank note and oversized note' {
        $first = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        { Add-HandoffInvestigationNote -Path $path @ids -ObservationId ([guid]::NewGuid()) -Text 'Do not attach elsewhere.' } | Should -Throw
        { Add-HandoffInvestigationNote -Path $path @ids -ObservationId $first.id -Text '   ' } | Should -Throw
        { Add-HandoffInvestigationNote -Path $path @ids -ObservationId $first.id -Text ('x' * 16001) } | Should -Throw
        (Get-HandoffInvestigation -Path $path @ids).notes.Count | Should -Be 0
    }
    It 'detects accidental changes instead of silently accepting altered history' {
        $first = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        $file = Join-Path $path ('observation-' + $first.id + '.json')
        $json = Get-Content -LiteralPath $file -Raw
        $json.Replace('Require MFA for support', 'Altered policy name') | Set-Content -LiteralPath $file -Encoding utf8
        { Get-HandoffInvestigation -Path $path @ids } | Should -Throw '*checksum*'
    }
    It 'rejects a copied record belonging to another investigation' {
        $first = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        $other = Join-Path $TestDrive ([guid]::NewGuid().ToString('D'))
        $null = Save-HandoffInvestigationObservation -Path $other @ids -Snapshot $snapshot
        Copy-Item -LiteralPath (Join-Path $path ('observation-' + $first.id + '.json')) -Destination $other
        { Get-HandoffInvestigation -Path $other @ids } | Should -Throw '*foreign*'
    }
    It 'rejects a rehashed inconsistent evaluation rather than trusting an absence claim' {
        $first = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        Rewrite-TestRecord (Join-Path $path ('observation-' + $first.id + '.json')) { param($record) $record.evaluation.canConcludeNoExplicitReferences = $true }
        { Get-HandoffInvestigation -Path $path @ids } | Should -Throw '*evaluation*'
    }
    It 'rejects truncated records and unsupported envelopes without repairing them' {
        $first = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        $file = Join-Path $path ('observation-' + $first.id + '.json')
        '{"schemaVersion":' | Set-Content -LiteralPath $file
        { Get-HandoffInvestigation -Path $path @ids } | Should -Throw
        @{schemaVersion=2;content='{}'} | ConvertTo-Json | Set-Content -LiteralPath $file
        { Get-HandoffInvestigation -Path $path @ids } | Should -Throw '*envelope*'
    }
    It 'never replaces an existing published filename and cleans only its own staging file' {
        $first = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        $file = Join-Path $path ('observation-' + $first.id + '.json')
        $hash = (Get-FileHash -LiteralPath $file).Hash
        { & (Get-Module Handoff.Evidence) { param($directory,$record) Write-HandoffEvidenceRecord $directory ('observation-' + $record.id + '.json') $record } $path ([hashtable]@{id=$first.id;kind='observation'}) } | Should -Throw
        (Get-FileHash -LiteralPath $file).Hash | Should -Be $hash
        @(Get-ChildItem -LiteralPath $path -Filter '*.tmp' -Force).Count | Should -Be 0
    }
    It 'fails safely while another writer holds the directory lock' {
        $first = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        $lock = [IO.File]::Open((Join-Path $path '.handoff-write.lock'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { { Add-HandoffInvestigationNote -Path $path @ids -ObservationId $first.id -Text 'Concurrent note' } | Should -Throw }
        finally { $lock.Dispose() }
        (Get-HandoffInvestigation -Path $path @ids).notes.Count | Should -Be 0
    }
    It 'does not publish a partial record when the per-record size limit fails' {
        $first = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        $limit = (Get-ChildItem -LiteralPath $path -Filter '*.json' | Measure-Object Length -Maximum).Maximum + 100
        try {
            & (Get-Module Handoff.Evidence) { param($limit) $script:MaxRecordBytes = $limit } $limit
            { Add-HandoffInvestigationNote -Path $path @ids -ObservationId $first.id -Text ('x' * 12000) } | Should -Throw '*record exceeds*'
        } finally { & (Get-Module Handoff.Evidence) { $script:MaxRecordBytes = 16MB } }
        (Get-HandoffInvestigation -Path $path @ids).notes.Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $path -Filter '*.tmp' -Force).Count | Should -Be 0
    }
    It 'refuses an append that would make the investigation unreadable by its total limit' {
        $first = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        $size = (Get-ChildItem -LiteralPath $path -Filter '*.json' | Measure-Object Length -Sum).Sum
        try {
            & (Get-Module Handoff.Evidence) { param($limit) $script:MaxInvestigationBytes = $limit } ($size + 100)
            { Add-HandoffInvestigationNote -Path $path @ids -ObservationId $first.id -Text 'Cannot exceed the total limit.' } | Should -Throw '*storage limit*'
        } finally { & (Get-Module Handoff.Evidence) { $script:MaxInvestigationBytes = 64MB } }
        (Get-HandoffInvestigation -Path $path @ids).notes.Count | Should -Be 0
    }
    It 'resolves relative paths against the PowerShell filesystem location' {
        Push-Location $TestDrive
        try {
            $relative = [guid]::NewGuid().ToString('D')
            $first = Save-HandoffInvestigationObservation -Path $relative @ids -Snapshot $snapshot
            $null = Add-HandoffInvestigationNote -Path $relative @ids -ObservationId $first.id -Text 'Relative-path note'
            (Get-HandoffInvestigation -Path $relative @ids).notes.Count | Should -Be 1
            Test-Path -LiteralPath (Join-Path $TestDrive "$relative/investigation.json") | Should -BeTrue
        } finally { Pop-Location }
    }
    It 'rejects non-filesystem provider paths' {
        { Save-HandoffInvestigationObservation -Path 'Env:HandoffEvidenceShouldNotExist' @ids -Snapshot $snapshot } | Should -Throw '*filesystem*'
    }
    It 'rejects a linked investigation directory before writing through it' {
        $target = Join-Path $TestDrive ([guid]::NewGuid().ToString('D'))
        $null = New-Item -ItemType Directory -Path $target
        $type = $(if ($IsWindows) { 'Junction' } else { 'SymbolicLink' })
        $null = New-Item -ItemType $type -Path $path -Target $target
        { Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot } | Should -Throw '*ordinary*'
        @(Get-ChildItem -LiteralPath $target -Force).Count | Should -Be 0
    }
    It 'rejects a rehashed note pointing at a missing observation' {
        $first = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        $note = Add-HandoffInvestigationNote -Path $path @ids -ObservationId $first.id -Text 'Original note'
        Rewrite-TestRecord (Join-Path $path ('note-' + $note.id + '.json')) { param($record) $record.observationId = [guid]::NewGuid().ToString('D') }
        { Get-HandoffInvestigation -Path $path @ids } | Should -Throw '*missing observation*'
    }
}

Describe 'Differences between saved observations' {
    BeforeEach {
        $script:path = Join-Path $TestDrive ([guid]::NewGuid().ToString('D'))
        $script:ids = @{TenantId=$tenant;GroupId=$group}
        $script:snapshot = New-EvidenceSnapshot
        $script:first = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        $snapshot.collectedAt = '2026-11-09T12:00:00Z'
    }
    It 'reports state, name and filter differences by stable reference identity' {
        $snapshot.conditionalAccess.policies[0].state = 'disabled'
        $snapshot.conditionalAccess.policies[0].displayName = 'REQUIRE MFA FOR SUPPORT'
        $snapshot.compliance.policies[0].assignments[0].target.deviceAndAppManagementAssignmentFilterType = 'include'
        $snapshot.compliance.policies[0].assignments[0].target.deviceAndAppManagementAssignmentFilterId = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'
        $second = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        $diff = Compare-HandoffInvestigationObservation -Path $path @ids -EarlierObservationId $first.id -LaterObservationId $second.id
        $diff.changedReferences.Count | Should -Be 2
        $diff.policyChanges.Count | Should -Be 2
        $diff.newlyObserved.Count | Should -Be 0
        $diff.notObservedLater.Count | Should -Be 0
        $diff.summary | Should -Match 'changed references: 2'
        $diff.claim | Should -Be 'differences_between_observations_only'
    }
    It 'shows a policy-setting difference even when reference counts and targeting stay the same' {
        $snapshot.conditionalAccess.policies[0].grantControls.operator = 'AND'
        $second = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        $diff = Compare-HandoffInvestigationObservation -Path $path @ids -EarlierObservationId $first.id -LaterObservationId $second.id
        $diff.changedReferences.Count | Should -Be 0
        $diff.policyChanges.Count | Should -Be 1
        $diff.policyChanges[0].before.grantControls.operator | Should -Be 'OR'
        $diff.policyChanges[0].after.grantControls.operator | Should -Be 'AND'
        $diff.policyChanges[0].changedFields | Should -Contain 'grantControls'
    }
    It 'never calls missing references deletions when later collection is partial' {
        $snapshot.conditionalAccess.status = 'partial'
        $snapshot.conditionalAccess.policies = @()
        $snapshot.compliance.policies = @()
        $second = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        $diff = Compare-HandoffInvestigationObservation -Path $path @ids -EarlierObservationId $first.id -LaterObservationId $second.id
        $diff.notObservedLater.Count | Should -Be 2
        $diff.coverageAfter | Should -Be 'incomplete'
        $diff.verification | Should -Match 'not proof of creation, deletion'
        $diff.summary | Should -Not -Match 'removed|deleted|safe'
    }
    It 'reports newly observed references without claiming they were just created' {
        $snapshot.conditionalAccess.policies[0].conditions.users.excludeGroups = @($group)
        $second = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        $diff = Compare-HandoffInvestigationObservation -Path $path @ids -EarlierObservationId $first.id -LaterObservationId $second.id
        $diff.newlyObserved.Count | Should -Be 1
        $diff.newlyObserved[0].relation | Should -Be 'exclude'
    }
    It 'ignores object-key ordering but retains case-sensitive value changes' {
        $old = $snapshot.conditionalAccess.policies[0]
        $snapshot.conditionalAccess.policies[0] = [ordered]@{state=$old.state;grantControls=$old.grantControls;conditions=$old.conditions;displayName=$old.displayName;id=$old.id}
        $second = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        $diff = Compare-HandoffInvestigationObservation -Path $path @ids -EarlierObservationId $first.id -LaterObservationId $second.id
        $diff.policyChanges.Count | Should -Be 0
        $diff.changedReferences.Count | Should -Be 0
    }
    It 'rejects missing, identical and reverse-time comparison selections' {
        $second = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        { Compare-HandoffInvestigationObservation -Path $path @ids -EarlierObservationId $first.id -LaterObservationId $first.id } | Should -Throw
        { Compare-HandoffInvestigationObservation -Path $path @ids -EarlierObservationId $first.id -LaterObservationId ([guid]::NewGuid()) } | Should -Throw
        { Compare-HandoffInvestigationObservation -Path $path @ids -EarlierObservationId $second.id -LaterObservationId $first.id } | Should -Throw
    }
    It 'refuses ambiguous duplicate assignment identities instead of losing one in the diff' {
        $snapshot.compliance.policies[0].assignments += $snapshot.compliance.policies[0].assignments[0]
        $second = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        { Compare-HandoffInvestigationObservation -Path $path @ids -EarlierObservationId $first.id -LaterObservationId $second.id } | Should -Throw '*Duplicate reference*'
    }
    It 'shows collection coverage changes separately from unchanged policy configuration' {
        $snapshot.compliance.policies[0].assignmentsStatus = 'partial'
        $snapshot.compliance.policies[0].assignmentsCollection = @{pagesRead=1;failureCode='deadline_exceeded'}
        $second = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
        $diff = Compare-HandoffInvestigationObservation -Path $path @ids -EarlierObservationId $first.id -LaterObservationId $second.id
        $diff.coverageAfter | Should -Be 'incomplete'
        $diff.policyChanges.Count | Should -Be 0
        $diff.changedReferences.Count | Should -Be 0
    }
}
