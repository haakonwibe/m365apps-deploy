#Requires -Version 5.1
<#
.SYNOPSIS
    Build Win32 .intunewin packages for every product, with an optional
    staging-only mode for lab iteration.

.DESCRIPTION
    Two-phase pipeline that always uses the same staging code path, so
    the local-test layout and the packaged .intunewin layout are
    identical by construction.

    Phase 1 - Staging (always runs):
        For each product, the shared Invoke-ProductStaging helper
        assembles a self-contained folder at:

            Build\Staging\<Product>\
              +-- Install/Uninstall/Detect *.ps1
              +-- Configurations\*.xml
              +-- Tools\setup.exe
              +-- Common\*.psm1

        This layout matches exactly what the Intune Management Extension
        extracts on a client when it delivers the corresponding
        .intunewin, so anything that runs from Build\Staging\<Product>\
        on a lab VM behaves the same way after a real Intune deployment.

    Phase 2 - Packaging (default; skipped with -StagingOnly):
        IntuneWinAppUtil.exe wraps each Build\Staging\<Product>\ folder
        into Build\Output\<Product>\<Install>.intunewin, the script
        emits per-product detection scripts to
        Build\Output\<Product>\DetectionScripts\ (one Detect-*.ps1 for
        simple products; one Detect-LanguagePack-<lang>.ps1 per
        supported Office language for LanguagePacks), and writes a
        matching <Product>-IntuneConfig.md with the exact install /
        uninstall / detection / dependency values to paste into the
        Intune Win32 app UI.

    Staging is retained on disk between runs for inspection and for
    copying to a lab VM. Use -CleanStaging to wipe Build\Staging\ at
    the end of the build.

.PARAMETER Products
    Which product folders to build. Defaults to all four product
    families.

.PARAMETER StagingOnly
    Stop after phase 1. Skips IntuneWinAppUtil.exe and the
    -IntuneConfig.md emission. Use this to produce folders you can
    copy to a lab VM and run directly - faster iteration than the
    full package-upload-assign loop. See docs\local-testing.md.

.PARAMETER CleanStaging
    Wipe Build\Staging\ at the end of the build. Ignored with
    -StagingOnly (Staging is the output in that mode).

.PARAMETER StagingPath
    Root folder for the intermediate staged layout. Defaults to
    Build\Staging\ relative to this script.

.PARAMETER OutputPath
    Root folder for .intunewin artefacts and -IntuneConfig.md files.
    Defaults to Build\Output\ relative to this script.

.PARAMETER IntuneWinAppUtilPath
    Path to IntuneWinAppUtil.exe. Defaults to the copy next to this
    script. Download from
    https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool.

.PARAMETER RepositoryRoot
    Root of the m365apps-deploy repo. Defaults to this script's parent.

.PARAMETER SetupExeSource
    Shared ODT setup.exe staged into each product's Tools\ folder.
    Defaults to <RepositoryRoot>\Source\setup.exe. Pass '' to disable
    staging and rely on per-product Tools\setup.exe copies in the repo.

.EXAMPLE
    # Full build: staging + .intunewin + IntuneConfig docs.
    .\Build-IntuneWinPackages.ps1

.EXAMPLE
    # Stage only (for lab-VM testing); no .intunewin produced.
    .\Build-IntuneWinPackages.ps1 -StagingOnly

.EXAMPLE
    # Full build, then wipe the Staging\ folder afterwards.
    .\Build-IntuneWinPackages.ps1 -CleanStaging

.EXAMPLE
    # Per-product setup.exe overrides (no shared source):
    .\Build-IntuneWinPackages.ps1 -SetupExeSource ''

.NOTES
    Script  : Build-IntuneWinPackages.ps1
    Project : m365apps-deploy
    Version : <see Common/ODTVersion.psm1>
