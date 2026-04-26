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
    Version : 1.0.0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-zA-Z]{2}(-[a-zA-Z]{2,8}){1,3}$')]
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
$ScriptVersion = '1.0.0'
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
Import-Module (Join-Path $commonPath 'ODTPrerequisites.psm1') -Force
Import-Module (Join-Path $commonPath 'ODTOfficeState.psm1')   -Force
Import-Module (Join-Path $commonPath 'ODTInvoke.psm1')        -Force
Import-Module (Join-Path $commonPath 'ODTLanguages.psm1')     -Force

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
    if (Test-LanguagePackInstalled -LanguageID $LanguageID -TargetProduct $TargetProduct) {
        Write-ODTLog -Message ("Language pack {0} for {1} is already installed; no action needed." -f $LanguageID, $TargetProduct) -Severity 2 -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
        $summary = 'Language pack already installed.'
        return
    }

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

    Write-ODTLog -Message 'Starting setup.exe /configure.' -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
    $result = Invoke-ODTSetup -SetupExePath $setupPath -ConfigurationPath $renderedPath

    $severity = if ($result.Success) { 1 } else { 3 }
    Write-ODTLog -Message ("setup.exe exit: {0} ({1}s). {2}" -f $result.ExitCode, $result.DurationSeconds, $result.Message) -Severity $severity -Component $ScriptName -LogFile $LogFile -LogPath $LogPath

    if (-not $result.Success) {
        $exit = $result.ExitCode
        $summary = ("Language pack install failed: {0}" -f $result.Message)
        throw $summary
    }

    # Post-install verification (silent-failure catch). Test-LanguagePackInstalled
    # uses Registry64 helpers — see rule #3 in docs/architecture.md.
    if (-not (Test-LanguagePackInstalled -LanguageID $LanguageID -TargetProduct $TargetProduct)) {
        $exit = 17002
        $summary = "setup.exe returned 0 but language pack '$LanguageID' for $TargetProduct is not present. Treating as silent failure."
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
