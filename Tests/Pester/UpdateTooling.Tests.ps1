#Requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for Source\Update-Tooling.ps1.

.DESCRIPTION
    The script is a thin orchestrator over three external surfaces -
    Invoke-RestMethod (GitHub releases API), Invoke-WebRequest
    (binary downloads), and Get-AuthenticodeSignature. We mock all
    three so the tests run with no network and no real signature
    verification, then assert on the file-system state and manifest
    that the script produces.

    The script gates auto-execution on `$script:UpdateToolingTesting`;
    the BeforeAll sets that flag before dot-sourcing so Pester only
    pulls in the function definitions, then each test calls
    Invoke-UpdateTooling with mocks active.
#>

BeforeAll {
    $script:RepoRoot = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..')

    # Tell Update-Tooling.ps1 to skip its own top-level execution; we drive
    # Invoke-UpdateTooling explicitly from each test.
    $script:UpdateToolingTesting = $true
    . (Join-Path -Path $script:RepoRoot -ChildPath 'Source\Update-Tooling.ps1')

    $script:WorkRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("update-tooling-tests-$([Guid]::NewGuid().ToString('N'))")
    $null = New-Item -Path $script:WorkRoot -ItemType Directory -Force

    function New-FakeRepo {
        param(
            [string] $Name,
            [string] $ExistingSetupBytes  = 'OLD-SETUP-CONTENT',
            [string] $ExistingIntuneWinBytes = 'OLD-INTUNEWIN-CONTENT'
        )
        $repoDir   = Join-Path $script:WorkRoot $Name
        $sourceDir = Join-Path $repoDir 'Source'
        $buildDir  = Join-Path $repoDir 'Build'
        $null = New-Item -Path $sourceDir -ItemType Directory -Force
        $null = New-Item -Path $buildDir  -ItemType Directory -Force
        if ($ExistingSetupBytes) {
            Set-Content -LiteralPath (Join-Path $sourceDir 'setup.exe')        -Value $ExistingSetupBytes      -NoNewline
        }
        if ($ExistingIntuneWinBytes) {
            Set-Content -LiteralPath (Join-Path $buildDir  'IntuneWinAppUtil.exe') -Value $ExistingIntuneWinBytes -NoNewline
        }
        return $repoDir
    }

    function Get-BuildSpecs {
        param([string] $RepoDir)
        @(
            [pscustomobject]@{
                Name        = 'setup.exe'
                SourceUrl   = 'https://officecdn.microsoft.com/pr/wsus/setup.exe'
                TargetPath  = (Join-Path $RepoDir 'Source\setup.exe')
                VersionFrom = 'FileVersion'
            }
            [pscustomobject]@{
                Name        = 'IntuneWinAppUtil.exe'
                SourceUrl   = $null
                TargetPath  = (Join-Path $RepoDir 'Build\IntuneWinAppUtil.exe')
                VersionFrom = 'GitHubRelease'
            }
        )
    }

    # Factory that returns a fresh PSCustomObject matching the JSON-deserialised
    # shape Invoke-RestMethod actually returns. Hashtables won't do - the script
    # introspects .PSObject.Properties[name], which only resolves for
    # PSCustomObject (or anything else that exposes adapted-member properties).
    # Helper retained for documentation; inline definitions are used in mocks
    # because Pester MockWith bodies don't always see top-of-file functions.
    function New-FakeGitHubResponse {
        [pscustomobject]@{
            tag_name = 'v1.8.4'
            assets   = @(
                [pscustomobject]@{ name = 'IntuneWinAppUtil.exe'; browser_download_url = 'https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/releases/download/v1.8.4/IntuneWinAppUtil.exe' }
            )
        }
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:WorkRoot) {
        Remove-Item -LiteralPath $script:WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Invoke-UpdateTooling - happy path' {
    It 'downloads, verifies, places both binaries, and writes the manifest' {
        $repo = New-FakeRepo -Name "happy-$([Guid]::NewGuid().ToString('N'))"
        $work = Join-Path $script:WorkRoot ("happy-work-$([Guid]::NewGuid().ToString('N'))")
        $manifestPath = Join-Path $repo 'Source\tooling-versions.json'

        Mock -CommandName Invoke-RestMethod -MockWith {
            [pscustomobject]@{
                tag_name = 'v1.8.4'
                assets   = @(
                    [pscustomobject]@{ name = 'IntuneWinAppUtil.exe'; browser_download_url = 'https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/releases/download/v1.8.4/IntuneWinAppUtil.exe' }
                )
            }
        }
        Mock -CommandName Invoke-WebRequest -MockWith {
            param($Uri, $OutFile, $UseBasicParsing, $ErrorAction)
            # Fake "downloaded binary" - content is whatever we like for the test.
            Set-Content -LiteralPath $OutFile -Value "FRESH-CONTENT-FOR-$Uri" -NoNewline
        }
        Mock -CommandName Get-AuthenticodeSignature -MockWith {
            param($FilePath)
            [pscustomobject]@{
                Status            = 'Valid'
                StatusMessage     = 'Signature verified.'
                SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' }
            }
        }

        Invoke-UpdateTooling -RepositoryRoot $repo -WorkingDirectory $work `
            -BinarySpecs (Get-BuildSpecs -RepoDir $repo) `
            -ManifestPath $manifestPath -GitHubReleasesUrl 'https://example.invalid/api'

        # Both binaries replaced.
        (Get-Content -LiteralPath (Join-Path $repo 'Source\setup.exe') -Raw)            | Should -Match 'FRESH-CONTENT-FOR-https://officecdn'
        (Get-Content -LiteralPath (Join-Path $repo 'Build\IntuneWinAppUtil.exe') -Raw) | Should -Match 'FRESH-CONTENT-FOR-https://github.com'

        # Manifest written with required fields. Inspect both the raw JSON
        # (for timestamp shape - ConvertFrom-Json auto-deserialises ISO
        # strings to [DateTime] and Should -Match doesn't auto-coerce
        # those back to string) and the parsed object (for typed fields).
        Test-Path -LiteralPath $manifestPath | Should -BeTrue
        $rawJson = Get-Content -LiteralPath $manifestPath -Raw
        $rawJson | Should -Match '"lastUpdated":\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"'
        $rawJson | Should -Match '"downloadedAt":\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"'

        $manifest = $rawJson | ConvertFrom-Json
        $manifest.binaries.'setup.exe'.path                         | Should -Be 'Source\setup.exe'
        $manifest.binaries.'setup.exe'.sourceUrl                    | Should -Be 'https://officecdn.microsoft.com/pr/wsus/setup.exe'
        $manifest.binaries.'IntuneWinAppUtil.exe'.path              | Should -Be 'Build\IntuneWinAppUtil.exe'
        $manifest.binaries.'IntuneWinAppUtil.exe'.version           | Should -Be '1.8.4'
        $manifest.binaries.'IntuneWinAppUtil.exe'.sourceUrl         | Should -Match '^https://github.com/.+/IntuneWinAppUtil\.exe$'
    }
}

Describe 'Invoke-UpdateTooling - bad Authenticode' {
    It 'throws when signature status is not Valid and leaves existing binaries untouched' {
        $repo = New-FakeRepo -Name "badsig-$([Guid]::NewGuid().ToString('N'))"
        $work = Join-Path $script:WorkRoot ("badsig-work-$([Guid]::NewGuid().ToString('N'))")
        $manifestPath = Join-Path $repo 'Source\tooling-versions.json'

        Mock -CommandName Invoke-RestMethod -MockWith {
            [pscustomobject]@{
                tag_name = 'v1.8.4'
                assets   = @(
                    [pscustomobject]@{ name = 'IntuneWinAppUtil.exe'; browser_download_url = 'https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/releases/download/v1.8.4/IntuneWinAppUtil.exe' }
                )
            }
        }
        Mock -CommandName Invoke-WebRequest -MockWith {
            param($Uri, $OutFile, $UseBasicParsing, $ErrorAction)
            Set-Content -LiteralPath $OutFile -Value 'TAMPERED' -NoNewline
        }
        Mock -CommandName Get-AuthenticodeSignature -MockWith {
            param($FilePath)
            [pscustomobject]@{
                Status            = 'HashMismatch'
                StatusMessage     = 'The signature is not valid.'
                SignerCertificate = $null
            }
        }

        { Invoke-UpdateTooling -RepositoryRoot $repo -WorkingDirectory $work `
            -BinarySpecs (Get-BuildSpecs -RepoDir $repo) `
            -ManifestPath $manifestPath -GitHubReleasesUrl 'https://example.invalid/api' } |
            Should -Throw -ExpectedMessage "*Authenticode verification failed*"

        # Existing binaries must be unchanged.
        (Get-Content -LiteralPath (Join-Path $repo 'Source\setup.exe') -Raw)            | Should -Be 'OLD-SETUP-CONTENT'
        (Get-Content -LiteralPath (Join-Path $repo 'Build\IntuneWinAppUtil.exe') -Raw) | Should -Be 'OLD-INTUNEWIN-CONTENT'

        # No manifest written.
        Test-Path -LiteralPath $manifestPath | Should -BeFalse
    }

    It 'throws when signer subject is not Microsoft and leaves existing binaries untouched' {
        $repo = New-FakeRepo -Name "wrongsigner-$([Guid]::NewGuid().ToString('N'))"
        $work = Join-Path $script:WorkRoot ("wrongsigner-work-$([Guid]::NewGuid().ToString('N'))")
        $manifestPath = Join-Path $repo 'Source\tooling-versions.json'

        Mock -CommandName Invoke-RestMethod -MockWith {
            [pscustomobject]@{
                tag_name = 'v1.8.4'
                assets   = @(
                    [pscustomobject]@{ name = 'IntuneWinAppUtil.exe'; browser_download_url = 'https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/releases/download/v1.8.4/IntuneWinAppUtil.exe' }
                )
            }
        }
        Mock -CommandName Invoke-WebRequest -MockWith {
            param($Uri, $OutFile, $UseBasicParsing, $ErrorAction)
            Set-Content -LiteralPath $OutFile -Value 'CONTENT' -NoNewline
        }
        Mock -CommandName Get-AuthenticodeSignature -MockWith {
            param($FilePath)
            [pscustomobject]@{
                Status            = 'Valid'
                StatusMessage     = 'Signature verified.'
                SignerCertificate = [pscustomobject]@{ Subject = 'CN=Evil Corp, O=Evil Corp, C=XX' }
            }
        }

        { Invoke-UpdateTooling -RepositoryRoot $repo -WorkingDirectory $work `
            -BinarySpecs (Get-BuildSpecs -RepoDir $repo) `
            -ManifestPath $manifestPath -GitHubReleasesUrl 'https://example.invalid/api' } |
            Should -Throw -ExpectedMessage "*Unexpected signer*Evil Corp*"

        (Get-Content -LiteralPath (Join-Path $repo 'Source\setup.exe') -Raw)            | Should -Be 'OLD-SETUP-CONTENT'
        (Get-Content -LiteralPath (Join-Path $repo 'Build\IntuneWinAppUtil.exe') -Raw) | Should -Be 'OLD-INTUNEWIN-CONTENT'
        Test-Path -LiteralPath $manifestPath | Should -BeFalse
    }
}

Describe 'Invoke-UpdateTooling - GitHub API failures' {
    It 'throws cleanly when the API response is missing assets' {
        $repo = New-FakeRepo -Name "noassets-$([Guid]::NewGuid().ToString('N'))"
        $work = Join-Path $script:WorkRoot ("noassets-work-$([Guid]::NewGuid().ToString('N'))")
        $manifestPath = Join-Path $repo 'Source\tooling-versions.json'

        Mock -CommandName Invoke-RestMethod -MockWith {
            [pscustomobject]@{ tag_name = 'v1.8.4'; not_assets_field = @() }   # Wrong shape - no `assets` key.
        }
        Mock -CommandName Invoke-WebRequest -MockWith { Set-Content -LiteralPath $OutFile -Value 'X' -NoNewline }
        Mock -CommandName Get-AuthenticodeSignature -MockWith {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation' } }
        }

        { Invoke-UpdateTooling -RepositoryRoot $repo -WorkingDirectory $work `
            -BinarySpecs (Get-BuildSpecs -RepoDir $repo) `
            -ManifestPath $manifestPath -GitHubReleasesUrl 'https://example.invalid/api' } |
            Should -Throw -ExpectedMessage "*missing 'assets' array*"

        # Existing binaries untouched.
        (Get-Content -LiteralPath (Join-Path $repo 'Source\setup.exe') -Raw) | Should -Be 'OLD-SETUP-CONTENT'
        Test-Path -LiteralPath $manifestPath | Should -BeFalse
    }

    It 'falls back to the tag-pinned raw URL when the release has no IntuneWinAppUtil.exe asset' {
        # Microsoft stopped attaching the .exe as a release asset around
        # v1.8.7; the binary lives in the repo at the tagged commit. The
        # script must fall back to raw.githubusercontent.com/<...>/<tag>/...
        # rather than throwing.
        $repo = New-FakeRepo -Name "rawfallback-$([Guid]::NewGuid().ToString('N'))"
        $work = Join-Path $script:WorkRoot ("rawfallback-work-$([Guid]::NewGuid().ToString('N'))")
        $manifestPath = Join-Path $repo 'Source\tooling-versions.json'

        Mock -CommandName Invoke-RestMethod -MockWith {
            [pscustomobject]@{
                tag_name = 'v1.8.7'
                assets   = @()   # No assets - this is the current shape on the live repo.
            }
        }
        $script:downloadedFromUrl = $null
        Mock -CommandName Invoke-WebRequest -MockWith {
            param($Uri, $OutFile, $UseBasicParsing, $ErrorAction)
            $script:downloadedFromUrl = [string]$Uri
            Set-Content -LiteralPath $OutFile -Value "FRESH-$Uri" -NoNewline
        }
        Mock -CommandName Get-AuthenticodeSignature -MockWith {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation' } }
        }

        Invoke-UpdateTooling -RepositoryRoot $repo -WorkingDirectory $work `
            -BinarySpecs (Get-BuildSpecs -RepoDir $repo) `
            -ManifestPath $manifestPath -GitHubReleasesUrl 'https://example.invalid/api'

        # Manifest carries the tag-pinned raw URL.
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $manifest.binaries.'IntuneWinAppUtil.exe'.sourceUrl |
            Should -Be 'https://raw.githubusercontent.com/microsoft/Microsoft-Win32-Content-Prep-Tool/v1.8.7/IntuneWinAppUtil.exe'
        $manifest.binaries.'IntuneWinAppUtil.exe'.version |
            Should -Be '1.8.7'

        # The actual download went to that URL.
        Test-Path -LiteralPath (Join-Path $repo 'Build\IntuneWinAppUtil.exe') | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $repo 'Build\IntuneWinAppUtil.exe') -Raw) |
            Should -Match 'FRESH-https://raw\.githubusercontent\.com/microsoft/Microsoft-Win32-Content-Prep-Tool/v1\.8\.7/IntuneWinAppUtil\.exe'
    }

    It 'still prefers a release asset named IntuneWinAppUtil.exe when one is present' {
        # If Microsoft ever re-attaches the binary to a release, the
        # asset URL wins over the raw-URL fallback.
        $repo = New-FakeRepo -Name "preferasset-$([Guid]::NewGuid().ToString('N'))"
        $work = Join-Path $script:WorkRoot ("preferasset-work-$([Guid]::NewGuid().ToString('N'))")
        $manifestPath = Join-Path $repo 'Source\tooling-versions.json'

        $assetUrl = 'https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/releases/download/v2.0.0/IntuneWinAppUtil.exe'
        Mock -CommandName Invoke-RestMethod -MockWith {
            [pscustomobject]@{
                tag_name = 'v2.0.0'
                assets   = @(
                    [pscustomobject]@{ name = 'IntuneWinAppUtil.exe'; browser_download_url = $assetUrl }
                )
            }
        }
        Mock -CommandName Invoke-WebRequest -MockWith {
            param($Uri, $OutFile, $UseBasicParsing, $ErrorAction)
            Set-Content -LiteralPath $OutFile -Value "FRESH-$Uri" -NoNewline
        }
        Mock -CommandName Get-AuthenticodeSignature -MockWith {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation' } }
        }

        Invoke-UpdateTooling -RepositoryRoot $repo -WorkingDirectory $work `
            -BinarySpecs (Get-BuildSpecs -RepoDir $repo) `
            -ManifestPath $manifestPath -GitHubReleasesUrl 'https://example.invalid/api'

        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $manifest.binaries.'IntuneWinAppUtil.exe'.sourceUrl | Should -Be $assetUrl
        $manifest.binaries.'IntuneWinAppUtil.exe'.version   | Should -Be '2.0.0'
    }
}

