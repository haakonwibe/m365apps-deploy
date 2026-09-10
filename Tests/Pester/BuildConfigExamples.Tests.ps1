#Requires -Version 5.1
<#
.SYNOPSIS
    Guards for the ready-to-copy build-config.json examples in docs/examples/.

.DESCRIPTION
    These files exist to be copied verbatim into a real deployment, so a typo
    in one is a typo that ships. The build already rejects an unknown language
    before staging, but it does so on the operator's machine after they have
    copied the file - catching it here is cheaper.

    Each example is checked for: valid JSON, a Language that is actually in
    the Microsoft 365 Apps matrix, a scalar (not array) Language, and valid
    ExcludedApps entries if it overrides them.

    Run with:
        Invoke-Pester -Path .\Tests\Pester\BuildConfigExamples.Tests.ps1
#>

# Discovery-time enumeration: Pester evaluates -ForEach while discovering, so
# this has to run at script scope rather than in BeforeAll.
$repoRoot    = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..')
$examplesDir = Join-Path -Path $repoRoot -ChildPath 'docs\examples'
$exampleFiles = @()
if (Test-Path -LiteralPath $examplesDir -PathType Container) {
    $exampleFiles = Get-ChildItem -LiteralPath $examplesDir -Filter 'build-config.*.json' -File |
        ForEach-Object { @{ Name = $_.Name; FullName = $_.FullName } }
}

BeforeAll {
    $script:RepoRoot = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..')
    Import-Module (Join-Path -Path $script:RepoRoot -ChildPath 'Common\ODTLanguages.psm1') -Force
    . (Join-Path -Path $script:RepoRoot -ChildPath 'Build\Invoke-ProductStaging.ps1')

    $script:OfficeLanguages = @(Get-ODTSupportedLanguages -TargetProduct 'O365ProPlusRetail')
    $script:Tokens = Get-DefaultBuildTokens

    # Re-enumerated for the run phase: the discovery-time $exampleFiles above
    # feeds -ForEach, but is not in scope inside an It body.
    $script:ExamplesDir = Join-Path -Path $script:RepoRoot -ChildPath 'docs\examples'
    $script:ExampleFiles = @(Get-ChildItem -LiteralPath $script:ExamplesDir -Filter 'build-config.*.json' -File)
}

AfterAll {
    Remove-Module ODTLanguages -ErrorAction SilentlyContinue
}

Describe 'docs/examples build-config files' {

    It 'ships at least the four documented scenarios' {
        $script:ExampleFiles.Count | Should -BeGreaterOrEqual 4
    }

    It 'covers the en-us, en-gb, european and norwegian scenarios by name' {
        $names = @($script:ExampleFiles.Name)
        foreach ($expected in 'build-config.en-us.json','build-config.en-gb.json',
                              'build-config.european-multi.json','build-config.norwegian.json') {
            $names | Should -Contain $expected
        }
    }

    It 'lists every example file in the README table' {
        $readme = Get-Content -LiteralPath (Join-Path $script:ExamplesDir 'README.md') -Raw
        foreach ($file in $script:ExampleFiles) {
            $readme | Should -BeLike ('*{0}*' -f $file.Name) `
                -Because 'an example nobody can find is an example nobody uses'
        }
    }

    It 'has a README describing them' {
        Test-Path -LiteralPath (Join-Path $script:RepoRoot 'docs\examples\README.md') -PathType Leaf |
            Should -BeTrue
    }

    It '<Name> is valid JSON' -ForEach $exampleFiles {
        { Get-Content -LiteralPath $FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop } |
            Should -Not -Throw
    }

    It '<Name> sets a scalar Language, not an array' -ForEach $exampleFiles {
        # An array here coerces to 'nb-no nn-no' and hard-fails the build. The
        # examples must never model that.
        $config = Get-Content -LiteralPath $FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $config.PSObject.Properties['Language'] | Should -Not -BeNullOrEmpty
        $config.Language | Should -BeOfType ([string]) -Because 'Language is a BuildTime scalar token'
    }

    It '<Name> uses a Language that is in the Microsoft 365 Apps matrix' -ForEach $exampleFiles {
        $config = Get-Content -LiteralPath $FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:OfficeLanguages | Should -Contain $config.Language
    }

    It '<Name> declares every registered token' -ForEach $exampleFiles {
        # Keeps the examples honest as the token table grows: a new token
        # should be represented (even as null) rather than silently absent.
        $config = Get-Content -LiteralPath $FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($name in $script:Tokens.Keys) {
            if ([string]$script:Tokens[$name].Mode -eq 'Runtime') { continue }
            $config.PSObject.Properties[$name] | Should -Not -BeNullOrEmpty `
                -Because "'$name' is a build-time token and should appear in the example"
        }
    }

    It '<Name> uses only valid ExcludedApps IDs when it overrides them' -ForEach $exampleFiles {
        $config = Get-Content -LiteralPath $FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $config.ExcludedApps) { return }
        $known = @($script:Tokens.ExcludedApps.KnownValues)
        foreach ($app in @($config.ExcludedApps)) {
            $known | Should -Contain $app
        }
    }

    It '<Name> references only language IDs that exist, in its commentary' -ForEach $exampleFiles {
        # The _-prefixed keys are ignored by the build but read by humans, and
        # a wrong language ID there sends someone to a LanguagePack app that
        # cannot be built. Scan for anything shaped like a BCP-47 tag next to
        # a -LanguageID switch.
        $raw = Get-Content -LiteralPath $FullName -Raw -Encoding UTF8
        $referenced = @([regex]::Matches($raw, '-LanguageID\s+([a-z]{2,3}(?:-[a-z0-9]+)+)') |
            ForEach-Object { $_.Groups[1].Value })

        # Some examples list the pack languages as an array instead of, or as
        # well as, spelling out each command.
        $config = $raw | ConvertFrom-Json
        if ($config.PSObject.Properties['_additionalLanguageApps']) {
            $apps = $config._additionalLanguageApps
            if ($apps.PSObject.Properties['languageIds']) {
                $referenced += @($apps.languageIds)
            }
            # Per-language objects keyed by the language tag itself.
            foreach ($prop in $apps.PSObject.Properties) {
                if ($prop.Name -like '_*') { continue }
                if ($prop.Name -eq 'languageIds') { continue }
                $referenced += $prop.Name
            }
        }

        $referenced = @($referenced | Select-Object -Unique)

        # A single-language example legitimately references no packs at all;
        # one that declares _additionalLanguageApps must actually name some,
        # otherwise the block is decoration.
        if ($config.PSObject.Properties['_additionalLanguageApps']) {
            $referenced.Count | Should -BeGreaterThan 0 `
                -Because 'an _additionalLanguageApps block must name the languages it covers'
        }

        foreach ($lang in $referenced) {
            $script:OfficeLanguages | Should -Contain $lang `
                -Because "the example points an admin at language pack '$lang'"
        }
    }
}
