param([Parameter(Mandatory)][string]$FixtureRoot, [Parameter(Mandatory)][int]$Port)
# Test-owned fictional state and fake provider only. Not used by the normal launcher.
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../../Handoff.Workspace.psm1')
Import-Module (Join-Path $PSScriptRoot '../../Handoff.Evidence.psm1')
$snapshot=Get-Content (Join-Path $PSScriptRoot '../../examples/group-policy-snapshot.json') -Raw | ConvertFrom-Json -AsHashtable -DateKind String
$snapshot.group.displayName='Hostile <img src=x onerror="window.__injected=true"> group'
$snapshot.conditionalAccess.policies[0].displayName='Policy <script>window.__injected=true</script>'
$null=Save-HandoffInvestigationObservation -Path (Join-Path $FixtureRoot 'hostile/evidence') -TenantId $snapshot.tenantId -GroupId $snapshot.groupId -Snapshot $snapshot
& (Get-Module Handoff.Axon -All | Select-Object -First 1) {
    function script:Send-HandoffAxonRequest {
        param($Uri,$Headers,$Body,$TimeoutSeconds)
        $request=$Body | ConvertFrom-Json -AsHashtable
        $previous=$request.messages.Count - 2
        $text="**Support team** has two explicit recorded references. Coverage is incomplete. Follow-up context: $previous previous messages.`n`n- Require MFA for support includes the group.`n- Windows compliance includes the group.`n`nNo deletion approval. Literal hostile text: <img src=x onerror=window.__injected=true>"
        $text += @'


| Policy | State | Includes |

|---|---|---|

| Require MFA for support | Enabled | `Support team` |

| Literal \| <img src=x onerror=window.__injected=true> | Disabled | Group with an unresolved name |

1. Check *configured* targeting.
2. Verify `bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb` before making changes.

Unclosed formatting: `literal and **unclosed
'@
        return @{status=200;body=@{choices=@(@{finish_reason='stop';message=@{content=$text}})}}
    }
}
& (Get-Module Handoff.Workspace) {
    param($SnapshotFile)
    $script:WorkspaceFixtureSnapshotPath=$SnapshotFile
    # Browser-only fake reader. The normal launcher never imports this fixture.
    function script:New-HandoffLiveConnection {
        param($Profile)
        return @{profile=$Profile;status='authenticating';operation='connect';process=[pscustomobject]@{HasExited=$false};deadline=[datetime]::UtcNow.AddMinutes(2);device=$null;catalog=$null;readTicket=$null;resultId=$null;failureCode=$null;fixturePoll=0}
    }
    function script:Receive-HandoffLiveEvents {
        param($Connection)
        if ($Connection.status -eq 'authenticating') {
            $Connection.fixturePoll++
            if ($Connection.fixturePoll -eq 1) { return @{kind='device';device=@{url='https://microsoft.com/devicelogin';code='ABCD12345'}} }
            return @{kind='connected';profile=$Connection.profile}
        }
        if ($Connection.status -eq 'reading' -and $Connection.operation -eq 'catalog') {
            return @{kind='catalog';catalog=@{tenantId=$Connection.profile.tenantId;catalogType='visible_group_picker_v1';status='complete';referenceCounts='not_collected';items=@(@{id='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';displayName='Support team'});warning='Fictional bounded group list. Membership and policy counts were not collected.'}}
        }
        if ($Connection.status -eq 'reading' -and $Connection.operation -eq 'collect') {
            $snapshot=Get-Content $script:WorkspaceFixtureSnapshotPath -Raw | ConvertFrom-Json -AsHashtable -DateKind String
            $snapshot.collectedAt=[datetimeoffset]::UtcNow.ToString('o')
            return @{kind='snapshot';snapshot=$snapshot}
        }
        return @()
    }
    function script:Start-HandoffLiveOperation {
        param($Connection,$Action,$GroupId)
        $Connection.status='reading';$Connection.operation=$Action;$Connection.resultId=$null
    }
    function script:Stop-HandoffLiveConnection { param($Connection) }
} (Join-Path $PSScriptRoot '../../examples/group-policy-snapshot.json')
Start-HandoffWorkspace -InvestigationsRoot $FixtureRoot -Port $Port -NoBrowser
