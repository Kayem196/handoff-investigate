# Uses an existing delegated Microsoft.Graph.Authentication session. No login,
# consent, configuration changes, token extraction or module import side effects.
function New-HandoffReadBudget {
    param([int]$Seconds, [int]$MaxResponseBytes, [System.Threading.CancellationToken]$CancellationToken)
    if (-not ('Handoff.Investigation.ReadBudget' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'Handoff.Transport.cs') -ErrorAction Stop
    }
    return [Handoff.Investigation.ReadBudget]::new($Seconds, $MaxResponseBytes, $CancellationToken)
}

function Get-HandoffGraphClient {
    # Only this exact SDK pipeline has been checked for request-option handling.
    $sdk = Get-Module Microsoft.Graph.Authentication
    if (-not $sdk -or $sdk.Version -ne [version]'2.38.1') { throw [InvalidOperationException]::new('unsupported_sdk') }
    $endpoint = [Microsoft.Graph.PowerShell.Authentication.GraphSession]::Instance.Environment.GraphEndpoint
    if ($endpoint -cnotin @('https://graph.microsoft.com', 'https://graph.microsoft.com/')) {
        throw [System.Security.SecurityException]::new('The SDK transport endpoint does not match the supported cloud.')
    }
    return [Microsoft.Graph.PowerShell.Authentication.Helpers.HttpHelpers]::GetGraphHttpClient()
}

function Invoke-HandoffGraphRequest {
    param([string]$Uri, [hashtable]$State)
    $client = Get-HandoffGraphClient
    # The SDK isolates Kiota in its load context; instantiate only its public options.
    $assemblies = @([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'Microsoft.Kiota.Http.HttpClientLibrary' })
    if ($assemblies.Count -ne 1) { throw [InvalidOperationException]::new('unsupported_sdk') }
    $redirect = [Activator]::CreateInstance($assemblies[0].GetType('Microsoft.Kiota.Http.HttpClientLibrary.Middleware.Options.RedirectHandlerOption', $true))
    $redirect.MaxRedirect = 0
    $retry = [Activator]::CreateInstance($assemblies[0].GetType('Microsoft.Kiota.Http.HttpClientLibrary.Middleware.Options.RetryHandlerOption', $true))
    $retry.MaxRetry = 0
    $json = $State.budget.ReadAsync($client, $Uri, $redirect, $retry).GetAwaiter().GetResult()
    $State.cancellation.ThrowIfCancellationRequested()
    if ($State.budget.Expired) { throw [InvalidOperationException]::new('deadline_exceeded') }
    $response = ConvertFrom-Json -InputObject $json -AsHashtable -Depth 64 -ErrorAction Stop
    if ($State.budget.Expired) { throw [InvalidOperationException]::new('deadline_exceeded') }
    return $response
}

function Get-HandoffGraphBinding {
    param([guid]$TenantId)
    try { $current = Get-MgContext -ErrorAction Stop } catch { throw [System.Security.SecurityException]::new('A delegated Graph session is required.') }
    $observedTenant = [guid]::Empty
    $client = [guid]::Empty
    if (-not $current -or -not [guid]::TryParse([string]$current.TenantId, [ref]$observedTenant) -or
        $observedTenant -ne $TenantId -or $current.AuthType -ne 'Delegated' -or $current.Environment -ne 'Global' -or
        -not [guid]::TryParse([string]$current.ClientId, [ref]$client) -or $client -eq [guid]::Empty -or
        [string]::IsNullOrWhiteSpace([string]$current.Account)) {
        throw [System.Security.SecurityException]::new('The Graph session does not match the selected tenant and supported delegated profile.')
    }
    return (@($observedTenant.ToString(), $client.ToString(), [string]$current.Account, [string]$current.AuthType,
        [string]$current.Environment, [string]$current.ContextScope, (@($current.Scopes | Sort-Object) -join ",")) | ConvertTo-Json -Compress)
}

