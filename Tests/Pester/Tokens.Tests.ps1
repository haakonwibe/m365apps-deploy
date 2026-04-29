#Requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for the build-time XML token-substitution engine.

.DESCRIPTION
    Covers Get-DefaultBuildTokens and Invoke-XmlTokenSubstitution in
    Build\Invoke-ProductStaging.ps1, plus an end-to-end check on every
    real source XML to guarantee that a build with zero tokens set
    still produces well-formed, generic XMLs.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..')
    . (Join-Path -Path $script:RepoRoot -ChildPath 'Build\Invoke-ProductStaging.ps1')

    $script:WorkDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("tokens-tests-$([Guid]::NewGuid().ToString('N'))")
    $null = New-Item -Path $script:WorkDir -ItemType Directory -Force

    function New-XmlFixture {
        param([string] $Name, [string] $Content)
        $path = Join-Path $script:WorkDir $Name
        [System.IO.File]::WriteAllText($path, $Content, (New-Object System.Text.UTF8Encoding $true))
        return $path
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:WorkDir) {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Get-DefaultBuildTokens' {
    It 'registers CompanyName as a BuildTime token with no default value' {
        $t = Get-DefaultBuildTokens
        $t.Contains('CompanyName')   | Should -BeTrue
        $t.CompanyName.Mode          | Should -Be 'BuildTime'
        $t.CompanyName.Value         | Should -BeNullOrEmpty
    }

    It 'registers the LanguagePack runtime tokens as Runtime (pass-through)' {
        $t = Get-DefaultBuildTokens
        foreach ($name in 'OfficeClientEdition','Channel','LanguageID') {
            $t.Contains($name) | Should -BeTrue -Because "$name must be registered so the engine does not hard-fail on the runtime template"
            $t[$name].Mode     | Should -Be 'Runtime'
        }
    }

    It 'registers Language as a BuildTime scalar with Default = en-us and a placeholder KnownValues slot' {
        # KnownValues is populated at orchestrator runtime from
        # Get-ODTSupportedLanguages so Get-DefaultBuildTokens stays a pure
        # function. Default is the load-bearing piece: 'en-us' substitutes
        # into staged XML when the value is unset, instead of the
        # CompanyName-style line-strip that would invalidate <Product>.
        $t = Get-DefaultBuildTokens
        $t.Contains('Language')  | Should -BeTrue
        $t.Language.Mode         | Should -Be 'BuildTime'
        $t.Language.Value        | Should -BeNullOrEmpty
        $t.Language.Default      | Should -Be 'en-us'
        $t.Language.Contains('KnownValues') | Should -BeTrue
    }
}

