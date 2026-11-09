param([Parameter(Mandatory)][string]$Path)
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $Path) { throw 'Choose a new directory for this fictional offline example.' }
Import-Module (Join-Path $PSScriptRoot '../Handoff.Evidence.psm1') -Force
$ids = @{TenantId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';GroupId='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'}
$snapshotPath = Join-Path $PSScriptRoot 'group-policy-snapshot.json'
$firstSnapshot = Get-Content -LiteralPath $snapshotPath -Raw | ConvertFrom-Json -AsHashtable -DateKind String
$first = Save-HandoffInvestigationObservation -Path $Path @ids -Snapshot $firstSnapshot
$null = Add-HandoffInvestigationNote -Path $Path @ids -ObservationId $first.id -Text 'Fictional example: check the incomplete compliance source before drawing conclusions.'
# A refresh is supplied evidence here, not a hidden login or tenant read.
$laterSnapshot = Get-Content -LiteralPath $snapshotPath -Raw | ConvertFrom-Json -AsHashtable -DateKind String
$laterSnapshot.collectedAt = '2026-11-09T12:00:00Z'
$laterSnapshot.conditionalAccess.policies[0].state = 'disabled'
$laterSnapshot.compliance.status = 'complete'
$later = Save-HandoffInvestigationObservation -Path $Path @ids -Snapshot $laterSnapshot
Compare-HandoffInvestigationObservation -Path $Path @ids -EarlierObservationId $first.id -LaterObservationId $later.id
