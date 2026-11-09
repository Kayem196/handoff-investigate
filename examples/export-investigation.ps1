param([Parameter(Mandatory)][string]$OutDirectory)
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $OutDirectory) { throw 'Choose a new directory for these fictional offline exports.' }
$null = New-Item -ItemType Directory -Path $OutDirectory
Import-Module (Join-Path $PSScriptRoot '../Handoff.Evidence.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../Handoff.Report.psm1') -Force
$ids = @{TenantId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';GroupId='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'}
$journal = Join-Path $OutDirectory 'evidence'
$null = & (Join-Path $PSScriptRoot 'saved-investigation.ps1') -Path $journal
$saved = Get-HandoffInvestigation -Path $journal @ids
$earlier = $saved.observations[0]
$later = $saved.observations[-1]
$null = Add-HandoffInvestigationNote -Path $journal @ids -ObservationId $later.id -Text 'Fictional example: the later read completed, but membership, filter applicability and other workloads still need independent checks.'
$html = Export-HandoffInvestigationReport -Path $journal @ids -ObservationId $later.id -CompareWithObservationId $earlier.id -OutFile (Join-Path $OutDirectory 'group-investigation.html') -Format Html
$json = Export-HandoffInvestigationReport -Path $journal @ids -ObservationId $later.id -CompareWithObservationId $earlier.id -OutFile (Join-Path $OutDirectory 'group-investigation.json') -Format Json
$partial = Export-HandoffInvestigationReport -Path $journal @ids -ObservationId $earlier.id -OutFile (Join-Path $OutDirectory 'incomplete-observation.html') -Format Html
[pscustomobject]@{Html=$html.FullName;Json=$json.FullName;IncompleteExample=$partial.FullName;EvidenceDirectory=$journal}
