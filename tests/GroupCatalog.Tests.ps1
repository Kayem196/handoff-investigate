BeforeAll {
    function global:Get-MgContext { throw 'Unmocked SDK context access' }
    Import-Module "$PSScriptRoot/../Handoff.Collection.psm1" -Force
    $script:tenant = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    $script:group = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
    $script:other = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'
    $script:root = 'https://graph.microsoft.com/v1.0/groups'
}
Describe 'Bounded read-only group picker catalog' {
    BeforeEach {
        $script:binding = @{TenantId=$tenant;ClientId='dddddddd-dddd-dddd-dddd-dddddddddddd';Account='operator@example.invalid';AuthType='Delegated';Environment='Global';ContextScope='Process'}
        $script:requests = [Collections.Generic.List[string]]::new()
        Mock Get-MgContext -ModuleName Handoff.Collection { $script:binding }
        Mock Invoke-HandoffGraphRequest -ModuleName Handoff.Collection {
            param($Uri)
            $script:requests.Add($Uri)
            return @{value=@(@{id=$script:group;displayName='Support';mailEnabled=$false;groupTypes=@()})}
        }
    }
    It 'lists only basic properties through the existing bounded reader without policy or member reads' {
        $catalog = Get-HandoffGroupCatalog -TenantId $tenant
        $catalog.items.Count | Should -Be 1
        $catalog.items[0].id | Should -Be $group
        $catalog.items[0].mailEnabled | Should -BeFalse
        $catalog.status | Should -Be 'complete'
        $catalog.referenceCounts | Should -Be 'not_collected'
        $catalog.membershipOwnersActivity | Should -Be 'not_collected'
        $catalog.collection.requestCount | Should -Be 1
        $catalog.collection.limits.groups | Should -Be 200
        $catalog.collection.limits.responseBytes | Should -Be 4MB
        $requests[0] | Should -Be ($root+'?$select=id,displayName,groupTypes,securityEnabled,mailEnabled,onPremisesSyncEnabled&$top=100')
    }
    It 'paginates one resource and retains distinct groups with duplicate names' {
        Mock Invoke-HandoffGraphRequest -ModuleName Handoff.Collection {
            param($Uri)
            $script:requests.Add($Uri)
            if ($Uri -like '*skiptoken*') { return @{value=@(@{id=$script:other;displayName='Same name'})} }
            return @{value=@(@{id=$script:group;displayName='Same name'});'@odata.nextLink'=$script:root+'?$skiptoken=next'}
        }
        $catalog = Get-HandoffGroupCatalog -TenantId $tenant
        $catalog.items.Count | Should -Be 2
        $catalog.items.id | Should -Contain $group
        $catalog.items.id | Should -Contain $other
        $catalog.collection.pagesRead | Should -Be 2
    }
    It 'marks an empty authorised endpoint complete, not unavailable' {
        Mock Invoke-HandoffGraphRequest -ModuleName Handoff.Collection { @{value=@()} }
        $catalog = Get-HandoffGroupCatalog -TenantId $tenant
        $catalog.items.Count | Should -Be 0
        $catalog.status | Should -Be 'complete'
        $catalog.warning | Should -Match 'not a complete tenant inventory'
    }
    It 'does not turn a denial or malformed page into an empty complete inventory' -ForEach @('denied','malformed') {
        $script:failure = $_
        Mock Invoke-HandoffGraphRequest -ModuleName Handoff.Collection { if ($script:failure -eq 'denied') { throw 'private issuer or token detail' }; @{value=@{id='not an array'}} }
        $catalog = Get-HandoffGroupCatalog -TenantId $tenant
        $catalog.status | Should -Be 'unavailable'
        ($catalog | ConvertTo-Json -Depth 20) | Should -Not -Match 'private issuer|token detail'
    }
    It 'bounds retained groups, pages and request invocations' {
        Mock Invoke-HandoffGraphRequest -ModuleName Handoff.Collection { @{value=@(@{id=$script:group},@{id=$script:other});'@odata.nextLink'=$script:root+'?$skiptoken=next'} }
        $limited = Get-HandoffGroupCatalog -TenantId $tenant -MaxGroups 1
        $limited.items.Count | Should -Be 1
        $limited.status | Should -Be 'partial'
        $limited.failureCode | Should -Be 'item_limit'
        $pages = Get-HandoffGroupCatalog -TenantId $tenant -MaxPages 1
        $pages.failureCode | Should -Be 'page_limit'
        $requests = Get-HandoffGroupCatalog -TenantId $tenant -MaxRequests 1
        $requests.failureCode | Should -Be 'request_limit'
    }
    It 'rejects foreign resource, cloud or version pagination before following it' -ForEach @(
        'https://attacker.invalid/v1.0/groups', 'http://graph.microsoft.com/v1.0/groups',
        'https://graph.microsoft.com/v1.0/users', 'https://graph.microsoft.com/beta/groups'
    ) {
        $script:unsafe = $_
        Mock Invoke-HandoffGraphRequest -ModuleName Handoff.Collection {
            param($Uri)
            $script:requests.Add($Uri)
            @{value=@(@{id=$script:group});'@odata.nextLink'=$script:unsafe}
        }
        $catalog = Get-HandoffGroupCatalog -TenantId $tenant
        $catalog.failureCode | Should -Be 'invalid_next_link'
        $catalog.items.Count | Should -Be 1
        $requests.Count | Should -Be 1
    }
    It 'marks malformed properties and duplicate IDs incomplete while retaining valid groups' {
        Mock Invoke-HandoffGraphRequest -ModuleName Handoff.Collection {
            @{value=@(@{id=$script:group;displayName='A'},@{id=$script:group.ToUpperInvariant();displayName='B'},@{id='not-a-guid'},@{id=$script:other;mailEnabled='false'})}
        }
        $catalog = Get-HandoffGroupCatalog -TenantId $tenant
        $catalog.items.Count | Should -Be 1
        $catalog.status | Should -Be 'partial'
        $catalog.issues.code | Should -Contain 'duplicate_group'
        $catalog.issues.code | Should -Contain 'invalid_group'
        $catalog.issues.code | Should -Contain 'invalid_group_properties'
    }
    It 'does not retain unexpected or accidentally overfetched group properties' {
        Mock Invoke-HandoffGraphRequest -ModuleName Handoff.Collection { @{value=@(@{id=$script:group;displayName='A';members=@(@{id='private'});extension_private='do not retain'})} }
        $catalog = Get-HandoffGroupCatalog -TenantId $tenant
        $catalog.items[0].Contains('members') | Should -BeFalse
        $catalog.items[0].Contains('extension_private') | Should -BeFalse
    }
    It 'withholds a catalog for the wrong tenant or a changed reader session' {
        $binding.TenantId = $other
        { Get-HandoffGroupCatalog -TenantId $tenant } | Should -Throw
        $requests.Count | Should -Be 0
        $binding.TenantId = $tenant
        Mock Invoke-HandoffGraphRequest -ModuleName Handoff.Collection { $script:binding.Account='another@example.invalid'; @{value=@()} }
        { Get-HandoffGroupCatalog -TenantId $tenant } | Should -Throw
    }
    It 'uses the shared deadline and preserves a fixed timeout outcome' {
        Mock Invoke-HandoffGraphRequest -ModuleName Handoff.Collection { Start-Sleep -Milliseconds 1100; @{value=@(@{id=$script:group})} }
        $catalog = Get-HandoffGroupCatalog -TenantId $tenant -TimeoutSeconds 1
        $catalog.status | Should -Be 'unavailable'
        $catalog.failureCode | Should -Be 'deadline_exceeded'
        $catalog.items.Count | Should -Be 0
    }
    It 'returns no catalog on external cancellation' {
        $cancel = [Threading.CancellationTokenSource]::new()
        try { $cancel.Cancel(); { Get-HandoffGroupCatalog -TenantId $tenant -CancellationToken $cancel.Token } | Should -Throw }
        finally { $cancel.Dispose() }
        $requests.Count | Should -Be 0
    }
}
