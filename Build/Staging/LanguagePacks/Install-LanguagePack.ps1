#Requires -Version 5.1
<#
.SYNOPSIS
    Install an additional Office language pack on top of an existing
    Click-to-Run install.

.DESCRIPTION
    Loads the language-pack template XML, replaces its tokens with the
    requested language and product, and invokes setup.exe /configure.

    Channel and OfficeClientEdition are read from the existing Office
    install so the language pack matches. This avoids the MatchInstalled /
    MatchPreviousMSI foot-gun (see docs/language-matrix.md).

.PARAMETER LanguageID
    BCP-47 language code, e.g. 'nb-no'.

.PARAMETER TargetProduct
    The Click-to-Run product that the language pack applies to. One of:
    O365ProPlusRetail, VisioProRetail, VisioStdRetail, ProjectProRetail,
    ProjectStdRetail. Defaults to O365ProPlusRetail.

.PARAMETER SetupExePath
    Path to setup.exe. Defaults to bundled Tools\setup.exe.

.PARAMETER UseEvergreenSetup
    Download a fresh ODT from Microsoft.

.PARAMETER LogPath
    Root log directory.

.PARAMETER SkipPrerequisiteChecks
    Bypass prerequisite checks.

.EXAMPLE
    .\Install-LanguagePack.ps1 -LanguageID nb-no

.EXAMPLE
    .\Install-LanguagePack.ps1 -LanguageID de-de -TargetProduct VisioProRetail

.NOTES
    Script  : Install-LanguagePack.ps1
    Project : m365apps-deploy
    Version : <see Common/ODTVersion.psm1>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-zA-Z]{2,3}(-[a-zA-Z]{2,8}){1,3}$')]
    [string] $LanguageID,

    [ValidateSet('O365ProPlusRetail','VisioProRetail','VisioStdRetail','ProjectProRetail','ProjectStdRetail')]
    [string] $TargetProduct = 'O365ProPlusRetail',

    [string] $SetupExePath,

    [switch] $UseEvergreenSetup,

    [string] $LogPath = 'C:\ProgramData\M365AppsDeploy\Logs',

    [switch] $SkipPrerequisiteChecks
)

$ErrorActionPreference = 'Stop'

$LanguageID    = $LanguageID.ToLowerInvariant()
$ScriptName    = 'Install-LanguagePack'
$LogFile       = ("LanguagePack-{0}-{1}-Install.log" -f $TargetProduct, $LanguageID)

# Body-time $PSScriptRoot is reliable; param-default-time is not under
# Intune Management Extension or PsExec -s with -File. See
# docs/architecture.md rule #2.
if ([string]::IsNullOrEmpty($SetupExePath)) {
    $SetupExePath = Join-Path -Path $PSScriptRoot -ChildPath 'Tools\setup.exe'
}

# Locate Common/: $PSScriptRoot\Common when deployed by Intune or run from a
# staged test folder (Build\Staging\<Product>\). Otherwise fall
# back to the sibling ..\Common next to the product folder in the repo.
$commonPath = if (Test-Path -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath 'Common')) {
    Join-Path -Path $PSScriptRoot -ChildPath 'Common'
} else {
    Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'Common'
}
Import-Module (Join-Path $commonPath 'ODTLogging.psm1')       -Force
Import-Module (Join-Path $commonPath 'ODTVersion.psm1')       -Force
Import-Module (Join-Path $commonPath 'ODTPrerequisites.psm1') -Force
Import-Module (Join-Path $commonPath 'ODTOfficeState.psm1')   -Force
Import-Module (Join-Path $commonPath 'ODTInvoke.psm1')        -Force
Import-Module (Join-Path $commonPath 'ODTLanguages.psm1')     -Force

$ScriptVersion = Get-ToolkitVersion

$sessionParams = @{
    LanguageID             = $LanguageID
    TargetProduct          = $TargetProduct
    SetupExePath           = $SetupExePath
    UseEvergreenSetup      = [bool]$UseEvergreenSetup
    LogPath                = $LogPath
    SkipPrerequisiteChecks = [bool]$SkipPrerequisiteChecks
}

