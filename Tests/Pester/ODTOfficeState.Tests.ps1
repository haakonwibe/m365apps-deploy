#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 tests for Common/ODTOfficeState.psm1.

.DESCRIPTION
    These tests use InModuleScope to substitute the registry lookups with
    controlled fixtures. They do not touch HKLM on the test machine.

    Run with:
        Invoke-Pester -Path .\Tests\Pester\ODTOfficeState.Tests.ps1
#>

BeforeAll {
    $repoRoot  = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..')
    $modulePath = Join-Path -Path $repoRoot -ChildPath 'Common\ODTOfficeState.psm1'
    Import-Module $modulePath -Force
}

AfterAll {
    Remove-Module ODTOfficeState -ErrorAction SilentlyContinue
}

Describe 'Get-OfficeConfiguration' {
    It 'returns $null when the C2R Configuration key is missing' {
        InModuleScope ODTOfficeState {
            Mock Get-Registry64Item { $null } -ParameterFilter { $Path -eq 'SOFTWARE\Microsoft\Office\ClickToRun\Configuration' }
            Get-OfficeConfiguration | Should -BeNullOrEmpty
        }
    }

    It 'parses ProductReleaseIds and key values into the expected object' {
        InModuleScope ODTOfficeState {
            Mock Get-Registry64Item {
                [pscustomobject]@{
                    ProductReleaseIds = 'O365ProPlusRetail,VisioProRetail'
                    Platform          = 'x64'
                    UpdateChannel     = 'http://officecdn.microsoft.com/pr/55336b82-a18d-4dd6-b5f6-9e5095c314a6'
                    CDNBaseUrl        = 'http://officecdn.microsoft.com/pr/55336b82-a18d-4dd6-b5f6-9e5095c314a6'
                    VersionToReport   = '16.0.17328.20310'
                    ClientCulture     = 'en-us'
                }
            } -ParameterFilter { $Path -eq 'SOFTWARE\Microsoft\Office\ClickToRun\Configuration' }
            Mock Get-Registry64Item { $null } -ParameterFilter { $Path -eq 'SOFTWARE\Microsoft\Office\ClickToRun\Configuration\ProductReleaseIds' }

            $result = Get-OfficeConfiguration
            $result | Should -Not -BeNullOrEmpty
            $result.ProductReleaseIds | Should -Contain 'O365ProPlusRetail'
            $result.ProductReleaseIds | Should -Contain 'VisioProRetail'
            $result.Platform          | Should -Be 'x64'
            $result.ClientCulture     | Should -Be 'en-us'
            $result.InstalledLanguages | Should -Contain 'en-us'
        }
    }
}

Describe 'Test-ProductInstalled' {
    It 'returns $true when the product is in ProductReleaseIds' {
        InModuleScope ODTOfficeState {
            Mock Get-OfficeConfiguration { [pscustomobject]@{ ProductReleaseIds = @('O365ProPlusRetail','VisioProRetail') } }
            (Test-ProductInstalled -ProductId 'O365ProPlusRetail') | Should -BeTrue
            (Test-ProductInstalled -ProductId 'VisioProRetail')    | Should -BeTrue
        }
    }

    It 'returns $false when the product is absent' {
        InModuleScope ODTOfficeState {
            Mock Get-OfficeConfiguration { [pscustomobject]@{ ProductReleaseIds = @('O365ProPlusRetail') } }
            (Test-ProductInstalled -ProductId 'ProjectProRetail') | Should -BeFalse
        }
    }

    It 'returns $false when no C2R configuration is present' {
        InModuleScope ODTOfficeState {
            Mock Get-OfficeConfiguration { $null }
            (Test-ProductInstalled -ProductId 'O365ProPlusRetail') | Should -BeFalse
        }
    }
}

Describe 'Get-InstalledLanguages' {
    It 'collects languages from the Uninstall hive using the ProductId prefix' {
        InModuleScope ODTOfficeState {
            Mock Get-OfficeConfiguration { [pscustomobject]@{ ClientCulture = 'en-us' } }
            Mock Get-Registry64SubKeyName {
                @(
                    'O365ProPlusRetail - nb-no',
                    'O365ProPlusRetail - de-de',
                    'VisioProRetail - en-us',
                    'Adobe Acrobat'
                )
            } -ParameterFilter { $Path -like 'SOFTWARE*\Uninstall' }

            $langs = Get-InstalledLanguages -ProductId 'O365ProPlusRetail'
            $langs | Should -Contain 'nb-no'
            $langs | Should -Contain 'de-de'
            $langs | Should -Contain 'en-us'
            $langs | Should -Not -Contain 'Adobe Acrobat'
        }
    }
}

Describe 'Test-LanguagePackInstalled' {
    It 'matches when the current LanguagePack key shape is present' {
        InModuleScope ODTOfficeState {
            Mock Get-InstalledLanguages { @('en-us','nb-no') } -ParameterFilter { $ProductId -eq 'LanguagePack' }
            Mock Get-InstalledLanguages { @() }               -ParameterFilter { $ProductId -eq 'O365ProPlusRetail' }
            (Test-LanguagePackInstalled -LanguageID 'NB-NO') | Should -BeTrue
            (Test-LanguagePackInstalled -LanguageID 'fr-fr') | Should -BeFalse
        }
    }

    It 'matches when only the legacy "<TargetProduct> - <lang>" key shape is present' {
        InModuleScope ODTOfficeState {
            Mock Get-InstalledLanguages { @() }               -ParameterFilter { $ProductId -eq 'LanguagePack' }
            Mock Get-InstalledLanguages { @('en-us','de-de') } -ParameterFilter { $ProductId -eq 'O365ProPlusRetail' }
            (Test-LanguagePackInstalled -LanguageID 'de-de' -TargetProduct 'O365ProPlusRetail') | Should -BeTrue
            (Test-LanguagePackInstalled -LanguageID 'fr-fr' -TargetProduct 'O365ProPlusRetail') | Should -BeFalse
        }
    }

    It 'prefers LanguagePack hits and does not miss just because TargetProduct is not passed' {
        InModuleScope ODTOfficeState {
            Mock Get-InstalledLanguages { @('sv-se') } -ParameterFilter { $ProductId -eq 'LanguagePack' }
            Mock Get-InstalledLanguages { @() }
            (Test-LanguagePackInstalled -LanguageID 'sv-se') | Should -BeTrue
        }
    }
}

