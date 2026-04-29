#Requires -Version 5.1
<#
.SYNOPSIS
    Refresh the two Microsoft binaries the build pipeline depends on,
    verify them, and drop them at their canonical locations.

.DESCRIPTION
    Replaces the manual "click through Microsoft Download Center,
    extract setup.exe, copy" flow with one command.

    Downloads:
      - setup.exe (Office Deployment Tool) from
        https://officecdn.microsoft.com/pr/wsus/setup.exe (the same
        URL the install scripts' -UseEvergreenSetup runtime path
        already uses).
      - IntuneWinAppUtil.exe from the latest release at
        microsoft/Microsoft-Win32-Content-Prep-Tool on GitHub.

    Both binaries are verified via Authenticode before being moved
    into place. Verification rejects anything where:
      - Signature status is not 'Valid', or
      - Signer subject does not match Microsoft Corporation.

    The verify-then-move ordering makes the placement effectively
    atomic per binary: a bad download cannot half-overwrite a good
    existing copy. If verification fails for either binary, neither
    is moved and the existing copies stay untouched.

    On full success, a manifest at Source\tooling-versions.json is
    rewritten with the version, source URL, and timestamp for each
    binary. The manifest is gitignored - it describes local state
    that varies per fork.

    Idempotent in the always-fetch sense: re-running the script
    always re-downloads both binaries. There is no "skip if already
    current" comparison. Cost is ~10 MB total per run.

.PARAMETER RepositoryRoot
    Repository root. Defaults to this script's parent (the repo
    root, since this script lives at <root>\Source\Update-Tooling.ps1).

.PARAMETER WorkingDirectory
    Scratch directory for staged downloads before verification.
    Defaults to a fresh subdirectory under $env:TEMP.

.EXAMPLE
    # Run from a PowerShell prompt at the repo root:
    .\Source\Update-Tooling.ps1

.NOTES
    Script  : Update-Tooling.ps1
    Project : m365apps-deploy
    Version : <see Common/ODTVersion.psm1>
#>
[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Split-Path -Path $PSScriptRoot -Parent),

    [string] $WorkingDirectory = (Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("update-tooling-" + [Guid]::NewGuid().ToString('N')))
)

$ErrorActionPreference = 'Stop'

# Canonical locations the build pipeline reads. Match what
# Build\Build-IntuneWinPackages.ps1 actually expects - do not assume.
$script:BinarySpecs = @(
    [pscustomobject]@{
        Name        = 'setup.exe'
        SourceUrl   = 'https://officecdn.microsoft.com/pr/wsus/setup.exe'
        TargetPath  = (Join-Path -Path $RepositoryRoot -ChildPath 'Source\setup.exe')
        VersionFrom = 'FileVersion'   # Read from FileVersionInfo
    }
    [pscustomobject]@{
        Name        = 'IntuneWinAppUtil.exe'
        SourceUrl   = $null            # Resolved via the GitHub releases API.
        TargetPath  = (Join-Path -Path $RepositoryRoot -ChildPath 'Build\IntuneWinAppUtil.exe')
        VersionFrom = 'GitHubRelease'  # Use the release tag from the API.
    }
)

$script:GitHubReleasesUrl = 'https://api.github.com/repos/microsoft/Microsoft-Win32-Content-Prep-Tool/releases/latest'
$script:ManifestPath      = Join-Path -Path $RepositoryRoot -ChildPath 'Source\tooling-versions.json'

function Write-Step {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Message)
    Write-Host ("[Update-Tooling] {0}" -f $Message)
}

function Invoke-DownloadWithRetry {
<#
.SYNOPSIS
    Download a URL to a file with up to N attempts and exponential backoff.
    Mirrors the retry shape used by Resolve-ODTSetupPath in
    Common\ODTInvoke.psm1 so behaviour is consistent across the
    toolkit's network calls.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [Parameter(Mandatory)] [string] $OutFile,
        [int] $MaxAttempts = 3
    )
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
            return
        }
        catch {
            if ($attempt -ge $MaxAttempts) {
                throw "Download failed for '$Uri' after $MaxAttempts attempts: $($_.Exception.Message)"
            }
            Start-Sleep -Seconds ([math]::Pow(2, $attempt))
        }
    }
}

