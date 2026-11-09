#Requires -Version 7.5
# Guided, confirmed reads only. Authentication/consent remain separate operator work.
Import-Module (Join-Path $PSScriptRoot 'Handoff.Collection.psm1') -Scope Local
Import-Module (Join-Path $PSScriptRoot 'Handoff.Evidence.psm1') -Scope Local
Import-Module (Join-Path $PSScriptRoot 'Handoff.Report.psm1') -Scope Local

function ConvertTo-HandoffConsoleText {
    param([string]$Text)
    # Escape terminal and bidi controls in tenant-provided text; never evaluate it.
    return [regex]::Replace($Text, '[\p{Cc}\p{Cf}]', { param($match) '\u' + ([int][char]$match.Value[0]).ToString('X4') })
}

function Get-HandoffConsoleReader {
    param([guid]$TenantId, [guid]$ClientId, [string]$Account)
    try { $context = Get-MgContext -ErrorAction Stop } catch { throw 'Connect the reviewed reader in a fresh process before using this guide.' }
    $required = @('GroupMember.Read.All','Policy.Read.All','DeviceManagementConfiguration.Read.All')
    $allowed = $required + @('openid','profile','offline_access','email')
    if (-not $context -or $context.TenantId -ine $TenantId.ToString() -or $context.ClientId -ine $ClientId.ToString() -or
        $context.Account -ine $Account -or $context.AuthType -cne 'Delegated' -or $context.Environment -cne 'Global' -or
        $context.ContextScope -cne 'Process' -or @($required | Where-Object { $_ -cnotin $context.Scopes }).Count -or
        @($context.Scopes | Where-Object { $_ -cnotin $allowed }).Count) {
        throw [Security.SecurityException]::new('The session does not match the selected process-scoped reader and approved read scopes. Stop; do not grant new permissions here.')
    }
    return (@($context.TenantId,$context.ClientId,$context.Account,$context.AuthType,$context.Environment,$context.ContextScope,(@($context.Scopes | Sort-Object) -join ',')) | ConvertTo-Json -Compress)
}

