BeforeAll {
    function global:Get-MgContext { throw 'Unmocked context access' }
    Import-Module "$PSScriptRoot/../Handoff.Collection.psm1" -Force
    Import-Module "$PSScriptRoot/../Handoff.Evidence.psm1" -Force
    Import-Module "$PSScriptRoot/../Handoff.Report.psm1" -Force
    $script:tenant = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    $script:group = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
    $script:other = 'dddddddd-dddd-dddd-dddd-dddddddddddd'
    $script:missing = 'ffffffff-ffff-ffff-ffff-ffffffffffff'
    $script:filter = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'
    $script:globalAdmin = '62e90394-69f5-4237-9190-012177145e10'
    $script:graphApp = '00000003-0000-0000-c000-000000000000'
}
Describe 'Directory name resolution' {
    BeforeEach {
        $script:requests = [Collections.Generic.List[string]]::new()
        Mock Get-MgContext -ModuleName Handoff.Collection { @{ TenantId = $script:tenant; ClientId = '11111111-1111-1111-1111-111111111111'; Account = 'reader@example.invalid'; AuthType = 'Delegated'; Environment = 'Global'; ContextScope = 'Process'; Scopes = @() } }
        Mock Invoke-HandoffGraphRequest -ModuleName Handoff.Collection {
            param($Uri, $State)
            $script:requests.Add([string]$Uri)
            switch -Wildcard ([string]$Uri) {
                "*/groups/$($script:group)*" { return @{ id = $script:group; displayName = 'Selected group' } }
                "*/groups/$($script:other)*" { return @{ id = $script:other; displayName = 'Break-glass <b>accounts</b>' } }
                "*/groups/$($script:missing)*" { throw 'raw issuer detail' }
                "*/assignmentFilters/*" { return @{ id = $script:filter; displayName = 'Windows corporate'; platform = 'windows10AndLater'; rule = '(device.model -eq "X")'; roleScopeTags = @('0') } }
                '*/identity/conditionalAccess/policies' { return @{ value = @(@{ id = '22222222-2222-2222-2222-222222222222'; displayName = 'Admins MFA'; state = 'enabled'
                    conditions = @{ users = @{ includeGroups = @($script:group); excludeGroups = @($script:other, $script:missing); includeRoles = @($script:globalAdmin, '99999999-9999-9999-9999-999999999999') }; applications = @{ includeApplications = @($script:graphApp) } } }) } }
                '*/deviceCompliancePolicies' { return @{ value = @(@{ id = '33333333-3333-3333-3333-333333333333'; displayName = 'Windows compliance' }) } }
                '*/assignments' { return @{ value = @(@{ id = 'a1'; target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $script:group; deviceAndAppManagementAssignmentFilterId = $script:filter; deviceAndAppManagementAssignmentFilterType = 'include' } }) } }
            }
            return @{ value = @() }
        }
    }
    It 'reads names for referenced groups and filters only, keeping failures as unresolved without changing coverage' {
        $snapshot = Get-HandoffPolicySnapshot -TenantId $tenant -GroupId $group
        $snapshot.directoryNames.groups[$other] | Should -Be 'Break-glass <b>accounts</b>'
        $snapshot.directoryNames.groups.ContainsKey($group) | Should -BeFalse
        $snapshot.directoryNames.filters[$filter].displayName | Should -Be 'Windows corporate'
        $snapshot.directoryNames.filters[$filter].rule | Should -Be '(device.model -eq "X")'
        $snapshot.directoryNames.filters[$filter].ContainsKey('roleScopeTags') | Should -BeFalse
        $snapshot.directoryNames.status | Should -Be 'partial'
        @($snapshot.directoryNames.unresolved | Where-Object id -eq $missing)[0].code | Should -Be 'request_failed'
        ($snapshot | ConvertTo-Json -Depth 20) | Should -Not -Match 'raw issuer detail'
        $snapshot.conditionalAccess.status | Should -Be 'complete'
        $snapshot.compliance.status | Should -Be 'complete'
        @($requests | Where-Object { $_ -match '/groups/|assignmentFilters' } | Where-Object { $_ -notmatch '^https://graph\.microsoft\.com/(v1\.0/groups/|beta/deviceManagement/assignmentFilters/)' }).Count | Should -Be 0
    }
    It 'rejects a name response for a different object' {
        Mock Invoke-HandoffGraphRequest -ModuleName Handoff.Collection {
            param($Uri, $State)
            if ([string]$Uri -like "*/groups/$($script:group)*") { return @{ id = $script:group; displayName = 'Selected group' } }
            if ([string]$Uri -like '*/groups/*') { return @{ id = $script:group; displayName = 'Wrong object' } }
            if ([string]$Uri -like '*/identity/conditionalAccess/policies') { return @{ value = @(@{ id = '22222222-2222-2222-2222-222222222222'; conditions = @{ users = @{ excludeGroups = @($script:other) } } }) } }
            return @{ value = @() }
        }
        $snapshot = Get-HandoffPolicySnapshot -TenantId $tenant -GroupId $group
        $snapshot.directoryNames.groups.Count | Should -Be 0
        $snapshot.directoryNames.unresolved[0].code | Should -Be 'invalid_name_response'
    }
    It 'saves names, indexes built-in roles and apps, and lists the rest as unresolved' {
        $snapshot = Get-HandoffPolicySnapshot -TenantId $tenant -GroupId $group
        $path = Join-Path $TestDrive ([guid]::NewGuid())
        $observation = Save-HandoffInvestigationObservation -Path $path -TenantId $tenant -GroupId $group -Snapshot $snapshot
        $names = (Get-HandoffInvestigationReport -Path $path -TenantId $tenant -GroupId $group -ObservationId $observation.id).names
        $names.groups[$group] | Should -Be 'Selected group'
        $names.groups[$other] | Should -Be 'Break-glass <b>accounts</b>'
        $names.roles[$globalAdmin] | Should -Be 'Global Administrator'
        $names.applications[$graphApp] | Should -Be 'Microsoft Graph'
        $names.filters[$filter].displayName | Should -Be 'Windows corporate'
        $names.unresolved | Should -Contain $missing
        $names.unresolved | Should -Contain '99999999-9999-9999-9999-999999999999'
        $names.unresolved | Should -Not -Contain $globalAdmin
    }
    It 'still names built-in roles for older observations without collected names' {
        $snapshot = Get-HandoffPolicySnapshot -TenantId $tenant -GroupId $group
        $snapshot.Remove('directoryNames')
        $path = Join-Path $TestDrive ([guid]::NewGuid())
        $observation = Save-HandoffInvestigationObservation -Path $path -TenantId $tenant -GroupId $group -Snapshot $snapshot
        $names = (Get-HandoffInvestigationReport -Path $path -TenantId $tenant -GroupId $group -ObservationId $observation.id).names
        $names.status | Should -Be 'not_collected'
        $names.roles[$globalAdmin] | Should -Be 'Global Administrator'
        $names.unresolved | Should -Contain $other
    }
}