#>
[CmdletBinding()]
param(
    [ValidateSet('M365Apps','Visio','Project','LanguagePacks')]
    [string[]] $Products = @('M365Apps','Visio','Project','LanguagePacks'),

    [switch] $StagingOnly,

    [switch] $CleanStaging,

    [string] $StagingPath = (Join-Path -Path $PSScriptRoot -ChildPath 'Staging'),

    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath 'Output'),

    [string] $IntuneWinAppUtilPath = (Join-Path -Path $PSScriptRoot -ChildPath 'IntuneWinAppUtil.exe'),

    [string] $RepositoryRoot = (Split-Path -Path $PSScriptRoot -Parent),

    [AllowEmptyString()]
    [string] $SetupExeSource = (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'Source\setup.exe'),

    # Optional org-specific values that get substituted into staged XMLs.
    # Resolution order: CLI parameter wins, then build-config.json, then
    # the registration-table default. For BuildTime scalar tokens, "unset"
    # means the line containing the placeholder is removed (mirrors OCT's
    # blank-field behaviour) — UNLESS the token registers a Default value
    # (e.g. -Language), in which case the Default is substituted instead.
    # For ArrayExpansion tokens, "unset" means the default array baked into
    # the source XML is preserved as-is.
    [AllowEmptyString()] [AllowNull()]
    [string] $CompanyName = $null,

    # Primary Microsoft 365 Apps UI language. Single tag (the toolkit's
    # base-install design principle: one base language, additional UI
    # languages ship as separate Win32 apps via LanguagePacks/). Validated
    # against Get-ODTSupportedLanguages -TargetProduct O365ProPlusRetail
    # before staging; unknown / typo'd codes fail the build. Unset / null /
    # empty falls back to the Default registered in Get-DefaultBuildTokens
    # ('en-us').
    [AllowEmptyString()] [AllowNull()]
    [string] $Language = $null,

    # Override the default exclusion set baked into m365apps-base.xml. An
    # explicit value here REPLACES the default (it does not supplement).
    # Pass an empty array to install every Office app. Validated against the
    # Microsoft ODT ExcludeApp ID list; unknown IDs fail the build before
    # staging starts.
    [AllowNull()]
    [string[]] $ExcludedApps = $null,

    [string] $BuildConfigPath = (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'build-config.json')
)

$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-ProductStaging.ps1')

# Build-time token resolution. Start from the canonical default registration
# (Get-DefaultBuildTokens), then layer config file values, then layer CLI
# parameters - so CLI wins, config file is the persisted middle, and unset
# stays unset.
$Tokens = Get-DefaultBuildTokens

# Populate runtime-resolved KnownValues sets (kept out of the static
# registration so Get-DefaultBuildTokens stays a pure function).
# Language: validate against the Microsoft 365 Apps language matrix in
# Common\ODTLanguages.psm1 — the canonical list is one source of truth,
# shared with the per-product language-pack validator.
$languagesModulePath = Join-Path -Path $RepositoryRoot -ChildPath 'Common\ODTLanguages.psm1'
if (Test-Path -LiteralPath $languagesModulePath -PathType Leaf) {
    $alreadyLoaded = [bool](Get-Module -Name 'ODTLanguages')
    if (-not $alreadyLoaded) {
        Import-Module -Name $languagesModulePath -Force -ErrorAction Stop
    }
    try {
        $Tokens.Language.KnownValues = @(Get-ODTSupportedLanguages -TargetProduct 'O365ProPlusRetail')
    }
    finally {
        if (-not $alreadyLoaded) {
            Remove-Module -Name 'ODTLanguages' -ErrorAction SilentlyContinue
        }
    }
}