function Start-HandoffGroupInvestigation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][guid]$TenantId,
        [Parameter(Mandatory)][guid]$ClientId,
        [Parameter(Mandatory)][ValidateNotNullOrWhiteSpace()][string]$Account,
        [Parameter(Mandatory)][string]$OutDirectory,
        [ValidateLength(0,256)][string]$NameContains = '',
        [ValidateRange(1,1000)][int]$MaxGroups = 200,
        [ValidateRange(1,600)][int]$TimeoutSeconds = 120
    )
    if ($TenantId -eq [guid]::Empty -or $ClientId -eq [guid]::Empty) { throw 'Nonempty tenant and reviewed client IDs are required.' }
    $provider = $null
    $drive = $null
    $output = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDirectory, [ref]$provider, [ref]$drive)
    if ($provider.Name -cne 'FileSystem' -or (Test-Path -LiteralPath $output)) { throw 'Choose a new private filesystem directory; existing destinations are never overwritten.' }
    $parent = [IO.Path]::GetDirectoryName($output)
    $parentItem = Get-Item -LiteralPath $parent -Force -ErrorAction Stop
    if (-not $parentItem.PSIsContainer -or ($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Choose an existing ordinary private parent directory.' }
    $readerArgs = @{TenantId=$TenantId;ClientId=$ClientId;Account=$Account}
    $binding = Get-HandoffConsoleReader @readerArgs
    Write-Host "Read-only Handoff guide. Tenant $TenantId; reviewed client $ClientId; account $(ConvertTo-HandoffConsoleText $Account)."
    Write-Host "First stage: list up to $MaxGroups visible groups, 10 pages / 50 SDK invocations, 4 MiB per response, ${TimeoutSeconds}s deadline. No owners, membership, activity or policy reference counts are read for the picker."
    Write-Host 'This guide never signs in, changes consent, executes arbitrary commands or modifies a tenant. Type READ to list groups; anything else cancels.'
    if ((Read-Host 'Confirm bounded group-list read') -cne 'READ') { return [pscustomobject]@{status='cancelled';stage='before_catalog'} }
    if ((Get-HandoffConsoleReader @readerArgs) -cne $binding) { throw [Security.SecurityException]::new('Reader session changed; no catalog read was started.') }
    $catalog = Get-HandoffGroupCatalog -TenantId $TenantId -MaxGroups $MaxGroups -TimeoutSeconds $TimeoutSeconds
    if ((Get-HandoffConsoleReader @readerArgs) -cne $binding) { throw [Security.SecurityException]::new('Reader session changed; discard the catalog.') }
    if ($catalog.schemaVersion -ne 1 -or $catalog.tenantId -cne $TenantId.ToString() -or $catalog.catalogType -cne 'visible_group_picker_v1') { throw 'Unexpected catalog identity or contract.' }
    $failure = $(if ($catalog.failureCode) { ConvertTo-HandoffConsoleText $catalog.failureCode } else { 'none recorded' })
    Write-Host "Catalog status: $(ConvertTo-HandoffConsoleText $catalog.status); failure: $failure; recorded issues: $($catalog.issues.Count)."
    Write-Host (ConvertTo-HandoffConsoleText $catalog.warning)
    Write-Host 'Reference counts for picker rows: NOT COLLECTED, not zero. Only the selected group gets a detailed policy investigation.'
    if ($catalog.status -cnotin @('complete','partial')) { return [pscustomobject]@{status='catalog_unavailable';catalogStatus=$catalog.status} }
    $groups = @($catalog.items | Where-Object { -not $NameContains -or ([string]$_.displayName).IndexOf($NameContains, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | Sort-Object displayName,id)
    if (-not $groups.Count) {
        Write-Host 'No matching groups were retained in this bounded list. This does not prove that the group or its references are absent.'
        return [pscustomobject]@{status='no_matching_groups';catalogStatus=$catalog.status;retainedGroups=$catalog.items.Count}
    }
    $choices = for ($index=0; $index -lt $groups.Count; $index++) {
        $name = $(if ([string]::IsNullOrWhiteSpace([string]$groups[$index].displayName)) { 'Name not recorded' } else { ConvertTo-HandoffConsoleText $groups[$index].displayName })
        [pscustomobject]@{Choice=$index+1;Name=$name;GroupId=$groups[$index].id}
    }
    Write-Host ($choices | Format-Table -AutoSize -Wrap | Out-String -Width 120)
    while ($true) {
        $answer = Read-Host 'Choose the displayed group number, or Q/empty to cancel'
        if ([string]::IsNullOrWhiteSpace($answer) -or $answer -ieq 'Q') { return [pscustomobject]@{status='cancelled';stage='group_selection'} }
        if ($answer -match '^[0-9]{1,4}$' -and [int]$answer -ge 1 -and [int]$answer -le $groups.Count) { break }
        Write-Host 'Enter a displayed number, not a command or a group name. Duplicate names are distinguished by group ID.'
    }
    $selected = $groups[[int]$answer-1]
    $groupId = [guid]$selected.id
    Write-Host "Selected tenant $TenantId; group $groupId; name $(ConvertTo-HandoffConsoleText $selected.displayName)."
    Write-Host "Next: resolve this exact group, read visible Conditional Access/compliance policies and assignments (100 pages/collection, 10,000 items, 1,000 SDK invocations, 4 MiB/response, ${TimeoutSeconds}s deadline)."
    Write-Host 'The result may be incomplete. Saving writes plaintext local evidence and HTML/JSON reports, not deletion approval.'
    Write-Host "Output directory: $(ConvertTo-HandoffConsoleText $output)"
    if ((Read-Host 'Type READ to collect and save this selected investigation; anything else cancels') -cne 'READ') { return [pscustomobject]@{status='cancelled';stage='before_investigation'} }
    if ((Get-HandoffConsoleReader @readerArgs) -cne $binding) { throw [Security.SecurityException]::new('Reader session changed; no selected-group read was started.') }
    $snapshot = Get-HandoffPolicySnapshot -TenantId $TenantId -GroupId $groupId -TimeoutSeconds $TimeoutSeconds
    if ((Get-HandoffConsoleReader @readerArgs) -cne $binding) { throw [Security.SecurityException]::new('Reader session changed; no evidence was saved.') }
    if ($snapshot.tenantId -ine $TenantId.ToString() -or $snapshot.groupId -ine $groupId.ToString() -or $snapshot.group.id -ine $groupId.ToString()) { throw 'Selected observation identity did not match; no evidence was saved.' }
    # Directory creation is exclusive. Another run can never turn this into an append.
    $staging = Join-Path $parent ('.handoff-investigation-' + [guid]::NewGuid().ToString('D'))
    $null = [IO.Directory]::CreateDirectory($staging)
    try { [IO.Directory]::Move($staging, $output) }
    finally { if ([IO.Directory]::Exists($staging)) { [IO.Directory]::Delete($staging) } } # Empty, test/run-owned staging only; never delete saved evidence.
    $journal = Join-Path $output 'evidence'
    $observation = Save-HandoffInvestigationObservation -Path $journal -TenantId $TenantId -GroupId $groupId -Snapshot $snapshot
    $html = Export-HandoffInvestigationReport -Path $journal -TenantId $TenantId -GroupId $groupId -ObservationId $observation.id -OutFile (Join-Path $output 'group-investigation.html') -Format Html
    $json = Export-HandoffInvestigationReport -Path $journal -TenantId $TenantId -GroupId $groupId -ObservationId $observation.id -OutFile (Join-Path $output 'group-investigation.json') -Format Json
    Write-Host 'Saved recorded evidence and reports. No tenant configuration was changed. Review coverage/manual checks and private content before sharing.'
    return [pscustomobject]@{status='saved';tenantId=$TenantId.ToString();groupId=$groupId.ToString();observationId=$observation.id;coverage=$observation.evaluation.coverage;references=$observation.evaluation.references.Count;catalogStatus=$catalog.status;evidenceDirectory=$journal;html=$html.FullName;json=$json.FullName}
}

Export-ModuleMember -Function Start-HandoffGroupInvestigation
