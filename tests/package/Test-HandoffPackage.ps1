param([Parameter(Mandatory)][string]$PackageRoot)
# Run in a fresh `pwsh -NoProfile`. Restricts module discovery to the package plus
# PowerShell's own modules, approximating a machine without this repository.
$ErrorActionPreference = 'Stop'
function Assert-Check($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$PackageRoot = (Resolve-Path -LiteralPath $PackageRoot).Path
$env:PSModulePath = $PackageRoot + [IO.Path]::PathSeparator + (Join-Path $PSHOME 'Modules')
$checks = [Collections.Generic.List[string]]::new()

foreach ($line in Get-Content -LiteralPath (Join-Path $PackageRoot 'SHA256SUMS.txt')) {
    $hash, $file = $line -split '  ', 2
    $path = Get-ChildItem -LiteralPath $PackageRoot -Directory -Filter Handoff | ForEach-Object { Get-ChildItem $_.FullName -Directory } | ForEach-Object { Join-Path $_.FullName $file }
    Assert-Check ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ieq $hash) "Checksum mismatch: $file"
}
$checks.Add('checksums match')

Import-Module Handoff
$module = Get-Module Handoff
Assert-Check ($module.ModuleBase.StartsWith($PackageRoot, [StringComparison]::OrdinalIgnoreCase)) 'Imported a module outside the package.'
$declared = (Import-PowerShellDataFile (Join-Path $module.ModuleBase 'Handoff.psd1')).FunctionsToExport
Assert-Check (@(Compare-Object @($module.ExportedFunctions.Keys) @($declared)).Count -eq 0) 'Exported commands differ from the manifest.'
Assert-Check (-not (Get-Module Microsoft.Graph.Authentication)) 'Import loaded the Graph SDK.'
$checks.Add('module imports from package without the Graph SDK')
$collection = @($module.NestedModules | Where-Object Name -eq 'Handoff.Collection')[0]
& $collection { $budget = New-HandoffReadBudget -Seconds 5 -MaxResponseBytes 1024 -CancellationToken ([Threading.CancellationToken]::None); $budget.Dispose() }
$checks.Add('packaged collector compiles its transport helper')

$work = Join-Path ([IO.Path]::GetTempPath()) ('handoff-package-smoke-' + [guid]::NewGuid().ToString('N'))
$snapshot = Get-Content (Join-Path $module.ModuleBase 'examples/group-policy-snapshot.json') -Raw | ConvertFrom-Json -AsHashtable -DateKind String
$ids = @{ TenantId = $snapshot.tenantId; GroupId = $snapshot.groupId }
$result = Get-HandoffGroupPolicyReference @ids -Snapshot $snapshot
Assert-Check ($result.references.Count -eq 2 -and $result.coverage -eq 'incomplete') 'Offline evaluator known answer changed.'
$first = Save-HandoffInvestigationObservation -Path (Join-Path $work 'evidence') @ids -Snapshot $snapshot
$null = New-Item -ItemType Directory -Path (Join-Path $work 'exports')
$html = Export-HandoffInvestigationReport -Path (Join-Path $work 'evidence') @ids -ObservationId $first.id -OutFile (Join-Path $work 'exports/report.html') -Format Html
Assert-Check ((Get-Content -LiteralPath $html.FullName -Raw) -match "style-src 'sha256-") 'Packaged report stylesheet was not embedded.'
$checks.Add('evaluate, save and export work from the packaged files')

$examples = & (Join-Path $module.ModuleBase 'examples/export-investigation.ps1') -OutDirectory (Join-Path $work 'example')
Assert-Check ((Test-Path -LiteralPath $examples.Html) -and (Test-Path -LiteralPath $examples.Json)) 'Packaged example failed.'
$checks.Add('packaged fictional example runs')
Assert-Check (-not (Get-Module Microsoft.Graph.Authentication)) 'Offline use loaded the Graph SDK.'
[pscustomobject]@{ Status = 'PASS'; Checks = $checks; WorkDirectory = $work } | ConvertTo-Json
