# Offline evaluator only. No authentication, SDK imports, network or tenant writes.
function Get-HandoffGroupPolicyReference {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][guid]$TenantId,
        [Parameter(Mandatory)][guid]$GroupId,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot
    )
    $parsedTenant = [guid]::Empty
    $collectedAt = [datetimeoffset]::MinValue
    $timeInput = $Snapshot.collectedAt
    # Newer PowerShell JSON readers materialise ISO UTC timestamps as DateTime.
    if ($timeInput -is [datetime] -and $timeInput.Kind -eq [DateTimeKind]::Utc) { $timeInput = $timeInput.ToString('o') }
    if ($timeInput -is [datetimeoffset]) { $timeInput = $timeInput.ToString('o') }
    if ($TenantId -eq [guid]::Empty -or $GroupId -eq [guid]::Empty -or $Snapshot.schemaVersion -ne 1 -or
        -not [guid]::TryParse([string]$Snapshot.tenantId, [ref]$parsedTenant) -or $parsedTenant -ne $TenantId -or
        [string]$timeInput -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$' -or
        -not [datetimeoffset]::TryParse([string]$timeInput, [ref]$collectedAt)) {
        throw 'Invalid snapshot version, tenant binding or collection time.'
    }
    $references = [System.Collections.Generic.List[object]]::new()
    $issues = [System.Collections.Generic.List[object]]::new()
    $context = [System.Collections.Generic.List[object]]::new()
    foreach ($family in @('conditionalAccess', 'compliance')) {
        $source = $Snapshot[$family]
        if ($source -isnot [System.Collections.IDictionary]) {
            $issues.Add(@{ source = $family; code = 'source_incomplete'; policyId = $null })
            continue
        }
        if ($source.status -ne 'complete') {
            $issues.Add(@{ source = $family; code = 'source_incomplete'; policyId = $null })
        }
        if ($source.policies -isnot [array]) {
            $issues.Add(@{ source = $family; code = 'missing_policy_list'; policyId = $null })
            continue
        }
        $seen = [System.Collections.Generic.HashSet[guid]]::new()
        foreach ($policy in $source.policies) {
            $policyId = [guid]::Empty
            if ($policy -isnot [System.Collections.IDictionary] -or
                -not [guid]::TryParse([string]$policy.id, [ref]$policyId) -or $policyId -eq [guid]::Empty) {
                $issues.Add(@{ source = $family; code = 'invalid_policy'; policyId = $null })
                continue
            }
            if (-not $seen.Add($policyId)) {
                $issues.Add(@{ source = $family; code = 'duplicate_policy'; policyId = $policyId.ToString() })
                continue
            }
            # Read only explicit group references. Other targeting is context, not
            # a calculation of who is affected or a prediction of runtime access.
            $candidates = [System.Collections.Generic.List[object]]::new()
            if ($family -eq 'conditionalAccess') {
                if ($policy.conditions -isnot [System.Collections.IDictionary] -or
                    $policy.conditions.users -isnot [System.Collections.IDictionary]) {
                    $issues.Add(@{ source = $family; code = 'missing_user_conditions'; policyId = $policyId.ToString() })
                    continue
                }
                $users = $policy.conditions.users
                foreach ($field in @('includeGroups', 'excludeGroups')) {
                    if ($null -ne $users[$field] -and $users[$field] -isnot [array]) {
                        $issues.Add(@{ source = $family; code = 'invalid_group_list'; policyId = $policyId.ToString() })
                        continue
                    }
                    foreach ($id in $users[$field]) {
                        $candidates.Add(@{ groupId = $id; relation = $(if ($field -eq 'includeGroups') { 'include' } else { 'exclude' })
                            path = "conditions.users.$field"; assignmentId = $null; filter = $null })
                    }
                }
                if (@($users.Keys | Where-Object { $_ -notin @('includeGroups', 'excludeGroups') -and $null -ne $users[$_] -and @($users[$_]).Count -gt 0 }).Count -gt 0) {
                    $context.Add(@{ source = $family; policyId = $policyId.ToString(); kind = 'other_conditional_access_targeting' })
                }
            } else {
                if ($policy.assignmentsStatus -ne 'complete' -or $policy.assignments -isnot [array]) {
                    $issues.Add(@{ source = $family; code = 'assignments_incomplete'; policyId = $policyId.ToString() })
                }
                foreach ($assignment in $policy.assignments) {
                    if ($assignment -isnot [System.Collections.IDictionary] -or $assignment.target -isnot [System.Collections.IDictionary]) {
                        $issues.Add(@{ source = $family; code = 'invalid_assignment'; policyId = $policyId.ToString() })
                        continue
                    }
                    $target = $assignment.target
                    $type = [string]$target['@odata.type']
                    if ($type -in @('#microsoft.graph.allDevicesAssignmentTarget', '#microsoft.graph.allLicensedUsersAssignmentTarget')) {
                        $context.Add(@{ source = $family; policyId = $policyId.ToString(); kind = $type })
                        continue
                    }
                    if ($type -notin @('#microsoft.graph.groupAssignmentTarget', '#microsoft.graph.exclusionGroupAssignmentTarget')) {
                        $issues.Add(@{ source = $family; code = 'unsupported_assignment_target'; policyId = $policyId.ToString(); targetType = $type })
                        continue
                    }
                    $candidates.Add(@{ groupId = $target.groupId; relation = $(if ($type -eq '#microsoft.graph.groupAssignmentTarget') { 'include' } else { 'exclude' })
                        path = 'assignments.target.groupId'; assignmentId = $assignment.id
                        filter = @{ id = $target.deviceAndAppManagementAssignmentFilterId; type = $target.deviceAndAppManagementAssignmentFilterType } })
                }
            }
            foreach ($candidate in $candidates) {
                $referencedId = [guid]::Empty
                if (-not [guid]::TryParse([string]$candidate.groupId, [ref]$referencedId) -or $referencedId -eq [guid]::Empty) {
                    $issues.Add(@{ source = $family; code = 'invalid_group_id'; policyId = $policyId.ToString() })
                    continue
                }
                if ($referencedId -eq $GroupId) {
                    $references.Add([pscustomobject]@{
                        source = $family; policyId = $policyId.ToString(); policyName = [string]$policy.displayName
                        policyState = $(if ($family -eq 'conditionalAccess') { [string]$policy.state } else { $null })
                        groupId = $GroupId.ToString(); relation = $candidate.relation; sourcePath = $candidate.path
                        assignmentId = $candidate.assignmentId; filter = $candidate.filter
                    })
                }
            }
        }
    }
    [pscustomobject]@{
        schemaVersion = 1; tenantId = $TenantId.ToString(); groupId = $GroupId.ToString()
        collectedAt = $collectedAt.ToUniversalTime().ToString('o')
        claim = 'explicit_group_references_only'
        coverage = $(if ($issues.Count -eq 0) { 'complete_for_explicit_references' } else { 'incomplete' })
        canConcludeNoExplicitReferences = ($issues.Count -eq 0 -and $references.Count -eq 0)
        references = $references.ToArray(); context = $context.ToArray(); issues = $issues.ToArray()
    }
}
Export-ModuleMember -Function Get-HandoffGroupPolicyReference