Describe 'Invoke-UpdateTooling - manifest is gated on full success' {
    It 'does not write the manifest when the second binary fails verification' {
        $repo = New-FakeRepo -Name "partial-$([Guid]::NewGuid().ToString('N'))"
        $work = Join-Path $script:WorkRoot ("partial-work-$([Guid]::NewGuid().ToString('N'))")
        $manifestPath = Join-Path $repo 'Source\tooling-versions.json'

        Mock -CommandName Invoke-RestMethod -MockWith {
            [pscustomobject]@{
                tag_name = 'v1.8.4'
                assets   = @(
                    [pscustomobject]@{ name = 'IntuneWinAppUtil.exe'; browser_download_url = 'https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/releases/download/v1.8.4/IntuneWinAppUtil.exe' }
                )
            }
        }
        Mock -CommandName Invoke-WebRequest -MockWith {
            param($Uri, $OutFile, $UseBasicParsing, $ErrorAction)
            Set-Content -LiteralPath $OutFile -Value "FRESH-$Uri" -NoNewline
        }
        # First call returns Valid+Microsoft; second call returns invalid.
        $script:authCallCount = 0
        Mock -CommandName Get-AuthenticodeSignature -MockWith {
            param($FilePath)
            $script:authCallCount++
            if ($script:authCallCount -eq 1) {
                [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation' } }
            }
            else {
                [pscustomobject]@{ Status = 'NotSigned'; StatusMessage = 'No signature.'; SignerCertificate = $null }
            }
        }

        { Invoke-UpdateTooling -RepositoryRoot $repo -WorkingDirectory $work `
            -BinarySpecs (Get-BuildSpecs -RepoDir $repo) `
            -ManifestPath $manifestPath -GitHubReleasesUrl 'https://example.invalid/api' } |
            Should -Throw -ExpectedMessage "*Authenticode verification failed*"

        # Phase 1 fails before phase 2 (the move) starts, so BOTH existing
        # binaries must still be the originals - even though setup.exe's
        # download passed verification, no move happens until every binary
        # has been verified.
        (Get-Content -LiteralPath (Join-Path $repo 'Source\setup.exe') -Raw)            | Should -Be 'OLD-SETUP-CONTENT'
        (Get-Content -LiteralPath (Join-Path $repo 'Build\IntuneWinAppUtil.exe') -Raw) | Should -Be 'OLD-INTUNEWIN-CONTENT'

        # No manifest written.
        Test-Path -LiteralPath $manifestPath | Should -BeFalse
    }
}
