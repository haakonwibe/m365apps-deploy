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

    It 'enumerates 3-letter primaries and script-tag languages from ProductReleaseIds' {
        # The narrower ^[a-z]{2}-[a-z]{2}$ regex used before v1.0.3 silently
        # truncated multi-lingual installs that included tags like
        # chr-cher-us (3-letter primary) or az-latn-az (script subtag),
        # leaving Resolve-VisioProjectLanguages with an incomplete input.
        # The widened canonical BCP-47 pattern covers both shapes.
        InModuleScope ODTOfficeState {
            Mock Get-Registry64Item {
                [pscustomobject]@{
                    ProductReleaseIds = 'O365ProPlusRetail'
                    Platform          = 'x64'
                    UpdateChannel     = 'http://officecdn.microsoft.com/pr/55336b82-a18d-4dd6-b5f6-9e5095c314a6'
                    ClientCulture     = 'nb-no'
                }
            } -ParameterFilter { $Path -eq 'SOFTWARE\Microsoft\Office\ClickToRun\Configuration' }
            Mock Get-Registry64Item {
                [pscustomobject]@{
                    'nb-no'        = ''
                    'chr-cher-us'  = ''   # 3-letter primary
                    'az-latn-az'   = ''   # script subtag
                    'sr-latn-rs'   = ''   # another script subtag
                    'LastScenario' = 'noise that the !PS|Active|LastScenario filter rejects'
                }
            } -ParameterFilter { $Path -eq 'SOFTWARE\Microsoft\Office\ClickToRun\Configuration\ProductReleaseIds' }

            $r = Get-OfficeConfiguration
            $r.InstalledLanguages | Should -Contain 'nb-no'
            $r.InstalledLanguages | Should -Contain 'chr-cher-us'
            $r.InstalledLanguages | Should -Contain 'az-latn-az'
            $r.InstalledLanguages | Should -Contain 'sr-latn-rs'
            $r.InstalledLanguages | Should -Not -Contain 'LastScenario'
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
            Mock Get-Registry64SubKeyName {
                @(
                    'O365ProPlusRetail - en-us',
                    'O365ProPlusRetail - nb-no',
                    'O365ProPlusRetail - de-de',
                    'VisioProRetail - en-us',
                    'Adobe Acrobat'
                )
            } -ParameterFilter { $Path -like 'SOFTWARE*\Uninstall' }

            $langs = Get-InstalledLanguages -ProductId 'O365ProPlusRetail'
            $langs | Should -Contain 'en-us'
            $langs | Should -Contain 'nb-no'
            $langs | Should -Contain 'de-de'
            $langs | Should -Not -Contain 'Adobe Acrobat'
        }
    }

    It 'does not include ClientCulture (Uninstall keys are the source of truth)' {
        # v1.0.6 fix: pre-v1.0.6, ClientCulture was unconditionally added to
        # the result, causing Test-LanguagePackInstalled to false-positive
        # on machines where the language was the M365 Apps base culture but
        # had no LanguagePack/per-product Uninstall key.
        InModuleScope ODTOfficeState {
            Mock Get-OfficeConfiguration { [pscustomobject]@{ ClientCulture = 'fr-fr'; ProductReleaseIds = @('O365ProPlusRetail') } }
            Mock Get-Registry64SubKeyName { @('O365ProPlusRetail - en-us') } -ParameterFilter { $Path -like 'SOFTWARE*\Uninstall' }

            $langs = Get-InstalledLanguages -ProductId 'O365ProPlusRetail'
            $langs | Should -Not -Contain 'fr-fr' `
                -Because 'ClientCulture is no longer auto-included; the Uninstall keys carry the truth'
            $langs | Should -Contain 'en-us'
        }
    }
}

Describe 'Get-LanguagePackInstallationStatus (v1.0.7 — structured per-product status)' {
    # The function answers the same question as Test-LanguagePackInstalled
    # (is the language pack installed across every C2R product?) but
    # additionally reports the per-product breakdown so install/uninstall
    # scripts can log which products are present/missing.

    It 'returns Installed=true and every PerProduct entry true when every product has the language' {
        InModuleScope ODTOfficeState {
            Mock Get-OfficeConfiguration { [pscustomobject]@{ ProductReleaseIds = @('O365ProPlusRetail','VisioProRetail','ProjectProRetail') } }
            Mock Get-InstalledLanguages { @('en-us','nb-no') } -ParameterFilter { $ProductId -eq 'O365ProPlusRetail' }
            Mock Get-InstalledLanguages { @('en-us','nb-no') } -ParameterFilter { $ProductId -eq 'VisioProRetail' }
            Mock Get-InstalledLanguages { @('en-us','nb-no') } -ParameterFilter { $ProductId -eq 'ProjectProRetail' }

            $r = Get-LanguagePackInstallationStatus -LanguageID 'nb-no'
            $r.LanguageID                            | Should -Be 'nb-no'
            $r.Installed                             | Should -BeTrue
            $r.PerProduct['O365ProPlusRetail']       | Should -BeTrue
            $r.PerProduct['VisioProRetail']          | Should -BeTrue
            $r.PerProduct['ProjectProRetail']        | Should -BeTrue
        }
    }

    It 'returns Installed=false with the missing product flagged (Project missing the language)' {
        # Mirrors v1.0.5 scenario-2 / v1.0.6 fix exactly, generalised to Project.
        InModuleScope ODTOfficeState {
            Mock Get-OfficeConfiguration { [pscustomobject]@{ ProductReleaseIds = @('O365ProPlusRetail','VisioProRetail','ProjectProRetail') } }
            Mock Get-InstalledLanguages { @('en-us','nb-no') } -ParameterFilter { $ProductId -eq 'O365ProPlusRetail' }
            Mock Get-InstalledLanguages { @('en-us','nb-no') } -ParameterFilter { $ProductId -eq 'VisioProRetail' }
            Mock Get-InstalledLanguages { @('en-us') }         -ParameterFilter { $ProductId -eq 'ProjectProRetail' }

            $r = Get-LanguagePackInstallationStatus -LanguageID 'nb-no'
            $r.Installed                       | Should -BeFalse
            $r.PerProduct['O365ProPlusRetail'] | Should -BeTrue
            $r.PerProduct['VisioProRetail']    | Should -BeTrue
            $r.PerProduct['ProjectProRetail']  | Should -BeFalse
        }
    }

    It 'returns Installed=false with the missing product flagged (Visio missing the language)' {
        InModuleScope ODTOfficeState {
            Mock Get-OfficeConfiguration { [pscustomobject]@{ ProductReleaseIds = @('O365ProPlusRetail','VisioProRetail','ProjectProRetail') } }
            Mock Get-InstalledLanguages { @('en-us','nb-no') } -ParameterFilter { $ProductId -eq 'O365ProPlusRetail' }
            Mock Get-InstalledLanguages { @('en-us') }         -ParameterFilter { $ProductId -eq 'VisioProRetail' }
            Mock Get-InstalledLanguages { @('en-us','nb-no') } -ParameterFilter { $ProductId -eq 'ProjectProRetail' }

            $r = Get-LanguagePackInstallationStatus -LanguageID 'nb-no'
            $r.Installed                       | Should -BeFalse
            $r.PerProduct['O365ProPlusRetail'] | Should -BeTrue
            $r.PerProduct['VisioProRetail']    | Should -BeFalse
            $r.PerProduct['ProjectProRetail']  | Should -BeTrue
        }
    }

    It 'returns Installed=false and all PerProduct entries false when no product has the language' {
        InModuleScope ODTOfficeState {
            Mock Get-OfficeConfiguration { [pscustomobject]@{ ProductReleaseIds = @('O365ProPlusRetail','VisioProRetail') } }
            Mock Get-InstalledLanguages { @('en-us') } -ParameterFilter { $ProductId -eq 'O365ProPlusRetail' }
            Mock Get-InstalledLanguages { @('en-us') } -ParameterFilter { $ProductId -eq 'VisioProRetail' }

            $r = Get-LanguagePackInstallationStatus -LanguageID 'fr-fr'
            $r.Installed                       | Should -BeFalse
            $r.PerProduct['O365ProPlusRetail'] | Should -BeFalse
            $r.PerProduct['VisioProRetail']    | Should -BeFalse
        }
    }

    It 'returns Installed=false with empty PerProduct when no C2R configuration is detected' {
        InModuleScope ODTOfficeState {
            Mock Get-OfficeConfiguration { $null }

            $r = Get-LanguagePackInstallationStatus -LanguageID 'nb-no'
            $r.Installed         | Should -BeFalse
            $r.PerProduct.Count  | Should -Be 0
        }
    }

    It 'returns Installed=false with empty PerProduct when ProductReleaseIds is empty' {
        InModuleScope ODTOfficeState {
            Mock Get-OfficeConfiguration { [pscustomobject]@{ ProductReleaseIds = @() } }

            $r = Get-LanguagePackInstallationStatus -LanguageID 'nb-no'
            $r.Installed         | Should -BeFalse
            $r.PerProduct.Count  | Should -Be 0
        }
    }

    It 'includes the LanguagePack pseudo-product when ProductReleaseIds carries it' {
        # Some ODT installs register the LanguagePack pseudo-product alongside
        # the real ProductReleaseIds. The status function reports it as a row
        # like any other — accuracy over filtering, per the v1.0.7 audit.
        InModuleScope ODTOfficeState {
            Mock Get-OfficeConfiguration { [pscustomobject]@{ ProductReleaseIds = @('O365ProPlusRetail','LanguagePack') } }
            Mock Get-InstalledLanguages { @('nb-no') } -ParameterFilter { $ProductId -eq 'O365ProPlusRetail' }
            Mock Get-InstalledLanguages { @('nb-no') } -ParameterFilter { $ProductId -eq 'LanguagePack' }

            $r = Get-LanguagePackInstallationStatus -LanguageID 'nb-no'
            $r.PerProduct.Keys              | Should -Contain 'LanguagePack'
            $r.PerProduct['LanguagePack']   | Should -BeTrue
            $r.Installed                    | Should -BeTrue
        }
    }

    It 'normalises the LanguageID to lower-case in the result' {
        InModuleScope ODTOfficeState {
            Mock Get-OfficeConfiguration { [pscustomobject]@{ ProductReleaseIds = @('O365ProPlusRetail') } }
            Mock Get-InstalledLanguages { @('nb-no') } -ParameterFilter { $ProductId -eq 'O365ProPlusRetail' }

            $r = Get-LanguagePackInstallationStatus -LanguageID 'NB-NO'
            $r.LanguageID | Should -Be 'nb-no'
            $r.Installed  | Should -BeTrue
        }
    }
}

Describe 'Test-LanguagePackInstalled (v1.0.6 — per-installed-product semantic)' {
    # The function answers "is the language installed for EVERY currently
    # installed Click-to-Run product?" Used by Install-LanguagePack to
    # decide whether to skip the install (idempotency) and by post-install
    # verification to catch silent setup.exe failures.

    It 'returns TRUE when every installed product has the language' {
        InModuleScope ODTOfficeState {
            Mock Get-OfficeConfiguration { [pscustomobject]@{ ProductReleaseIds = @('O365ProPlusRetail','VisioProRetail') } }
            Mock Get-InstalledLanguages { @('en-us','nb-no') } -ParameterFilter { $ProductId -eq 'O365ProPlusRetail' }
            Mock Get-InstalledLanguages { @('en-us','nb-no') } -ParameterFilter { $ProductId -eq 'VisioProRetail' }

            (Test-LanguagePackInstalled -LanguageID 'NB-NO') | Should -BeTrue
            (Test-LanguagePackInstalled -LanguageID 'en-us') | Should -BeTrue
        }
    }

    It 'returns FALSE when any installed product is missing the language (v1.0.5 scenario 2 regression)' {
        # M365 Apps installed in nb-NO directly (creates O365ProPlusRetail - nb-no
        # but not VisioProRetail - nb-no). Visio in en-us only.
        # Pre-v1.0.6, this returned TRUE via the legacy-shape fallback +
        # ClientCulture noise, so Install-LanguagePack would skip and Visio
        # would never gain nb-NO. The per-product check fixes it.
        InModuleScope ODTOfficeState {
            Mock Get-OfficeConfiguration { [pscustomobject]@{ ProductReleaseIds = @('O365ProPlusRetail','VisioProRetail') } }
            Mock Get-InstalledLanguages { @('nb-no') }   -ParameterFilter { $ProductId -eq 'O365ProPlusRetail' }
            Mock Get-InstalledLanguages { @('en-us') }   -ParameterFilter { $ProductId -eq 'VisioProRetail' }

            (Test-LanguagePackInstalled -LanguageID 'nb-no') | Should -BeFalse `
                -Because 'Visio is missing nb-no; Install-LanguagePack should run setup.exe to spread the LP'
        }
    }

    It 'returns FALSE when the language is in no installed product' {
        InModuleScope ODTOfficeState {
            Mock Get-OfficeConfiguration { [pscustomobject]@{ ProductReleaseIds = @('O365ProPlusRetail') } }
            Mock Get-InstalledLanguages { @('en-us') } -ParameterFilter { $ProductId -eq 'O365ProPlusRetail' }

            (Test-LanguagePackInstalled -LanguageID 'fr-fr') | Should -BeFalse
        }
    }

    It 'returns FALSE when no C2R configuration is detected' {
        InModuleScope ODTOfficeState {
            Mock Get-OfficeConfiguration { $null }

            (Test-LanguagePackInstalled -LanguageID 'nb-no') | Should -BeFalse
        }
    }

    It 'returns FALSE when ProductReleaseIds is empty' {
        InModuleScope ODTOfficeState {
            Mock Get-OfficeConfiguration { [pscustomobject]@{ ProductReleaseIds = @() } }

            (Test-LanguagePackInstalled -LanguageID 'nb-no') | Should -BeFalse
        }
    }

    It 'is case-insensitive on the language tag' {
        InModuleScope ODTOfficeState {
            Mock Get-OfficeConfiguration { [pscustomobject]@{ ProductReleaseIds = @('O365ProPlusRetail') } }
            Mock Get-InstalledLanguages { @('nb-no') } -ParameterFilter { $ProductId -eq 'O365ProPlusRetail' }

            (Test-LanguagePackInstalled -LanguageID 'NB-NO') | Should -BeTrue
            (Test-LanguagePackInstalled -LanguageID 'Nb-No') | Should -BeTrue
        }
    }

    It 'walks every product in ProductReleaseIds (multi-product install)' {
        # M365 Apps + Visio + Project all installed and all have the language.
        InModuleScope ODTOfficeState {
            Mock Get-OfficeConfiguration { [pscustomobject]@{ ProductReleaseIds = @('O365ProPlusRetail','VisioProRetail','ProjectProRetail') } }
            Mock Get-InstalledLanguages { @('en-us','nb-no') } -ParameterFilter { $ProductId -eq 'O365ProPlusRetail' }
            Mock Get-InstalledLanguages { @('en-us','nb-no') } -ParameterFilter { $ProductId -eq 'VisioProRetail' }
            Mock Get-InstalledLanguages { @('en-us','nb-no') } -ParameterFilter { $ProductId -eq 'ProjectProRetail' }

            (Test-LanguagePackInstalled -LanguageID 'nb-no') | Should -BeTrue
        }
    }

    It 'returns FALSE if the third installed product is missing the language even when first two have it' {
        InModuleScope ODTOfficeState {
            Mock Get-OfficeConfiguration { [pscustomobject]@{ ProductReleaseIds = @('O365ProPlusRetail','VisioProRetail','ProjectProRetail') } }
            Mock Get-InstalledLanguages { @('en-us','nb-no') } -ParameterFilter { $ProductId -eq 'O365ProPlusRetail' }
            Mock Get-InstalledLanguages { @('en-us','nb-no') } -ParameterFilter { $ProductId -eq 'VisioProRetail' }
            Mock Get-InstalledLanguages { @('en-us') }         -ParameterFilter { $ProductId -eq 'ProjectProRetail' }

            (Test-LanguagePackInstalled -LanguageID 'nb-no') | Should -BeFalse
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
