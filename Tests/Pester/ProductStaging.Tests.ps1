#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 tests for Build\Invoke-ProductStaging.ps1.

.DESCRIPTION
    Focuses on Test-StagedPowerShellFiles - the integrity guard that
    must refuse empty / command-less / syntax-broken scripts before
    the IntuneWinAppUtil step. A zero-byte or comment-only Install-*.ps1
    parses cleanly but ships a silent no-op deployment, so the build
    must reject it before packaging.
#>

BeforeAll {
    $repoRoot = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..')
    . (Join-Path -Path $repoRoot -ChildPath 'Build\Invoke-ProductStaging.ps1')

    $script:RepoRoot = $repoRoot
    $script:WorkDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("staging-tests-$([Guid]::NewGuid().ToString('N'))")
    $null = New-Item -Path $script:WorkDir -ItemType Directory -Force
}

AfterAll {
    if (Test-Path -LiteralPath $script:WorkDir) {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Test-StagedPowerShellFiles' {
    It 'throws when the target folder does not exist' {
        { Test-StagedPowerShellFiles -Path (Join-Path $script:WorkDir 'does-not-exist') } |
            Should -Throw -ExpectedMessage "*does not exist*"
    }

    It 'passes when the folder contains a well-formed script' {
        $dir = Join-Path $script:WorkDir 'ok'
        $null = New-Item -Path $dir -ItemType Directory -Force
        @'
[CmdletBinding()]
param()
Write-Output 'hello'
exit 0
'@ | Set-Content -LiteralPath (Join-Path $dir 'good.ps1') -Encoding UTF8

        $r = Test-StagedPowerShellFiles -Path $dir
        $r.Passed  | Should -BeTrue
        $r.Scanned | Should -Be 1
        $r.Issues.Count | Should -Be 0
    }

    It 'fails on a zero-byte script' {
        $dir = Join-Path $script:WorkDir 'empty'
        $null = New-Item -Path $dir -ItemType Directory -Force
        $victim = Join-Path $dir 'Install-M365Apps.ps1'
        # Write just the UTF-8 BOM - the canonical "valid empty script" edge case.
        [System.IO.File]::WriteAllBytes($victim, @(0xEF, 0xBB, 0xBF))

        $r = Test-StagedPowerShellFiles -Path $dir
        $r.Passed  | Should -BeFalse
        $r.Scanned | Should -Be 1
        $r.Issues.Count | Should -Be 1
        $r.Issues[0].File    | Should -Be $victim
        $r.Issues[0].Size    | Should -Be 3
        $r.Issues[0].Problem | Should -Match 'Empty or command-free script'
    }

    It 'fails on a comments-only script (no CommandAst)' {
        $dir = Join-Path $script:WorkDir 'comments'
        $null = New-Item -Path $dir -ItemType Directory -Force
        @'
# Just a comment
# Nothing actually runs.
'@ | Set-Content -LiteralPath (Join-Path $dir 'comment-only.ps1') -Encoding UTF8

        $r = Test-StagedPowerShellFiles -Path $dir
        $r.Passed | Should -BeFalse
        $r.Issues[0].Problem | Should -Match 'Empty or command-free script'
    }

    It 'fails on a syntactically broken script' {
        $dir = Join-Path $script:WorkDir 'broken'
        $null = New-Item -Path $dir -ItemType Directory -Force
        @'
param()
if ($true) {
    Write-Output 'unterminated...
'@ | Set-Content -LiteralPath (Join-Path $dir 'broken.ps1') -Encoding UTF8

        $r = Test-StagedPowerShellFiles -Path $dir
        $r.Passed | Should -BeFalse
        $r.Issues[0].Problem | Should -Match 'parser error'
    }

    It 'scans recursively and reports each failing file' {
        $dir = Join-Path $script:WorkDir 'mixed'
        $null = New-Item -Path $dir -ItemType Directory -Force
        $null = New-Item -Path (Join-Path $dir 'sub') -ItemType Directory -Force

        # good at root
        "Write-Output 'ok'" | Set-Content -LiteralPath (Join-Path $dir 'good.ps1') -Encoding UTF8
        # empty in subfolder
        [System.IO.File]::WriteAllBytes((Join-Path $dir 'sub\empty.ps1'), @(0xEF, 0xBB, 0xBF))
        # broken at root
        "if (" | Set-Content -LiteralPath (Join-Path $dir 'broken.ps1') -Encoding UTF8

        $r = Test-StagedPowerShellFiles -Path $dir
        $r.Passed  | Should -BeFalse
        $r.Scanned | Should -Be 3
        $r.Issues.Count | Should -Be 2
        ($r.Issues | ForEach-Object { [System.IO.Path]::GetFileName($_.File) } | Sort-Object) |
            Should -Be @('broken.ps1','empty.ps1')
    }

    It 'passes when a folder has zero .ps1 files (nothing to reject)' {
        $dir = Join-Path $script:WorkDir 'nops1'
        $null = New-Item -Path $dir -ItemType Directory -Force
        '<xml/>' | Set-Content -LiteralPath (Join-Path $dir 'some.xml') -Encoding UTF8

        $r = Test-StagedPowerShellFiles -Path $dir
        $r.Passed  | Should -BeTrue
        $r.Scanned | Should -Be 0
        $r.Issues.Count | Should -Be 0
    }
}

Describe 'Publish-DetectionScripts' {

    BeforeAll {
        $script:Definitions = Get-ProductDefinitions
    }

    It 'creates DetectionScripts\ and copies the single Detect-*.ps1 for a simple product' {
        $stage = Join-Path $script:WorkDir 'simple-stage'
        $out   = Join-Path $script:WorkDir 'simple-out'
        $null = New-Item -Path $stage -ItemType Directory -Force
        $null = New-Item -Path $out -ItemType Directory -Force

        $detect = Join-Path $stage 'Detect-M365Apps.ps1'
        @'
[CmdletBinding()] param() Write-Output 'detected'; exit 0
'@ | Set-Content -LiteralPath $detect -Encoding UTF8

        $spec = $script:Definitions['M365Apps']
        $r = Publish-DetectionScripts -Product 'M365Apps' -Spec $spec -StagingPath $stage -OutputDir $out -RepositoryRoot $script:RepoRoot

        $r.Product     | Should -Be 'M365Apps'
        $r.ScriptCount | Should -Be 1
        $r.Variants.Count | Should -Be 0

        $expected = Join-Path $out 'DetectionScripts\Detect-M365Apps.ps1'
        Test-Path -LiteralPath $expected -PathType Leaf | Should -BeTrue
    }

    It 'fails clearly when the simple-product staging is missing the detect script' {
        $stage = Join-Path $script:WorkDir 'simple-no-detect'
        $out   = Join-Path $script:WorkDir 'simple-no-detect-out'
        $null = New-Item -Path $stage -ItemType Directory -Force
        $null = New-Item -Path $out -ItemType Directory -Force

        $spec = $script:Definitions['Visio']
        { Publish-DetectionScripts -Product 'Visio' -Spec $spec -StagingPath $stage -OutputDir $out -RepositoryRoot $script:RepoRoot } |
            Should -Throw -ExpectedMessage "*missing in staging*"
    }

    It 'clears stale DetectionScripts contents on re-run (idempotent)' {
        $stage = Join-Path $script:WorkDir 'idem-stage'
        $out   = Join-Path $script:WorkDir 'idem-out'
        $null = New-Item -Path $stage -ItemType Directory -Force
        $null = New-Item -Path $out -ItemType Directory -Force

        $detect = Join-Path $stage 'Detect-M365Apps.ps1'
        @'
[CmdletBinding()] param() exit 0
'@ | Set-Content -LiteralPath $detect -Encoding UTF8

        # Pre-populate DetectionScripts\ with a stale wrapper that should be wiped.
        $detectionDir = Join-Path $out 'DetectionScripts'
        $null = New-Item -Path $detectionDir -ItemType Directory -Force
        'stale' | Set-Content -LiteralPath (Join-Path $detectionDir 'STALE-from-old-build.ps1') -Encoding UTF8

        $spec = $script:Definitions['M365Apps']
        $null = Publish-DetectionScripts -Product 'M365Apps' -Spec $spec -StagingPath $stage -OutputDir $out -RepositoryRoot $script:RepoRoot

        Test-Path -LiteralPath (Join-Path $detectionDir 'STALE-from-old-build.ps1') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $detectionDir 'Detect-M365Apps.ps1')      | Should -BeTrue
    }

    It 'generates one self-contained wrapper per Office language for LanguagePacks' {
        $stage = Join-Path $script:WorkDir 'lp-stage'
        $out   = Join-Path $script:WorkDir 'lp-out'
        $null = New-Item -Path $stage -ItemType Directory -Force
        $null = New-Item -Path $out -ItemType Directory -Force

        # The build helper reads Detect-LanguagePack.ps1 from the stage. Use the
        # real source as the input - this is the contract, not a mock.
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'LanguagePacks\Detect-LanguagePack.ps1') -Destination $stage -Force

        $spec = $script:Definitions['LanguagePacks']
        $r = Publish-DetectionScripts -Product 'LanguagePacks' -Spec $spec -StagingPath $stage -OutputDir $out -RepositoryRoot $script:RepoRoot

        $r.Product     | Should -Be 'LanguagePacks'
        $r.ScriptCount | Should -BeGreaterThan 100   # Office language list is ~110 entries.
        $r.Variants    | Should -Contain 'nb-no'
        $r.Variants    | Should -Contain 'en-us'
        $r.Variants    | Should -Contain 'de-de'

        # Every wrapper must parse cleanly and contain its language code.
        $wrappers = Get-ChildItem -LiteralPath $r.DetectionDir -Filter 'Detect-LanguagePack-*.ps1' -File
        $wrappers.Count | Should -Be $r.ScriptCount

        foreach ($lang in @('nb-no','en-us','zh-cn')) {
            $path = Join-Path $r.DetectionDir ("Detect-LanguagePack-{0}.ps1" -f $lang)
            Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue

            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
            @($errors).Count | Should -Be 0

            $content = Get-Content -LiteralPath $path -Raw
            $content | Should -Match ("\`$LanguageID\s*=\s*'{0}'" -f [regex]::Escape($lang))
            $content | Should -Match "\`$TargetProduct\s*=\s*'O365ProPlusRetail'"
        }
    }
}

