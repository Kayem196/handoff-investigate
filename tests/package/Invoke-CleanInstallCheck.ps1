param([string]$ResultsDirectory, [string]$ModulesRoot)
# Offline clean-install acceptance: verifies the kit, installs to the current user's
# module directory, then imports by name in a fresh process under the default
# execution policy. No Graph SDK, login, network or tenant access.
$ErrorActionPreference = 'Stop'
if (-not $ResultsDirectory) { $ResultsDirectory = Join-Path $PSScriptRoot ('results-' + [datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ')) }
$ResultsDirectory = [IO.Path]::GetFullPath($ResultsDirectory)
if (Test-Path -LiteralPath $ResultsDirectory) { throw 'Choose a new results directory.' }
$null = New-Item -ItemType Directory -Path $ResultsDirectory
$steps = [Collections.Generic.List[object]]::new()
function Add-Step([string]$Name, [bool]$Pass, $Detail) { $steps.Add([ordered]@{step=$Name;status=$(if($Pass){'PASS'}else{'FAIL'});detail=$Detail}); Write-Host ('{0}: {1}' -f $Name, $(if($Pass){'PASS'}else{'FAIL'})) }
$record = [ordered]@{schemaVersion=1;startedAtUtc=[datetimeoffset]::UtcNow.ToString('o');status='ERROR'
    os=[Environment]::OSVersion.VersionString;osBuild=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).CurrentBuild
    powershell=$PSVersionTable.PSVersion.ToString();runtime=[Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
    executionPolicy=(Get-ExecutionPolicy -List | ForEach-Object { '{0}={1}' -f $_.Scope,$_.ExecutionPolicy }) -join '; '}
$target = $null
try {
    Add-Step 'PowerShell 7.5 or later' ($PSVersionTable.PSVersion -ge [version]'7.5') $record.powershell
    $record.preExisting = @{handoff=@(Get-Module -ListAvailable Handoff | ForEach-Object { $_.ModuleBase });graphAuthentication=@(Get-Module -ListAvailable Microsoft.Graph.Authentication | ForEach-Object { $_.Version.ToString() })}
    Add-Step 'No Handoff module installed beforehand' ($record.preExisting.handoff.Count -eq 0) $record.preExisting

    $mismatches = @(foreach ($line in Get-Content -LiteralPath (Join-Path $PSScriptRoot 'SHA256SUMS.txt')) {
        $hash, $file = $line -split '  ', 2
        $path = Join-Path $PSScriptRoot "Handoff/0.1.0/$file"
        if (-not (Test-Path -LiteralPath $path) -or (Get-FileHash -LiteralPath $path).Hash -ine $hash) { $file }
    })
    Add-Step 'Package checksums' ($mismatches.Count -eq 0) $mismatches
    if ($mismatches.Count) { throw 'Checksum mismatch; package not installed.' }
    $marked = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Handoff') -Recurse -File | Where-Object { Get-Item -LiteralPath $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue } | ForEach-Object Name)
    $record.downloadMarkedFiles = $marked
    Write-Host "Files marked as downloaded (Zone.Identifier): $($marked.Count)"

    $modules = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell/Modules'
    # Rehearsal only: install elsewhere and expose that path to the child process.
    if ($ModulesRoot) { $modules = [IO.Path]::GetFullPath($ModulesRoot); $env:PSModulePath = $modules + [IO.Path]::PathSeparator + $env:PSModulePath; $record.rehearsal = $true }
    $target = Join-Path $modules 'Handoff/0.1.0'
    $record.installPath = $target
    if (Test-Path -LiteralPath (Join-Path $modules 'Handoff')) { throw 'A Handoff module folder already exists; nothing was overwritten.' }
    $null = New-Item -ItemType Directory -Path $target -Force
    Copy-Item -Path (Join-Path $PSScriptRoot 'Handoff/0.1.0/*') -Destination $target -Recurse
    Add-Step 'Installed to current-user modules' (Test-Path -LiteralPath (Join-Path $target 'Handoff.psd1')) $target

    # Fresh process, default execution policy, normal module path: what a user gets.
    $env:HANDOFF_CLEAN_RESULTS = $ResultsDirectory
    $child = @'
$ErrorActionPreference = 'Stop'
$out = [ordered]@{}
try {
    Import-Module Handoff
    $m = Get-Module Handoff
    $out.moduleBase = $m.ModuleBase; $out.commands = @($m.ExportedFunctions.Keys).Count
    $out.declaredCommands = @((Import-PowerShellDataFile (Join-Path $m.ModuleBase 'Handoff.psd1')).FunctionsToExport).Count
    $out.graphLoaded = [bool](Get-Module Microsoft.Graph.Authentication)
    $files = & (Join-Path $m.ModuleBase 'examples/export-investigation.ps1') -OutDirectory (Join-Path $env:HANDOFF_CLEAN_RESULTS 'example')
    $report = Get-Content -LiteralPath $files.Json -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    $out.exampleReferences = $report.references.Count; $out.html = Test-Path -LiteralPath $files.Html
    $collection = @($m.NestedModules | Where-Object Name -eq 'Handoff.Collection')[0]
    & $collection { (New-HandoffReadBudget -Seconds 5 -MaxResponseBytes 1024 -CancellationToken ([Threading.CancellationToken]::None)).Dispose() }
    $out.transportCompiled = $true
    $out.graphLoadedAfter = [bool](Get-Module Microsoft.Graph.Authentication)
} catch { $out.error = $_.Exception.Message }
$out | ConvertTo-Json -Compress
'@
    $json = pwsh -NoProfile -Command $child
    $result = ($json | Select-Object -Last 1) | ConvertFrom-Json -AsHashtable
    $record.freshProcess = $result
    Add-Step 'Import by name in a fresh process' (-not $result.error -and $result.moduleBase -eq $target -and $result.commands -eq $result.declaredCommands) $result.error
    Add-Step 'Graph SDK not loaded by offline use' (-not $result.error -and -not $result.graphLoaded -and -not $result.graphLoadedAfter) $null
    Add-Step 'Packaged example produced reports' (-not $result.error -and $result.exampleReferences -eq 2 -and $result.html) $null
    Add-Step 'Collector compiled its transport helper' (-not $result.error -and $result.transportCompiled) $null
    $record.status = $(if (@($steps | Where-Object status -eq 'FAIL').Count) { 'FAIL' } else { 'PASS' })
} catch {
    $record.failure = $_.Exception.Message
    Write-Host "Stopped: $($_.Exception.Message)"
} finally {
    $record.steps = $steps.ToArray()
    $record.completedAtUtc = [datetimeoffset]::UtcNow.ToString('o')
    $record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $ResultsDirectory 'clean-install-results.json') -Encoding utf8
}
Write-Host ''
Write-Host "Overall: $($record.status). Results: $ResultsDirectory"
if ($target) { Write-Host "To uninstall afterwards: Remove-Item -LiteralPath '$([IO.Path]::GetDirectoryName($target))' -Recurse" }