$buildConfigLoaded = $null
if (Test-Path -LiteralPath $BuildConfigPath -PathType Leaf) {
    try {
        $buildConfigLoaded = Get-Content -LiteralPath $BuildConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Build-IntuneWinPackages: '$BuildConfigPath' is not valid JSON: $($_.Exception.Message)"
    }
    foreach ($name in $Tokens.Keys) {
        $mode = [string]$Tokens[$name].Mode
        if (-not $buildConfigLoaded.PSObject.Properties[$name]) { continue }
        $configValue = $buildConfigLoaded.$name
        if ($mode -eq 'BuildTime') {
            # Scalar string. JSON null reads back as $null; coerce
            # non-null to string.
            $Tokens[$name].Value = if ($null -eq $configValue) { $null } else { [string]$configValue }
        }
        elseif ($mode -eq 'ArrayExpansion') {
            # Array of strings. JSON null reads as $null (=> use default
            # block from XML). Anything else must be enumerable; coerce
            # to a string[].
            if ($null -eq $configValue) {
                $Tokens[$name].Value = $null
            }
            else {
                $Tokens[$name].Value = @($configValue | ForEach-Object { [string]$_ })
            }
        }
        # Runtime tokens are not config-driven; ignore.
    }
}

# CLI parameters override the config file. Add new tokens here as
# one-liners when extending the registration table.
if ($PSBoundParameters.ContainsKey('CompanyName'))  { $Tokens.CompanyName.Value  = $CompanyName }
if ($PSBoundParameters.ContainsKey('Language'))     { $Tokens.Language.Value     = $Language }
if ($PSBoundParameters.ContainsKey('ExcludedApps')) { $Tokens.ExcludedApps.Value = $ExcludedApps }

$definitions     = Get-ProductDefinitions
$sourceAvailable = (-not [string]::IsNullOrWhiteSpace($SetupExeSource)) -and `
                  (Test-Path -LiteralPath $SetupExeSource -PathType Leaf)

Write-Output ("Repository root       : {0}" -f $RepositoryRoot)
Write-Output ("Staging path          : {0}" -f $StagingPath)
Write-Output ("Output path           : {0} {1}" -f $OutputPath, $(if ($StagingOnly) { '(skipped: -StagingOnly)' } else { '' }))
Write-Output ("IntuneWinAppUtil path : {0}" -f $IntuneWinAppUtilPath)
$setupSummary = if ($sourceAvailable) { $SetupExeSource }
                elseif ([string]::IsNullOrWhiteSpace($SetupExeSource)) { '<disabled>' }
                else { "$SetupExeSource (missing - per-product Tools\setup.exe used if present)" }
Write-Output ("Setup.exe source      : {0}" -f $setupSummary)
Write-Output ("Products              : {0}" -f ($Products -join ', '))
Write-Output ("Mode                  : {0}" -f $(if ($StagingOnly) { 'Staging only' } else { 'Full build (Staging + Output)' }))

$buildTimeTokenSummary = foreach ($name in $Tokens.Keys) {
    $mode = [string]$Tokens[$name].Mode
    if ($mode -eq 'BuildTime') {
        $value = $Tokens[$name].Value
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
            ("{0}='{1}'" -f $name, $value)
        }
        elseif ($Tokens[$name].Contains('Default') -and `
                -not [string]::IsNullOrWhiteSpace([string]$Tokens[$name].Default)) {
            ("{0}='{1}' (default)" -f $name, $Tokens[$name].Default)
        }
        else {
            ("{0}=<unset, line stripped>" -f $name)
        }
    }
    elseif ($mode -eq 'ArrayExpansion') {
        $value = $Tokens[$name].Value
        if ($null -eq $value) {
            # Default path: read the actual IDs out of the source XML so the
            # banner shows what is being applied, not just where it came
            # from. Falls back to the old <default from XML> form if the
            # source XML can't be parsed for any reason.
            $defaults = Get-ArrayTokenDefaults -TokenName $name -TokenSpec $Tokens[$name] -RepositoryRoot $RepositoryRoot
            if ($defaults.Count -gt 0) {
                ("{0}={1} (default)" -f $name, ($defaults -join ','))
            }
            else {
                ("{0}=<default from XML>" -f $name)
            }
        }
        elseif (@($value).Count -eq 0) {
            ("{0}=<override: empty array>" -f $name)
        }
        else {
            $sorted = @($value | Sort-Object -Property @{ Expression = { $_.ToLowerInvariant() } })
            ("{0}={1} (override)" -f $name, ($sorted -join ','))
        }
    }
}
$tokenSummaryText = if ($buildTimeTokenSummary) { ($buildTimeTokenSummary -join '; ') } else { '<no build-time tokens registered>' }
$configSummary = if ($buildConfigLoaded) { $BuildConfigPath } else { '<no build-config.json>' }
Write-Output ("Build config          : {0}" -f $configSummary)
Write-Output ("Build-time tokens     : {0}" -f $tokenSummaryText)
Write-Output ''

