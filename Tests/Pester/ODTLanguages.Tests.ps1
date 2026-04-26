#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 tests for Common/ODTLanguages.psm1.
#>

BeforeAll {
    $repoRoot = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..')
    Import-Module (Join-Path $repoRoot 'Common\ODTLanguages.psm1') -Force
}

AfterAll {
    Remove-Module ODTLanguages -ErrorAction SilentlyContinue
}

Describe 'Get-ODTSupportedLanguages' {
    It 'returns a non-empty list for each known product' {
        foreach ($p in 'O365ProPlusRetail','VisioProRetail','ProjectProRetail','VisioStdRetail','ProjectStdRetail') {
            (Get-ODTSupportedLanguages -TargetProduct $p).Count | Should -BeGreaterThan 0
        }
    }

    It 'Visio languages are a subset of Office languages' {
        $office = Get-ODTSupportedLanguages -TargetProduct 'O365ProPlusRetail'
        $visio  = Get-ODTSupportedLanguages -TargetProduct 'VisioProRetail'
        foreach ($lang in $visio) {
            $office | Should -Contain $lang
        }
    }
}

Describe 'Test-ODTLanguageSupported' {
    It 'accepts nb-no for Office, Visio and Project' {
        (Test-ODTLanguageSupported -LanguageID 'nb-no' -TargetProduct 'O365ProPlusRetail') | Should -BeTrue
        (Test-ODTLanguageSupported -LanguageID 'nb-no' -TargetProduct 'VisioProRetail')    | Should -BeTrue
        (Test-ODTLanguageSupported -LanguageID 'nb-no' -TargetProduct 'ProjectProRetail')  | Should -BeTrue
    }

    It 'rejects Office-only languages on Visio' {
        # af-za is in Office but not Visio.
        (Test-ODTLanguageSupported -LanguageID 'af-za' -TargetProduct 'O365ProPlusRetail') | Should -BeTrue
        (Test-ODTLanguageSupported -LanguageID 'af-za' -TargetProduct 'VisioProRetail')    | Should -BeFalse
    }

    It 'is case-insensitive on input' {
        (Test-ODTLanguageSupported -LanguageID 'NB-NO' -TargetProduct 'VisioProRetail') | Should -BeTrue
    }
}

Describe 'Assert-ODTLanguageSupported' {
    It 'throws a clear error when the combination is unsupported' {
        { Assert-ODTLanguageSupported -LanguageID 'af-za' -TargetProduct 'VisioProRetail' } |
            Should -Throw -ExpectedMessage "*not supported for product 'VisioProRetail'*"
    }

    It 'does not throw when the combination is supported' {
        { Assert-ODTLanguageSupported -LanguageID 'en-us' -TargetProduct 'VisioProRetail' } | Should -Not -Throw
    }
}
