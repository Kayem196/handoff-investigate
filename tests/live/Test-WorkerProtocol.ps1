param([switch]$BadBinding,[switch]$UnsupportedCommand)
# Fresh-process offline check of the real worker loop, with no Graph SDK or network.
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../../Handoff.Live.psm1')
$module=Get-Module Handoff.Live
$snapshot=Get-Content (Join-Path $PSScriptRoot '../../examples/group-policy-snapshot.json') -Raw | ConvertFrom-Json -AsHashtable -DateKind String
$profile=@{tenantId=$snapshot.tenantId;clientId='cccccccc-cccc-cccc-cccc-cccccccccccc';account='reader@fictional.invalid'}
$init=@{requestId=('1'*32);profile=$profile} | ConvertTo-Json -Compress
$catalog=@{requestId=('2'*32);action=$(if($UnsupportedCommand){'Invoke-Expression'}else{'catalog'})} | ConvertTo-Json -Compress
$collect=@{requestId=('3'*32);action='collect';groupId=$snapshot.groupId} | ConvertTo-Json -Compress
$inputText=$init+"`n"+$catalog+"`n"+$collect+"`n"
$inputReader=[IO.StringReader]::new($inputText);$outputWriter=[IO.StringWriter]::new()
$oldIn=[Console]::In;$oldOut=[Console]::Out
try {
    [Console]::SetIn($inputReader);[Console]::SetOut($outputWriter)
    $captured=& $module {
        param($p,$s,$bad)
        $script:WorkerFixtureProfile=$p;$script:WorkerFixtureSnapshot=$s;$script:WorkerFixtureBadBinding=$bad
        $script:WorkerFixtureScopes=@();$script:WorkerFixtureReads=0
        function script:Import-Module {
            param($Name,$RequiredVersion,$Scope,$ErrorAction)
            if ($Name -eq 'Microsoft.Graph.Authentication' -and [string]$RequiredVersion -eq '2.38.1') { return }
            if ([string]$Name -like '*Handoff.Collection.psm1') { return }
            throw 'Unexpected import in offline worker check.'
        }
        function script:Get-MgContext {
            if (-not $script:WorkerFixtureScopes.Count) { return $null }
            $scopes=$script:WorkerFixtureScopes
            if ($script:WorkerFixtureBadBinding) { $scopes+=@('Group.ReadWrite.All') }
            return [pscustomobject]@{TenantId=$script:WorkerFixtureProfile.tenantId;ClientId=$script:WorkerFixtureProfile.clientId;Account=$script:WorkerFixtureProfile.account;AuthType='Delegated';ContextScope='Process';Environment='Global';Scopes=$scopes}
        }
        function script:Connect-MgGraph {
            [CmdletBinding()]param($TenantId,$ClientId,$ContextScope,$Environment,[switch]$NoWelcome,[switch]$UseDeviceAuthentication,[string[]]$Scopes)
            if ($TenantId -ne $script:WorkerFixtureProfile.tenantId -or $ClientId -ne $script:WorkerFixtureProfile.clientId -or $ContextScope -ne 'Process' -or $Environment -ne 'Global' -or -not $UseDeviceAuthentication) { throw 'Unexpected auth profile.' }
            $script:WorkerFixtureScopes=$Scopes
            'To sign in, use a web browser to open the page https://microsoft.com/devicelogin and enter the code ABCD12345 to authenticate.'
        }
        function script:Get-HandoffGroupCatalog {
            param($TenantId,$MaxGroups,$TimeoutSeconds)
            if ($MaxGroups -ne 200 -or $TimeoutSeconds -ne 120) { throw 'Unbounded catalog.' }
            $script:WorkerFixtureReads++
            return @{tenantId=$TenantId;items=@(@{id=$script:WorkerFixtureSnapshot.groupId;displayName='Support team'})}
        }
        function script:Get-HandoffPolicySnapshot {
            param($TenantId,$GroupId,$TimeoutSeconds)
            if ([string]$GroupId -ne $script:WorkerFixtureSnapshot.groupId -or $TimeoutSeconds -ne 120) { throw 'Unexpected policy scope.' }
            $script:WorkerFixtureReads++
            return $script:WorkerFixtureSnapshot
        }
        Invoke-HandoffLiveWorker
        return @{scopes=$script:WorkerFixtureScopes;reads=$script:WorkerFixtureReads}
    } $profile $snapshot $BadBinding.IsPresent
} finally { [Console]::SetIn($oldIn);[Console]::SetOut($oldOut);$inputReader.Dispose() }
$events=@($outputWriter.ToString().Trim() -split '\r?\n' | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable -Depth 64 })
$outputWriter.Dispose()
if (Get-Module Microsoft.Graph.Authentication) { throw 'The offline worker check loaded the SDK.' }
$expected=@('GroupMember.Read.All','Policy.Read.All','DeviceManagementConfiguration.Read.All')
if (@(Compare-Object ($captured.scopes | Sort-Object) ($expected | Sort-Object)).Count) { throw 'Worker requested unexpected scopes.' }
if ($BadBinding) {
    if ($events[-1].failureCode -ne 'reader_binding_failed' -or $captured.reads -ne 0) { throw 'Unsafe binding was accepted.' }
} elseif ($UnsupportedCommand) {
    if ($events[-1].failureCode -ne 'unsupported_live_action' -or $captured.reads -ne 0) { throw 'An arbitrary command was accepted.' }
} elseif (($events.kind -join ',') -ne 'starting,device,connected,catalog,snapshot' -or $captured.reads -ne 2) { throw 'Worker protocol did not complete its fixed operation sequence.' }
[pscustomobject]@{status='PASS';case=$(if($BadBinding){'bad-binding'}elseif($UnsupportedCommand){'unsupported-command'}else{'fixed-sequence'});events=@($events.kind);requestedScopes=$captured.scopes;reads=$captured.reads;networkCalls=0} | ConvertTo-Json -Compress