if (-not $StagingOnly) {
    if (-not (Test-Path -LiteralPath $IntuneWinAppUtilPath -PathType Leaf)) {
        throw "IntuneWinAppUtil.exe not found at '$IntuneWinAppUtilPath'. Download from https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool."
    }
    if (-not (Test-Path -LiteralPath $OutputPath)) {
        $null = New-Item -Path $OutputPath -ItemType Directory -Force
    }
}
if (-not (Test-Path -LiteralPath $StagingPath)) {
    $null = New-Item -Path $StagingPath -ItemType Directory -Force
}

function Write-IntuneConfigDoc {
<#
.SYNOPSIS
    Emit <Product>-IntuneConfig.md next to the .intunewin with the
    exact values to paste into the Intune Win32 app UI.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Product,
        [Parameter(Mandatory)][hashtable] $Spec,
        [Parameter(Mandatory)][string] $OutputDir
    )

    $displayName = $Spec.DisplayName
    $publisher   = $Spec.Publisher
    $install     = $Spec.SetupScript
    $uninstall   = $Spec.UninstallScript
    $detect      = $Spec.DetectScript
    $installStem = [System.IO.Path]::GetFileNameWithoutExtension($install)
    $generated   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')

    # Shared top of the document.
    $header = @'
# __DISPLAY__ - Intune Win32 app configuration

Auto-generated by `Build\Build-IntuneWinPackages.ps1`.
Paste each field into the corresponding Intune admin-center control.

Package file: `__PRODUCT__\__INSTALL_STEM__.intunewin`

## 1. App information
| Field | Value |
|-------|-------|
| Name      | __DISPLAY__ |
| Publisher | __PUBLISHER__ |
| Description | See the product page or your in-house deployment notes. |

## 2. Program
| Field | Value |
|-------|-------|
__PROGRAM_ROW_INSTALL__
__PROGRAM_ROW_UNINSTALL__
| Install behaviour        | System |
| Device restart behaviour | Determine behaviour based on return codes |

## 3. Return codes
Start from the Intune default list, then **add `17002` as Failed**.
That code is how this toolkit reports "setup.exe returned 0 but the
product is not actually installed" silent-failure detection.

| Return code | Code type |
|-------------|-----------|
| 0     | Success |
| 1707  | Success |
| 3010  | Soft reboot |
| 1641  | Hard reboot |
| 1618  | Retry |
| 1603  | Failed |
| 17002 | Failed |

## 4. Requirements
| Field | Value |
|-------|-------|
| Operating system architecture | 64-bit |
| Minimum operating system      | Windows 10 21H2 (adjust to your org baseline) |

## 5. Detection rules
Choose **Use a custom detection script** and upload:

__DETECTION_SCRIPT_LINE__
- Run as 32-bit process on 64-bit clients: **No**
- Enforce script signature check: **No** (enable only if you sign your scripts)

## 6. Dependencies / parameterisation
__DEPENDENCY_SECTION__
## 7. Assignment
Target the appropriate Entra (Azure AD) dynamic group:

- License-based dynamic groups (e.g. users with a Visio Plan 2 service plan)
- Language-based dynamic groups for language packs

