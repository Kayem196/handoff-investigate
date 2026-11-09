@{
    ModuleVersion        = '0.1.0'
    GUID                 = '6f0f3c7e-2d4b-4b8e-9a51-7c3e0d8f2a14'
    Author               = 'Handoff contributors'
    Description          = 'Read-only investigation of explicit group references in Conditional Access and Intune device-compliance policies. Preview; see INSTALL.md for supported versions and limits.'
    PowerShellVersion    = '7.5'
    CompatiblePSEditions = @('Core')
    # No RequiredModules: offline evaluation, evidence and reports must load without
    # the Graph SDK. Live collection checks for Microsoft.Graph.Authentication 2.38.1.
    NestedModules        = @(
        'Handoff.Investigation.psm1', 'Handoff.Collection.psm1', 'Handoff.Evidence.psm1',
        'Handoff.Report.psm1', 'Handoff.Console.psm1', 'Handoff.Axon.psm1'
    )
    FunctionsToExport    = @(
        'Get-HandoffGroupPolicyReference', 'Get-HandoffPolicySnapshot', 'Get-HandoffGroupCatalog',
        'Save-HandoffInvestigationObservation', 'Get-HandoffInvestigation', 'Add-HandoffInvestigationNote',
        'Compare-HandoffInvestigationObservation', 'Get-HandoffInvestigationReport',
        'Export-HandoffInvestigationReport', 'Start-HandoffGroupInvestigation', 'Invoke-HandoffAxonExplanation'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    FileList             = @(
        'Handoff.psd1', 'Handoff.Investigation.psm1', 'Handoff.Collection.psm1', 'Handoff.Transport.cs',
        'Handoff.Evidence.psm1', 'Handoff.Report.psm1', 'Handoff.Console.psm1', 'Handoff.Axon.psm1', 'report/report.css',
        'examples/group-policy-snapshot.json', 'examples/saved-investigation.ps1',
        'examples/export-investigation.ps1', 'README.md', 'INSTALL.md', 'docs/USER-TESTING.md', 'docs/WORKSPACE.md', 'LICENSE',
        'Start-Handoff.ps1', 'Handoff.Workspace.psm1', 'workspace/index.html', 'workspace/app.js', 'workspace/app.css',
        'workspace/mark.svg', 'workspace/Geist.woff2', 'workspace/Geist-OFL.txt'
    )
    PrivateData          = @{ PSData = @{ Prerelease = 'preview1'; Tags = @('Entra', 'Intune', 'ConditionalAccess', 'Investigation', 'ReadOnly') } }
}
