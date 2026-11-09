BeforeAll {
    Import-Module "$PSScriptRoot/../Handoff.Workspace.psm1" -Force
    $script:workspace=Get-Module Handoff.Workspace
    $script:liveModule=Get-Module Handoff.Live -All | Select-Object -First 1
    function LiveAction($name,$body=@{}) { & $workspace { param($s,$n,$b) Invoke-HandoffWorkspaceAction -State $s -Action $n -Body $b } $state $name $body }
    function ConnectedReader {
        $null=LiveAction live-connect ($profile + @{approveRead=$true})
        $script:events=@(@{kind='connected';profile=$profile})
        $null=LiveAction live-status
    }
    function CatalogReader {
        ConnectedReader
        $null=LiveAction live-catalog @{approveRead=$true}
        $script:events=@(@{kind='catalog';catalog=$catalog})
        $null=LiveAction live-status
    }
}
Describe 'Workspace live reader authority and evidence' {
    BeforeEach {
        $script:state=& $workspace { param($p) New-HandoffWorkspaceState $p } (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $script:profile=@{tenantId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';clientId='cccccccc-cccc-cccc-cccc-cccccccccccc';account='reader@fictional.invalid'}
        $script:group='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        $script:catalog=@{tenantId=$profile.tenantId;catalogType='visible_group_picker_v1';status='complete';referenceCounts='not_collected';items=@(@{id=$group;displayName='Support team'})}
        $script:events=@();$script:reads=[Collections.Generic.List[object]]::new()
        Mock New-HandoffLiveConnection -ModuleName Handoff.Workspace { param($Profile) @{profile=$Profile;status='authenticating';operation='connect';process=[pscustomobject]@{HasExited=$false};deadline=[datetime]::UtcNow.AddMinutes(2);device=$null;catalog=$null;readTicket=$null;resultId=$null;failureCode=$null} }
        Mock Receive-HandoffLiveEvents -ModuleName Handoff.Workspace { $output=$script:events; $script:events=@(); return $output }
        Mock Start-HandoffLiveOperation -ModuleName Handoff.Workspace {
            param($Connection,$Action,$GroupId)
            $script:reads.Add(@{action=$Action;groupId=$GroupId})
            $Connection.status='reading';$Connection.operation=$Action;$Connection.resultId=$null
        }
        Mock Stop-HandoffLiveConnection -ModuleName Handoff.Workspace {}
    }
    It 'starts no Microsoft process merely by loading the workspace or submitting unapproved sign-in' {
        (LiveAction state).live.status | Should -Be 'disconnected'
        { LiveAction live-connect ($profile+@{approveRead=$false}) } | Should -Throw '*Review and confirm*'
        { LiveAction live-connect ($profile+@{approveRead=@($true)}) } | Should -Throw '*Review and confirm*'
        Should -Invoke New-HandoffLiveConnection -ModuleName Handoff.Workspace -Times 0
    }
    It 'validates profile identity and cannot silently replace an active reader' {
        { LiveAction live-connect @{tenantId='invalid';clientId=$profile.clientId;account=$profile.account;approveRead=$true} } | Should -Throw '*tenant ID*'
        ConnectedReader
        { LiveAction live-connect ($profile+@{approveRead=$true}) } | Should -Throw '*Disconnect*'
        $reads.Count | Should -Be 0
    }
    It 'does not accept a different signed-in tenant or leak raw worker failures' {
        $null=LiveAction live-connect ($profile+@{approveRead=$true})
        $script:events=@(@{kind='connected';profile=($profile+@{})})
        $events[0].profile.tenantId='dddddddd-dddd-dddd-dddd-dddddddddddd'
        $result=LiveAction live-status
        $result.status | Should -Be 'failed'
        $result.failureCode | Should -Be 'reader_binding_failed'
        Should -Invoke Stop-HandoffLiveConnection -ModuleName Handoff.Workspace -Times 1
    }
    It 'requires a confirmed catalog read and withholds unknown group IDs' {
        ConnectedReader
        { LiveAction live-catalog @{} } | Should -Throw '*confirm*'
        { LiveAction live-prepare @{groupId=$group} } | Should -Throw '*current reader list*'
        $null=LiveAction live-catalog @{approveRead=$true}
        $script:events=@(@{kind='catalog';catalog=$catalog});$null=LiveAction live-status
        { LiveAction live-prepare @{groupId='eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'} } | Should -Throw '*current reader list*'
        $reads.Count | Should -Be 1
    }
    It 'binds a one-use read confirmation to the catalog group and enforces its expiry' {
        CatalogReader
        $review=LiveAction live-prepare @{groupId=$group}
        $null=LiveAction live-cancel-review
        { LiveAction live-collect @{ticket=$review.ticket;approveRead=$true} } | Should -Throw '*expired*'
        $review=LiveAction live-prepare @{groupId=$group}
        { LiveAction live-collect @{ticket=$review.ticket;approveRead=$false} } | Should -Throw '*Review the exact group*'
        $state.live.readTicket.expires=[datetime]::UtcNow.AddSeconds(-1)
        { LiveAction live-collect @{ticket=$review.ticket;approveRead=$true} } | Should -Throw '*expired*'
        $review=LiveAction live-prepare @{groupId=$group}
        $null=LiveAction live-collect @{ticket=$review.ticket;approveRead=$true;groupId='eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'}
        $reads[1].groupId | Should -Be $group
        { LiveAction live-collect @{ticket=$review.ticket;approveRead=$true} } | Should -Throw
        $reads.Count | Should -Be 2
    }
    It 'saves fresh observations append-only and never inherits an old chat or sharing grant' {
        CatalogReader
        $snapshot=Get-Content "$PSScriptRoot/../examples/group-policy-snapshot.json" -Raw | ConvertFrom-Json -AsHashtable -DateKind String
        $snapshot.collectedAt='2026-11-09T12:00:00.0000000+00:00'
        $review=LiveAction live-prepare @{groupId=$group};$null=LiveAction live-collect @{ticket=$review.ticket;approveRead=$true}
        $script:events=@(@{kind='snapshot';snapshot=$snapshot})
        $first=(LiveAction live-status).resultId
        $state.items[$first].fresh | Should -BeTrue
        $state.grants[$first]=$true;$state.history[$first]=@(@{role='user';content='Old conversation'})
        $manifest=Join-Path $state.items[$first].scope.Path 'investigation.json'
        $hash=(Get-FileHash $manifest).Hash
        $snapshot.collectedAt='2026-11-09T13:00:00.0000000+00:00'
        $review=LiveAction live-prepare @{groupId=$group};$null=LiveAction live-collect @{ticket=$review.ticket;approveRead=$true}
        $state.pending=@{ticket='stale-model-request'}
        $script:events=@(@{kind='snapshot';snapshot=$snapshot})
        $second=(LiveAction live-status).resultId
        $second | Should -Not -Be $first
        $state.items[$second].scope.Path | Should -Be $state.items[$first].scope.Path
        $state.items[$second].scope.ObservationId | Should -Not -Be $state.items[$first].scope.ObservationId
        $state.grants.ContainsKey($second) | Should -BeFalse
        $state.history.ContainsKey($second) | Should -BeFalse
        $state.history[$first][0].content | Should -Be 'Old conversation'
        $state.pending | Should -BeNullOrEmpty
        (Get-FileHash $manifest).Hash | Should -Be $hash
        @(Get-ChildItem $state.items[$second].scope.Path -Filter 'observation-*.json').Count | Should -Be 2
    }
    It 'rejects a foreign snapshot instead of saving it' {
        CatalogReader
        $review=LiveAction live-prepare @{groupId=$group};$null=LiveAction live-collect @{ticket=$review.ticket;approveRead=$true}
        $snapshot=Get-Content "$PSScriptRoot/../examples/group-policy-snapshot.json" -Raw | ConvertFrom-Json -AsHashtable -DateKind String
        $snapshot.tenantId='dddddddd-dddd-dddd-dddd-dddddddddddd'
        $script:events=@(@{kind='snapshot';snapshot=$snapshot})
        (LiveAction live-status).failureCode | Should -Be 'reader_binding_failed'
        $state.items.Count | Should -Be 1
        Test-Path $state.root | Should -BeFalse
    }
    It 'withholds AI sends during Microsoft operations and can disconnect without losing AI state' {
        ConnectedReader
        $state.key=ConvertTo-SecureString 'fictional-provider-key-123' -AsPlainText -Force
        $state.history.example=@(@{role='user';content='Earlier question'})
        $null=LiveAction live-catalog @{approveRead=$true}
        { LiveAction prepare @{id='example';question='Explain'} } | Should -Throw '*Finish or cancel*'
        $null=LiveAction live-disconnect
        $state.live | Should -BeNullOrEmpty
        $state.key.Length | Should -BeGreaterThan 0
        $state.history.example.Count | Should -Be 1
        $state.key.Dispose()
    }
    It 'accepts only a Microsoft device-code link and returns fixed timeout codes' {
        $null=LiveAction live-connect ($profile+@{approveRead=$true})
        $script:events=@(@{kind='device';device=@{url='https://attacker.invalid';code='ABCDEFGH'}})
        (LiveAction live-status).status | Should -Be 'failed'
        $null=LiveAction live-connect ($profile+@{approveRead=$true})
        $state.live.deadline=[datetime]::UtcNow.AddSeconds(-1)
        (LiveAction live-status).failureCode | Should -Be 'live_operation_timeout'
    }
}
Describe 'Pinned device message translation' {
    It 'extracts only the known Microsoft prompt, never arbitrary provider text' {
        $translate={ param($m) ConvertFrom-HandoffDeviceMessage $m }
        $device=& $liveModule $translate 'To sign in, use a web browser to open the page https://microsoft.com/devicelogin and enter the code ABCD12345 to authenticate.'
        $device.url | Should -Be 'https://microsoft.com/devicelogin'
        $device.code | Should -Be 'ABCD12345'
        # Exact wording printed by SDK 2.38.1 in live testing, 9 November 2026.
        $current=& $liveModule $translate 'To sign in, use a web browser to open the page https://login.microsoft.com/device and enter the code WXYZ98765 to authenticate.'
        $current.url | Should -Be 'https://login.microsoft.com/device'
        $current.code | Should -Be 'WXYZ98765'
        (& $liveModule $translate 'open https://login.microsoft.com/device.attacker.invalid and enter the code ABCD12345') | Should -BeNullOrEmpty
        (& $liveModule $translate 'Open https://attacker.invalid and enter the code ABCD12345') | Should -BeNullOrEmpty
        (& $liveModule $translate 'raw issuer error with token material') | Should -BeNullOrEmpty
    }
    It 'runs the real stdio worker protocol offline in a fresh process' -ForEach @(
        @{argument=$null},@{argument='-BadBinding'},@{argument='-UnsupportedCommand'}
    ) {
        $arguments=@('-NoProfile','-File',"$PSScriptRoot/live/Test-WorkerProtocol.ps1")
        if ($_.argument) { $arguments+=$_.argument }
        $output=& (Get-Process -Id $PID).Path @arguments
        $LASTEXITCODE | Should -Be 0
        ($output | ConvertFrom-Json).status | Should -Be 'PASS'
    }
    It 'filters unknown stdout and rejects stale worker request identifiers' {
        $text="raw SDK line not for the UI`n"+(@{requestId=('1'*32);kind='starting'} | ConvertTo-Json -Compress)+"`n"
        $reader=[IO.StreamReader]::new([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($text)))
        try {
            $connection=@{requestId=('1'*32);line=$reader.ReadLineAsync();process=[pscustomobject]@{StandardOutput=$reader}}
            $events=@(& $liveModule { param($c) Receive-HandoffLiveEvents $c } $connection)
            $events.Count | Should -Be 1
            $events[0].kind | Should -Be 'starting'
        } finally { $reader.Dispose() }
        $reader=[IO.StreamReader]::new([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($text)))
        try {
            $connection=@{requestId=('2'*32);line=$reader.ReadLineAsync();process=[pscustomobject]@{StandardOutput=$reader}}
            { & $liveModule { param($c) Receive-HandoffLiveEvents $c } $connection } | Should -Throw '*invalid_live_event*'
        } finally { $reader.Dispose() }
    }
}
