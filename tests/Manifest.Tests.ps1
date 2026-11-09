Describe 'Module manifest' {
    BeforeAll {
        $script:root = Join-Path $PSScriptRoot '..'
        $script:data = Import-PowerShellDataFile (Join-Path $root 'Handoff.psd1')
    }
    It 'exports exactly the functions the nested modules export' {
        $declared = foreach ($file in $data.NestedModules) {
            $text = Get-Content (Join-Path $root $file) -Raw
            [regex]::Match($text, '(?m)^Export-ModuleMember -Function (.+)$').Groups[1].Value -split ',' | ForEach-Object Trim
        }
        @(Compare-Object @($declared | Sort-Object) @($data.FunctionsToExport | Sort-Object)).Count | Should -Be 0
    }
    It 'lists every packaged runtime file and takes no hard Graph SDK dependency' {
        foreach ($file in $data.FileList | Where-Object { $_ -ne 'LICENSE' }) { Test-Path -LiteralPath (Join-Path $root $file) | Should -BeTrue }
        ((Test-Path -LiteralPath (Join-Path $root 'LICENSE')) -or (Test-Path -LiteralPath (Join-Path $root '../LICENSE'))) | Should -BeTrue
        $data.Contains('RequiredModules') | Should -BeFalse
        foreach ($file in $data.NestedModules) { $data.FileList | Should -Contain $file }
    }
}
