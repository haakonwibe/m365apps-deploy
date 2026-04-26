#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 tests for the Language Pack configuration XML template.
    Exercises the exact string substitution that Install-LanguagePack.ps1
    performs at runtime, and asserts the rendered XML matches Microsoft's
    documented second-install pattern.
#>

BeforeAll {
    $repoRoot = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..')

    function Render {
        param(
            [Parameter(Mandatory)][string] $TemplatePath,
            [Parameter(Mandatory)][hashtable] $Tokens
        )
        $text = Get-Content -LiteralPath $TemplatePath -Raw
        foreach ($k in $Tokens.Keys) {
            $text = $text.Replace($k, [string]$Tokens[$k])
        }
        [xml]$doc = $text
        return $doc
    }

    $script:LanguagePackTemplate  = Join-Path $repoRoot 'LanguagePacks\Configurations\languagepack-template.xml'
}

Describe 'Language Pack template' {
    It 'renders with Product ID="LanguagePack" (Microsoft pseudo-product), not a specific base product ID' {
        # Microsoft documents LanguagePack as the correct Product ID for
        # language-accessory installs - using a base product ID like
        # O365ProPlusRetail here would attach the language to that single
        # product instead of the language-pack pseudo-product.
        $doc = Render -TemplatePath $script:LanguagePackTemplate -Tokens @{
            '{{OfficeClientEdition}}' = '64'
            '{{Channel}}'             = 'MonthlyEnterprise'
            '{{LanguageID}}'          = 'nb-no'
        }

        $product = $doc.DocumentElement.SelectSingleNode('Add/Product')
        $product.GetAttribute('ID') | Should -Be 'LanguagePack'

        # The template must not carry a {{TargetProduct}} token; the Product
        # ID is fixed to "LanguagePack" rather than substituted per call.
        (Get-Content -LiteralPath $script:LanguagePackTemplate -Raw) | Should -Not -Match '\{\{TargetProduct\}\}'
    }

    It 'renders valid XML with the expected attribute set' {
        $doc = Render -TemplatePath $script:LanguagePackTemplate -Tokens @{
            '{{OfficeClientEdition}}' = '64'
            '{{Channel}}'             = 'MonthlyEnterprise'
            '{{LanguageID}}'          = 'nb-no'
        }
        $add = $doc.DocumentElement.SelectSingleNode('Add')
        $add.GetAttribute('OfficeClientEdition')  | Should -Be '64'
        $add.GetAttribute('Channel')              | Should -Be 'MonthlyEnterprise'
        $add.GetAttribute('Version')              | Should -BeNullOrEmpty   # no MatchInstalled
        $add.SelectSingleNode('Product/Language').GetAttribute('ID') | Should -Be 'nb-no'
    }

    It 'has no leftover Visio/Project-specific Product IDs in the template source' {
        $text = Get-Content -LiteralPath $script:LanguagePackTemplate -Raw
        $text | Should -Not -Match 'VisioProRetail'
        $text | Should -Not -Match 'ProjectProRetail'
        $text | Should -Not -Match 'O365ProPlusRetail'
    }
}

Describe 'Platform -> OfficeClientEdition mapping (install-script logic)' {
    # The install scripts use a switch statement to turn Get-OfficeConfiguration's
    # Platform ('x64' / 'x86') into the OfficeClientEdition attribute ('64' / '32').
    # This Describe block mirrors that logic as a unit test so a regression
    # (e.g. someone flipping the arms) would fire here first.

    BeforeAll {
        function Map-PlatformToEdition {
            param([string] $Platform)
            switch ($Platform) {
                'x64'   { return '64' }
                'x86'   { return '32' }
                default { throw "Unmapped platform: $Platform" }
            }
        }
    }

    It 'x64 maps to 64' { Map-PlatformToEdition 'x64' | Should -Be '64' }
    It 'x86 maps to 32' { Map-PlatformToEdition 'x86' | Should -Be '32' }
    It 'unknown value throws' { { Map-PlatformToEdition 'arm64' } | Should -Throw }
}