function Invoke-HandoffGraphRead {
    param([string]$Uri, [hashtable]$State)
    $State.cancellation.ThrowIfCancellationRequested()
    if ($State.budget.Expired) { throw [InvalidOperationException]::new('deadline_exceeded') }
    if ((Get-HandoffGraphBinding -TenantId $State.tenantId) -cne $State.binding) {
        throw [System.Security.SecurityException]::new('The Graph session changed; discard this collection.')
    }
    if ($State.requestCount -ge $State.maxRequests) { throw [InvalidOperationException]::new('request_limit') }
    $State.requestCount++
    try { $response = Invoke-HandoffGraphRequest -Uri $Uri -State $State }
    catch [System.Security.SecurityException] {
        throw [System.Security.SecurityException]::new('The SDK transport identity or endpoint changed; discard this collection.')
    }
    catch {
        $State.cancellation.ThrowIfCancellationRequested()
        $code = 'request_failed'
        if ($State.budget.Expired) { $code = 'deadline_exceeded' }
        else {
            $failure = $_.Exception
            while ($failure) {
                if ($failure.Message -in @('response_limit', 'redirect_rejected', 'unsupported_sdk')) { $code = $failure.Message; break }
                $failure = $failure.InnerException
            }
        }
        throw [InvalidOperationException]::new($code) # No original cause/body/token returned.
    }
    $State.cancellation.ThrowIfCancellationRequested()
    if ($State.budget.Expired) { throw [InvalidOperationException]::new('deadline_exceeded') }
    if ((Get-HandoffGraphBinding -TenantId $State.tenantId) -cne $State.binding) {
        throw [System.Security.SecurityException]::new('The Graph session changed; discard this collection.')
    }
    return $response
}

function Read-HandoffGraphCollection {
    param([string]$Uri, [hashtable]$State)
    $root = [uri]$Uri
    $next = $Uri
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $items = [System.Collections.Generic.List[object]]::new()
    $pages = 0
    $failure = $null
    while ($next) {
        if ($State.retainedItems -ge $State.maxItems) { $failure = 'item_limit'; break }
        $pageUri = $null
        if ($next.Length -gt 8192 -or -not [uri]::TryCreate($next, [UriKind]::Absolute, [ref]$pageUri) -or
            $pageUri.Scheme -cne 'https' -or $pageUri.IdnHost -cne 'graph.microsoft.com' -or $pageUri.Port -ne 443 -or
            $pageUri.UserInfo -or $pageUri.Fragment -or $pageUri.AbsolutePath -cne $root.AbsolutePath) {
            $failure = 'invalid_next_link'; break
        }
        if (-not $seen.Add($pageUri.AbsoluteUri)) { $failure = 'pagination_cycle'; break }
        if ($pages -ge $State.maxPages) { $failure = 'page_limit'; break }
        try { $page = Invoke-HandoffGraphRead -Uri $next -State $State }
        catch [System.Security.SecurityException] { throw }
        catch {
            $State.cancellation.ThrowIfCancellationRequested()
            $failure = $(if ($_.Exception.Message -in @('request_limit', 'response_limit', 'redirect_rejected', 'deadline_exceeded', 'unsupported_sdk')) { $_.Exception.Message } else { 'request_failed' })
            break
        }
        if ($page -isnot [System.Collections.IDictionary] -or $page.Contains('error') -or $page.value -isnot [array]) {
            $failure = 'invalid_page'; break
        }
        $pages++
        foreach ($item in $page.value) {
            if ($State.retainedItems -ge $State.maxItems) { $failure = 'item_limit'; break }
            $items.Add($item)
            $State.retainedItems++
        }
        if ($failure) { break }
        if ($null -eq $page['@odata.nextLink']) { $next = $null }
        elseif ($page['@odata.nextLink'] -isnot [string] -or [string]::IsNullOrWhiteSpace($page['@odata.nextLink'])) {
            $failure = 'invalid_next_link'; break
        } else { $next = $page['@odata.nextLink'] }
    }
    return @{
        policies = $items.ToArray(); pagesRead = $pages; failureCode = $failure
        status = $(if (-not $failure) { 'complete' } elseif ($pages -gt 0) { 'partial' } else { 'unavailable' })
    }
}

