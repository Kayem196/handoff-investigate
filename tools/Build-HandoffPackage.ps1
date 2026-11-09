param([Parameter(Mandatory)][string]$OutDirectory)
# Copies only the manifest's FileList into <out>/Handoff/<version>, plus checksums.
$ErrorActionPreference = 'Stop'
$source = Resolve-Path (Join-Path $PSScriptRoot '..')
$data = Import-PowerShellDataFile (Join-Path $source 'Handoff.psd1')
$OutDirectory = [IO.Path]::GetFullPath($OutDirectory)
if (Test-Path -LiteralPath $OutDirectory) { throw 'Choose a new output directory; packages are never overwritten.' }
$target = Join-Path $OutDirectory "Handoff/$($data.ModuleVersion)"
$null = New-Item -ItemType Directory -Path $target
foreach ($file in $data.FileList) {
    $from = Join-Path $source $file
    # While staged inside the larger repository, the licence lives one level up.
    if ($file -eq 'LICENSE' -and -not (Test-Path -LiteralPath $from)) { $from = Join-Path $source '../LICENSE' }
    if (-not (Test-Path -LiteralPath $from -PathType Leaf)) { throw "Missing packaged file: $file" }
    $to = Join-Path $target $file
    $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($to)) -Force
    Copy-Item -LiteralPath $from -Destination $to
}
# Validate the assembled package, where every FileList entry must exist.
$null = Test-ModuleManifest -Path (Join-Path $target 'Handoff.psd1') -ErrorAction Stop
$sums = foreach ($file in $data.FileList | Sort-Object) { '{0}  {1}' -f (Get-FileHash -LiteralPath (Join-Path $target $file) -Algorithm SHA256).Hash.ToLowerInvariant(), $file }
$sums | Set-Content -LiteralPath (Join-Path $OutDirectory 'SHA256SUMS.txt') -Encoding utf8
[pscustomobject]@{ Module = $target; Files = $data.FileList.Count; Checksums = (Join-Path $OutDirectory 'SHA256SUMS.txt') }