Describe 'Get-OfficeChannelName' {
    It 'translates the full registry URL for MonthlyEnterprise to the channel name' {
        Get-OfficeChannelName -UpdateChannel 'http://officecdn.microsoft.com/pr/55336b82-a18d-4dd6-b5f6-9e5095c314a6' |
            Should -Be 'MonthlyEnterprise'
    }

    It 'translates the full registry URL for Current' {
        Get-OfficeChannelName -UpdateChannel 'http://officecdn.microsoft.com/pr/492350f6-3a01-4f97-b9c0-c7c6ddf67d60' |
            Should -Be 'Current'
    }

    It 'translates a bare GUID' {
        Get-OfficeChannelName -UpdateChannel '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114' |
            Should -Be 'SemiAnnual'
    }

    It 'passes a known channel name through unchanged (case-insensitive)' {
        Get-OfficeChannelName -UpdateChannel 'MonthlyEnterprise' | Should -Be 'MonthlyEnterprise'
        Get-OfficeChannelName -UpdateChannel 'monthlyenterprise' | Should -Be 'MonthlyEnterprise'
    }

    It 'returns $null for an unknown GUID and emits a warning' {
        $result = Get-OfficeChannelName -UpdateChannel 'http://officecdn.microsoft.com/pr/00000000-0000-0000-0000-000000000000' -WarningAction SilentlyContinue -WarningVariable w
        $result | Should -BeNullOrEmpty
        $w.Count | Should -BeGreaterThan 0
        $w[0].Message | Should -Match 'not in the known channel map'
    }

    It 'returns $null for empty / whitespace input without warning noise' {
        Get-OfficeChannelName -UpdateChannel '' | Should -BeNullOrEmpty
        Get-OfficeChannelName -UpdateChannel '   ' | Should -BeNullOrEmpty
    }

    It 'returns $null for strings with no GUID and no channel-name match, with a warning' {
        $result = Get-OfficeChannelName -UpdateChannel 'not-a-url' -WarningAction SilentlyContinue -WarningVariable w
        $result | Should -BeNullOrEmpty
        $w.Count | Should -BeGreaterThan 0
    }

    It 'bridges the registry GUID form and the XML channel name (string compare alone never matches)' {
        # The registry stores the channel as a URL like .../pr/55336b82-...
        # while the XML says "MonthlyEnterprise". String comparison never
        # matches the two, so the channel-mismatch warning in Install-Visio /
        # Install-Project must translate one form to the other first.
        $registryForm = 'http://officecdn.microsoft.com/pr/55336b82-a18d-4dd6-b5f6-9e5095c314a6'
        $xmlForm      = 'MonthlyEnterprise'
        $registryName = Get-OfficeChannelName -UpdateChannel $registryForm
        $xmlName      = Get-OfficeChannelName -UpdateChannel $xmlForm
        $registryName | Should -Be $xmlName
        ($xmlForm -ieq $registryName) | Should -BeTrue    # canonical comparison matches
    }

    It 'reports a real mismatch when the channels differ (MonthlyEnterprise vs Current)' {
        $registryName = Get-OfficeChannelName -UpdateChannel 'http://officecdn.microsoft.com/pr/55336b82-a18d-4dd6-b5f6-9e5095c314a6'
        $xmlName      = Get-OfficeChannelName -UpdateChannel 'Current'
        ($xmlName -ieq $registryName) | Should -BeFalse
    }
}

Describe 'Get-OfficeChannelGuid' {
    It 'returns the known GUID for each documented channel name' {
        Get-OfficeChannelGuid -ChannelName 'Current'           | Should -Be '492350f6-3a01-4f97-b9c0-c7c6ddf67d60'
        Get-OfficeChannelGuid -ChannelName 'MonthlyEnterprise' | Should -Be '55336b82-a18d-4dd6-b5f6-9e5095c314a6'
        Get-OfficeChannelGuid -ChannelName 'SemiAnnual'        | Should -Be '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114'
        Get-OfficeChannelGuid -ChannelName 'SemiAnnualPreview' | Should -Be 'b8f9b850-328d-4355-9145-c59439a0c4cf'
        Get-OfficeChannelGuid -ChannelName 'CurrentPreview'    | Should -Be '64256afe-f5d9-4f86-8936-8840a6a4f5be'
        Get-OfficeChannelGuid -ChannelName 'Beta'              | Should -Be '5440fd1f-7ecb-4221-8110-145efaa6372f'
        Get-OfficeChannelGuid -ChannelName 'PerpetualVL2021'   | Should -Be 'f2e724c1-748f-4b47-8fb8-8e0d210e9208'
    }

    It 'is case-insensitive on input' {
        Get-OfficeChannelGuid -ChannelName 'monthlyenterprise' | Should -Be '55336b82-a18d-4dd6-b5f6-9e5095c314a6'
    }

    It 'returns $null with a warning for unknown channel names' {
        $result = Get-OfficeChannelGuid -ChannelName 'ImaginaryChannel' -WarningAction SilentlyContinue -WarningVariable w
        $result | Should -BeNullOrEmpty
        $w.Count | Should -BeGreaterThan 0
    }
}