Start-ODTLogSession -ScriptName $ScriptName -ScriptVersion $ScriptVersion -Parameters $sessionParams -LogFile $LogFile -LogPath $LogPath

# Surface invocation context so empty $PSScriptRoot is visible in the
# log header (would otherwise show as a downstream "file not found"
# further into the script).
Write-ODTLog -Message ("Invocation context: PSScriptRoot='{0}' PSCommandPath='{1}' Resolved SetupExePath='{2}'" -f $PSScriptRoot, $PSCommandPath, $SetupExePath) -Component $ScriptName -LogFile $LogFile -LogPath $LogPath

$exit    = 0
$summary = 'Language pack install succeeded.'

try {
    # Early validation: fail with a clear error on unsupported combinations.
    Assert-ODTLanguageSupported -LanguageID $LanguageID -TargetProduct $TargetProduct
    Write-ODTLog -Message ("Language '{0}' validated against matrix for {1}." -f $LanguageID, $TargetProduct) -Component $ScriptName -LogFile $LogFile -LogPath $LogPath

    if (-not $SkipPrerequisiteChecks) {
        $prereq = Invoke-ODTPrerequisiteChecks
        foreach ($r in $prereq.Results) {
            $severity = if ($r.Passed) { 1 } else { 3 }
            $status = if ($r.Passed) { 'PASS' } else { 'FAIL' }
            Write-ODTLog -Message ("Prerequisite {0}: {1} - {2}" -f $r.CheckName, $status, $r.Details) -Severity $severity -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
        }
        if (-not $prereq.AllPassed) { throw $prereq.Summary }
    }

    $existing = Get-OfficeConfiguration
    if ($null -eq $existing) {
        throw "No Click-to-Run Office install detected. Install M365 Apps before deploying language packs."
    }
    if (-not (Test-ProductInstalled -ProductId $TargetProduct)) {
        throw "$TargetProduct is not installed. Install it before adding a language pack."
    }
    # Per-installed-product status snapshot. Logged here so admins reading
    # CMTrace/IME logs see exactly which products have the language and which
    # don't, mirroring the decision the script is about to make. The aggregate
    # Installed flag is true only when every Click-to-Run product on the
    # machine carries the language; one missing add-on (Visio/Project in
    # particular) is enough to require setup.exe to run and spread the LP.
    $preStatus = Get-LanguagePackInstallationStatus -LanguageID $LanguageID
    $preSummary = ($preStatus.PerProduct.GetEnumerator() | ForEach-Object {
        "{0}={1}" -f $_.Key, $(if ($_.Value) { 'installed' } else { 'missing' })
    }) -join ', '
    if ([string]::IsNullOrWhiteSpace($preSummary)) { $preSummary = '<no Click-to-Run products detected>' }
    Write-ODTLog -Message ("Language pack '{0}' status: {1}." -f $LanguageID, $preSummary) -Component $ScriptName -LogFile $LogFile -LogPath $LogPath

    if ($preStatus.Installed) {
        $allProducts = ($preStatus.PerProduct.Keys) -join ', '
        Write-ODTLog -Message ("Language pack '{0}' already installed for every C2R product ({1}); skipping setup.exe." -f $LanguageID, $allProducts) -Severity 2 -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
        $summary = 'Language pack already installed.'
        return
    }

    Write-ODTLog -Message 'Running setup.exe to spread the language pack across the products that are missing it.' -Component $ScriptName -LogFile $LogFile -LogPath $LogPath

    # Template uses explicit OfficeClientEdition + Channel per Microsoft's
    # documented language-pack install pattern, and Product ID="LanguagePack"
    # (Microsoft's product-agnostic pseudo-product for language accessories).
    # -TargetProduct is used only for the upstream language-matrix check and
    # the downstream registry detection; it is NOT substituted into the XML.
    $channelName = Get-OfficeChannelName -UpdateChannel $existing.UpdateChannel
    if (-not $channelName) {
        throw ("Cannot resolve installed Office channel from UpdateChannel value '{0}'. Language pack install aborted." -f $existing.UpdateChannel)
    }
    $edition = switch ($existing.Platform) {
        'x64'   { '64'; break }
        'x86'   { '32'; break }
        default { throw ("Cannot map installed Office Platform '{0}' to OfficeClientEdition. Expected 'x64' or 'x86'." -f $existing.Platform) }
    }
    Write-ODTLog -Message ("Rendering template for language '{0}' on channel '{1}', {2}-bit." -f $LanguageID, $channelName, $edition) -Component $ScriptName -LogFile $LogFile -LogPath $LogPath

    $templatePath = Join-Path -Path $PSScriptRoot -ChildPath 'Configurations\languagepack-template.xml'
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        throw "Language pack template not found: $templatePath"
    }
    $xmlText = Get-Content -LiteralPath $templatePath -Raw
    $xmlText = $xmlText.Replace('{{LanguageID}}', $LanguageID).
                        Replace('{{Channel}}', $channelName).
                        Replace('{{OfficeClientEdition}}', $edition)

    $renderedPath = Join-Path -Path $env:TEMP -ChildPath ("languagepack-$TargetProduct-$LanguageID-$(Get-Random).xml")
    Set-Content -LiteralPath $renderedPath -Value $xmlText -Encoding UTF8
    Write-ODTLog -Message ("Rendered template to: {0}" -f $renderedPath) -Component $ScriptName -LogFile $LogFile -LogPath $LogPath


    $setupPath = Resolve-ODTSetupPath -SetupExePath $SetupExePath -UseEvergreen:$UseEvergreenSetup

    Write-ODTLog -Message ("Installing language pack: '{0}'." -f $LanguageID) -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
    Write-ODTLog -Message 'Starting setup.exe /configure.' -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
    $result = Invoke-ODTSetup -SetupExePath $setupPath -ConfigurationPath $renderedPath

    $severity = if ($result.Success) { 1 } else { 3 }
    Write-ODTLog -Message ("setup.exe exit: {0} ({1}s). {2}" -f $result.ExitCode, $result.DurationSeconds, $result.Message) -Severity $severity -Component $ScriptName -LogFile $LogFile -LogPath $LogPath

    if (-not $result.Success) {
        $exit = $result.ExitCode
        $summary = ("Language pack install failed: {0}" -f $result.Message)
        throw $summary
    }

    # Post-install verification: re-snapshot per-product status. Logged
    # for admin visibility (so the log shows the exact before/after diff)
    # and used to detect silent setup.exe failures (the post-install
    # snapshot must mark every product installed; if any is still missing,
    # setup.exe returned 0 without doing the work — surface as 17002).
    # Get-LanguagePackInstallationStatus uses Registry64 helpers — see
    # rule #3 in docs/architecture.md.
    $postStatus = Get-LanguagePackInstallationStatus -LanguageID $LanguageID
    $postSummary = ($postStatus.PerProduct.GetEnumerator() | ForEach-Object {
        "{0}={1}" -f $_.Key, $(if ($_.Value) { 'installed' } else { 'missing' })
    }) -join ', '
    if ([string]::IsNullOrWhiteSpace($postSummary)) { $postSummary = '<no Click-to-Run products detected>' }
    Write-ODTLog -Message ("Post-install language pack status: {0}." -f $postSummary) -Component $ScriptName -LogFile $LogFile -LogPath $LogPath

    if (-not $postStatus.Installed) {
        $exit = 17002
        $missing = ($postStatus.PerProduct.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object { $_.Key }) -join ', '
        $summary = ("setup.exe returned 0 but language pack '{0}' is still missing for: {1}. Treating as silent failure." -f $LanguageID, $missing)
        Write-ODTLog -Message $summary -Severity 3 -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
        throw $summary
    }

    if ($result.ExitCode -in 3010, 1641) { $summary = 'Language pack installed. Reboot required.' }
}
catch {
    if ($exit -eq 0) { $exit = 1603 }
    $summary = $_.Exception.Message
    Write-ODTLog -Message ("Unhandled error: {0}`nLine: {1}" -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber) -Severity 3 -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
}
finally {
    Stop-ODTLogSession -ScriptName $ScriptName -ExitCode $exit -Message $summary -LogFile $LogFile -LogPath $LogPath
}

exit $exit