Assignment strategy is outside the toolkit's scope - see your org's
ring policy. Assign as **Required** for automatic deployment or
**Available** for Company Portal self-service.

---
Generated: __GENERATED__
'@

    # Row 2 (install / uninstall): parameterised vs static.
    if ($Spec.Parameterised) {
        $programInstall   = '| Install command   | _Parameterised_ - see section 6 below for per-variant values |'
        $programUninstall = '| Uninstall command | _Parameterised_ - see section 6 below for per-variant values |'
    }
    else {
        $programInstall   = '| Install command   | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File ' + $install + '` |'
        $programUninstall = '| Uninstall command | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File ' + $uninstall + '` |'
    }

    # Detection script line: parameterised wrappers vs direct.
    # In both cases the file is in the per-product DetectionScripts\ folder
    # next to the .intunewin, so the upload path is unambiguous.
    if ($Spec.Parameterised) {
        $detectionLine = '- Script: `DetectionScripts\Detect-LanguagePack-<LanguageID>.ps1` (in this product folder, one per language; upload the script matching the language being deployed)'
    }
    else {
        $detectionLine = '- Script: `DetectionScripts\' + $detect + '` (in this product folder; upload the exact file)'
    }

    # Section 6 is the product-shape-specific block.
    if ($Spec.RequiresBase -and -not $Spec.Parameterised) {
        $dependencySection = @'
Add **Microsoft 365 Apps for Enterprise** as a required dependency
with **Automatically install: Yes**. Visio and Project will refuse to
install if the base Office install is missing, and the toolkit
enforces the channel / architecture match.

'@
    }
    elseif ($Spec.Parameterised) {
        if ($Product -eq 'LanguagePacks') {
            $exampleLangId      = 'nb-no'
            $exampleTargetTag   = ' -TargetProduct O365ProPlusRetail'
            $exampleTargetQuote = " -TargetProduct 'O365ProPlusRetail'"
            $exampleTitle       = $displayName + ' - nb-no'
        }
        else {
            $exampleLangId      = 'es-es'
            $exampleTargetTag   = ''
            $exampleTargetQuote = ''
            $exampleTitle       = $displayName + ' - es-es'
        }

        $paramTemplate = @'
This .intunewin is re-usable - you create **one Intune Win32 app per**
**(language, target product) pair** you want to deploy, all pointing
at this same package with different install / uninstall command
parameters.

### Example: __EXAMPLE_TITLE__

- **Name**: `__EXAMPLE_TITLE__`
- **Install command**: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File __INSTALL__ -LanguageID __LANG____TARGET_TAG__`
- **Uninstall command**: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File __UNINSTALL__ -LanguageID __LANG____TARGET_TAG__`

### Detection script (Intune does not pass parameters to detection)

The build emits one self-contained wrapper per supported Office language
in `DetectionScripts\` next to this `.intunewin`. Each wrapper has the
language ID hard-coded and is ready to upload directly:

- `__LANG__` -> `DetectionScripts\Detect-LanguagePack-__LANG__.ps1`

The primary registry-key check (`LanguagePack - <lang>`) is
product-agnostic, so the same wrapper works for Office, Visio,
and Project language packs without per-product variants.

Then add **Microsoft 365 Apps for Enterprise** (or the matching
Visio / Project app for a Visio / Project language pack) as a
required dependency with **Automatically install: Yes**.

'@
        $dependencySection = $paramTemplate.
            Replace('__EXAMPLE_TITLE__', $exampleTitle).
            Replace('__INSTALL__', $install).
            Replace('__UNINSTALL__', $uninstall).
            Replace('__DETECT__', $detect).
            Replace('__LANG__', $exampleLangId).
            Replace('__TARGET_TAG__', $exampleTargetTag).
            Replace('__TARGET_QUOTE__', $exampleTargetQuote)
    }
    else {
        $dependencySection = @'
No dependencies. This is the base Office install.

'@
    }

    $doc = $header.
        Replace('__DISPLAY__', $displayName).
        Replace('__PRODUCT__', $Product).
        Replace('__INSTALL_STEM__', $installStem).
        Replace('__PUBLISHER__', $publisher).
        Replace('__PROGRAM_ROW_INSTALL__', $programInstall).
        Replace('__PROGRAM_ROW_UNINSTALL__', $programUninstall).
        Replace('__DETECTION_SCRIPT_LINE__', $detectionLine).
        Replace('__DEPENDENCY_SECTION__', $dependencySection).
        Replace('__GENERATED__', $generated)

    $docPath = Join-Path -Path $OutputDir -ChildPath ("{0}-IntuneConfig.md" -f $Product)
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($docPath, $doc, $utf8Bom)
    return $docPath
}

$results = New-Object System.Collections.Generic.List[pscustomobject]
foreach ($product in $Products) {
    Write-Output ("=== {0} ===" -f $product)

    $staged = Invoke-ProductStaging -Product $product -RepositoryRoot $RepositoryRoot -OutputRoot $StagingPath -SetupExeSource $SetupExeSource -Tokens $Tokens

    Write-Output ("    Staged to : {0}" -f $staged.StagingPath)
    Write-Output ("    setup.exe : {0} ({1})" -f $staged.SetupSource, $staged.Message)

    if ($staged.Status -eq 'Skipped') {
        Write-Warning ("    Skipped: {0}" -f $staged.Message)
        $results.Add([pscustomobject]@{ Product = $product; Status = 'Skipped'; Reason = $staged.Message })
        continue
    }
    if ($staged.Status -eq 'Warning') {
        Write-Warning ("    {0}: {1}" -f $product, $staged.Message)
    }

    # Integrity gate: refuse to ship (or stage-for-lab-test) a product
    # whose .ps1 files are empty, command-less, or fail to parse. The
    # check runs for both the full build and -StagingOnly so neither
    # path can produce a silent no-op package - an Install-*.ps1 that
    # IntuneWinAppUtil packages cleanly but does nothing at deploy time.
    $validation = Test-StagedPowerShellFiles -Path $staged.StagingPath
    Write-Output ("    Validated : {0} .ps1 files parse-clean with at least one command" -f $validation.Scanned)
    if (-not $validation.Passed) {
        foreach ($issue in $validation.Issues) {
            $relative = $issue.File.Substring($staged.StagingPath.Length).TrimStart('\','/')
            Write-Warning ("    INVALID [{0}]: {1}" -f $relative, $issue.Problem)
        }
        $reason = ("{0} .ps1 file(s) failed integrity check: {1}" -f $validation.Issues.Count,
                   (($validation.Issues | ForEach-Object { [System.IO.Path]::GetFileName($_.File) }) -join ', '))
        $results.Add([pscustomobject]@{
            Product = $product
            Status  = 'Invalid'
            Reason  = $reason
        })
        Write-Output ''
        continue
    }

    if ($StagingOnly) {
        $results.Add([pscustomobject]@{
            Product      = $product
            Status       = 'Staged'
            SetupSource  = $staged.SetupSource
            StagingPath  = $staged.StagingPath
            PackagePath  = $null
            ConfigDocPath= $null
        })
        Write-Output ''
        continue
    }

    # Phase 2: run IntuneWinAppUtil against the staged folder.
    $spec       = $definitions[$product]
    $setupLeaf  = $spec.SetupScript
    $productOut = Join-Path -Path $OutputPath -ChildPath $product
    if (Test-Path -LiteralPath $productOut) {
        # Idempotent: clear prior .intunewin files but leave any sibling user notes.
        Get-ChildItem -LiteralPath $productOut -File -Filter '*.intunewin' -ErrorAction SilentlyContinue | Remove-Item -Force
    }
    else {
        $null = New-Item -Path $productOut -ItemType Directory -Force
    }

    $args = @(
        '-c', ('"{0}"' -f $staged.StagingPath),
        '-s', ('"{0}"' -f $setupLeaf),
        '-o', ('"{0}"' -f $productOut),
        '-q'
    )
    Write-Output ("    > IntuneWinAppUtil.exe {0}" -f ($args -join ' '))
    # Capture IntuneWinAppUtil output to temp files so the per-file copy
    # chatter does not flood the console. Re-emit it only on non-zero exit
    # so failures stay diagnosable.
    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath $IntuneWinAppUtilPath -ArgumentList $args `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        if ($proc.ExitCode -ne 0) {
            Write-Warning ("    IntuneWinAppUtil.exe exited with code {0} for {1}." -f $proc.ExitCode, $product)
            $captured = @()
            if (Test-Path -LiteralPath $stdoutFile) { $captured += Get-Content -LiteralPath $stdoutFile }
            if (Test-Path -LiteralPath $stderrFile) { $captured += Get-Content -LiteralPath $stderrFile }
            if ($captured.Count -gt 0) {
                Write-Output '    --- IntuneWinAppUtil.exe output: ---'
                $captured | ForEach-Object { Write-Output ("      {0}" -f $_) }
                Write-Output '    --- end output ---'
            }
            $results.Add([pscustomobject]@{ Product = $product; Status = 'Failed'; Reason = ("IntuneWinAppUtil exit {0}" -f $proc.ExitCode) })
            continue
        }
    }
    finally {
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }

    $produced = Get-ChildItem -LiteralPath $productOut -Filter '*.intunewin' -File |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $produced) {
        $results.Add([pscustomobject]@{ Product = $product; Status = 'Failed'; Reason = 'No .intunewin produced' })
        continue
    }
    Write-Output ("    Package   : {0}" -f $produced.FullName)

    # Phase 3: emit detection scripts to <Output>\<Product>\DetectionScripts\.
    # For simple products this is a copy; for LanguagePacks it generates one
    # per-language wrapper from the canonical Detect-LanguagePack.ps1 body.
    $detection = Publish-DetectionScripts -Product $product -Spec $spec -StagingPath $staged.StagingPath -OutputDir $productOut -RepositoryRoot $RepositoryRoot
    Write-Output ("    Detection : {0} ({1} script{2})" -f $detection.DetectionDir, $detection.ScriptCount, $(if ($detection.ScriptCount -eq 1) { '' } else { 's' }))

    $docPath = Write-IntuneConfigDoc -Product $product -Spec $spec -OutputDir $productOut
    Write-Output ("    Config    : {0}" -f $docPath)

    $results.Add([pscustomobject]@{
        Product         = $product
        Status          = 'OK'
        SetupSource     = $staged.SetupSource
        StagingPath     = $staged.StagingPath
        PackagePath     = $produced.FullName
        DetectionDir    = $detection.DetectionDir
        DetectionCount  = $detection.ScriptCount
        ConfigDocPath   = $docPath
    })
    Write-Output ''
}

Write-Output '=== Build summary ==='
$results | Format-Table -AutoSize | Out-String | Write-Output

if ($CleanStaging -and -not $StagingOnly) {
    if (Test-Path -LiteralPath $StagingPath) {
        Remove-Item -LiteralPath $StagingPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Output ("Cleaned staging folder: {0}" -f $StagingPath)
    }
}
elseif (-not $StagingOnly) {
    Write-Output ("Staging retained at: {0}" -f $StagingPath)
    Write-Output "  (pass -CleanStaging on the next build to wipe it automatically,"
    Write-Output "   or copy a staged folder to a lab VM for local testing -"
    Write-Output "   see docs\local-testing.md)."
}
else {
    Write-Output "Staging complete at: $StagingPath"
    Write-Output '  (see docs\local-testing.md for the lab-VM workflow)'
}

$failed = @($results | Where-Object { $_.Status -notin @('OK', 'Staged') })
if ($failed.Count -gt 0) { exit 1 } else { exit 0 }
