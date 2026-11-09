#Requires -Version 7.5
# Local UI host. Graph runs only in a confirmed, isolated reader child.
$script:Axon = Import-Module (Join-Path $PSScriptRoot 'Handoff.Axon.psm1') -Scope Local -PassThru
Import-Module (Join-Path $PSScriptRoot 'Handoff.Evidence.psm1') -Scope Local
Import-Module (Join-Path $PSScriptRoot 'Handoff.Report.psm1') -Scope Local
Import-Module (Join-Path $PSScriptRoot 'Handoff.Live.psm1') -Scope Local

function New-HandoffWorkspaceState {
    param([string]$InvestigationsRoot, [string]$ReaderProfilePath)
    $state = @{items=@{};history=@{};grants=@{};pending=$null;key=$null;provider='OpenAI';model='gpt-5';warnings=@();selected=$null
        root=[IO.Path]::GetFullPath($InvestigationsRoot);live=$null;readerDefaults=@{};loadedBytes=0L}
    if ($ReaderProfilePath) {
        $profileFile=Get-Item -LiteralPath $ReaderProfilePath -Force
        if ($profileFile.Length -gt 4096 -or $profileFile.PSIsContainer -or ($profileFile.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Choose an ordinary reader profile JSON file under 4 KiB.' }
        $state.readerDefaults=ConvertTo-HandoffReaderProfile (Get-Content -LiteralPath $profileFile.FullName -Raw | ConvertFrom-Json -AsHashtable)
    }
    $sample = Get-Content (Join-Path $PSScriptRoot 'examples/group-policy-snapshot.json') -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    $samplePath = Join-Path ([IO.Path]::GetTempPath()) ('handoff-workspace-sample-' + [guid]::NewGuid().ToString('N'))
    $observation = Save-HandoffInvestigationObservation -Path $samplePath -TenantId $sample.tenantId -GroupId $sample.groupId -Snapshot $sample
    $scope = @{Path=$samplePath;TenantId=$sample.tenantId;GroupId=$sample.groupId;ObservationId=$observation.id}
    $state.items.example = @{id='example';sample=$true;scope=$scope;report=(Get-HandoffInvestigationReport @scope)}
    $usedBytes = 0L
    if (Test-Path -LiteralPath $InvestigationsRoot) {
        $root = Get-Item -LiteralPath $InvestigationsRoot -Force
        if (-not $root.PSIsContainer -or ($root.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Choose an ordinary local investigations folder.' }
        $directories = @(Get-ChildItem -LiteralPath $root.FullName -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 21)
        if ($directories.Count -gt 20) { $state.warnings += 'Only the 20 newest investigation folders were considered.' }
        foreach ($directory in ($directories | Select-Object -First 20)) {
            try {
                if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked folder.' }
                $evidence = Join-Path $directory.FullName 'evidence'
                $manifest = Get-Item -LiteralPath (Join-Path $evidence 'investigation.json') -Force
                if ($manifest.Length -gt 64KB -or ($manifest.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Invalid manifest.' }
                $length = (Get-ChildItem -LiteralPath $evidence -File -Filter '*.json' | Measure-Object Length -Sum).Sum
                if ($length -gt 64MB -or ($usedBytes + $length) -gt 64MB) { throw 'Workspace evidence budget.' }
                $usedBytes += $length
                $identity = (Get-Content -LiteralPath $manifest.FullName -Raw | ConvertFrom-Json -AsHashtable).content | ConvertFrom-Json -AsHashtable
                $saved = Get-HandoffInvestigation -Path $evidence -TenantId $identity.tenantId -GroupId $identity.groupId
                $latest = $saved.observations | Sort-Object savedAt -Descending | Select-Object -First 1
                if (-not $latest) { throw 'No observation.' }
                $scope = @{Path=$evidence;TenantId=$saved.tenantId;GroupId=$saved.groupId;ObservationId=$latest.id}
                $report = Get-HandoffInvestigationReport @scope
                if ([Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json $report -Depth 64 -Compress)) -gt 16MB) { throw 'Workspace report budget.' }
                $id = 'saved-' + $state.items.Count
                $state.items[$id] = @{id=$id;sample=$false;scope=$scope;report=$report}
            } catch { $state.warnings += 'A saved investigation could not be loaded or exceeded the local budget. Its files were not changed.' }
        }
    }
    $state.loadedBytes=$usedBytes
    return $state
}

function Get-HandoffWorkspaceLiveSummary {
    param($State)
    if (-not $State.live) { return @{status='disconnected';catalog=$null} }
    return @{status=$State.live.status;operation=$State.live.operation;profile=$State.live.profile;device=$State.live.device
        catalog=$State.live.catalog;resultId=$State.live.resultId;failureCode=$State.live.failureCode}
}

function Save-HandoffWorkspaceLiveSnapshot {
    param($State, [System.Collections.IDictionary]$Snapshot)
    $connection=$State.live
    if ($Snapshot.tenantId -ine $connection.profile.tenantId -or $Snapshot.groupId -ine $connection.expectedGroup -or $Snapshot.group.id -ine $connection.expectedGroup) { throw 'reader_binding_failed' }
    if ($State.items.Count -ge 100) { throw 'workspace_item_limit' }
    $bytes=[Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json $Snapshot -Depth 64 -Compress -WarningAction Stop))
    if ($bytes -gt 16MB -or ($State.loadedBytes + 3L*$bytes) -gt 64MB) { throw 'live_result_limit' }
    $existing=$State.items.Values | Where-Object { -not $_.sample -and $_.scope.TenantId -ieq $Snapshot.tenantId -and $_.scope.GroupId -ieq $Snapshot.groupId } | Sort-Object { $_.report.collectedAt } -Descending | Select-Object -First 1
    if ($existing) { $journal=$existing.scope.Path }
    else {
        $null=New-Item -ItemType Directory -Path $State.root -Force
        if ((Get-Item -LiteralPath $State.root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'live_save_failed' }
        $journal=Join-Path (Join-Path $State.root ([guid]::NewGuid().ToString('D'))) 'evidence'
    }
    $observation=Save-HandoffInvestigationObservation -Path $journal -TenantId $Snapshot.tenantId -GroupId $Snapshot.groupId -Snapshot $Snapshot
    $scope=@{Path=$journal;TenantId=$Snapshot.tenantId;GroupId=$Snapshot.groupId;ObservationId=$observation.id}
    $report=Get-HandoffInvestigationReport @scope
    $id='observation-' + $observation.id
    $State.items[$id]=@{id=$id;sample=$false;scope=$scope;report=$report;fresh=$true}
    $State.loadedBytes+=(Get-Item -LiteralPath (Join-Path $journal ('observation-' + $observation.id + '.json'))).Length
    $State.pending=$null
    return $id # New item/observation means no inherited AI conversation or sharing grant.
}

function Update-HandoffWorkspaceLive {
    param($State)
    $connection=$State.live
    if (-not $connection -or $connection.status -eq 'failed') { return }
    try {
        foreach ($event in @(Receive-HandoffLiveEvents $connection)) {
            switch -CaseSensitive ($event.kind) {
                'starting' { if ($connection.operation -cne 'connect') { throw 'invalid_live_event' } }
                'device' {
                    if ($connection.status -cne 'authenticating' -or $event.device.url -cne 'https://microsoft.com/devicelogin' -or $event.device.code -cnotmatch '^[A-Z0-9]{8,12}$') { throw 'invalid_live_event' }
                    $connection.device=$event.device
                }
                'connected' {
                    if ($connection.status -cne 'authenticating' -or $event.profile.tenantId -cne $connection.profile.tenantId -or $event.profile.clientId -cne $connection.profile.clientId -or $event.profile.account -ine $connection.profile.account) { throw 'reader_binding_failed' }
                    $connection.status='connected'; $connection.device=$null
                }
                'catalog' {
                    $catalog=$event.catalog
                    if ($connection.operation -cne 'catalog' -or $catalog.tenantId -cne $connection.profile.tenantId -or
                        $catalog.catalogType -cne 'visible_group_picker_v1' -or $catalog.items -isnot [array] -or $catalog.items.Count -gt 200 -or
                        $catalog.status -cnotin @('complete','partial','unavailable') -or $catalog.referenceCounts -cne 'not_collected') { throw 'invalid_live_event' }
                    $seen=[Collections.Generic.HashSet[guid]]::new()
                    foreach ($group in $catalog.items) {
                        $id=[guid]::Empty
                        if (-not [guid]::TryParse([string]$group.id,[ref]$id) -or $id -eq [guid]::Empty -or -not $seen.Add($id) -or
                            ($null -ne $group.displayName -and ($group.displayName -isnot [string] -or $group.displayName.Length -gt 1024))) { throw 'invalid_live_event' }
                    }
                    $connection.catalog=$catalog; $connection.status='connected'; $connection.device=$null
                }
                'snapshot' {
                    if ($connection.operation -cne 'collect' -or $connection.status -cne 'reading') { throw 'invalid_live_event' }
                    $connection.resultId=Save-HandoffWorkspaceLiveSnapshot -State $State -Snapshot $event.snapshot
                    $connection.status='connected'
                }
                'failed' { throw [InvalidOperationException]::new([string]$event.failureCode) }
            }
        }
        if (($connection.status -in @('authenticating','reading') -and [datetime]::UtcNow -gt $connection.deadline) -or $connection.process.HasExited) { throw 'live_operation_timeout' }
    } catch {
        $code=$_.Exception.Message
        $connection.failureCode=if ($code -in @('sdk_unavailable','reader_binding_failed','group_not_in_catalog','live_result_limit','workspace_item_limit','live_operation_timeout')) { $code } else { 'live_operation_failed' }
        $connection.status='failed'; $connection.device=$null; $connection.readTicket=$null; $State.pending=$null
        Stop-HandoffLiveConnection $connection
    }
}

function Get-HandoffWorkspaceSummary {
    param($State)
    $items = @($State.items.Values | Sort-Object sample,@{Expression={$_.report.collectedAt};Descending=$true} | ForEach-Object {
        @{id=$_.id;sample=$_.sample;fresh=[bool]$_.fresh;name=$_.report.group.displayName;groupId=$_.report.groupId;collectedAt=$_.report.collectedAt;coverage=$_.report.coverage;references=$_.report.references.Count}
    })
    return @{items=$items;provider=$State.provider;model=$State.model;keyConfigured=($null -ne $State.key);warnings=$State.warnings;selected=$State.selected
        readerDefaults=$State.readerDefaults;live=(Get-HandoffWorkspaceLiveSummary $State)}
}

function Invoke-HandoffWorkspaceAction {
    param($State, [string]$Action, [System.Collections.IDictionary]$Body)
    if ($Action -ceq 'live-disconnect') {
        Stop-HandoffLiveConnection $State.live; $State.live=$null; $State.pending=$null
        return Get-HandoffWorkspaceLiveSummary $State
    }
    Update-HandoffWorkspaceLive $State
    switch -CaseSensitive ($Action) {
        'live-status' { return Get-HandoffWorkspaceLiveSummary $State }
        'live-cancel-review' { if ($State.live) { $State.live.readTicket=$null }; return @{status='cancelled'} }
        'live-connect' {
            if ($Body.approveRead -isnot [bool] -or -not $Body.approveRead) { throw [ArgumentException]::new('Review and confirm the reader identity and three read scopes before signing in.') }
            if ($State.live -and $State.live.status -ne 'failed') { throw [ArgumentException]::new('Disconnect the current reader before connecting another one.') }
            $profile=ConvertTo-HandoffReaderProfile $Body
            $State.live=New-HandoffLiveConnection $profile; $State.pending=$null; $State.readerDefaults=$profile
            return Get-HandoffWorkspaceLiveSummary $State
        }
        'live-catalog' {
            if (-not $State.live -or $State.live.status -cne 'connected' -or $Body.approveRead -isnot [bool] -or -not $Body.approveRead) { throw [ArgumentException]::new('Connect the reader and confirm the bounded group-list read first.') }
            $State.live.catalog=$null; $State.live.readTicket=$null; $State.pending=$null
            Start-HandoffLiveOperation $State.live 'catalog'
            return Get-HandoffWorkspaceLiveSummary $State
        }
        'live-prepare' {
            $connection=$State.live
            if (-not $connection -or $connection.status -cne 'connected' -or $Body.groupId -isnot [string] -or
                @($connection.catalog.items | Where-Object id -CEQ $Body.groupId).Count -ne 1) { throw [ArgumentException]::new('Choose a group from the current reader list before collecting policies.') }
            $group=@($connection.catalog.items | Where-Object id -CEQ $Body.groupId)[0]
            $ticket=[guid]::NewGuid().ToString('N')
            $connection.readTicket=@{ticket=$ticket;groupId=$group.id;expires=[datetime]::UtcNow.AddMinutes(5)}
            $State.pending=$null
            return @{ticket=$ticket;group=$group;profile=$connection.profile;limits=@{seconds=120;pagesPerCollection=100;items=10000;requests=1000;responseBytes=4MB}}
        }
        'live-collect' {
            $connection=$State.live; $ticket=$connection.readTicket
            if (-not $connection -or $connection.status -cne 'connected' -or -not $ticket -or $Body.ticket -cne $ticket.ticket -or
                [datetime]::UtcNow -gt $ticket.expires -or $Body.approveRead -isnot [bool] -or -not $Body.approveRead) { throw [ArgumentException]::new('Review the exact group and confirm a fresh policy read; the earlier confirmation may have expired.') }
            $connection.expectedGroup=$ticket.groupId; $connection.readTicket=$null; $State.pending=$null
            Start-HandoffLiveOperation $connection 'collect' $ticket.groupId
            return Get-HandoffWorkspaceLiveSummary $State
        }
    }
    if ($Action -cin @('prepare','send') -and $State.live -and $State.live.status -in @('authenticating','reading')) { throw [ArgumentException]::new('Finish or cancel the Microsoft read before sharing an AI request.') }
    switch ($Action) {
        'state' { return Get-HandoffWorkspaceSummary $State }
        'provider' {
            if ($Body.provider -cnotin @('OpenAI','Anthropic') -or $Body.model -isnot [string] -or $Body.model -cnotmatch '^[A-Za-z0-9._:-]{1,128}$' -or
                $Body.apiKey -isnot [string] -or $Body.apiKey -cnotmatch '^[\x21-\x7e]{10,512}$') { throw [ArgumentException]::new('Check the provider, model and key. No settings were saved.') }
            $key = ConvertTo-SecureString $Body.apiKey -AsPlainText -Force
            if ($State.key) { $State.key.Dispose() }
            $State.key=$key; $State.provider=$Body.provider; $State.model=$Body.model
            $State.history=@{}; $State.grants=@{}; $State.pending=$null
            return Get-HandoffWorkspaceSummary $State
        }
        'forget' {
            if ($State.key) { $State.key.Dispose() }; $State.key=$null
            $State.history=@{}; $State.grants=@{}; $State.pending=$null
            return Get-HandoffWorkspaceSummary $State
        }
    }
    if ($Body.id -isnot [string] -or -not $State.items.ContainsKey($Body.id)) { throw [ArgumentException]::new('Select a saved investigation from this workspace.') }
    $item = $State.items[$Body.id]
    switch ($Action) {
        'investigation' {
            $State.selected=$Body.id; $State.pending=$null
            return @{report=$item.report;sample=$item.sample;fresh=[bool]$item.fresh;messages=@($State.history[$Body.id] | Where-Object { $null -ne $_ });approved=$State.grants.ContainsKey($Body.id)}
        }
        'reset' {
            $State.history.Remove($Body.id); $State.grants.Remove($Body.id); $State.pending=$null
            return @{status='reset'}
        }
        'cancel' { $State.pending=$null; return @{status='cancelled'} }
        'prepare' {
            $State.pending=$null
            if (-not $State.key) { throw [ArgumentException]::new('Add your AI provider key in AI settings first.') }
            if ($State.selected -cne $Body.id) { throw [ArgumentException]::new('The selected investigation changed. Reopen it before sending.') }
            if ($Body.question -isnot [string] -or [string]::IsNullOrWhiteSpace($Body.question) -or $Body.question.Length -gt 4000) { throw [ArgumentException]::new('Write a question of 1 to 4,000 characters.') }
            if ($Body.question -match 'sk-[A-Za-z0-9_-]{12,}') { throw [ArgumentException]::new('That looks like an API key. Remove it from the question; nothing was sent.') }
            $scope = @{} + $item.scope + @{Provider=$State.provider;Model=$State.model}
            $history = @($State.history[$Body.id] | Where-Object { $null -ne $_ })
            $prepared = & $script:Axon { param($s,$q,$h) New-HandoffAxonConversationTurn -Scope $s -Question $q -History $h } $scope $Body.question $history
            $ticket = [guid]::NewGuid().ToString('N')
            $State.pending = @{ticket=$ticket;id=$Body.id;question=$Body.question;prepared=$prepared;expires=[datetime]::UtcNow.AddMinutes(5)}
            return @{ticket=$ticket;sharing=$prepared.sharing;approvalRequired=(-not $State.grants.ContainsKey($Body.id));name=$item.report.group.displayName;technicalPayload=$prepared.body}
        }
        'send' {
            $pending=$State.pending
            if (-not $pending -or $Body.ticket -cne $pending.ticket -or $Body.id -cne $pending.id -or $State.selected -cne $pending.id -or
                [datetime]::UtcNow -gt $pending.expires -or -not $State.key) { throw [ArgumentException]::new('This request expired or changed. Send the question again to review it.') }
            if (-not $State.grants.ContainsKey($Body.id) -and ($Body.approveSharing -isnot [bool] -or -not $Body.approveSharing)) { throw [ArgumentException]::new('Approve sharing for this investigation and provider before sending.') }
            $State.pending=$null # Consume before transport: repeated clicks cannot resend it.
            $State.grants[$Body.id]=$true
            $answer = & $script:Axon { param($p,$k) Send-HandoffAxonConversationTurn -Prepared $p -ApiKey $k } $pending.prepared $State.key
            if ($answer.status -eq 'answered') {
                $State.history[$Body.id] = @($State.history[$Body.id] | Where-Object { $null -ne $_ }) + @(@{role='user';content=$pending.question},@{role='assistant';content=$answer.answer;truncated=[bool]$answer.truncated})
            }
            return $answer
        }
        default { throw [ArgumentException]::new('Unsupported workspace action.') }
    }
}

function Test-HandoffWorkspaceRequest {
    param($Request, [string]$Origin, [string]$Token, [switch]$Api)
    if ($Request.UserHostName -cne ([uri]$Origin).Authority -or $Request.Url.Host -cne '127.0.0.1' -or
        $Request.Headers['Sec-Fetch-Site'] -eq 'cross-site') { return $false }
    if ($Api -and ($Request.Headers['X-Handoff-Session'] -cne $Token -or
        ($Request.HttpMethod -cne 'GET' -and $Request.Headers['Origin'] -cne $Origin))) { return $false }
    return $true
}

function Start-HandoffWorkspace {
    [CmdletBinding()]
    param([string]$InvestigationsRoot = (Join-Path $env:LOCALAPPDATA 'Handoff/Investigations'), [ValidateRange(1024,65535)][int]$Port=43187, [switch]$NoBrowser, [string]$ReaderProfilePath)
    $state = New-HandoffWorkspaceState -InvestigationsRoot $InvestigationsRoot -ReaderProfilePath $ReaderProfilePath
    $token = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
    $origin="http://127.0.0.1:$Port"
    $listener=[Net.HttpListener]::new(); $listener.Prefixes.Add("$origin/")
    $assets=@{'/'=@('index.html','text/html; charset=utf-8');'/app.js'=@('app.js','text/javascript; charset=utf-8');'/app.css'=@('app.css','text/css; charset=utf-8');'/mark.svg'=@('mark.svg','image/svg+xml');'/Geist.woff2'=@('Geist.woff2','font/woff2')}
    try {
        $listener.Start()
        Write-Host "Handoff workspace: $origin (local only). Close it with Stop workspace in the UI."
        if (-not $NoBrowser) { Start-Process "$origin/#$token" | Out-Null }
        else { Write-Output (@{url="$origin/#$token";port=$Port} | ConvertTo-Json -Compress) }
        $lastRequest=[datetime]::UtcNow
        $running=$true
        while ($running -and ([datetime]::UtcNow - $lastRequest).TotalMinutes -lt 60) {
            $waiting=$listener.GetContextAsync()
            while (-not $waiting.Wait(1000)) { if (([datetime]::UtcNow - $lastRequest).TotalMinutes -ge 60) { $running=$false; break } }
            if (-not $running) { break }
            $context=$waiting.GetAwaiter().GetResult(); $request=$context.Request; $response=$context.Response
            $lastRequest=[datetime]::UtcNow
            $response.Headers['Cache-Control']='no-store'
            $response.Headers['X-Content-Type-Options']='nosniff'
            $response.Headers['Referrer-Policy']='no-referrer'
            $response.Headers['Content-Security-Policy']="default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
            $response.Headers['Permissions-Policy']='camera=(), microphone=(), geolocation=()'
            try {
                $path=$request.Url.AbsolutePath; $api=$path.StartsWith('/api/',[StringComparison]::Ordinal)
                if (-not (Test-HandoffWorkspaceRequest -Request $request -Origin $origin -Token $token -Api:$api)) { $response.StatusCode=403; $bytes=[Text.Encoding]::UTF8.GetBytes('{"error":"This browser request is not authorised for the local workspace."}') }
                elseif ($assets.ContainsKey($path) -and $request.HttpMethod -ceq 'GET') {
                    $response.ContentType=$assets[$path][1]
                    $bytes=[IO.File]::ReadAllBytes((Join-Path $PSScriptRoot ('workspace/' + $assets[$path][0])))
                } elseif ($api -and $request.HttpMethod -ceq 'POST' -and $request.ContentType -like 'application/json*' -and $request.ContentLength64 -ge 0 -and $request.ContentLength64 -le 64KB) {
                    # Bound both size and read time before JSON parsing.
                    $inputBytes=[byte[]]::new([int]$request.ContentLength64)
                    $deadline=[Threading.CancellationTokenSource]::new([timespan]::FromSeconds(5))
                    try { $null=$request.InputStream.ReadExactlyAsync([Memory[byte]]$inputBytes,$deadline.Token).AsTask().GetAwaiter().GetResult() }
                    finally { $deadline.Dispose() }
                    $body=[Text.Encoding]::UTF8.GetString($inputBytes) | ConvertFrom-Json -AsHashtable -Depth 8
                    if ($body -isnot [System.Collections.IDictionary]) { throw [ArgumentException]::new('Expected a workspace request object.') }
                    $action=$path.Substring(5)
                    if ($action -ceq 'stop') { $running=$false; $result=@{status='stopped'} }
                    else { $result=Invoke-HandoffWorkspaceAction -State $state -Action $action -Body $body }
                    $body=$null
                    $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $result -Depth 64 -Compress))
                } else { $response.StatusCode=404; $bytes=[Text.Encoding]::UTF8.GetBytes('{"error":"This workspace endpoint is not available."}') }
            } catch {
                $response.StatusCode=400
                $message=if ($_.Exception -is [ArgumentException]) { $_.Exception.Message } else { 'Handoff could not complete this request. Check the selected evidence and AI settings, or restart the workspace. Nothing was changed in your tenant.' }
                $bytes=[Text.Encoding]::UTF8.GetBytes((@{error=$message} | ConvertTo-Json -Compress))
            } finally { $request.InputStream.Close() }
            try {
                if (-not $response.ContentType) { $response.ContentType='application/json; charset=utf-8' }
                $response.ContentLength64=$bytes.Length
                $response.OutputStream.Write($bytes,0,$bytes.Length)
            } finally { $response.Close() }
        }
    } finally {
        Stop-HandoffLiveConnection $state.live
        if ($state.key) { $state.key.Dispose(); $state.key=$null }
        $state.history.Clear(); $state.pending=$null; $state.grants.Clear()
        $listener.Close()
    }
}

Export-ModuleMember -Function Start-HandoffWorkspace
