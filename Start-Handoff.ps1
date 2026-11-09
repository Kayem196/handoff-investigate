#Requires -Version 7.5
param([string]$InvestigationsRoot = (Join-Path $env:LOCALAPPDATA 'Handoff/Investigations'), [int]$Port=43187, [switch]$NoBrowser, [string]$ReaderProfilePath)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Handoff.Workspace.psm1')
Start-HandoffWorkspace -InvestigationsRoot $InvestigationsRoot -Port $Port -NoBrowser:$NoBrowser -ReaderProfilePath $ReaderProfilePath
