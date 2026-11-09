#Requires -Version 7.5
# The UI host never imports Graph: a private stdio child owns the delegated session.
function ConvertTo-HandoffReaderProfile {
    param([System.Collections.IDictionary]$Value)
    $tenant=[guid]::Empty; $client=[guid]::Empty
    if (-not [guid]::TryParse([string]$Value.tenantId,[ref]$tenant) -or $tenant -eq [guid]::Empty -or
        -not [guid]::TryParse([string]$Value.clientId,[ref]$client) -or $client -eq [guid]::Empty -or
        $Value.account -isnot [string] -or $Value.account.Length -gt 254 -or $Value.account -notmatch '^[^\s\p{Cc}\p{Cf}]+@[^\s\p{Cc}\p{Cf}]+$') {
        throw [ArgumentException]::new('Enter a tenant ID, dedicated reader client ID and expected sign-in account.')
    }
    return @{tenantId=$tenant.ToString();clientId=$client.ToString();account=$Value.account}
}

function Get-HandoffLiveBinding {
    param($Profile)
    $context=Get-MgContext -ErrorAction Stop
    $required=@('GroupMember.Read.All','Policy.Read.All','DeviceManagementConfiguration.Read.All')
    $allowed=$required+@('openid','profile','offline_access','email')
    if (-not $context -or $context.TenantId -ine $Profile.tenantId -or $context.ClientId -ine $Profile.clientId -or $context.Account -ine $Profile.account -or
        $context.AuthType -cne 'Delegated' -or $context.ContextScope -cne 'Process' -or $context.Environment -cne 'Global' -or
        @($required | Where-Object { $_ -cnotin $context.Scopes }).Count -or @($context.Scopes | Where-Object { $_ -cnotin $allowed }).Count) {
        throw [Security.SecurityException]::new('reader_binding_failed')
    }
    return (@($context.TenantId,$context.ClientId,$context.Account,$context.AuthType,$context.ContextScope,$context.Environment,(@($context.Scopes | Sort-Object) -join ',')) | ConvertTo-Json -Compress)
}

function ConvertFrom-HandoffDeviceMessage {
    param([string]$Message)
    # Only the known SDK's device message is translated, never raw SDK errors or tokens.
    # SDK 2.38.1 currently prints login.microsoft.com/device; the older address is also official.
    if ($Message.Length -le 2000 -and $Message -match '(https://(?:login\.microsoft\.com/device|microsoft\.com/devicelogin))(?![\w./-])[^\r\n]*?\bcode\s+([A-Z0-9]{8,12})\b') {
        return @{url=$Matches[1];code=$Matches[2]}
    }
    return $null
}

function Write-HandoffLiveEvent {
    param([hashtable]$Event)
    $json=ConvertTo-Json -InputObject $Event -Depth 64 -Compress -WarningAction Stop
    if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 16MB) { throw [InvalidOperationException]::new('live_result_limit') }
    [Console]::Out.WriteLine($json); [Console]::Out.Flush()
}

