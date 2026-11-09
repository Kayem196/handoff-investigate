BeforeAll {
    function global:Get-MgContext { throw 'Unmocked SDK context access' }
    Import-Module "$PSScriptRoot/../Handoff.Console.psm1" -Force
    $script:tenant = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    $script:client = 'dddddddd-dddd-dddd-dddd-dddddddddddd'
    $script:group = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
    $script:other = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'
    $script:account = 'operator@example.invalid'
    $script:snapshotFile = Join-Path $PSScriptRoot '../examples/group-policy-snapshot.json'
}
Describe 'Confirmed, stable-ID guided group investigations' {
    BeforeEach {
        $script:output = Join-Path $TestDrive ([guid]::NewGuid().ToString('D'))
        $script:guideArgs = @{TenantId=$tenant;ClientId=$client;Account=$account;OutDirectory=$output}
        $script:context = @{TenantId=$tenant;ClientId=$client;Account=$account;AuthType='Delegated';Environment='Global';ContextScope='Process';Scopes=@('GroupMember.Read.All','Policy.Read.All','DeviceManagementConfiguration.Read.All')}
        $script:catalog = @{schemaVersion=1;catalogType='visible_group_picker_v1';tenantId=$tenant;status='complete';failureCode=$null;issues=@();warning='Bounded visible list, not absence proof.';items=@(@{id=$group;displayName='Same name'},@{id=$other;displayName='Same name'})}
        $script:answers = [Collections.Generic.Queue[string]]::new()
        foreach ($answer in @('READ','2','READ')) { $answers.Enqueue($answer) }
        $script:messages = [Collections.Generic.List[string]]::new()
        $script:collision = $false
        Mock Get-MgContext -ModuleName Handoff.Console { $script:context }
        Mock Write-Host -ModuleName Handoff.Console { param($Object) $script:messages.Add([string]$Object) }
        Mock Read-Host -ModuleName Handoff.Console { $script:answers.Dequeue() }
        Mock Get-HandoffGroupCatalog -ModuleName Handoff.Console { $script:catalog }
        Mock Get-HandoffPolicySnapshot -ModuleName Handoff.Console {
            param($TenantId,$GroupId)
            $snapshot=Get-Content $script:snapshotFile -Raw | ConvertFrom-Json -AsHashtable -DateKind String
            $snapshot.tenantId=$TenantId.ToString();$snapshot.groupId=$GroupId.ToString();$snapshot.group.id=$GroupId.ToString()
            $snapshot.group.displayName='Freshly resolved name'
            $snapshot.conditionalAccess.policies[0].conditions.users.includeGroups=@($GroupId.ToString())
            $snapshot.compliance.policies[0].assignments[0].target.groupId=$GroupId.ToString()
            if ($script:collision) { $null=New-Item -ItemType Directory -Path $script:output; 'Preserve concurrent work' | Set-Content -LiteralPath (Join-Path $script:output 'existing.txt') }
            return $snapshot
        }
    }
    It 'collects only the explicitly selected stable ID, then saves evidence and safe reports' {
        $result = Start-HandoffGroupInvestigation @guideArgs
        $result.status | Should -Be 'saved'
        $result.groupId | Should -Be $other
        $result.references | Should -Be 2
        $result.coverage | Should -Be 'incomplete'
        Test-Path -LiteralPath $result.html | Should -BeTrue
        Test-Path -LiteralPath $result.json | Should -BeTrue
        $report=Get-Content -LiteralPath $result.json -Raw | ConvertFrom-Json -AsHashtable -DateKind String
        $report.group.id | Should -Be $other
        $report.group.displayName | Should -Be 'Freshly resolved name'
        ($messages -join "`n") | Should -Match 'NOT COLLECTED, not zero'
        Should -Invoke Get-HandoffGroupCatalog -ModuleName Handoff.Console -Exactly -Times 1
        Should -Invoke Get-HandoffPolicySnapshot -ModuleName Handoff.Console -Exactly -Times 1 -ParameterFilter { $GroupId -eq [guid]$script:other }
    }
    It 'performs no reads or writes if the initial read confirmation is declined' {
        $answers.Clear();$answers.Enqueue('Q')
        $result = Start-HandoffGroupInvestigation @guideArgs
        $result.stage | Should -Be 'before_catalog'
        Should -Invoke Get-HandoffGroupCatalog -ModuleName Handoff.Console -Times 0
        Test-Path -LiteralPath $output | Should -BeFalse
    }
    It 'cancels at selection or final confirmation without collecting policies or saving files' -ForEach @('selection','confirmation') {
        $answers.Clear();$answers.Enqueue('READ')
        if ($_ -eq 'selection') { $answers.Enqueue('Q') } else { $answers.Enqueue('1');$answers.Enqueue('NO') }
        $result = Start-HandoffGroupInvestigation @guideArgs
        $result.status | Should -Be 'cancelled'
        Should -Invoke Get-HandoffPolicySnapshot -ModuleName Handoff.Console -Times 0
        Test-Path -LiteralPath $output | Should -BeFalse
    }
    It 'treats empty input as cancellation rather than looping without an interactive host' {
        $answers.Clear();$answers.Enqueue('READ');$answers.Enqueue('')
        (Start-HandoffGroupInvestigation @guideArgs).status | Should -Be 'cancelled'
        Test-Path -LiteralPath $output | Should -BeFalse
    }
    It 'rejects command-like input and out-of-range numbers without executing them' {
        $answers.Clear()
        foreach ($answer in @('READ','Invoke-Expression something','9999','0','2','READ')) { $answers.Enqueue($answer) }
        $result = Start-HandoffGroupInvestigation @guideArgs
        $result.groupId | Should -Be $other
        Should -Invoke Get-HandoffPolicySnapshot -ModuleName Handoff.Console -Exactly -Times 1
    }
    It 'stops before reads for a different reader, broader API scopes or non-process context' -ForEach @('account','client','scope','context') {
        switch ($_) {
            account { $context.Account='another@example.invalid' }
            client { $context.ClientId=$group }
            scope { $context.Scopes += 'Directory.ReadWrite.All' }
            context { $context.ContextScope='CurrentUser' }
        }
        { Start-HandoffGroupInvestigation @guideArgs } | Should -Throw
        Should -Invoke Get-HandoffGroupCatalog -ModuleName Handoff.Console -Times 0
        Test-Path -LiteralPath $output | Should -BeFalse
    }
    It 'withholds data if the reader changes while the catalog is being read' {
        Mock Get-HandoffGroupCatalog -ModuleName Handoff.Console { $script:context.Account='another@example.invalid';$script:catalog }
        { Start-HandoffGroupInvestigation @guideArgs } | Should -Throw
        Should -Invoke Get-HandoffPolicySnapshot -ModuleName Handoff.Console -Times 0
        Test-Path -LiteralPath $output | Should -BeFalse
    }
    It 'does not save a selected observation from a changed session or mismatched identity' -ForEach @('session','identity') {
        $script:mode = $_
        Mock Get-HandoffPolicySnapshot -ModuleName Handoff.Console {
            param($TenantId,$GroupId)
            if ($script:mode -eq 'session') { $script:context.Account='another@example.invalid' }
            @{tenantId=$TenantId.ToString();groupId='ffffffff-ffff-ffff-ffff-ffffffffffff';group=@{id=$GroupId.ToString()}}
        }
        { Start-HandoffGroupInvestigation @guideArgs } | Should -Throw
        Test-Path -LiteralPath $output | Should -BeFalse
    }
    It 'does not confuse unavailable catalog data with an empty successful search' {
        $catalog.status='unavailable';$catalog.failureCode='request_failed';$catalog.items=@()
        $result=Start-HandoffGroupInvestigation @guideArgs
        $result.status | Should -Be 'catalog_unavailable'
        Should -Invoke Get-HandoffPolicySnapshot -ModuleName Handoff.Console -Times 0
    }
    It 'keeps a partial picker warning and avoids an absence claim for a local no-match filter' {
        $catalog.status='partial'
        $result=Start-HandoffGroupInvestigation @guideArgs -NameContains 'Not in these retained rows'
        $result.status | Should -Be 'no_matching_groups'
        $result.catalogStatus | Should -Be 'partial'
        ($messages -join "`n") | Should -Match 'does not prove'
        Test-Path -LiteralPath $output | Should -BeFalse
    }
    It 'uses a literal local name filter rather than sending user text as an API query' {
        $catalog.items[1].displayName='[Support*]'
        $answers.Clear();foreach ($answer in @('READ','1','READ')) { $answers.Enqueue($answer) }
        $result=Start-HandoffGroupInvestigation @guideArgs -NameContains '[Support*]'
        $result.groupId | Should -Be $other
        Should -Invoke Get-HandoffGroupCatalog -ModuleName Handoff.Console -ParameterFilter { $TenantId -eq [guid]$script:tenant } -Exactly -Times 1
    }
    It 'escapes tenant-provided ANSI and bidirectional controls before terminal display' {
        $catalog.items[0].displayName="`e[2J$([char]0x202e)spoof"
        $answers.Clear();$answers.Enqueue('READ');$answers.Enqueue('Q')
        $null=Start-HandoffGroupInvestigation @guideArgs
        $text=$messages -join "`n"
        $text | Should -Not -Match ([regex]::Escape("`e[2J"))
        $text | Should -Not -Match ([regex]::Escape([string][char]0x202e))
        $text | Should -Match '\\u001B\[2J\\u202Espoof'
    }
    It 'rejects existing destinations or invalid parents before any API read' {
        $null=New-Item -ItemType Directory -Path $output
        { Start-HandoffGroupInvestigation @guideArgs } | Should -Throw
        $guideArgs.OutDirectory=Join-Path $TestDrive 'missing-parent/child'
        { Start-HandoffGroupInvestigation @guideArgs } | Should -Throw
        Should -Invoke Get-HandoffGroupCatalog -ModuleName Handoff.Console -Times 0
    }
    It 'does not append into or replace a destination created during the read' {
        $script:collision = $true
        { Start-HandoffGroupInvestigation @guideArgs } | Should -Throw
        (Get-Content -LiteralPath (Join-Path $output 'existing.txt') -Raw).Trim() | Should -Be 'Preserve concurrent work'
        @(Get-ChildItem -LiteralPath $TestDrive -Directory -Filter '.handoff-investigation-*' -Force).Count | Should -Be 0
    }
    It 'preserves completed evidence if report export subsequently fails' {
        Mock Export-HandoffInvestigationReport -ModuleName Handoff.Console { throw 'Synthetic local export failure' }
        { Start-HandoffGroupInvestigation @guideArgs } | Should -Throw
        @(Get-ChildItem -LiteralPath (Join-Path $output 'evidence') -Filter 'observation-*.json').Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path $output 'evidence/investigation.json') | Should -BeTrue
    }
}
