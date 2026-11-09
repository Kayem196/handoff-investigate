#Requires -Version 7.5
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../Handoff.Live.psm1')
Invoke-HandoffLiveWorker
