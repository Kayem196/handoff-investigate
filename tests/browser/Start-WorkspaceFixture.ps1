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
        return @{status=200;body=@{choices=@(@{finish_reason='stop';message=@{content=$text}})}}
    }
}
Start-HandoffWorkspace -InvestigationsRoot $FixtureRoot -Port $Port -NoBrowser
