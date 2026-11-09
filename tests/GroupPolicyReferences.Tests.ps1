BeforeAll {
    Import-Module "$PSScriptRoot/../Handoff.Investigation.psm1" -Force
    $script:tenant = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    $script:group = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
    function New-Snapshot {
        @{ schemaVersion = 1; tenantId = $tenant; collectedAt = '2026-11-08T12:00:00Z'
           conditionalAccess = @{ status = 'complete'; policies = @() }
           compliance = @{ status = 'complete'; policies = @() } }
    }
    function New-CA($id = 'cccccccc-cccc-cccc-cccc-cccccccccccc') {
        @{ id = $id; displayName = 'Same name'; state = 'disabled'
           conditions = @{ users = @{ includeGroups = @($group); excludeGroups = @($group) } } }
    }
}
Describe 'Offline Handoff group-policy references' {
    It 'preserves includes and exclusions even for disabled policies without predicting impact' {
        $snapshot = New-Snapshot
        $snapshot.conditionalAccess.policies = @(New-CA)
        $result = Get-HandoffGroupPolicyReference -TenantId $tenant -GroupId $group -Snapshot $snapshot
        $result.references.Count | Should -Be 2
        $result.references.relation | Should -Contain 'include'
        $result.references.relation | Should -Contain 'exclude'
        $result.references[0].policyState | Should -Be 'disabled'
        $result.references[0].sourcePath | Should -Be 'conditions.users.includeGroups'
        $result.claim | Should -Be 'explicit_group_references_only'
        $result.canConcludeNoExplicitReferences | Should -BeFalse
    }
    It 'uses group and policy IDs rather than matching display names' {
        $snapshot = New-Snapshot
        $first = New-CA
        $second = New-CA 'dddddddd-dddd-dddd-dddd-dddddddddddd'
        $second.conditions.users.includeGroups = @('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee')
        $second.conditions.users.excludeGroups = @()
        $snapshot.conditionalAccess.policies = @($first, $second)
        $result = Get-HandoffGroupPolicyReference -TenantId $tenant -GroupId $group.ToUpperInvariant() -Snapshot $snapshot
        $result.references.Count | Should -Be 2
        $result.references.policyId | Should -Not -Contain $second.id
    }
    It 'recognises compliance inclusion and exclusion and retains assignment filters' {
        $snapshot = New-Snapshot
        $snapshot.compliance.policies = @(@{ id = 'cccccccc-cccc-cccc-cccc-cccccccccccc'; displayName = 'Compliance'
            assignmentsStatus = 'complete'; assignments = @(
                @{ id = 'assignment-a'; target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $group
                    deviceAndAppManagementAssignmentFilterId = 'dddddddd-dddd-dddd-dddd-dddddddddddd'; deviceAndAppManagementAssignmentFilterType = 'include' } }
                @{ id = 'assignment-b'; target = @{ '@odata.type' = '#microsoft.graph.exclusionGroupAssignmentTarget'; groupId = $group } }
            ) })
        $result = Get-HandoffGroupPolicyReference -TenantId $tenant -GroupId $group -Snapshot $snapshot
        $result.references.Count | Should -Be 2
        $result.references.relation | Should -Contain 'exclude'
        $result.references[0].filter.id | Should -Be 'dddddddd-dddd-dddd-dddd-dddddddddddd'
        $result.references[0].assignmentId | Should -Be 'assignment-a'
    }
    It 'keeps broad targeting as context rather than inventing a group reference' {
        $snapshot = New-Snapshot
        $ca = New-CA
        $ca.conditions.users = @{ includeUsers = @('All'); includeRoles = @('some-role') }
        $snapshot.conditionalAccess.policies = @($ca)
        $snapshot.compliance.policies = @(@{ id = 'dddddddd-dddd-dddd-dddd-dddddddddddd'; displayName = 'All devices'
            assignmentsStatus = 'complete'; assignments = @(@{ id = 'a'; target = @{ '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget' } }) })
        $result = Get-HandoffGroupPolicyReference -TenantId $tenant -GroupId $group -Snapshot $snapshot
        $result.references.Count | Should -Be 0
        $result.context.Count | Should -Be 2
        $result.context[0].kind | Should -Be 'other_conditional_access_targeting'
        $result.canConcludeNoExplicitReferences | Should -BeTrue
    }
    It 'withholds an absence conclusion on partial or unavailable source collection' -ForEach @('partial', 'unavailable') {
        $snapshot = New-Snapshot
        $snapshot.conditionalAccess.status = $_
        $result = Get-HandoffGroupPolicyReference -TenantId $tenant -GroupId $group -Snapshot $snapshot
        $result.coverage | Should -Be 'incomplete'
        $result.canConcludeNoExplicitReferences | Should -BeFalse
        $result.issues.code | Should -Contain 'source_incomplete'
    }
    It 'does not turn missing assignments or unknown assignment types into a clean result' {
        $snapshot = New-Snapshot
        $snapshot.compliance.policies = @(
            @{ id = 'cccccccc-cccc-cccc-cccc-cccccccccccc'; assignmentsStatus = 'partial' }
            @{ id = 'dddddddd-dddd-dddd-dddd-dddddddddddd'; assignmentsStatus = 'complete'; assignments = @(
                @{ id = 'unknown'; target = @{ '@odata.type' = '#microsoft.graph.futureTarget'; groupId = $group } }) }
        )
        $result = Get-HandoffGroupPolicyReference -TenantId $tenant -GroupId $group -Snapshot $snapshot
        $result.canConcludeNoExplicitReferences | Should -BeFalse
        $result.issues.code | Should -Contain 'assignments_incomplete'
        $result.issues.code | Should -Contain 'unsupported_assignment_target'
        $result.references.Count | Should -Be 0
    }
    It 'keeps known references when another policy is malformed or duplicated' {
        $snapshot = New-Snapshot
        $ca = New-CA
        $snapshot.conditionalAccess.policies = @($ca, $ca, @{ id = 'not-an-id' })
        $result = Get-HandoffGroupPolicyReference -TenantId $tenant -GroupId $group -Snapshot $snapshot
        $result.references.Count | Should -Be 2
        $result.coverage | Should -Be 'incomplete'
        $result.issues.code | Should -Contain 'duplicate_policy'
        $result.issues.code | Should -Contain 'invalid_policy'
    }
    It 'rejects a foreign tenant and invalid snapshot metadata before evaluating' {
        $snapshot = New-Snapshot
        $snapshot.tenantId = 'ffffffff-ffff-ffff-ffff-ffffffffffff'
        { Get-HandoffGroupPolicyReference -TenantId $tenant -GroupId $group -Snapshot $snapshot } | Should -Throw
        $snapshot = New-Snapshot
        $snapshot.schemaVersion = 2
        { Get-HandoffGroupPolicyReference -TenantId $tenant -GroupId $group -Snapshot $snapshot } | Should -Throw
        $snapshot = New-Snapshot
        $snapshot.collectedAt = 'invalid'
        { Get-HandoffGroupPolicyReference -TenantId $tenant -GroupId $group -Snapshot $snapshot } | Should -Throw
    }
    It 'defaults missing source data to incomplete and does not mutate its input' {
        $snapshot = New-Snapshot
        $snapshot.Remove('compliance')
        $before = $snapshot | ConvertTo-Json -Depth 20 -Compress
        $result = Get-HandoffGroupPolicyReference -TenantId $tenant -GroupId $group -Snapshot $snapshot
        $result.coverage | Should -Be 'incomplete'
        ($snapshot | ConvertTo-Json -Depth 20 -Compress) | Should -Be $before
    }
}
Describe 'Snapshot boundary cases' {
    It 'evaluates a JSON round trip and preserves incomplete known evidence' {
        $snapshot = New-Snapshot
        $snapshot.conditionalAccess.status = 'partial'
        $snapshot.conditionalAccess.policies = @(New-CA)
        $json = $snapshot | ConvertTo-Json -Depth 20
        $result = Get-HandoffGroupPolicyReference -TenantId $tenant -GroupId $group -Snapshot ($json | ConvertFrom-Json -AsHashtable)
        $result.references.Count | Should -Be 2
        $result.coverage | Should -Be 'incomplete'
    }
    It 'does not accept invalid group-list shapes or IDs as evidence of absence' {
        $snapshot = New-Snapshot
        $ca = New-CA
        $ca.conditions.users.includeGroups = $group
        $ca.conditions.users.excludeGroups = @('invalid')
        $snapshot.conditionalAccess.policies = @($ca)
        $result = Get-HandoffGroupPolicyReference -TenantId $tenant -GroupId $group -Snapshot $snapshot
        $result.canConcludeNoExplicitReferences | Should -BeFalse
        $result.issues.code | Should -Contain 'invalid_group_list'
        $result.issues.code | Should -Contain 'invalid_group_id'
    }
    It 'requires an unambiguous timestamp with an explicit UTC or offset designator' {
        $snapshot = New-Snapshot
        $snapshot.collectedAt = '2026-11-08'
        { Get-HandoffGroupPolicyReference -TenantId $tenant -GroupId $group -Snapshot $snapshot } | Should -Throw
    }
}
