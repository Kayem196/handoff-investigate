BeforeAll {
    # Transport boundary substitutes only; no authentication or external requests.
    function global:Get-MgContext { throw 'Unmocked context access' }
    Import-Module "$PSScriptRoot/../Handoff.Collection.psm1" -Force
    Import-Module "$PSScriptRoot/../Handoff.Investigation.psm1" -Force
}
Describe 'Bounded read-only policy collection' {
    BeforeEach {
        $script:tenant = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        $script:group = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        $script:policy = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
        $script:requests = [System.Collections.Generic.List[string]]::new()
        $script:binding = @{ TenantId = $tenant; ClientId = 'dddddddd-dddd-dddd-dddd-dddddddddddd'; Account = 'operator@example.invalid'; AuthType = 'Delegated'; Environment = 'Global'; ContextScope = 'Process' }
        $script:caPath = 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies'
        $script:compliancePath = 'https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies'
        Mock Get-MgContext -ModuleName Handoff.Collection { $script:binding }
        Mock Invoke-HandoffGraphRequest -ModuleName Handoff.Collection {
            param($Uri, $State)
            $script:requests.Add([string]$Uri)
            if ([string]$Uri -like '*/groups/*') { return @{ id = $script:group; displayName = 'Selected group' } }
            return @{ value = @() }
        }
    }
    It 'resolves the exact group and returns an evaluator-compatible empty snapshot' {
        $result = Get-HandoffPolicySnapshot -TenantId $tenant -GroupId $group
        $result.group.id | Should -Be $group
        $result.conditionalAccess.status | Should -Be 'complete'
        $result.compliance.status | Should -Be 'complete'
        $result.collection.requestCount | Should -Be 3
        $result.collection.limits.responseBytes | Should -Be 4MB
        $result.collection.limits.durationSeconds | Should -Be 120
        $result.collection.transport | Should -Be 'sdk_2.38.1_streamed_request_options_v1'
        $evaluated = Get-HandoffGroupPolicyReference -TenantId $tenant -GroupId $group -Snapshot $result
        $evaluated.canConcludeNoExplicitReferences | Should -BeTrue
    }
    It 'reads every CA and nested compliance assignment page' {
        Mock Invoke-HandoffGraphRequest -ModuleName Handoff.Collection {
            param($Method, $Uri, $OutputType)
            $script:requests.Add([string]$Uri)
            if ([string]$Uri -like '*/groups/*') { return @{ id = $script:group } }
            if ([string]$Uri -eq $script:caPath) { return @{ value = @(@{ id = $script:policy; state = 'enabled'; conditions = @{ users = @{ includeGroups = @($script:group) } } }); '@odata.nextLink' = $script:caPath + '?$skiptoken=next' } }
            if ([string]$Uri -eq $script:compliancePath) { return @{ value = @(@{ id = $script:policy; displayName = 'Compliance' }) } }
            if ([string]$Uri -like '*/assignments') { return @{ value = @(); '@odata.nextLink' = [string]$Uri + '?$skiptoken=next' } }
            if ([string]$Uri -like '*/assignments?*') { return @{ value = @(@{ id = 'assignment'; target = @{ '@odata.type' = '#microsoft.graph.exclusionGroupAssignmentTarget'; groupId = $script:group } }) } }
            return @{ value = @() }
        }
        $result = Get-HandoffPolicySnapshot -TenantId $tenant -GroupId $group
        $result.conditionalAccess.pagesRead | Should -Be 2
        $result.compliance.policies[0].assignmentsStatus | Should -Be 'complete'
        $result.compliance.policies[0].assignments.Count | Should -Be 1
        $evaluated = Get-HandoffGroupPolicyReference -TenantId $tenant -GroupId $group -Snapshot $result
        $evaluated.references.Count | Should -Be 2
        $evaluated.references.relation | Should -Contain 'exclude'
    }
    It 'collects filter metadata that the v1 assignment contract omits' {
        Mock Invoke-HandoffGraphRequest -ModuleName Handoff.Collection {
            param($Method, $Uri)
            if ([string]$Uri -like '*/groups/*') { return @{ id = $script:group } }
            if ([string]$Uri -eq $script:compliancePath) { return @{ value = @(@{ id = $script:policy }) } }
            $target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $script:group }
            if ([string]$Uri -like '*/assignments') {
                if ([string]$Uri -like 'https://graph.microsoft.com/beta/*') {
                    $target.deviceAndAppManagementAssignmentFilterId = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'
                    $target.deviceAndAppManagementAssignmentFilterType = 'include'
                }
                return @{ value = @(@{ id = 'filtered-assignment'; target = $target }) }
            }
            return @{ value = @() }
        }
        $snapshot = Get-HandoffPolicySnapshot -TenantId $tenant -GroupId $group
        $result = Get-HandoffGroupPolicyReference -TenantId $tenant -GroupId $group -Snapshot $snapshot
        $result.references[0].filter.id | Should -Be 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'
        $result.references[0].filter.type | Should -Be 'include'
        $snapshot.collection.source | Should -Be 'graph_v1_beta_delegated_policy_snapshot_v1'
        $snapshot.collection.apiVersions.complianceAssignments | Should -Be 'beta'
    }
    It 'rejects beta assignment pagination that changes version or policy' -ForEach @(
        'https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies/cccccccc-cccc-cccc-cccc-cccccccccccc/assignments',
        'https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies/eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee/assignments'
    ) {
        $script:badAssignmentLink = $_
        Mock Invoke-HandoffGraphRequest -ModuleName Handoff.Collection {
            param($Method, $Uri)
            $script:requests.Add([string]$Uri)
            if ([string]$Uri -like '*/groups/*') { return @{ id = $script:group } }
            if ([string]$Uri -eq $script:compliancePath) { return @{ value = @(@{ id = $script:policy }) } }
            if ([string]$Uri -like '*/assignments') {
                return @{ value = @(@{ id = 'known'; target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $script:group } }); '@odata.nextLink' = $script:badAssignmentLink }
            }
            return @{ value = @() }
        }
        $snapshot = Get-HandoffPolicySnapshot -TenantId $tenant -GroupId $group
        $snapshot.compliance.policies[0].assignmentsStatus | Should -Be 'partial'
        $snapshot.compliance.policies[0].assignmentsCollection.failureCode | Should -Be 'invalid_next_link'
        $requests.Count | Should -Be 4
        $result = Get-HandoffGroupPolicyReference -TenantId $tenant -GroupId $group -Snapshot $snapshot
        $result.references.Count | Should -Be 1
        $result.canConcludeNoExplicitReferences | Should -BeFalse
    }
    It 'rejects foreign or non-delegated context before any Graph read' {
        $binding.TenantId = 'ffffffff-ffff-ffff-ffff-ffffffffffff'
        { Get-HandoffPolicySnapshot -TenantId $tenant -GroupId $group } | Should -Throw
        $requests.Count | Should -Be 0
        $binding.TenantId = $tenant
        $binding.AuthType = 'AppOnly'
        { Get-HandoffPolicySnapshot -TenantId $tenant -GroupId $group } | Should -Throw
        $requests.Count | Should -Be 0
    }
    It 'withholds the whole result when context changes during a request' {
        Mock Invoke-HandoffGraphRequest -ModuleName Handoff.Collection {
            $script:binding.ClientId = 'ffffffff-ffff-ffff-ffff-ffffffffffff'
            return @{ id = $script:group }
        }
        { Get-HandoffPolicySnapshot -TenantId $tenant -GroupId $group } | Should -Throw
    }
    It 'rejects a response for a different selected group' {
        Mock Invoke-HandoffGraphRequest -ModuleName Handoff.Collection { @{ id = $script:policy } }
        { Get-HandoffPolicySnapshot -TenantId $tenant -GroupId $group } | Should -Throw
    }
    It 'retains completed pages but never follows an off-resource nextLink' -ForEach @(
        'https://attacker.invalid/v1.0/identity/conditionalAccess/policies',
        'http://graph.microsoft.com/v1.0/identity/conditionalAccess/policies',
        'https://graph.microsoft.com/v1.0/users',
        'https://user@graph.microsoft.com/v1.0/identity/conditionalAccess/policies',
        'https://graph.microsoft.com:444/v1.0/identity/conditionalAccess/policies',
        'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies#fragment'
    ) {
        $script:badLink = $_
        Mock Invoke-HandoffGraphRequest -ModuleName Handoff.Collection {
            param($Method, $Uri)
            $script:requests.Add([string]$Uri)
            if ([string]$Uri -like '*/groups/*') { return @{ id = $script:group } }
            if ([string]$Uri -eq $script:caPath) { return @{ value = @(@{ id = $script:policy }); '@odata.nextLink' = $script:badLink } }
            return @{ value = @() }
        }
        $result = Get-HandoffPolicySnapshot -TenantId $tenant -GroupId $group
        $result.conditionalAccess.status | Should -Be 'partial'
        $result.conditionalAccess.policies.Count | Should -Be 1
        $result.conditionalAccess.failureCode | Should -Be 'invalid_next_link'
        $requests.Count | Should -Be 3
    }
    It 'bounds cyclic pagination and retains the first page' {
        Mock Invoke-HandoffGraphRequest -ModuleName Handoff.Collection {
            param($Method, $Uri)
            if ([string]$Uri -like '*/groups/*') { return @{ id = $script:group } }
            if ([string]$Uri -eq $script:caPath) { return @{ value = @(@{ id = $script:policy }); '@odata.nextLink' = $script:caPath } }
            return @{ value = @() }
        }
        $result = Get-HandoffPolicySnapshot -TenantId $tenant -GroupId $group
        $result.conditionalAccess.failureCode | Should -Be 'pagination_cycle'
        $result.conditionalAccess.pagesRead | Should -Be 1
    }
    It 'marks assignment failure explicitly and discards private SDK errors' {
        Mock Invoke-HandoffGraphRequest -ModuleName Handoff.Collection {
            param($Method, $Uri)
            if ([string]$Uri -like '*/groups/*') { return @{ id = $script:group } }
            if ([string]$Uri -eq $script:compliancePath) { return @{ value = @(@{ id = $script:policy }) } }
            if ([string]$Uri -like '*/assignments') { throw 'private token and issuer response' }
            return @{ value = @() }
        }
        $result = Get-HandoffPolicySnapshot -TenantId $tenant -GroupId $group
        $result.compliance.status | Should -Be 'partial'
        $result.compliance.policies[0].assignmentsStatus | Should -Be 'unavailable'
        ($result | ConvertTo-Json -Depth 20) | Should -Not -Match 'private|token|issuer response'
        (Get-HandoffGroupPolicyReference -TenantId $tenant -GroupId $group -Snapshot $result).canConcludeNoExplicitReferences | Should -BeFalse
    }
    It 'bounds page and SDK invocation counts' {
        Mock Invoke-HandoffGraphRequest -ModuleName Handoff.Collection {
            param($Method, $Uri)
            if ([string]$Uri -like '*/groups/*') { return @{ id = $script:group } }
            if ([string]$Uri -eq $script:caPath) { return @{ value = @(); '@odata.nextLink' = $script:caPath + '?$skiptoken=next' } }
            return @{ value = @() }
        }
        $result = Get-HandoffPolicySnapshot -TenantId $tenant -GroupId $group -MaxPages 1 -MaxRequests 2
        $result.conditionalAccess.failureCode | Should -Be 'page_limit'
        $result.compliance.failureCode | Should -Be 'request_limit'
        $result.collection.requestCount | Should -Be 2
    }
    It 'does not accept a malformed page as an empty successful collection' {
        Mock Invoke-HandoffGraphRequest -ModuleName Handoff.Collection {
            param($Method, $Uri)
            if ([string]$Uri -like '*/groups/*') { return @{ id = $script:group } }
            return @{ value = @{ id = 'not-an-array' } }
        }
        $result = Get-HandoffPolicySnapshot -TenantId $tenant -GroupId $group
        $result.conditionalAccess.status | Should -Be 'unavailable'
        $result.conditionalAccess.failureCode | Should -Be 'invalid_page'
    }

    It 'bounds retained items across policy families and assignment collections' {
        Mock Invoke-HandoffGraphRequest -ModuleName Handoff.Collection {
            param($Method, $Uri)
            if ([string]$Uri -like '*/groups/*') { return @{ id = $script:group } }
            if ([string]$Uri -eq $script:caPath) { return @{ value = @(@{ id = $script:policy }) } }
            return @{ value = @(@{ id = $script:policy }, @{ id = $script:group }) }
        }
        $result = Get-HandoffPolicySnapshot -TenantId $tenant -GroupId $group -MaxItems 2
        $result.collection.retainedItems | Should -Be 2
        $result.compliance.status | Should -Be 'partial'
        $result.compliance.failureCode | Should -Be 'item_limit'
        $result.compliance.policies.Count | Should -Be 1
        $result.compliance.policies[0].assignmentsStatus | Should -Be 'unavailable'
    }
    It 'retains the first assignment page when a later assignment read fails' {
        Mock Invoke-HandoffGraphRequest -ModuleName Handoff.Collection {
            param($Method, $Uri)
            if ([string]$Uri -like '*/groups/*') { return @{ id = $script:group } }
            if ([string]$Uri -eq $script:compliancePath) { return @{ value = @(@{ id = $script:policy }) } }
            if ([string]$Uri -like '*/assignments') { return @{ value = @(@{ id = 'known'; target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $script:group } }); '@odata.nextLink' = [string]$Uri + '?$skiptoken=next' } }
            if ([string]$Uri -like '*/assignments?*') { throw 'private failure body' }
            return @{ value = @() }
        }
        $result = Get-HandoffPolicySnapshot -TenantId $tenant -GroupId $group
        $result.compliance.policies[0].assignmentsStatus | Should -Be 'partial'
        $evaluated = Get-HandoffGroupPolicyReference -TenantId $tenant -GroupId $group -Snapshot $result
        $evaluated.references.Count | Should -Be 1
        $evaluated.coverage | Should -Be 'incomplete'
    }
    It 'treats missing or invalid policy IDs as incomplete without requesting their assignments' {
        Mock Invoke-HandoffGraphRequest -ModuleName Handoff.Collection {
            param($Method, $Uri)
            $script:requests.Add([string]$Uri)
            if ([string]$Uri -like '*/groups/*') { return @{ id = $script:group } }
            if ([string]$Uri -eq $script:compliancePath) { return @{ value = @(@{ id = '../../users' }) } }
            return @{ value = @() }
        }
        $result = Get-HandoffPolicySnapshot -TenantId $tenant -GroupId $group
        $result.compliance.failureCode | Should -Be 'invalid_policy'
        $requests.Count | Should -Be 3
    }

    It 'rejects an error envelope even if it contains an empty value array' {
        Mock Invoke-HandoffGraphRequest -ModuleName Handoff.Collection {
            param($Method, $Uri)
            if ([string]$Uri -like '*/groups/*') { return @{ id = $script:group } }
            return @{ value = @(); error = @{ message = 'private issuer error' } }
        }
        $result = Get-HandoffPolicySnapshot -TenantId $tenant -GroupId $group
        $result.conditionalAccess.failureCode | Should -Be 'invalid_page'
        (Get-HandoffGroupPolicyReference -TenantId $tenant -GroupId $group -Snapshot $result).canConcludeNoExplicitReferences | Should -BeFalse
    }

    It 'retains earlier evidence and fixed transport failure codes' -ForEach @('response_limit', 'redirect_rejected', 'unsupported_sdk') {
        $script:transportFailure = $_
        Mock Invoke-HandoffGraphRequest -ModuleName Handoff.Collection {
            param($Uri)
            if ([string]$Uri -like '*/groups/*') { return @{id=$script:group} }
            if ([string]$Uri -eq $script:caPath) {
                return @{value=@(@{id=$script:policy}); '@odata.nextLink'=$script:caPath+'?$skiptoken=next'}
            }
            if ([string]$Uri -like '*skiptoken*') { throw [InvalidOperationException]::new($script:transportFailure) }
            return @{value=@()}
        }
        $result = Get-HandoffPolicySnapshot -TenantId $tenant -GroupId $group
        $result.conditionalAccess.failureCode | Should -Be $transportFailure
        $result.conditionalAccess.status | Should -Be 'partial'
        $result.conditionalAccess.policies.Count | Should -Be 1
        $result.compliance.status | Should -Be 'complete'
        (Get-HandoffGroupPolicyReference -TenantId $tenant -GroupId $group -Snapshot $result).canConcludeNoExplicitReferences | Should -BeFalse
    }
    It 'stops further reads at the shared deadline and drops the interrupted page' {
        Mock Invoke-HandoffGraphRequest -ModuleName Handoff.Collection {
            param($Uri)
            $script:requests.Add([string]$Uri)
            if ([string]$Uri -like '*/groups/*') { return @{id=$script:group} }
            Start-Sleep -Milliseconds 1100
            return @{value=@(@{id=$script:policy})}
        }
        $result = Get-HandoffPolicySnapshot -TenantId $tenant -GroupId $group -TimeoutSeconds 1
        $result.conditionalAccess.failureCode | Should -Be 'deadline_exceeded'
        $result.conditionalAccess.policies.Count | Should -Be 0
        $result.compliance.failureCode | Should -Be 'deadline_exceeded'
        $requests.Count | Should -Be 2
    }
    It 'returns no investigation for caller cancellation' {
        $cancel = [Threading.CancellationTokenSource]::new()
        try {
            $cancel.Cancel()
            { Get-HandoffPolicySnapshot -TenantId $tenant -GroupId $group -CancellationToken $cancel.Token } | Should -Throw
            $requests.Count | Should -Be 0
        } finally { $cancel.Dispose() }
    }
    It 'withholds observations if a transport endpoint check fails' {
        Mock Invoke-HandoffGraphRequest -ModuleName Handoff.Collection {
            param($Uri)
            if ([string]$Uri -like '*/groups/*') { return @{id=$script:group} }
            throw [Security.SecurityException]::new('Unexpected SDK transport endpoint')
        }
        { Get-HandoffPolicySnapshot -TenantId $tenant -GroupId $group } | Should -Throw
    }
    It 'rejects an unverified SDK version before obtaining its HTTP client' {
        Mock Get-Module -ModuleName Handoff.Collection { [pscustomobject]@{Version=[version]'99.0.0'} }
        InModuleScope Handoff.Collection { { Get-HandoffGraphClient } | Should -Throw '*unsupported_sdk*' }
    }
}