Describe 'Invoke-ProductStaging carries the whole Common surface' {
    # Common\*.psm1 is staged by wildcard, so a new module is picked up with no
    # registration anywhere. That is convenient but fragile: converting the
    # wildcard to an explicit list would silently drop whichever module was
    # added last, and the failure would only surface on a client as
    # "module not found" during an install. This test pins the wildcard.

    BeforeAll {
        $script:ParityStage = Join-Path $script:WorkDir 'parity-stage'
        $null = New-Item -Path $script:ParityStage -ItemType Directory -Force

        # -Tokens $null copies sources verbatim, which is what we want here:
        # this test is about which files arrive, not about substitution.
        $script:ParityResult = Invoke-ProductStaging -Product 'M365Apps' `
            -RepositoryRoot $script:RepoRoot -OutputRoot $script:ParityStage -Tokens $null
    }

    It 'stages the M365Apps product' {
        $script:ParityResult.Status | Should -BeIn @('OK', 'Warning')
        $script:ParityResult.StagingPath | Should -Not -BeNullOrEmpty
    }

    It 'copies every Common module, not a hard-coded subset' {
        $expected = @(Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'Common') -Filter '*.psm1' -File |
            Select-Object -ExpandProperty Name | Sort-Object)
        $actual = @(Get-ChildItem -LiteralPath (Join-Path $script:ParityResult.StagingPath 'Common') -Filter '*.psm1' -File |
            Select-Object -ExpandProperty Name | Sort-Object)

        $actual -join ',' | Should -Be ($expected -join ',') `
            -Because 'Common\*.psm1 is staged by wildcard and must stay that way'
    }

    It 'copies every product Configuration XML, including the consumer removal one' {
        $expected = @(Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'M365Apps\Configurations') -Filter '*.xml' -File |
            Select-Object -ExpandProperty Name | Sort-Object)
        $actual = @(Get-ChildItem -LiteralPath (Join-Path $script:ParityResult.StagingPath 'Configurations') -Filter '*.xml' -File |
            Select-Object -ExpandProperty Name | Sort-Object)

        $actual -join ',' | Should -Be ($expected -join ',')
        $actual | Should -Contain 'm365apps-remove-consumer.xml'
    }

    It 'stages a Common surface the install script can actually load' {
        # Every module Install-M365Apps.ps1 imports must be present in the
        # staged Common\, because that is the only copy a client ever sees.
        $installSource = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'M365Apps\Install-M365Apps.ps1') -Raw
        $imported = [regex]::Matches($installSource, "Join-Path\s+\`$commonPath\s+'([^']+\.psm1)'") |
            ForEach-Object { $_.Groups[1].Value }
        @($imported).Count | Should -BeGreaterThan 0

        foreach ($module in $imported) {
            Test-Path -LiteralPath (Join-Path $script:ParityResult.StagingPath (Join-Path 'Common' $module)) -PathType Leaf |
                Should -BeTrue -Because "$module is imported by Install-M365Apps.ps1"
        }
    }
}
