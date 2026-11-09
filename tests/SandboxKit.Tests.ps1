Describe 'Offline Sandbox kit' {
    BeforeAll {
        $builder = Join-Path $PSScriptRoot 'package/sandbox/New-SandboxKit.ps1'
        $zip = Join-Path $TestDrive 'PowerShell-7.6.9-win-x64.zip'
        Set-Content -LiteralPath $zip -Value 'fictional runtime for kit-layout tests only'
        $officialHash = 'CE7484804C0F0AD4DDA10C958E71ACDAF7EEBFB22505C1B480F89E0E9F1DA94D'
    }
    It 'rejects a different runtime before creating a kit' {
        $out = Join-Path $TestDrive 'bad-runtime'
        { & $builder -OutDirectory $out -PortablePowerShellZip $zip } | Should -Throw '*checksum*'
        Test-Path -LiteralPath $out | Should -BeFalse
    }
    It 'builds a current package with only a read-only kit and writable results mapped' {
        Mock Get-FileHash { @{Hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($LiteralPath)))} }
        Mock Get-FileHash { @{Hash=$officialHash} } -ParameterFilter { $LiteralPath -eq $zip }
        $out = Join-Path $TestDrive 'kit & layout'
        $built = & $builder -OutDirectory $out -PortablePowerShellZip $zip
        [xml]$config = Get-Content -LiteralPath $built.Launcher -Raw
        $config.Configuration.Networking | Should -Be 'Disable'
        $config.Configuration.ClipboardRedirection | Should -Be 'Disable'
        $config.Configuration.vGPU | Should -Be 'Disable'
        $maps = @($config.Configuration.MappedFolders.MappedFolder)
        $maps.Count | Should -Be 2
        $maps[0].HostFolder | Should -Be $built.Kit
        $maps[0].ReadOnly | Should -Be 'true'
        $maps[1].HostFolder | Should -Be $built.Results
        $maps[1].ReadOnly | Should -Be 'false'
        @(Get-ChildItem -LiteralPath $built.Results).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $built.Kit 'Handoff/0.1.0/Handoff.Axon.psm1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $built.Kit 'Invoke-CleanInstallCheck.ps1') | Should -BeTrue
        $config.Configuration.LogonCommand.Command | Should -Match 'Start-SandboxCheck.ps1'
        { & $builder -OutDirectory $out -PortablePowerShellZip $zip } | Should -Throw '*never overwritten*'
    }
    It 'returns a failing exit code and saved result for a bad package checksum' {
        $kit = Join-Path $TestDrive 'bad-package'
        $null = New-Item -ItemType Directory -Path $kit
        $check = Join-Path $kit 'Invoke-CleanInstallCheck.ps1'
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'package/Invoke-CleanInstallCheck.ps1') -Destination $check
        '0000000000000000000000000000000000000000000000000000000000000000  missing.psm1' | Set-Content (Join-Path $kit 'SHA256SUMS.txt')
        $results = Join-Path $kit 'results'
        $null = & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File $check -ResultsDirectory $results -ModulesRoot (Join-Path $kit 'modules')
        $LASTEXITCODE | Should -Be 1
        $record = Get-Content (Join-Path $results 'clean-install-results.json') -Raw | ConvertFrom-Json
        $record.status | Should -Be 'ERROR'
        $record.failure | Should -Match 'Checksum mismatch'
        Test-Path (Join-Path $kit 'modules') | Should -BeFalse
    }
    It 'records bootstrap failure rather than treating DONE as a pass' {
        $kit = Join-Path $TestDrive 'missing-runtime'
        $results = Join-Path $TestDrive 'bootstrap-results'
        $null = New-Item -ItemType Directory -Path $kit,$results
        $bootstrap = Join-Path $PSScriptRoot 'package/sandbox/Start-SandboxCheck.ps1'
        $null = & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File $bootstrap -KitPath $kit -ResultsRoot $results
        $LASTEXITCODE | Should -Be 1
        $run = Get-ChildItem -LiteralPath $results -Directory | Select-Object -First 1
        Test-Path (Join-Path $run.FullName 'DONE') | Should -BeTrue
        $record = Get-Content (Join-Path $run.FullName 'sandbox-results.json') -Raw | ConvertFrom-Json
        $record.status | Should -Be 'ERROR'
        $record.failure | Should -Match 'zip missing'
    }
}
