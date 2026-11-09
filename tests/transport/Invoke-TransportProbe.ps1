param(
    [Parameter(Mandatory)][string]$PythonPath,
    [Parameter(Mandatory)][string]$OutFile
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'This probe is currently verified on Windows only.' }
Import-Module Microsoft.Graph.Authentication -RequiredVersion 2.38.1
if (Get-MgContext) { throw 'Run this probe in a fresh pwsh -NoProfile process without a Graph session.' }
$PythonPath = (Resolve-Path -LiteralPath $PythonPath).Path
$OutFile = [IO.Path]::GetFullPath($OutFile)
$newReport = [IO.File]::Open($OutFile, [IO.FileMode]::CreateNew)
$newReport.Dispose()
$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('handoff-transport-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temporaryDirectory
$readyPath = Join-Path $temporaryDirectory 'ready.json'
$server = $null
$records = [System.Collections.Generic.List[object]]::new()
$report = @{ schemaVersion=1; status='ERROR'; sdkVersion='2.38.1'; powershell=$PSVersionTable.PSVersion.ToString(); runtime=[Runtime.InteropServices.RuntimeInformation]::FrameworkDescription; syntheticCredentialOnly=$true; tenantCalls=0; scope='Local HTTP, explicit fictional Authorization header; not live delegated authentication or TLS validation'; cases=@() }
$headers = @{ Authorization='Bearer fictional-local-transport-probe' }

function Assert-Probe($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Invoke-Probe([string]$Name, [string]$Path, [int]$MaxRetry=0, [int]$Timeout=5, [string]$OutputType='Hashtable', [long]$BufferBytes=0) {
    $before = Invoke-RestMethod -Uri ($address.origin + '/stats') -TimeoutSec 3
    $null = Set-MgRequestContext -MaxRetry $MaxRetry -RetryDelay 0 -ClientTimeout $Timeout
    # Probe the platform cap; the production collector does not currently set it.
    if ($BufferBytes -gt 0) { [Microsoft.Graph.PowerShell.Authentication.Helpers.HttpHelpers]::GetGraphHttpClient().MaxResponseContentBufferSize = $BufferBytes }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $allocatedBefore = [GC]::GetTotalAllocatedBytes($true)
    $outcome = 'returned'; $errorType = $null; $paddingBytes = 0
    try {
        $response = Invoke-MgGraphRequest -Method GET -Uri ($address.origin + $Path) -Headers $headers -OutputType $OutputType -ErrorAction Stop
        if ($OutputType -eq 'Hashtable' -and $response.value.Count -gt 0) { $paddingBytes = $response.value[0].padding.Length }
        if ($response -is [IDisposable]) { $response.Dispose() }
    } catch { $outcome='failed'; $errorType=$_.Exception.GetType().FullName }
    $watch.Stop()
    $allocated = [GC]::GetTotalAllocatedBytes($true) - $allocatedBefore
    $after = Invoke-RestMethod -Uri ($address.origin + '/stats') -TimeoutSec 3
    $countBefore = ($before.counts.PSObject.Properties.Value | Measure-Object -Sum).Sum
    $countAfter = ($after.counts.PSObject.Properties.Value | Measure-Object -Sum).Sum
    $record = [pscustomobject]@{ name=$Name; path=$Path; outcome=$outcome; errorType=$errorType; httpAttempts=($countAfter-$countBefore); elapsedSeconds=[math]::Round($watch.Elapsed.TotalSeconds,3); observedPaddingBytes=$paddingBytes; cumulativeManagedAllocatedBytes=$allocated; maxRetry=$MaxRetry; timeoutSeconds=$Timeout; outputType=$OutputType; bufferBytes=$BufferBytes }
    $records.Add($record)
}

try {
    $defaults = Get-MgRequestContext
    $report.defaults = @{ clientTimeoutSeconds=$defaults.ClientTimeout.TotalSeconds; maxRetry=$defaults.MaxRetry; retryDelay=$defaults.RetryDelay; retriesTimeLimitSeconds=$defaults.RetriesTimeLimit.TotalSeconds }
    $serverArguments = '-I "' + (Join-Path $PSScriptRoot 'server.py') + '" "' + $readyPath + '"'
    $server = Start-Process -FilePath $PythonPath -ArgumentList $serverArguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $temporaryDirectory 'stdout.txt') -RedirectStandardError (Join-Path $temporaryDirectory 'stderr.txt')
    $startup = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $readyPath) -and $startup.Elapsed.TotalSeconds -lt 5 -and -not $server.HasExited) { Start-Sleep -Milliseconds 20 }
    Assert-Probe (Test-Path -LiteralPath $readyPath) 'Loopback fixture server did not become ready.'
    $address = Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json
    foreach ($value in @($address.origin,$address.other)) {
        $uri = [uri]$value
        Assert-Probe ($uri.Scheme -eq 'http' -and $uri.Host -eq '127.0.0.1' -and $uri.Port -gt 0 -and -not $uri.UserInfo -and -not $uri.Query -and -not $uri.Fragment) 'Fixture URL is not loopback-only.'
    }
    Connect-MgGraph -AccessToken (ConvertTo-SecureString 'fictional-local-transport-probe' -AsPlainText -Force) -NoWelcome
    Invoke-Probe 'retry recovery' '/retry' -MaxRetry 3
    Invoke-Probe 'retry exhaustion' '/always503' -MaxRetry 3
    Invoke-Probe 'retries disabled' '/always503'
    Invoke-Probe 'authentication retry' '/always401'
    Invoke-Probe 'header timeout' '/slow-header' -Timeout 1
    Invoke-Probe 'body timeout despite raw response output' '/slow-body' -Timeout 1 -OutputType HttpResponseMessage
    Invoke-Probe 'same-origin redirect' '/redirect-same'
    Invoke-Probe 'host-changing redirect' '/redirect-host'
    Invoke-Probe 'port-changing redirect' '/redirect-port'
    Invoke-Probe 'large response allocation' '/large'
    Invoke-Probe 'chunked response allocation' '/large-chunked'
    Invoke-Probe 'compressed response allocation' '/gzip-large'
    Invoke-Probe 'content-length buffer cap' '/large' -BufferBytes 1MB
    Invoke-Probe 'chunked buffer cap' '/large-chunked' -BufferBytes 1MB
    Invoke-Probe 'decompressed buffer cap' '/gzip-large' -BufferBytes 1MB

    $pipeline = [powershell]::Create()
    try {
        $null = $pipeline.AddScript({ param($uri)
            Import-Module Microsoft.Graph.Authentication -RequiredVersion 2.38.1
            if ((Get-MgContext).AuthType -ne 'UserProvidedAccessToken') { throw 'Expected the probe-owned fictional session.' }
            $null = Set-MgRequestContext -ClientTimeout 10 -MaxRetry 0
            Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType Hashtable -ErrorAction Stop
        }).AddArgument($address.origin + '/cancel')
        $pending = $pipeline.BeginInvoke()
        $started = [Diagnostics.Stopwatch]::StartNew()
        do {
            $stats = Invoke-RestMethod -Uri ($address.origin + '/stats') -TimeoutSec 3
            if ($stats.counts.PSObject.Properties['/cancel']) { break }
            Start-Sleep -Milliseconds 20
        } while ($started.Elapsed.TotalSeconds -lt 3 -and -not $pending.IsCompleted)
        Assert-Probe ([bool]$stats.counts.PSObject.Properties['/cancel']) 'Cancellation probe did not reach its local endpoint.'
        $stopWatch = [Diagnostics.Stopwatch]::StartNew()
        $pipeline.Stop()
        $stopWatch.Stop()
        $records.Add([pscustomobject]@{ name='pipeline cancellation'; outcome=$pipeline.InvocationStateInfo.State.ToString(); elapsedSeconds=[math]::Round($stopWatch.Elapsed.TotalSeconds,3); httpAttempts=$stats.counts.'/cancel' })
        try { $null = $pipeline.EndInvoke($pending) } catch [Management.Automation.PipelineStoppedException] {}
    } finally { $pipeline.Dispose() }

    $report.server = Invoke-RestMethod -Uri ($address.origin + '/stats') -TimeoutSec 3
    Assert-Probe ($records.Count -eq 16) 'Expected sixteen transport cases.'
    $byName = @{}; foreach ($record in $records) { $byName[$record.name]=$record }
    Assert-Probe ($byName['retry recovery'].httpAttempts -eq 3 -and $byName['retry recovery'].outcome -eq 'returned') 'Recovery retry count changed.'
    Assert-Probe ($byName['retry exhaustion'].httpAttempts -eq 4 -and $byName['retry exhaustion'].outcome -eq 'failed') 'Exhaustion retry count changed.'
    Assert-Probe ($byName['retries disabled'].httpAttempts -eq 1 -and $byName['authentication retry'].httpAttempts -eq 2) 'SDK retry behaviour changed.'
    foreach ($name in @('header timeout','body timeout despite raw response output')) { Assert-Probe ($byName[$name].outcome -eq 'failed' -and $byName[$name].elapsedSeconds -lt 3) 'One-second timeout was not observed.' }
    foreach ($record in @($records | Where-Object bufferBytes -eq 0 | Where-Object name -Match 'response allocation')) { Assert-Probe ($record.outcome -eq 'returned' -and $record.observedPaddingBytes -eq 8MB) 'Large-response baseline changed.' }
    foreach ($record in @($records | Where-Object bufferBytes -gt 0)) { Assert-Probe ($record.outcome -eq 'failed' -and $record.observedPaddingBytes -eq 0) 'Response buffer cap did not reject before JSON conversion.' }
    $captures = @($report.server.observations | Where-Object path -Like '/captured*')
    Assert-Probe ($captures.Count -eq 3) 'Redirect target coverage changed.'
    foreach ($name in @('same-origin redirect','host-changing redirect','port-changing redirect')) { Assert-Probe ($byName[$name].httpAttempts -eq 2) 'Redirect HTTP attempt count changed.' }
    Assert-Probe (@($captures | Where-Object { $_.path -eq '/captured-same' -and $_.hasFixtureAuthorization }).Count -eq 1) 'Same-origin fixture authorization changed.'
    Assert-Probe (@($captures | Where-Object { $_.path -ne '/captured-same' -and $_.hasAuthorization }).Count -eq 0) 'Authorization forwarded to another host/port.'
    Assert-Probe ($byName['pipeline cancellation'].outcome -eq 'Stopped' -and $byName['pipeline cancellation'].elapsedSeconds -lt 2) 'Pipeline cancellation did not stop promptly.'
    $report.status = 'PASS'
} finally {
    # SDK disconnect deletes the shared auth record; clear only this probe's memory.
    $probeSession = [Microsoft.Graph.PowerShell.Authentication.GraphSession]::Instance
    if ($probeSession.AuthContext.AuthType -eq 'UserProvidedAccessToken') {
        if ($probeSession.GraphHttpClient) { $probeSession.GraphHttpClient.Dispose() }
        $probeSession.GraphHttpClient = $null
        $probeSession.AuthContext = $null
    }
    if ($server -and -not $server.HasExited) { $server.Kill(); $server.WaitForExit() }
    $report.helperStopped = [bool]($server -and $server.HasExited)
    $report.cases=$records.ToArray()
    $report.completedAtUtc=[datetimeoffset]::UtcNow.ToString('o')
    $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutFile -Encoding utf8
    foreach ($file in @('ready.json','stdout.txt','stderr.txt')) { $path=Join-Path $temporaryDirectory $file; if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path } }
    Remove-Item -LiteralPath $temporaryDirectory
}
[pscustomobject]@{Status=$report.status;Cases=$records.Count;Report=$OutFile;TenantCalls=0} | ConvertTo-Json