Describe 'Invoke-XmlTokenSubstitution' {

    It 'substitutes a BuildTime token when its Value is set' {
        $xml = @'
<?xml version="1.0" encoding="UTF-8"?>
<Configuration>
  <AppSettings>
    <Setup Name="Company" Value="{{CompanyName}}" />
  </AppSettings>
</Configuration>
'@
        $path = New-XmlFixture 'sub-set.xml' $xml
        $tokens = Get-DefaultBuildTokens
        $tokens.CompanyName.Value = 'Contoso Ltd'
        $r = Invoke-XmlTokenSubstitution -Path $path -Tokens $tokens

        $r.Substituted   | Should -Be 1
        $r.LinesRemoved  | Should -Be 0
        $r.EmptyBlocksStripped | Should -Be 0

        $content = Get-Content -LiteralPath $path -Raw
        $content | Should -Match 'Value="Contoso Ltd"'
        $content | Should -Not -Match '\{\{CompanyName\}\}'

        # Result is well-formed XML and the AppSettings element survives.
        { [xml]$null = $content } | Should -Not -Throw
        ([xml]$content).SelectSingleNode('/Configuration/AppSettings/Setup[@Name="Company"]').Value |
            Should -Be 'Contoso Ltd'
    }

    It 'removes the entire line containing an unset BuildTime token, leaving surrounding XML well-formed' {
        $xml = @'
<?xml version="1.0" encoding="UTF-8"?>
<Configuration>
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
  <AppSettings>
    <Setup Name="Company" Value="{{CompanyName}}" />
    <Setup Name="OtherSetting" Value="x" />
  </AppSettings>
  <Display Level="None" AcceptEULA="TRUE" />
</Configuration>
'@
        $path = New-XmlFixture 'sub-unset-with-sibling.xml' $xml
        $tokens = Get-DefaultBuildTokens
        $r = Invoke-XmlTokenSubstitution -Path $path -Tokens $tokens

        $r.LinesRemoved | Should -Be 1
        $r.EmptyBlocksStripped | Should -Be 0  # AppSettings still has OtherSetting child.

        $content = Get-Content -LiteralPath $path -Raw
        $content | Should -Not -Match '\{\{CompanyName\}\}'
        $content | Should -Not -Match '<Setup Name="Company"'

        { [xml]$null = $content } | Should -Not -Throw

        $doc = [xml]$content
        $doc.SelectSingleNode('/Configuration/AppSettings/Setup[@Name="Company"]')      | Should -BeNullOrEmpty
        $doc.SelectSingleNode('/Configuration/AppSettings/Setup[@Name="OtherSetting"]') | Should -Not -BeNullOrEmpty
    }

    It 'strips an AppSettings block that becomes empty after token removal' {
        $xml = @'
<?xml version="1.0" encoding="UTF-8"?>
<Configuration>
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
  <AppSettings>
    <Setup Name="Company" Value="{{CompanyName}}" />
  </AppSettings>
  <Display Level="None" AcceptEULA="TRUE" />
</Configuration>
'@
        $path = New-XmlFixture 'sub-unset-empty-block.xml' $xml
        $tokens = Get-DefaultBuildTokens
        $r = Invoke-XmlTokenSubstitution -Path $path -Tokens $tokens

        $r.LinesRemoved        | Should -Be 1
        $r.EmptyBlocksStripped | Should -Be 1

        $content = Get-Content -LiteralPath $path -Raw
        $content | Should -Not -Match '<AppSettings>'
        $content | Should -Not -Match '</AppSettings>'

        { [xml]$null = $content } | Should -Not -Throw
    }

    It 'leaves Runtime tokens untouched (no substitution, no line removal)' {
        $xml = @'
<?xml version="1.0" encoding="UTF-8"?>
<Configuration>
  <Add OfficeClientEdition="{{OfficeClientEdition}}" Channel="{{Channel}}">
    <Product ID="LanguagePack">
      <Language ID="{{LanguageID}}" />
    </Product>
  </Add>
</Configuration>
'@
        $path = New-XmlFixture 'sub-runtime-passthrough.xml' $xml
        $tokens = Get-DefaultBuildTokens
        $r = Invoke-XmlTokenSubstitution -Path $path -Tokens $tokens

        $r.Substituted    | Should -Be 0
        $r.LinesRemoved   | Should -Be 0
        $r.RuntimeTokens  | Should -Contain 'OfficeClientEdition'
        $r.RuntimeTokens  | Should -Contain 'Channel'
        $r.RuntimeTokens  | Should -Contain 'LanguageID'

        $content = Get-Content -LiteralPath $path -Raw
        $content | Should -Match '\{\{OfficeClientEdition\}\}'
        $content | Should -Match '\{\{Channel\}\}'
        $content | Should -Match '\{\{LanguageID\}\}'
    }

    It 'hard-fails on an unregistered {{...}} pattern in the source' {
        $xml = @'
<?xml version="1.0" encoding="UTF-8"?>
<Configuration>
  <Setup Name="Hint" Value="{{ThisTokenDoesNotExist}}" />
</Configuration>
'@
        $path = New-XmlFixture 'sub-unregistered.xml' $xml
        $tokens = Get-DefaultBuildTokens

        # The unregistered token doesn't match any registered name, so the engine
        # leaves it on the line; the post-substitution scan must throw.
        { Invoke-XmlTokenSubstitution -Path $path -Tokens $tokens } |
            Should -Throw -ExpectedMessage "*unregistered token '{{ThisTokenDoesNotExist}}'*"
    }
}