function Get-LatestIntuneWinAppUtilAsset {
<#
.SYNOPSIS
    Query the GitHub releases API for the latest IntuneWinAppUtil.exe
    download URL plus its version. Returns a hashtable with Url and
    Version.

.DESCRIPTION
    GitHub API at /repos/<owner>/<repo>/releases/latest returns a JSON
    object with `tag_name` and an `assets[]` array. The maintainers
    used to attach `IntuneWinAppUtil.exe` as a release asset, but the
    current pattern (observed at v1.8.7) is to ship zero assets and
    keep the binary checked into the repo at the tag's commit.

    Resolution order:
      1. If the release has an asset named exactly
         'IntuneWinAppUtil.exe', use its `browser_download_url`. This
         path stays correct if Microsoft ever re-attaches the binary
         to the release.
      2. Otherwise fall back to the tag-pinned raw URL on
         raw.githubusercontent.com:
            https://raw.githubusercontent.com/microsoft/Microsoft-Win32-Content-Prep-Tool/<tag>/IntuneWinAppUtil.exe
         which retrieves the binary from the repo at the tagged
         commit (more deterministic than pulling from `master`).

    Throws if the response shape is unexpected, or if neither
    resolution path produces a URL.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string] $ApiUrl = $script:GitHubReleasesUrl
    )

    Write-Step ("Querying GitHub releases API: {0}" -f $ApiUrl)
    $release = $null
    try {
        $release = Invoke-RestMethod -Uri $ApiUrl -UseBasicParsing -ErrorAction Stop
    }
    catch {
        throw "Failed to query GitHub releases API at '$ApiUrl': $($_.Exception.Message)"
    }

    if ($null -eq $release) {
        throw "GitHub releases API returned a null response for '$ApiUrl'."
    }
    if (-not $release.PSObject.Properties['tag_name']) {
        throw "GitHub releases API response missing 'tag_name' field. Response shape unexpected."
    }
    if (-not $release.PSObject.Properties['assets']) {
        throw "GitHub releases API response missing 'assets' array. Response shape unexpected."
    }

    $rawTag = [string]$release.tag_name
    if ([string]::IsNullOrWhiteSpace($rawTag)) {
        throw "GitHub releases API response has an empty 'tag_name'."
    }
    $version = $rawTag
    if ($version.StartsWith('v', [System.StringComparison]::OrdinalIgnoreCase)) {
        $version = $version.Substring(1)
    }

    # Preferred: a release asset named IntuneWinAppUtil.exe.
    $assets = @($release.assets)
    $match  = $assets | Where-Object { $_.name -eq 'IntuneWinAppUtil.exe' } | Select-Object -First 1
    if ($match) {
        if (-not $match.PSObject.Properties['browser_download_url']) {
            throw "Asset '$($match.name)' missing 'browser_download_url' field."
        }
        return @{
            Url     = [string]$match.browser_download_url
            Version = $version
            Source  = 'release-asset'
        }
    }

    # Fallback: tag-pinned raw URL. The maintainers stopped attaching
    # the .exe as a release asset around v1.8.7; the binary lives in
    # the repo at HEAD and at every tag's commit. Pin to the tag for
    # determinism.
    $rawUrl = ('https://raw.githubusercontent.com/microsoft/Microsoft-Win32-Content-Prep-Tool/{0}/IntuneWinAppUtil.exe' -f $rawTag)
    Write-Step ("Release '{0}' has no IntuneWinAppUtil.exe asset; falling back to tag-pinned raw URL." -f $rawTag)
    return @{
        Url     = $rawUrl
        Version = $version
        Source  = 'raw-tag'
    }
}

