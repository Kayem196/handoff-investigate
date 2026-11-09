param([Parameter(Mandatory)][string]$OutDirectory)
$ErrorActionPreference = 'Stop'
if (Get-Module Microsoft.Graph.Authentication) { throw 'Run the fictional fixtures in a fresh pwsh -NoProfile process without the Graph SDK.' }
$files = & (Join-Path $PSScriptRoot '../../examples/export-investigation.ps1') -OutDirectory $OutDirectory
Import-Module (Join-Path $PSScriptRoot '../../Handoff.Evidence.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../../Handoff.Report.psm1') -Force
$snapshot = Get-Content (Join-Path $PSScriptRoot '../../examples/group-policy-snapshot.json') -Raw | ConvertFrom-Json -AsHashtable -DateKind String
$attack = '</style></title><img src=https://example.invalid/leak onerror=window.__handoffInjected=1><script>window.__handoffInjected=1</script>'
$snapshot.group.displayName = $attack
$snapshot.conditionalAccess.policies[0].displayName = $attack
$snapshot.compliance.policies[0].assignments[0].target.deviceAndAppManagementAssignmentFilterId = $attack
$snapshot.compliance.policies[0].assignments[0].target.deviceAndAppManagementAssignmentFilterType = 'include'
$ids = @{TenantId=$snapshot.tenantId;GroupId=$snapshot.groupId}
$path = Join-Path $OutDirectory 'hostile-evidence'
$observation = Save-HandoffInvestigationObservation -Path $path @ids -Snapshot $snapshot
$null = Add-HandoffInvestigationNote -Path $path @ids -ObservationId $observation.id -Text $attack
$hostile = Export-HandoffInvestigationReport -Path $path @ids -ObservationId $observation.id -OutFile (Join-Path $OutDirectory 'hostile-observation.html') -Format Html
if (Get-Module Microsoft.Graph.Authentication) { throw 'Unexpected SDK import during the offline fixtures.' }
[pscustomobject]@{Complete=$files.Html;Incomplete=$files.IncompleteExample;Hostile=$hostile.FullName;Json=$files.Json}