function Get-HandoffPolicySnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][guid]$TenantId,
        [Parameter(Mandatory)][guid]$GroupId,
        [ValidateRange(1,1000)][int]$MaxPages = 100,
        [ValidateRange(1,10000)][int]$MaxItems = 10000,
        [ValidateRange(1,10000)][int]$MaxRequests = 1000,
        [ValidateRange(1024,16777216)][int]$MaxResponseBytes = 4MB,
        [ValidateRange(1,600)][int]$TimeoutSeconds = 120,
        [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None
    )
    if ($TenantId -eq [guid]::Empty -or $GroupId -eq [guid]::Empty) { throw 'Nonempty tenant and group IDs are required.' }
    $budget = New-HandoffReadBudget -Seconds $TimeoutSeconds -MaxResponseBytes $MaxResponseBytes -CancellationToken $CancellationToken
    try {
        $started = [datetimeoffset]::UtcNow.ToString('o')
        $state = @{ tenantId = $TenantId; binding = (Get-HandoffGraphBinding -TenantId $TenantId)
            requestCount = 0; retainedItems = 0; maxRequests = $MaxRequests; maxPages = $MaxPages; maxItems = $MaxItems
            budget = $budget; cancellation = $CancellationToken }
        try {
            $group = Invoke-HandoffGraphRead -State $state -Uri ("https://graph.microsoft.com/v1.0/groups/$GroupId" + '?$select=id,displayName,groupTypes,securityEnabled,mailEnabled,onPremisesSyncEnabled')
        } catch [System.Security.SecurityException] { throw }
        catch { $CancellationToken.ThrowIfCancellationRequested(); throw 'The selected group could not be read; no investigation was returned.' }
        $resolvedId = [guid]::Empty
        if ($group -isnot [System.Collections.IDictionary] -or -not [guid]::TryParse([string]$group.id, [ref]$resolvedId) -or $resolvedId -ne $GroupId) {
            throw 'The selected group response did not match; no investigation was returned.'
        }
        $ca = Read-HandoffGraphCollection -State $state -Uri 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies'
        $compliance = Read-HandoffGraphCollection -State $state -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies'
        foreach ($policy in $compliance.policies) {
            $policyId = [guid]::Empty
            if ($policy -isnot [System.Collections.IDictionary] -or -not [guid]::TryParse([string]$policy.id, [ref]$policyId) -or $policyId -eq [guid]::Empty) {
                if ($compliance.status -eq 'complete') { $compliance.status = 'partial' }
                $compliance.failureCode = 'invalid_policy'
                continue
            }
            # The v1.0 assignment contract omits filter ID/mode; beta retains them.
            $assignments = Read-HandoffGraphCollection -State $state -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies/$policyId/assignments"
            $policy['assignments'] = $assignments.policies
            $policy['assignmentsStatus'] = $assignments.status
            $policy['assignmentsCollection'] = @{ pagesRead = $assignments.pagesRead; failureCode = $assignments.failureCode }
            if ($assignments.status -ne 'complete') {
                if ($compliance.status -eq 'complete') { $compliance.status = 'partial' }
                if (-not $compliance.failureCode) { $compliance.failureCode = 'assignments_incomplete' }
            }
        }
        $CancellationToken.ThrowIfCancellationRequested()
        if ((Get-HandoffGraphBinding -TenantId $TenantId) -cne $state.binding) {
            throw [System.Security.SecurityException]::new('The Graph session changed; discard this collection.')
        }
        return @{
            schemaVersion = 1; tenantId = $TenantId.ToString(); groupId = $GroupId.ToString()
            group = $group; collectedAt = $started
            collection = @{ source = 'graph_v1_beta_delegated_policy_snapshot_v1'; completedAt = [datetimeoffset]::UtcNow.ToString('o')
                apiVersions = @{ group = 'v1.0'; conditionalAccess = 'v1.0'; compliancePolicies = 'v1.0'; complianceAssignments = 'beta' }
                transport = 'sdk_2.38.1_streamed_request_options_v1'
                requestCount = $state.requestCount; retainedItems = $state.retainedItems; limits = @{ pagesPerCollection = $MaxPages; retainedItems = $MaxItems; sdkInvocations = $MaxRequests; responseBytes = $MaxResponseBytes; durationSeconds = $TimeoutSeconds } }
            conditionalAccess = $ca; compliance = $compliance
        }
    } finally { $budget.Dispose() }
}
function Get-HandoffGroupCatalog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][guid]$TenantId,
        [ValidateRange(1,1000)][int]$MaxGroups = 200,
        [ValidateRange(1,100)][int]$MaxPages = 10,
        [ValidateRange(1,1000)][int]$MaxRequests = 50,
        [ValidateRange(1024,16777216)][int]$MaxResponseBytes = 4MB,
        [ValidateRange(1,600)][int]$TimeoutSeconds = 120,
        [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None
    )
    if ($TenantId -eq [guid]::Empty) { throw 'A nonempty tenant ID is required.' }
    $budget = New-HandoffReadBudget -Seconds $TimeoutSeconds -MaxResponseBytes $MaxResponseBytes -CancellationToken $CancellationToken
    try {
        $started = [datetimeoffset]::UtcNow.ToString('o')
        $state = @{tenantId=$TenantId;binding=(Get-HandoffGraphBinding -TenantId $TenantId)
            requestCount=0;retainedItems=0;maxRequests=$MaxRequests;maxPages=$MaxPages;maxItems=$MaxGroups
            budget=$budget;cancellation=$CancellationToken}
        $read = Read-HandoffGraphCollection -State $state -Uri 'https://graph.microsoft.com/v1.0/groups?$select=id,displayName,groupTypes,securityEnabled,mailEnabled,onPremisesSyncEnabled&$top=100'
        $items = [Collections.Generic.List[object]]::new()
        $issues = [Collections.Generic.List[object]]::new()
        $seen = [Collections.Generic.HashSet[guid]]::new()
        foreach ($item in $read.policies) {
            $CancellationToken.ThrowIfCancellationRequested()
            $id = [guid]::Empty
            if ($item -isnot [System.Collections.IDictionary] -or -not [guid]::TryParse([string]$item.id, [ref]$id) -or $id -eq [guid]::Empty) {
                $issues.Add(@{code='invalid_group';groupId=$null}); continue
            }
            if (-not $seen.Add($id)) { $issues.Add(@{code='duplicate_group';groupId=$id.ToString()}); continue }
            $invalid = ($null -ne $item.displayName -and $item.displayName -isnot [string]) -or
                ($null -ne $item.groupTypes -and ($item.groupTypes -isnot [array] -or @($item.groupTypes | Where-Object { $_ -isnot [string] }).Count))
            foreach ($flag in @('securityEnabled','mailEnabled','onPremisesSyncEnabled')) {
                if ($null -ne $item[$flag] -and $item[$flag] -isnot [bool]) { $invalid = $true }
            }
            if ($invalid) { $issues.Add(@{code='invalid_group_properties';groupId=$id.ToString()}); continue }
            $row = [ordered]@{id=$id.ToString()}
            foreach ($key in @('displayName','groupTypes','securityEnabled','mailEnabled','onPremisesSyncEnabled')) {
                if ($item.Contains($key)) { $row[$key] = $item[$key] }
            }
            $items.Add($row)
        }
        $CancellationToken.ThrowIfCancellationRequested()
        if ($budget.Expired -and $read.status -eq 'complete') { $read.status='partial';$read.failureCode='deadline_exceeded' }
        if ((Get-HandoffGraphBinding -TenantId $TenantId) -cne $state.binding) {
            throw [System.Security.SecurityException]::new('The Graph session changed; discard this catalog.')
        }
        $status = $(if ($issues.Count) { 'partial' } else { $read.status })
        return [ordered]@{
            schemaVersion=1;catalogType='visible_group_picker_v1';tenantId=$TenantId.ToString();collectedAt=$started
            status=$status;failureCode=$read.failureCode;issues=$issues.ToArray();items=$items.ToArray()
            referenceCounts='not_collected';membershipOwnersActivity='not_collected'
            collection=@{source='graph_v1_delegated_group_catalog_v1';transport='sdk_2.38.1_streamed_request_options_v1'
                completedAt=[datetimeoffset]::UtcNow.ToString('o');pagesRead=$read.pagesRead;requestCount=$state.requestCount;retainedItems=$state.retainedItems
                limits=@{groups=$MaxGroups;pages=$MaxPages;sdkInvocations=$MaxRequests;responseBytes=$MaxResponseBytes;durationSeconds=$TimeoutSeconds}}
            warning='A bounded visible group list, not a complete tenant inventory or reference-ranked assessment. Missing groups may reflect limits, permissions or replication delays. Dynamic distribution groups are not returned. No absence, inactivity, ownership or deletion conclusion is established.'
        }
    } finally { $budget.Dispose() }
}

Export-ModuleMember -Function Get-HandoffPolicySnapshot,Get-HandoffGroupCatalog
