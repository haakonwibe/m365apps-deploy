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

Describe 'Visio/Project base XML carries the en-us literal' {
    # v1.0.5 dropped runtime language resolution for Visio/Project: the
    # base XMLs hardcode <Language ID="en-us" />, and additional UI
    # languages ship as separate Win32 apps via LanguagePacks/. This
    # test pins the contract — no future contributor accidentally
    # re-introduces the {{LanguageID}} runtime token in those XMLs.
    BeforeAll {
        $script:RepoRoot = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..')
    }

    It '<Path> hardcodes <Language ID="en-us" />' -ForEach @(
        @{ Path = 'Visio\Configurations\visio-base.xml' }
        @{ Path = 'Project\Configurations\project-base.xml' }
    ) {
        $full    = Join-Path $script:RepoRoot $Path
        $content = Get-Content -LiteralPath $full -Raw

        $content | Should -Match '<Language ID="en-us"\s*/>' `
            -Because 'Visio/Project install in en-us by design (v1.0.5); language overlays come via LanguagePacks/'
        $content | Should -Not -Match '\{\{LanguageID\}\}' `
            -Because 'the runtime LanguageID token belongs only in LanguagePacks/Configurations/languagepack-template.xml'
    }
}

Describe 'Removed: Resolve-VisioProjectLanguage / VisioProjectUnsupportedCultures (v1.0.5)' {
    # The v1.0.1-1.0.3 resolver function and the unsupported-cultures
    # data structure are removed in v1.0.5. These tests pin the deletion
    # so a future contributor doesn't accidentally re-introduce them.
    BeforeAll {
        $script:OdtLanguagesSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\Common\ODTLanguages.psm1') -Raw
    }

    It 'Resolve-VisioProjectLanguage(s) is not exported' {
        $exports = (Get-Module ODTLanguages).ExportedFunctions.Keys
        $exports | Should -Not -Contain 'Resolve-VisioProjectLanguage'
        $exports | Should -Not -Contain 'Resolve-VisioProjectLanguages'
    }

    It 'source does not declare Resolve-VisioProjectLanguage(s)' {
        $script:OdtLanguagesSource | Should -Not -Match 'function Resolve-VisioProjectLanguage'
    }

    It 'source does not declare $script:VisioProjectUnsupportedCultures' {
        $script:OdtLanguagesSource | Should -Not -Match '\$script:VisioProjectUnsupportedCultures'
    }
}

Describe 'BCP-47 validator covers every tag in the supported-language matrix' {
    # Pins the deployed ValidatePattern (Install-/Uninstall-/Detect-LanguagePack and
    # the Test-* helpers) against the actual matrix in ODTLanguages.psm1, so that a
    # narrow regex or a malformed new tag fails CI before it fails an Intune deployment.
    BeforeDiscovery {
        Import-Module (Join-Path $PSScriptRoot '..\..\Common\ODTLanguages.psm1') -Force
        $script:LanguageCases = @()
        foreach ($product in 'O365ProPlusRetail','VisioProRetail','ProjectProRetail') {
            foreach ($tag in (Get-ODTSupportedLanguages -TargetProduct $product)) {
                $script:LanguageCases += @{ Product = $product; Tag = $tag }
            }
        }
    }

    It 'tag <Tag> matches the canonical BCP-47 regex' -ForEach $script:LanguageCases {
        $Tag | Should -Match '^[a-zA-Z]{2,3}(-[a-zA-Z]{2,8}){1,3}$'
    }

    It 'tag <Tag> is accepted by Test-ODTLanguageSupported for <Product>' -ForEach $script:LanguageCases {
        # Exercises the deployed ValidatePattern end-to-end: a parameter-binding failure
        # would surface as ParameterArgumentValidationError before the matrix lookup runs.
        (Test-ODTLanguageSupported -LanguageID $Tag -TargetProduct $Product) | Should -BeTrue
    }
}
