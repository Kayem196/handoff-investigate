# Runs inside Windows Sandbox under the built-in Windows PowerShell 5.1.
# Unpacks the bundled portable PowerShell 7, then runs the offline clean-install check.
param([Parameter(Mandatory)][string]$KitPath, [Parameter(Mandatory)][string]$ResultsRoot)
$ErrorActionPreference = 'Stop'
$log = Join-Path $ResultsRoot ('sandbox-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))
New-Item -ItemType Directory -Path $log | Out-Null
Start-Transcript -Path (Join-Path $log 'sandbox-transcript.txt') | Out-Null
$record = [ordered]@{status='ERROR';networkAdaptersUp=$null;checkExitCode=$null}
try {
    $zip = Get-ChildItem -LiteralPath $KitPath -Filter 'PowerShell-*-win-x64.zip' | Select-Object -First 1
    if (-not $zip) { throw 'Portable PowerShell zip missing from the kit.' }
    $expected = (Get-Content -LiteralPath (Join-Path $KitPath 'POWERSHELL-SHA256.txt') -Raw).Trim().Split(' ')[0]
    if ((Get-FileHash -LiteralPath $zip.FullName -Algorithm SHA256).Hash -ne $expected) { throw 'Portable PowerShell checksum mismatch.' }
    Expand-Archive -LiteralPath $zip.FullName -DestinationPath 'C:\pwsh7' -Force
    $network = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up').Count
    $record.networkAdaptersUp = $network
    "Network adapters up inside sandbox: $network" | Tee-Object -FilePath (Join-Path $log 'network.txt')
    if ($network -ne 0) { throw 'Expected networking disabled; check not started.' }
    # The kit folder is mapped read-only, so the check writes its results here instead.
    & 'C:\pwsh7\pwsh.exe' -NoProfile -ExecutionPolicy Bypass -File (Join-Path $KitPath 'Invoke-CleanInstallCheck.ps1') -ResultsDirectory (Join-Path $log 'check')
    $record.checkExitCode = $LASTEXITCODE
    if ($LASTEXITCODE -ne 0) { throw 'Clean-install check did not pass; inspect check/clean-install-results.json.' }
    $record.status = 'PASS'
    "pwsh exit code: $LASTEXITCODE"
} catch {
    $record.failure = $_.Exception.Message
    "Sandbox bootstrap failed: $($_.Exception.Message)"
} finally {
    $record | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $log 'sandbox-results.json') -Encoding UTF8
    Stop-Transcript | Out-Null
    New-Item -ItemType File -Path (Join-Path $log 'DONE') | Out-Null
}
if ($record.status -ne 'PASS') { exit 1 }