function Test-MicrosoftSignedBinary {
<#
.SYNOPSIS
    Verify a binary is Authenticode-signed by Microsoft Corporation
    with a Valid status. Throws on any failure - no soft warnings.

.DESCRIPTION
    Authenticode verification gives signed-by + chain-valid +
    not-revoked in one call. Microsoft does not publish hashes for
    these binaries, so signature verification is the strongest
    integrity check available without speculative cert pinning.

    Both setup.exe and IntuneWinAppUtil.exe currently sign as
    'CN=Microsoft Corporation'. If the subject ever changes the
    script throws and the operator investigates - we don't
    speculatively add fallback patterns.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $DisplayName
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Authenticode verification: file not found at '$Path' for '$DisplayName'."
    }

    $sig = Get-AuthenticodeSignature -FilePath $Path
    if ([string]$sig.Status -ne 'Valid') {
        throw "Authenticode verification failed for '$DisplayName': status='$($sig.Status)' message='$($sig.StatusMessage)'."
    }
    if ($null -eq $sig.SignerCertificate) {
        throw "Authenticode verification: no signer certificate present on '$DisplayName'."
    }
    $subject = [string]$sig.SignerCertificate.Subject
    if ($subject -notmatch 'CN=Microsoft Corporation') {
        throw "Unexpected signer for '$DisplayName': '$subject'. Expected subject containing 'CN=Microsoft Corporation'. If Microsoft changed the cert subject, investigate before relaxing this check."
    }
}