function Invoke-HandoffLiveWorker {
    $ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'
    $WarningPreference='SilentlyContinue'; $VerbosePreference='SilentlyContinue'; $DebugPreference='SilentlyContinue'
    [Threading.Thread]::CurrentThread.CurrentUICulture='en-US'
    $requestId=$null
    try {
        $line=[Console]::In.ReadLine()
        if (-not $line -or $line.Length -gt 4096) { throw 'invalid_initialization' }
        $init=$line | ConvertFrom-Json -AsHashtable -Depth 8
        $requestId=$init.requestId
        if ($requestId -notmatch '^[a-f0-9]{32}$') { throw 'invalid_initialization' }
        $profile=ConvertTo-HandoffReaderProfile $init.profile
        try { Import-Module Microsoft.Graph.Authentication -RequiredVersion 2.38.1 -ErrorAction Stop }
        catch { throw [InvalidOperationException]::new('sdk_unavailable') }
        if (Get-MgContext) { throw [Security.SecurityException]::new('reader_binding_failed') }
        Import-Module (Join-Path $PSScriptRoot 'Handoff.Collection.psm1') -Scope Local
        Write-HandoffLiveEvent @{requestId=$requestId;kind='starting'}
        Connect-MgGraph -TenantId $profile.tenantId -ClientId $profile.clientId -ContextScope Process -Environment Global -NoWelcome -UseDeviceAuthentication `
            -Scopes GroupMember.Read.All,Policy.Read.All,DeviceManagementConfiguration.Read.All -ErrorAction Stop | ForEach-Object {
                if ($_ -is [string]) { $device=ConvertFrom-HandoffDeviceMessage $_; if ($device) { Write-HandoffLiveEvent @{requestId=$requestId;kind='device';device=$device} } }
            }
        $binding=Get-HandoffLiveBinding $profile
        Write-HandoffLiveEvent @{requestId=$requestId;kind='connected';profile=$profile}
        $catalog=$null
        while ($null -ne ($line=[Console]::In.ReadLine())) {
            if ($line.Length -gt 4096) { throw 'invalid_command' }
            $command=$line | ConvertFrom-Json -AsHashtable -Depth 8
            $requestId=$command.requestId
            if ($requestId -notmatch '^[a-f0-9]{32}$' -or (Get-HandoffLiveBinding $profile) -cne $binding) { throw [Security.SecurityException]::new('reader_binding_failed') }
            switch -CaseSensitive ($command.action) {
                'catalog' {
                    $catalog=Get-HandoffGroupCatalog -TenantId $profile.tenantId -MaxGroups 200 -TimeoutSeconds 120
                    if ((Get-HandoffLiveBinding $profile) -cne $binding) { throw [Security.SecurityException]::new('reader_binding_failed') }
                    Write-HandoffLiveEvent @{requestId=$requestId;kind='catalog';catalog=$catalog}
                }
                'collect' {
                    $group=[guid]::Empty
                    if (-not [guid]::TryParse([string]$command.groupId,[ref]$group) -or -not $catalog -or
                        @($catalog.items | Where-Object id -CEQ $group.ToString()).Count -ne 1) { throw [Security.SecurityException]::new('group_not_in_catalog') }
                    $snapshot=Get-HandoffPolicySnapshot -TenantId $profile.tenantId -GroupId $group -TimeoutSeconds 120
                    if ((Get-HandoffLiveBinding $profile) -cne $binding -or $snapshot.tenantId -ine $profile.tenantId -or $snapshot.groupId -ine $group.ToString() -or $snapshot.group.id -ine $group.ToString()) { throw [Security.SecurityException]::new('reader_binding_failed') }
                    Write-HandoffLiveEvent @{requestId=$requestId;kind='snapshot';snapshot=$snapshot}
                }
                default { throw [Security.SecurityException]::new('unsupported_live_action') }
            }
        }
    } catch {
        $code=if ($_.Exception.Message -in @('sdk_unavailable','reader_binding_failed','group_not_in_catalog','unsupported_live_action','live_result_limit')) { $_.Exception.Message } else { 'live_operation_failed' }
        Write-HandoffLiveEvent @{requestId=$requestId;kind='failed';failureCode=$code}
    } finally {
        # Do not call Disconnect-MgGraph: it can touch the user's shared auth record.
        if ('Microsoft.Graph.PowerShell.Authentication.GraphSession' -as [type]) {
            $session=[Microsoft.Graph.PowerShell.Authentication.GraphSession]::Instance
            if ($session.GraphHttpClient) { $session.GraphHttpClient.Dispose() }
            $session.GraphHttpClient=$null; $session.AuthContext=$null
            if ($session.InMemoryTokenCache) { $session.InMemoryTokenCache.ClearCache() }
        }
    }
}

function New-HandoffLiveConnection {
    param([hashtable]$Profile)
    $profile=ConvertTo-HandoffReaderProfile $Profile
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=(Get-Process -Id $PID).Path
    foreach ($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot 'workspace/Invoke-LiveWorker.ps1'))) { $start.ArgumentList.Add($argument) }
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $process=[Diagnostics.Process]::Start($start)
    $id=[guid]::NewGuid().ToString('N')
    try {
        $process.StandardInput.WriteLine((@{requestId=$id;profile=$profile} | ConvertTo-Json -Compress)); $process.StandardInput.Flush()
        return @{process=$process;line=$process.StandardOutput.ReadLineAsync();errors=$process.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
            profile=$profile;requestId=$id;status='authenticating';operation='connect';deadline=[datetime]::UtcNow.AddSeconds(150);device=$null;catalog=$null;readTicket=$null;resultId=$null;failureCode=$null}
    } catch { if (-not $process.HasExited) { $process.Kill($true) }; $process.Dispose(); throw }
}

function Start-HandoffLiveOperation {
    param($Connection,[string]$Action,[string]$GroupId)
    if ($Connection.status -cne 'connected' -or $Action -cnotin @('catalog','collect') -or $Connection.process.HasExited) { throw [ArgumentException]::new('Connect the reviewed reader and finish its current operation first.') }
    $id=[guid]::NewGuid().ToString('N')
    $command=@{requestId=$id;action=$Action}
    if ($Action -eq 'collect') { $command.groupId=$GroupId }
    $Connection.process.StandardInput.WriteLine(($command | ConvertTo-Json -Compress)); $Connection.process.StandardInput.Flush()
    $Connection.requestId=$id; $Connection.status='reading'; $Connection.operation=$Action
    $Connection.deadline=[datetime]::UtcNow.AddSeconds(140); $Connection.resultId=$null; $Connection.failureCode=$null
}

function Receive-HandoffLiveEvents {
    param($Connection)
    $events=[Collections.Generic.List[object]]::new()
    for ($i=0; $i -lt 8 -and $Connection.line -and $Connection.line.IsCompleted; $i++) {
        $line=$Connection.line.GetAwaiter().GetResult()
        if ($null -eq $line) { break }
        $Connection.line=$Connection.process.StandardOutput.ReadLineAsync()
        if ($line.Length -gt 16MB) { throw 'live_result_limit' }
        # Ignore unknown SDK stdout, never relay it to the browser or AI.
        if (-not $line.StartsWith('{',[StringComparison]::Ordinal)) { continue }
        $event=$line | ConvertFrom-Json -AsHashtable -Depth 64 -DateKind String
        if ($event.requestId -cne $Connection.requestId -or $event.kind -cnotin @('starting','device','connected','catalog','snapshot','failed')) { throw 'invalid_live_event' }
        $events.Add($event)
    }
    return $events.ToArray()
}

function Stop-HandoffLiveConnection {
    param($Connection)
    if ($Connection -and $Connection.process) {
        try { if (-not $Connection.process.HasExited) { $Connection.process.Kill($true); $null=$Connection.process.WaitForExit(5000) } }
        finally { $Connection.process.Dispose(); $Connection.process=$null; $Connection.line=$null; $Connection.device=$null; $Connection.readTicket=$null }
    }
}

Export-ModuleMember -Function ConvertTo-HandoffReaderProfile,New-HandoffLiveConnection,Start-HandoffLiveOperation,Receive-HandoffLiveEvents,Stop-HandoffLiveConnection,Invoke-HandoffLiveWorker