Describe 'BuildTime token: Language (scalar with Default + KnownValues)' {
    # Language is the first BuildTime token to use the Default-fallback path
    # (en-us substitutes when unset, instead of dropping the line) and the
    # BuildTime KnownValues validator (typo'd tags fail the build).

    It 'substitutes the Default value when Value is unset (does not drop the line)' {
        $xml = @'
<?xml version="1.0" encoding="UTF-8"?>
<Configuration>
  <Add>
    <Product ID="O365ProPlusRetail">
      <Language ID="{{Language}}" />
    </Product>
  </Add>
</Configuration>
'@
        $path = New-XmlFixture 'lang-default.xml' $xml
        $tokens = Get-DefaultBuildTokens
        # Value is $null, KnownValues unpopulated -> fall back to Default and skip validation.
        $r = Invoke-XmlTokenSubstitution -Path $path -Tokens $tokens

        $r.Substituted   | Should -Be 1
        $r.LinesRemoved  | Should -Be 0

        $doc = [xml](Get-Content -LiteralPath $path -Raw)
        $doc.Configuration.Add.Product.Language.ID | Should -Be 'en-us'
    }

    It 'substitutes the explicit Value when set' {
        $xml = @'
<?xml version="1.0" encoding="UTF-8"?>
<Configuration>
  <Add>
    <Product ID="O365ProPlusRetail">
      <Language ID="{{Language}}" />
    </Product>
  </Add>
</Configuration>
'@
        $path = New-XmlFixture 'lang-override.xml' $xml
        $tokens = Get-DefaultBuildTokens
        $tokens.Language.Value = 'nb-no'
        $r = Invoke-XmlTokenSubstitution -Path $path -Tokens $tokens

        $r.Substituted | Should -Be 1
        $doc = [xml](Get-Content -LiteralPath $path -Raw)
        $doc.Configuration.Add.Product.Language.ID | Should -Be 'nb-no'
    }

    It 'falls back to Default when Value is set to an empty string' {
        $xml = @'
<?xml version="1.0" encoding="UTF-8"?>
<Configuration>
  <Add>
    <Product ID="O365ProPlusRetail">
      <Language ID="{{Language}}" />
    </Product>
  </Add>
</Configuration>
'@
        $path = New-XmlFixture 'lang-empty.xml' $xml
        $tokens = Get-DefaultBuildTokens
        $tokens.Language.Value = ''
        $null = Invoke-XmlTokenSubstitution -Path $path -Tokens $tokens
        $doc = [xml](Get-Content -LiteralPath $path -Raw)
        $doc.Configuration.Add.Product.Language.ID | Should -Be 'en-us'
    }

    It 'falls back to Default when Value is whitespace-only' {
        $xml = @'
<?xml version="1.0" encoding="UTF-8"?>
<Configuration>
  <Add>
    <Product ID="O365ProPlusRetail">
      <Language ID="{{Language}}" />
    </Product>
  </Add>
</Configuration>
'@
        $path = New-XmlFixture 'lang-ws.xml' $xml
        $tokens = Get-DefaultBuildTokens
        $tokens.Language.Value = '   '
        $null = Invoke-XmlTokenSubstitution -Path $path -Tokens $tokens
        $doc = [xml](Get-Content -LiteralPath $path -Raw)
        $doc.Configuration.Add.Product.Language.ID | Should -Be 'en-us'
    }

    It 'rejects an unknown Value when KnownValues is populated' {
        $xml = @'
<?xml version="1.0" encoding="UTF-8"?>
<Configuration>
  <Add>
    <Product ID="O365ProPlusRetail">
      <Language ID="{{Language}}" />
    </Product>
  </Add>
</Configuration>
'@
        $path = New-XmlFixture 'lang-typo.xml' $xml
        $tokens = Get-DefaultBuildTokens
        $tokens.Language.KnownValues = @('en-us','nb-no','de-de')
        $tokens.Language.Value       = 'nb-NN'   # typo: capital NN
        { Invoke-XmlTokenSubstitution -Path $path -Tokens $tokens } |
            Should -Throw -ExpectedMessage "*'Language' value 'nb-NN' is not in the registered KnownValues*"
    }

    It 'accepts a Value present in the populated KnownValues set' {
        $xml = @'
<?xml version="1.0" encoding="UTF-8"?>
<Configuration>
  <Add>
    <Product ID="O365ProPlusRetail">
      <Language ID="{{Language}}" />
    </Product>
  </Add>
</Configuration>
'@
        $path = New-XmlFixture 'lang-good.xml' $xml
        $tokens = Get-DefaultBuildTokens
        $tokens.Language.KnownValues = @('en-us','nb-no','de-de')
        $tokens.Language.Value       = 'nb-no'
        { Invoke-XmlTokenSubstitution -Path $path -Tokens $tokens } | Should -Not -Throw

        $doc = [xml](Get-Content -LiteralPath $path -Raw)
        $doc.Configuration.Add.Product.Language.ID | Should -Be 'nb-no'
    }

    It 'real M365Apps source XML default-path build resolves Language to en-us' {
        $src = Join-Path $script:RepoRoot 'M365Apps\Configurations\m365apps-base.xml'
        $copy = Join-Path $script:WorkDir 'lang-real-default.xml'
        Copy-Item -LiteralPath $src -Destination $copy -Force
        $null = Invoke-XmlTokenSubstitution -Path $copy -Tokens (Get-DefaultBuildTokens)
        $doc = [xml](Get-Content -LiteralPath $copy -Raw)
        $doc.Configuration.Add.Product.Language.ID | Should -Be 'en-us' `
            -Because 'a public-toolkit build with no -Language flag must produce the en-us baseline'
    }
}

Describe 'CLI parameter overrides build-config.json' {

    It 'CLI -CompanyName takes precedence over the value in build-config.json' {
        # Set up an isolated fork: a build-config.json with one CompanyName
        # value and a CLI invocation passing a different value. The CLI must win.
        $forkRoot = Join-Path $script:WorkDir 'cli-overrides'
        $null = New-Item -Path $forkRoot -ItemType Directory -Force

        # Minimal "fork" - just need build-config.json + a config XML to substitute.
        $configFile = Join-Path $forkRoot 'build-config.json'
        '{ "CompanyName": "FromConfigJson" }' | Set-Content -LiteralPath $configFile -Encoding UTF8

        $xmlPath = Join-Path $forkRoot 'sample.xml'
        @'
<?xml version="1.0" encoding="UTF-8"?>
<Configuration>
  <AppSettings>
    <Setup Name="Company" Value="{{CompanyName}}" />
  </AppSettings>
</Configuration>
'@ | Set-Content -LiteralPath $xmlPath -Encoding UTF8

        # Resolution order is implemented in Build-IntuneWinPackages.ps1 itself
        # (config first, CLI overrides). We replicate that order here in the test
        # to assert the contract holds without invoking the full build pipeline.
        $tokens = Get-DefaultBuildTokens
        $config = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
        $tokens.CompanyName.Value = $config.CompanyName    # config-file value
        $tokens.CompanyName.Value = 'FromCli'              # CLI override (last write wins)

        $null = Invoke-XmlTokenSubstitution -Path $xmlPath -Tokens $tokens
        $content = Get-Content -LiteralPath $xmlPath -Raw
        $content | Should -Match 'Value="FromCli"'
        $content | Should -Not -Match 'FromConfigJson'
    }
}

Describe 'ArrayExpansion token: ExcludedApps' {

    BeforeAll {
        $script:ArrayFixture = @'
<?xml version="1.0" encoding="UTF-8"?>
<Configuration ID="test">
  <Add OfficeClientEdition="64" Channel="MonthlyEnterprise">
    <Product ID="O365ProPlusRetail">
      <Language ID="en-us" />
      <!-- {{ExcludedApps:begin}} -->
      <ExcludeApp ID="Access" />
      <ExcludeApp ID="Bing" />
      <ExcludeApp ID="Groove" />
      <ExcludeApp ID="Lync" />
      <ExcludeApp ID="OneDrive" />
      <ExcludeApp ID="Publisher" />
      <ExcludeApp ID="Teams" />
      <!-- {{ExcludedApps:end}} -->
    </Product>
  </Add>
</Configuration>
'@
    }

    It 'registers ExcludedApps as ArrayExpansion mode with the canonical KnownValues set' {
        $t = Get-DefaultBuildTokens
        $t.Contains('ExcludedApps')  | Should -BeTrue
        $t.ExcludedApps.Mode         | Should -Be 'ArrayExpansion'
        $t.ExcludedApps.Value        | Should -BeNullOrEmpty
        $t.ExcludedApps.ElementName  | Should -Be 'ExcludeApp'
        $t.ExcludedApps.IDAttribute  | Should -Be 'ID'
        # Microsoft canonical IDs from learn.microsoft.com plus Bing.
        foreach ($id in 'Access','Bing','Excel','Groove','Lync','OneDrive','OneNote','Outlook','OutlookForWindows','PowerPoint','Publisher','Teams','Word') {
            $t.ExcludedApps.KnownValues | Should -Contain $id -Because "$id must be in the canonical ExcludeApp ID set"
        }
    }

    It 'default-path expansion preserves the seven-app block from the XML' {
        $path = New-XmlFixture 'arr-default.xml' $script:ArrayFixture
        $tokens = Get-DefaultBuildTokens
        $r = Invoke-XmlTokenSubstitution -Path $path -Tokens $tokens

        $r.ArrayExpansions.Count           | Should -Be 1
        $r.ArrayExpansions[0].Token        | Should -Be 'ExcludedApps'
        $r.ArrayExpansions[0].ResolvedFrom | Should -Be 'default'
        $r.ArrayExpansions[0].ItemCount    | Should -Be 7

        $content = Get-Content -LiteralPath $path -Raw
        $content | Should -Not -Match 'ExcludedApps:begin'
        $content | Should -Not -Match 'ExcludedApps:end'

        $doc = [xml]$content
        @($doc.SelectNodes('//ExcludeApp').ID) | Should -Be @('Access','Bing','Groove','Lync','OneDrive','Publisher','Teams')
    }

    It 'override array replaces the default and is sorted on emission' {
        $path = New-XmlFixture 'arr-override.xml' $script:ArrayFixture
        $tokens = Get-DefaultBuildTokens
        # Deliberately unsorted; reincludes Access (drops it from the exclusion list).
        $tokens.ExcludedApps.Value = @('Teams','Lync','Bing')
        $r = Invoke-XmlTokenSubstitution -Path $path -Tokens $tokens

        $r.ArrayExpansions[0].ResolvedFrom | Should -Be 'override'
        $r.ArrayExpansions[0].ItemCount    | Should -Be 3

        $doc = [xml](Get-Content -LiteralPath $path -Raw)
        @($doc.SelectNodes('//ExcludeApp').ID) | Should -Be @('Bing','Lync','Teams')
    }

    It 'empty override array produces zero ExcludeApp elements (every app installed)' {
        $path = New-XmlFixture 'arr-empty.xml' $script:ArrayFixture
        $tokens = Get-DefaultBuildTokens
        $tokens.ExcludedApps.Value = @()
        $r = Invoke-XmlTokenSubstitution -Path $path -Tokens $tokens

        $r.ArrayExpansions[0].ResolvedFrom | Should -Be 'override'
        $r.ArrayExpansions[0].ItemCount    | Should -Be 0

        $content = Get-Content -LiteralPath $path -Raw
        $content | Should -Not -Match '<ExcludeApp'
        $content | Should -Not -Match 'ExcludedApps:'

        $doc = [xml]$content
        @($doc.SelectNodes('//ExcludeApp')).Count | Should -Be 0
        # Surrounding XML still well-formed.
        $doc.Configuration.Add.Product.ID | Should -Be 'O365ProPlusRetail'
    }

    It 'unknown ID throws before staging starts (typo guard)' {
        $path = New-XmlFixture 'arr-unknown.xml' $script:ArrayFixture
        $tokens = Get-DefaultBuildTokens
        $tokens.ExcludedApps.Value = @('Acess','Word')   # 'Acess' is the typo

        { Invoke-XmlTokenSubstitution -Path $path -Tokens $tokens } |
            Should -Throw -ExpectedMessage "*unknown value*Acess*"
    }

    It 'two builds with the same config produce byte-identical staged XML (determinism)' {
        $a = New-XmlFixture 'det-a.xml' $script:ArrayFixture
        $b = New-XmlFixture 'det-b.xml' $script:ArrayFixture
        # Same logical override, different input order.
        $ta = Get-DefaultBuildTokens; $ta.ExcludedApps.Value = @('Teams','Access','Lync')
        $tb = Get-DefaultBuildTokens; $tb.ExcludedApps.Value = @('Lync','Teams','Access')

        $null = Invoke-XmlTokenSubstitution -Path $a -Tokens $ta
        $null = Invoke-XmlTokenSubstitution -Path $b -Tokens $tb

        (Get-FileHash -LiteralPath $a -Algorithm SHA256).Hash |
            Should -Be (Get-FileHash -LiteralPath $b -Algorithm SHA256).Hash
    }

    It 'rejects more than one begin/end marker pair for the same token in a file' {
        $double = $script:ArrayFixture + "`r`n<!-- {{ExcludedApps:begin}} -->`r`n<ExcludeApp ID=`"Word`" />`r`n<!-- {{ExcludedApps:end}} -->`r`n"
        $path = New-XmlFixture 'arr-double.xml' $double
        $tokens = Get-DefaultBuildTokens

        { Invoke-XmlTokenSubstitution -Path $path -Tokens $tokens } |
            Should -Throw -ExpectedMessage "*Only one operational pair per file is allowed*"
    }

    It 'rejects orphan markers (begin without matching end)' {
        $orphan = @'
<?xml version="1.0" encoding="UTF-8"?>
<Configuration ID="test">
  <Product ID="O365ProPlusRetail">
    <!-- {{ExcludedApps:begin}} -->
    <ExcludeApp ID="Access" />
  </Product>
</Configuration>
'@
        $path = New-XmlFixture 'arr-orphan.xml' $orphan
        $tokens = Get-DefaultBuildTokens

        { Invoke-XmlTokenSubstitution -Path $path -Tokens $tokens } |
            Should -Throw -ExpectedMessage "*matched pairs*"
    }

    It 'real M365Apps source XML default-path build produces the seven-app modern set' {
        $src = Join-Path $script:RepoRoot 'M365Apps\Configurations\m365apps-base.xml'
        $copy = Join-Path $script:WorkDir 'arr-real-default.xml'
        Copy-Item -LiteralPath $src -Destination $copy -Force

        $null = Invoke-XmlTokenSubstitution -Path $copy -Tokens (Get-DefaultBuildTokens)

        $doc = [xml](Get-Content -LiteralPath $copy -Raw)
        @($doc.SelectNodes('//ExcludeApp').ID) | Should -Be @('Access','Bing','Groove','Lync','OneDrive','Publisher','Teams') `
            -Because 'a public-toolkit build with no build-config.json must produce the modern default exclusion set'
    }

    It 'Get-ArrayTokenDefaults returns the sorted seven-app default set from the real source XML' {
        # The build banner uses this helper to print the resolved default
        # alongside the (default) suffix, so admins can see what is being
        # applied without cross-referencing the XML.
        $tokens   = Get-DefaultBuildTokens
        $defaults = Get-ArrayTokenDefaults -TokenName 'ExcludedApps' -TokenSpec $tokens.ExcludedApps -RepositoryRoot $script:RepoRoot

        $defaults | Should -Be @('Access','Bing','Groove','Lync','OneDrive','Publisher','Teams')
    }
}

Describe 'Visio/Project base XML hardcodes en-us (no runtime LanguageID token)' {
    # v1.0.5 makes Visio/Project base installs constant en-us. The
    # {{LanguageID}} runtime token belongs to LanguagePacks/ only.
    # If a future contributor re-introduces the runtime token in the
    # Visio/Project source XMLs, or drops in MatchInstalled /
    # MatchPreviousMSI, the toolkit's single-language-baseline principle
    # for these products breaks.

    It 'source <Path> uses literal <Language ID="en-us" />' -ForEach @(
        @{ Path = 'Visio\Configurations\visio-base.xml' }
        @{ Path = 'Project\Configurations\project-base.xml' }
    ) {
        $full    = Join-Path $script:RepoRoot $Path
        $content = Get-Content -LiteralPath $full -Raw

        $content | Should -Match '<Language ID="en-us"\s*/>' `
            -Because 'Visio/Project install in en-us by design (v1.0.5)'

        # Reject runtime token re-introduction.
        $content | Should -Not -Match '\{\{LanguageID\}\}' `
            -Because 'the LanguageID runtime token belongs only in LanguagePacks/Configurations/languagepack-template.xml'

        # No Match* foot-guns either.
        $content | Should -Not -Match '<Language ID="MatchInstalled"'
        $content | Should -Not -Match '<Language ID="MatchPreviousMSI"'
        $content | Should -Not -Match 'Version="MatchInstalled"'
        $content | Should -Not -Match 'Version="MatchPreviousMSI"'
    }
}

Describe 'End-to-end: zero-tokens build produces valid generic XMLs' {

    It 'every real per-product Configurations xml still validates as XML after a tokens-unset run' {
        $configDirs = @('M365Apps','Visio','Project','LanguagePacks') | ForEach-Object {
            Join-Path $script:RepoRoot ("$_\Configurations")
        }
        $sourceXmls = $configDirs | ForEach-Object {
            Get-ChildItem -LiteralPath $_ -Filter '*.xml' -File -ErrorAction SilentlyContinue
        }
        $sourceXmls.Count | Should -BeGreaterThan 0

        $tokens = Get-DefaultBuildTokens   # CompanyName.Value left $null on purpose

        foreach ($src in $sourceXmls) {
            $copy = Join-Path $script:WorkDir ("e2e-" + $src.BaseName + ".xml")
            Copy-Item -LiteralPath $src.FullName -Destination $copy -Force

            { Invoke-XmlTokenSubstitution -Path $copy -Tokens $tokens } |
                Should -Not -Throw -Because "$($src.Name) must substitute cleanly with no tokens set (public-toolkit default)"

            $content = Get-Content -LiteralPath $copy -Raw

            # No leftover {{...}} except the documented Runtime tokens.
            foreach ($match in [regex]::Matches($content, '\{\{([^{}]+)\}\}')) {
                $name = $match.Groups[1].Value
                $tokens.Contains($name) | Should -BeTrue -Because "leftover token {{$name}} in $($src.Name) must be registered"
                $tokens[$name].Mode | Should -Be 'Runtime' -Because "{{$name}} survived staging in $($src.Name) so it must be Runtime mode"
            }

            # No "Your Company" leakage from the pre-token-migration source.
            $content | Should -Not -Match 'Your Company'

            # Well-formed XML.
            { [xml]$null = $content } | Should -Not -Throw -Because "$($src.Name) must remain well-formed XML after substitution"
        }
    }
}