function Get-BinaryVersion {
<#
.SYNOPSIS
    Read the embedded FileVersion from a binary's VersionInfo.
    Returns $null if no FileVersion is present (some binaries don't
    set it - the caller decides whether that's acceptable).
#>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Path)

    try {
        $info = (Get-Item -LiteralPath $Path).VersionInfo
        if ($null -ne $info -and -not [string]::IsNullOrWhiteSpace($info.FileVersion)) {
            return [string]$info.FileVersion
        }
    }
    catch { }
    return $null
}

function Save-ToolingManifest {
<#
.SYNOPSIS
    Write Source\tooling-versions.json with the resolved metadata for
    each binary. Called only after every binary has been verified
    AND placed at its canonical location, so the manifest never
    references a binary that isn't there.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ManifestPath,
        [Parameter(Mandatory)] [string] $RepositoryRoot,
        [Parameter(Mandatory)] $Entries
    )
    $now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $binaries = [ordered]@{}
    foreach ($entry in $Entries) {
        $relativePath = $entry.TargetPath
        if ($relativePath.StartsWith($RepositoryRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            $relativePath = $relativePath.Substring($RepositoryRoot.Length).TrimStart('\','/')
        }
        $binaries[$entry.Name] = [ordered]@{
            path         = $relativePath
            version      = $entry.Version
            sourceUrl    = $entry.SourceUrl
            downloadedAt = $entry.DownloadedAt
        }
    }
    $manifest = [ordered]@{
        lastUpdated = $now
        binaries    = $binaries
    }
    $json = $manifest | ConvertTo-Json -Depth 6
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($ManifestPath, $json, $utf8Bom)
}

function Invoke-UpdateTooling {
<#
.SYNOPSIS
    Main entry point. Wrapping the flow in a function (rather than at
    top-level) lets Pester dot-source the script to install the helper
    function definitions without executing the flow, then call this
    function with mocks active.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepositoryRoot,
        [Parameter(Mandatory)] [string] $WorkingDirectory,
        [pscustomobject[]] $BinarySpecs = $script:BinarySpecs,
        [string] $ManifestPath = $script:ManifestPath,
        [string] $GitHubReleasesUrl = $script:GitHubReleasesUrl
    )

    if (-not (Test-Path -LiteralPath $WorkingDirectory)) {
        $null = New-Item -Path $WorkingDirectory -ItemType Directory -Force
    }

    Write-Step ("Repository root  : {0}" -f $RepositoryRoot)
    Write-Step ("Working directory: {0}" -f $WorkingDirectory)
    Write-Step ''

    try {
        # Resolve dynamic source URLs (only IntuneWinAppUtil today; others are static).
        $intunewinAsset = Get-LatestIntuneWinAppUtilAsset -ApiUrl $GitHubReleasesUrl
        Write-Step ("Latest IntuneWinAppUtil release: {0}" -f $intunewinAsset.Version)
        foreach ($spec in $BinarySpecs) {
            if ($spec.Name -eq 'IntuneWinAppUtil.exe') {
                $spec.SourceUrl = $intunewinAsset.Url
            }
        }

        # Phase 1: download + verify each binary into the working directory.
        # Nothing is moved into place yet; if any verification fails, the
        # existing canonical-location binaries stay untouched.
        $resolved = New-Object System.Collections.Generic.List[pscustomobject]
        foreach ($spec in $BinarySpecs) {
            $tempPath = Join-Path -Path $WorkingDirectory -ChildPath $spec.Name
            Write-Step ("Downloading {0} from {1}" -f $spec.Name, $spec.SourceUrl)
            Invoke-DownloadWithRetry -Uri $spec.SourceUrl -OutFile $tempPath
            Write-Step ("Verifying Authenticode signature on {0}" -f $spec.Name)
            Test-MicrosoftSignedBinary -Path $tempPath -DisplayName $spec.Name

            # Pick the version source per binary. setup.exe carries an
            # embedded FileVersion (e.g. 16.0.19929.20062); IntuneWinAppUtil's
            # GitHub release tag is the authoritative external version.
            $version = $null
            if ($spec.VersionFrom -eq 'FileVersion') {
                $version = Get-BinaryVersion -Path $tempPath
            }
            elseif ($spec.VersionFrom -eq 'GitHubRelease') {
                $version = $intunewinAsset.Version
            }
            if ([string]::IsNullOrWhiteSpace($version)) { $version = 'unknown' }

            $resolved.Add([pscustomobject]@{
                Name         = $spec.Name
                TempPath     = $tempPath
                TargetPath   = $spec.TargetPath
                SourceUrl    = $spec.SourceUrl
                Version      = $version
                DownloadedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            })
            Write-Step ("  OK  {0,-22} version={1}" -f $spec.Name, $version)
        }

        # Phase 2: every binary verified. Move into canonical locations.
        # If a second move fails after the first succeeds the partial state
        # (new setup.exe + old IntuneWinAppUtil) is recoverable on the next
        # run, which always re-downloads both. The manifest write below is
        # gated on the whole loop completing.
        foreach ($entry in $resolved) {
            $targetDir = Split-Path -Path $entry.TargetPath -Parent
            if (-not (Test-Path -LiteralPath $targetDir)) {
                $null = New-Item -Path $targetDir -ItemType Directory -Force
            }
            Write-Step ("Placing {0} -> {1}" -f $entry.Name, $entry.TargetPath)
            Move-Item -LiteralPath $entry.TempPath -Destination $entry.TargetPath -Force
        }

        # Phase 3: manifest. Only written after every binary is in place.
        Save-ToolingManifest -ManifestPath $ManifestPath -RepositoryRoot $RepositoryRoot -Entries $resolved
        Write-Step ("Manifest updated: {0}" -f $ManifestPath)

        Write-Step ''
        Write-Step 'Done. The build pipeline is now ready to run.'
    }
    finally {
        if (Test-Path -LiteralPath $WorkingDirectory) {
            Remove-Item -LiteralPath $WorkingDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# Skip auto-execution when dot-sourced by Pester (the test file sets
# $script:UpdateToolingTesting = $true before dot-sourcing).
if (-not (Get-Variable -Name 'UpdateToolingTesting' -Scope Script -ErrorAction SilentlyContinue)) {
    Invoke-UpdateTooling -RepositoryRoot $RepositoryRoot -WorkingDirectory $WorkingDirectory
}
