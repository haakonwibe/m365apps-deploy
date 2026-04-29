#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 tests asserting every install script (and the LP uninstall)
    discloses the language(s) being installed/removed before launching
    setup.exe.

.DESCRIPTION
    Admins reading IME / CMTrace logs should see one line per install
    that names the language(s) the device is about to install — without
    correlating to the staged XML. Symmetrically, the LP uninstall logs
    the language being removed. This pins the contract via static
    source-grep so a future refactor doesn't quietly drop the line.

    Run with:
        Invoke-Pester -Path .\Tests\Pester\InstallLogLanguageDisclosure.Tests.ps1
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..')
}

Describe 'Install / uninstall scripts disclose language(s) before setup.exe' {

    # Visio + Project deliberately not covered: v1.0.5 makes their base
    # install constant en-us, so a runtime language-disclosure log line
    # would log a constant. Language overlays for Visio/Project ship as
    # separate Win32 LP apps, which DO log per-call (the LP rows below).

    It '<Script> contains the language-disclosure log line' -ForEach @(
        @{ Script = 'M365Apps\Install-M365Apps.ps1';            Pattern = 'Installing M365 Apps with languages:' }
        @{ Script = 'LanguagePacks\Install-LanguagePack.ps1';   Pattern = 'Installing language pack:' }
        @{ Script = 'LanguagePacks\Uninstall-LanguagePack.ps1'; Pattern = 'Removing language pack:' }
    ) {
        $full    = Join-Path $script:RepoRoot $Script
        $content = Get-Content -LiteralPath $full -Raw
        $content | Should -Match ([regex]::Escape($Pattern)) `
            -Because 'admins must be able to confirm the resolved language(s) from the log alone'
    }

    It '<Script> places the disclosure before the "Starting setup.exe" log line' -ForEach @(
        @{ Script = 'M365Apps\Install-M365Apps.ps1';            Pattern = 'Installing M365 Apps with languages:' }
        @{ Script = 'LanguagePacks\Install-LanguagePack.ps1';   Pattern = 'Installing language pack:' }
        @{ Script = 'LanguagePacks\Uninstall-LanguagePack.ps1'; Pattern = 'Removing language pack:' }
    ) {
        $full       = Join-Path $script:RepoRoot $Script
        $content    = Get-Content -LiteralPath $full -Raw
        $discloseAt = $content.IndexOf($Pattern)
        $setupAt    = $content.IndexOf('Starting setup.exe')
        $discloseAt | Should -BeGreaterThan -1 -Because 'the disclosure pattern must be present'
        $setupAt    | Should -BeGreaterThan -1 -Because 'the "Starting setup.exe" log line must be present'
        $discloseAt | Should -BeLessThan $setupAt `
            -Because 'the disclosure must appear before "Starting setup.exe" so the language is logged at action time'
    }
}
