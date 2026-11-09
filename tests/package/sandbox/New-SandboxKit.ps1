param(
    [Parameter(Mandatory)][string]$OutDirectory,
    [Parameter(Mandatory)][string]$PortablePowerShellZip
)
# Offline kit: the only writable host mapping is the empty results directory.
$ErrorActionPreference = 'Stop'
$expected = 'CE7484804C0F0AD4DDA10C958E71ACDAF7EEBFB22505C1B480F89E0E9F1DA94D'
if ((Get-FileHash -LiteralPath $PortablePowerShellZip -Algorithm SHA256).Hash -ne $expected) { throw 'Expected the official PowerShell-7.6.9-win-x64.zip checksum.' }
$OutDirectory = [IO.Path]::GetFullPath($OutDirectory)
if (Test-Path -LiteralPath $OutDirectory) { throw 'Choose a new kit directory; existing files are never overwritten.' }
$kit = Join-Path $OutDirectory 'kit'
$results = Join-Path $OutDirectory 'results'
$null = New-Item -ItemType Directory -Path $OutDirectory
$null = & (Join-Path $PSScriptRoot '../../../tools/Build-HandoffPackage.ps1') -OutDirectory $kit
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../Invoke-CleanInstallCheck.ps1') -Destination $kit
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Start-SandboxCheck.ps1') -Destination $kit
Copy-Item -LiteralPath $PortablePowerShellZip -Destination (Join-Path $kit 'PowerShell-7.6.9-win-x64.zip')
$expected | Set-Content -LiteralPath (Join-Path $kit 'POWERSHELL-SHA256.txt') -Encoding ASCII
$null = New-Item -ItemType Directory -Path $results
$kitXml = [Security.SecurityElement]::Escape($kit)
$resultsXml = [Security.SecurityElement]::Escape($results)
@"
<Configuration>
  <Networking>Disable</Networking>
  <ClipboardRedirection>Disable</ClipboardRedirection>
  <vGPU>Disable</vGPU>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$kitXml</HostFolder>
      <SandboxFolder>C:\Kit</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$resultsXml</HostFolder>
      <SandboxFolder>C:\CheckResults</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Kit\Start-SandboxCheck.ps1 -KitPath C:\Kit -ResultsRoot C:\CheckResults</Command>
  </LogonCommand>
</Configuration>
"@ | Set-Content -LiteralPath (Join-Path $OutDirectory 'Run-Handoff-Check.wsb') -Encoding UTF8
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'README.md') -Destination (Join-Path $OutDirectory 'READ-ME.md')
[pscustomobject]@{Launcher=Join-Path $OutDirectory 'Run-Handoff-Check.wsb';Results=$results;Kit=$kit}
