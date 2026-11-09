param(
    [Parameter(Mandatory)][string]$PythonPath,
    [Parameter(Mandatory)][string]$OutFile
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'These integration checks are verified on Windows only.' }
Import-Module Microsoft.Graph.Authentication -RequiredVersion 2.38.1
if (Get-MgContext) { throw 'Use a fresh pwsh -NoProfile process without a Graph session.' }
$PythonPath = (Resolve-Path -LiteralPath $PythonPath).Path
$OutFile = [IO.Path]::GetFullPath($OutFile)
$newReport = [IO.File]::Open($OutFile, [IO.FileMode]::CreateNew)
$newReport.Dispose()
$directory = Join-Path ([IO.Path]::GetTempPath()) ('handoff-collector-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $directory
$ready = Join-Path $directory 'ready.json'
$server = $null
$client = $null
$report = @{ status='ERROR'; tenantCalls=0; syntheticCredentialOnly=$true; cases=@() }
$cases = [Collections.Generic.List[object]]::new()
function Assert-Check($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
try {
    $arguments = '-I "' + (Join-Path $PSScriptRoot 'server.py') + '" "' + $ready + '"'
    $server = Start-Process -FilePath $PythonPath -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $directory 'stdout.txt') -RedirectStandardError (Join-Path $directory 'stderr.txt')
    $startup = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $ready) -and $startup.Elapsed.TotalSeconds -lt 5 -and -not $server.HasExited) { Start-Sleep -Milliseconds 20 }
    Assert-Check (Test-Path -LiteralPath $ready) 'Fixture did not become ready.'
    $address = Get-Content -LiteralPath $ready -Raw | ConvertFrom-Json
    $origin = [uri]$address.origin
    Assert-Check ($origin.Scheme -eq 'http' -and $origin.Host -eq '127.0.0.1' -and -not $origin.UserInfo -and -not $origin.Query -and -not $origin.Fragment) 'Expected loopback fixture.'
    Connect-MgGraph -AccessToken (ConvertTo-SecureString 'fictional-local-transport-probe' -AsPlainText -Force) -NoWelcome
    # The SDK's cloud handler rewrites even absolute URLs. Confine it explicitly.
    $fixtureEnvironment = [Activator]::CreateInstance([Microsoft.Graph.PowerShell.Authentication.GraphSession]::Instance.Environment.GetType())
    $fixtureEnvironment.Name = 'HandoffLoopbackFixture'
    $fixtureEnvironment.GraphEndpoint = $address.origin
    [Microsoft.Graph.PowerShell.Authentication.GraphSession]::Instance.Environment = $fixtureEnvironment
    $sdk = [Microsoft.Graph.PowerShell.Authentication.Helpers.HttpHelpers]::GetGraphHttpClient()
    $contextBefore = Get-MgRequestContext | ConvertTo-Json -Depth 5 -Compress
    Add-Type -Path (Join-Path $PSScriptRoot 'LoopbackGraphHandler.cs')
    $route = [Handoff.TransportChecks.LoopbackGraphHandler]::new($sdk, $address.origin)
    $client = [Net.Http.HttpClient]::new($route)
    $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
    Import-Module (Join-Path $PSScriptRoot '../../Handoff.Collection.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../../Handoff.Investigation.psm1') -Force
    $module = Get-Module Handoff.Collection
    $rejected = $false
    try { & $module { Get-HandoffGraphClient } } catch [Security.SecurityException] { $rejected = $true }
    Assert-Check $rejected 'Production accepted the test-only cloud endpoint.'
    $cases.Add(@{path='production cloud endpoint guard';status='PASS'})
    # Override only identity and routing in this disposable, fictional-session process.
    & $module {
        param($fixtureClient)
        $script:fixtureClient = $fixtureClient
        function script:Get-HandoffGraphBinding { param($TenantId) return 'fictional-fixed-binding' }
        function script:Get-HandoffGraphClient { return $script:fixtureClient }
    } $client
    & $module {
        $budget = New-HandoffReadBudget -Seconds 10 -MaxResponseBytes 1024 -CancellationToken ([Threading.CancellationToken]::None)
        try {
            $group = Invoke-HandoffGraphRequest -Uri 'https://graph.microsoft.com/v1.0/groups/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' -State @{budget=$budget;cancellation=[Threading.CancellationToken]::None}
            if ($group.id -ne 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb') { throw 'Transport setup did not read the fictional group.' }
        } finally { $budget.Dispose() }
    }
    $ids = @{ TenantId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; GroupId='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' }
    foreach ($case in @(@('/empty',$null),@('/redirect-host','redirect_rejected'),@('/gzip-large','response_limit'),@('/slow-header','deadline_exceeded'))) {
        $route.CatalogNextPath = $case[0]
        $catalog = Get-HandoffGroupCatalog -TenantId $ids.TenantId -MaxResponseBytes 1024 -TimeoutSeconds $(if ($case[0] -eq '/slow-header') { 1 } else { 10 })
        Assert-Check ($catalog.items.Count -eq 2 -and $catalog.failureCode -eq $case[1]) 'Catalog lost completed groups or the fixed transport failure.'
        Assert-Check ($catalog.status -eq $(if ($case[1]) { 'partial' } else { 'complete' })) 'Catalog claimed an incorrect completion state.'
        Assert-Check ($catalog.referenceCounts -eq 'not_collected' -and $catalog.collection.requestCount -eq 2) 'Catalog invented reference counts or changed request accounting.'
        $cases.Add(@{path=('catalog '+$case[0]);failureCode=$catalog.failureCode;status='PASS'})
    }
    $matrix = @(
        @('/empty', $null),
        @('/exact-limit', $null),
        @('/large', 'response_limit'),
        @('/large-chunked', 'response_limit'),
        @('/gzip-large', 'response_limit'),
        @('/redirect-same', 'redirect_rejected'),
        @('/redirect-host', 'redirect_rejected'),
        @('/redirect-port', 'redirect_rejected'),
        @('/always503', 'request_failed'),
        @('/always401', 'request_failed'),
        @('/malformed', 'request_failed')
    )
    foreach ($status in @(301,302,303,307,308)) { $matrix += ,@("/redirect-status-$status", 'redirect_rejected') }
    foreach ($case in $matrix) {
        $route.NextPath = $case[0]
        $before = Invoke-RestMethod ($address.origin + '/stats') -TimeoutSec 3
        $snapshot = Get-HandoffPolicySnapshot @ids -MaxResponseBytes 1024
        Assert-Check ($snapshot.conditionalAccess.failureCode -eq $case[1]) ('Wrong failure code for ' + $case[0])
        Assert-Check ($snapshot.conditionalAccess.policies.Count -eq 1 -and $snapshot.compliance.status -eq 'complete') 'Lost completed evidence or healthy source.'
        $evaluation = Get-HandoffGroupPolicyReference @ids -Snapshot $snapshot
        Assert-Check ($evaluation.references.Count -eq 1) 'Lost known reference.'
        if ($case[1]) { Assert-Check (-not $evaluation.canConcludeNoExplicitReferences -and $evaluation.coverage -eq 'incomplete') 'Failure became complete evidence.' }
        $after = Invoke-RestMethod ($address.origin + '/stats') -TimeoutSec 3
        $attempts = $after.counts.PSObject.Properties[$case[0]].Value - $before.counts.PSObject.Properties[$case[0]].Value
        Assert-Check ($attempts -eq $(if ($case[0] -in @('/always401','/empty')) { 2 } else { 1 })) ('Unexpected HTTP attempt count for ' + $case[0] + ': ' + $attempts)
        Assert-Check (@($after.observations | Where-Object path -Like '/captured*').Count -eq 0) 'A redirect target was contacted.'
        $cases.Add(@{path=$case[0];failureCode=$snapshot.conditionalAccess.failureCode;httpAttempts=$attempts;status='PASS'})
    }
    # The cap/options belong to each read, not to the cached SDK client.
    $oldSdk = $sdk
    $null = Set-MgRequestContext -ClientTimeout 5 -MaxRetry 3
    $sdk = [Microsoft.Graph.PowerShell.Authentication.Helpers.HttpHelpers]::GetGraphHttpClient()
    $route.Sdk = $sdk
    $oldSdk.Dispose()
    $contextBefore = Get-MgRequestContext | ConvertTo-Json -Depth 5 -Compress
    $route.NextPath = '/gzip-large'
    $snapshot = Get-HandoffPolicySnapshot @ids -MaxResponseBytes 1024
    Assert-Check ($snapshot.conditionalAccess.failureCode -eq 'response_limit') 'SDK reset lost the response cap.'
    $cases.Add(@{path='SDK client reset';status='PASS'})
    foreach ($path in @('/slow-header','/slow-body','/cancel')) {
        $route.NextPath = $path
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $snapshot = Get-HandoffPolicySnapshot @ids -TimeoutSeconds 1
        $watch.Stop()
        Assert-Check ($snapshot.conditionalAccess.failureCode -eq 'deadline_exceeded' -and $snapshot.compliance.failureCode -eq 'deadline_exceeded') 'Deadline did not stop subsequent reads.'
        Assert-Check ($snapshot.conditionalAccess.policies.Count -eq 1 -and $watch.Elapsed.TotalSeconds -lt 3) 'Deadline lost evidence or did not cancel network work.'
        $cases.Add(@{path=$path;status='PASS';elapsedSeconds=$watch.Elapsed.TotalSeconds})
    }
    $route.GroupPath = '/collector-group-delayed'
    $route.PolicyPath = '/collector-ca-delayed'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $snapshot = Get-HandoffPolicySnapshot @ids -TimeoutSeconds 1
    Assert-Check ($snapshot.conditionalAccess.failureCode -eq 'deadline_exceeded' -and $snapshot.collection.requestCount -eq 2 -and $watch.Elapsed.TotalSeconds -lt 2) 'Deadline restarted between requests.'
    $cases.Add(@{path='deadline across requests';status='PASS';elapsedSeconds=$watch.Elapsed.TotalSeconds})
    $route.PolicyPath = '/collector-ca'
    $route.GroupPath = '/large-chunked'
    $threw = $false
    try { $null = Get-HandoffPolicySnapshot @ids -MaxResponseBytes 1024 } catch { $threw = $true }
    Assert-Check $threw 'Oversized group response returned an investigation.'
    $cases.Add(@{path='group response cap';status='PASS'})
    $route.GroupPath = '/collector-group'
    $route.NextPath = '/cancel'
    $beforeCancellation = Invoke-RestMethod ($address.origin + '/stats') -TimeoutSec 3
    $cancel = [Threading.CancellationTokenSource]::new()
    try {
        $cancel.CancelAfter(500)
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $threw = $false
        try { $null = Get-HandoffPolicySnapshot @ids -CancellationToken $cancel.Token } catch { $threw = $true }
        Assert-Check ($threw -and $watch.Elapsed.TotalSeconds -lt 3) 'External cancellation returned observations or failed to stop.'
        $afterCancellation = Invoke-RestMethod ($address.origin + '/stats') -TimeoutSec 3
        Assert-Check (($afterCancellation.counts.'/cancel' - $beforeCancellation.counts.'/cancel') -eq 1) 'Cancellation did not reach the in-flight fixture read.'
        $cases.Add(@{path='external cancellation';status='PASS'})
    } finally { $cancel.Dispose() }
    # Drive the real catalog/read/save/export path with synthetic identity/prompts only.
    $route.GroupPath='/collector-group';$route.PolicyPath='/collector-ca';$route.NextPath='/empty';$route.CatalogNextPath='/empty'
    Import-Module (Join-Path $PSScriptRoot '../../Handoff.Console.psm1') -Force
    & (Get-Module Handoff.Console) {
        $script:fixtureAnswers=[Collections.Generic.Queue[string]]::new()
        foreach ($answer in @('READ','1','READ')) { $script:fixtureAnswers.Enqueue($answer) }
        function script:Get-HandoffConsoleReader { param($TenantId,$ClientId,$Account) return 'fictional-fixed-binding' }
        function script:Read-Host { param($Prompt) return $script:fixtureAnswers.Dequeue() }
        function script:Write-Host { param($Object) }
    }
    $guideOutput=Join-Path ([IO.Path]::GetDirectoryName($OutFile)) ('handoff-guide-fictional-'+[guid]::NewGuid().ToString('N'))
    $guide=Start-HandoffGroupInvestigation -TenantId $ids.TenantId -ClientId 'dddddddd-dddd-dddd-dddd-dddddddddddd' -Account 'fixture@example.invalid' -OutDirectory $guideOutput
    Assert-Check ($guide.status -eq 'saved' -and $guide.groupId -eq $ids.GroupId -and $guide.references -eq 1) 'Synthetic guided path did not retain the selected reference.'
    Assert-Check ((Test-Path -LiteralPath $guide.html) -and (Test-Path -LiteralPath $guide.json)) 'Guided reports were not published.'
    $report.syntheticGuideEvidenceDirectory=$guideOutput
    $cases.Add(@{path='guided synthetic SDK/catalog/read/save/export';status='PASS'})
    Assert-Check ([object]::ReferenceEquals($sdk, [Microsoft.Graph.PowerShell.Authentication.GraphSession]::Instance.GraphHttpClient)) 'Collector replaced the shared client.'
    Assert-Check ($contextBefore -ceq (Get-MgRequestContext | ConvertTo-Json -Depth 5 -Compress)) 'Collector changed the ambient request settings.'
    # Request options must not leak: the ordinary SDK still follows a later redirect.
    $normal = Invoke-MgGraphRequest -Method GET -Uri ($address.origin + '/redirect-same') -OutputType Hashtable
    $stats = Invoke-RestMethod ($address.origin + '/stats') -TimeoutSec 3
    Assert-Check (@($stats.observations | Where-Object path -eq '/captured-same').Count -eq 1) 'Request options leaked into the shared SDK.'
    $cases.Add(@{path='ambient SDK preservation';status='PASS'})
    $report.status='PASS'
} finally {
    if ($client) { $client.Dispose() }
    $session = [Microsoft.Graph.PowerShell.Authentication.GraphSession]::Instance
    if ($session.AuthContext.AuthType -eq 'UserProvidedAccessToken') {
        if ($session.GraphHttpClient) { $session.GraphHttpClient.Dispose() }
        $session.GraphHttpClient=$null
        $session.AuthContext=$null
    }
    Remove-Module Handoff.Console,Handoff.Collection,Handoff.Investigation -ErrorAction SilentlyContinue
    if ($server -and -not $server.HasExited) { $server.Kill(); $server.WaitForExit() }
    $report.helperStopped=[bool]($server -and $server.HasExited)
    $report.cases=$cases.ToArray()
    $report.completedAtUtc=[datetimeoffset]::UtcNow.ToString('o')
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutFile -Encoding utf8
    foreach ($name in @('ready.json','stdout.txt','stderr.txt')) { $file=Join-Path $directory $name; if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file } }
    Remove-Item -LiteralPath $directory
}
[pscustomobject]@{Status=$report.status;Cases=$cases.Count;Report=$OutFile;TenantCalls=0} | ConvertTo-Json
