#Requires -Version 5.1
<#
.SYNOPSIS
    Remove a specific language pack from a Click-to-Run Office product.

.DESCRIPTION
    Uses the <Remove> element scoped to a single (Product, Language) pair so
    nothing else is touched.

.PARAMETER LanguageID
    BCP-47 language code of the language pack to remove.

.PARAMETER TargetProduct
    The Click-to-Run product. Defaults to O365ProPlusRetail.

.NOTES
    Script  : Uninstall-LanguagePack.ps1
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
$ScriptName    = 'Uninstall-LanguagePack'
$LogFile       = ("LanguagePack-{0}-{1}-Uninstall.log" -f $TargetProduct, $LanguageID)

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
$summary = 'Language pack uninstall succeeded.'

try {
    if (-not $SkipPrerequisiteChecks) {
        $prereq = Invoke-ODTPrerequisiteChecks
        foreach ($r in $prereq.Results) {
            $severity = if ($r.Passed) { 1 } else { 3 }
            $status = if ($r.Passed) { 'PASS' } else { 'FAIL' }
            Write-ODTLog -Message ("Prerequisite {0}: {1} - {2}" -f $r.CheckName, $status, $r.Details) -Severity $severity -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
        }
        if (-not $prereq.AllPassed) { throw $prereq.Summary }
    }

    # Per-installed-product status snapshot. The removal XML below targets
    # <Product ID="$TargetProduct"> specifically (not the LanguagePack
    # pseudo-product), so the skip decision is "does THIS TargetProduct
    # carry the language?" rather than "is the language anywhere on the
    # machine?" — the v1.0.6 aggregate Installed flag is the wrong question
    # for uninstall.
    $preStatus = Get-LanguagePackInstallationStatus -LanguageID $LanguageID
    $preSummary = ($preStatus.PerProduct.GetEnumerator() | ForEach-Object {
        "{0}={1}" -f $_.Key, $(if ($_.Value) { 'installed' } else { 'missing' })
    }) -join ', '
    if ([string]::IsNullOrWhiteSpace($preSummary)) { $preSummary = '<no Click-to-Run products detected>' }
    Write-ODTLog -Message ("Language pack '{0}' status: {1}." -f $LanguageID, $preSummary) -Component $ScriptName -LogFile $LogFile -LogPath $LogPath

    if (-not $preStatus.PerProduct.Contains($TargetProduct) -or -not $preStatus.PerProduct[$TargetProduct]) {
        Write-ODTLog -Message ("Language pack '{0}' is not installed for {1}; uninstall is a no-op for this target." -f $LanguageID, $TargetProduct) -Severity 2 -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
        $summary = 'Language pack not installed for the requested target product; nothing to do.'
        return
    }

    $xmlText = @"
<?xml version="1.0" encoding="UTF-8"?>
<Configuration ID="languagepack-remove-$TargetProduct-$LanguageID">
  <Remove All="FALSE">
    <Product ID="$TargetProduct">
      <Language ID="$LanguageID" />
    </Product>
  </Remove>
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
  <Display Level="None" AcceptEULA="TRUE" />
</Configuration>
"@

    $renderedPath = Join-Path -Path $env:TEMP -ChildPath ("languagepack-remove-$TargetProduct-$LanguageID-$(Get-Random).xml")
    Set-Content -LiteralPath $renderedPath -Value $xmlText -Encoding UTF8
    Write-ODTLog -Message ("Rendered removal XML: {0}" -f $renderedPath) -Component $ScriptName -LogFile $LogFile -LogPath $LogPath

    $setupPath = Resolve-ODTSetupPath -SetupExePath $SetupExePath -UseEvergreen:$UseEvergreenSetup

    Write-ODTLog -Message ("Removing language pack: '{0}' from {1}." -f $LanguageID, $TargetProduct) -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
    Write-ODTLog -Message 'Starting setup.exe /configure (removal).' -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
    $result = Invoke-ODTSetup -SetupExePath $setupPath -ConfigurationPath $renderedPath

    $severity = if ($result.Success) { 1 } else { 3 }
    Write-ODTLog -Message ("setup.exe exit: {0} ({1}s). {2}" -f $result.ExitCode, $result.DurationSeconds, $result.Message) -Severity $severity -Component $ScriptName -LogFile $LogFile -LogPath $LogPath

    if (-not $result.Success) {
        $exit = $result.ExitCode
        $summary = ("Language pack uninstall failed: {0}" -f $result.Message)
        throw $summary
    }

    # Post-uninstall verification: re-snapshot per-product status. Logged
    # for admin visibility (so the log shows the exact before/after diff
    # — products from which the language was removed read 'removed' here)
    # and used to detect silent setup.exe failures targeting the
    # TargetProduct specifically. Get-LanguagePackInstallationStatus uses
    # Registry64 helpers — see rule #3 in docs/architecture.md.
    $postStatus = Get-LanguagePackInstallationStatus -LanguageID $LanguageID
    $postSummary = ($postStatus.PerProduct.GetEnumerator() | ForEach-Object {
        "{0}={1}" -f $_.Key, $(if ($_.Value) { 'still installed' } else { 'removed' })
    }) -join ', '
    if ([string]::IsNullOrWhiteSpace($postSummary)) { $postSummary = '<no Click-to-Run products detected>' }
    Write-ODTLog -Message ("Post-uninstall language pack status: {0}." -f $postSummary) -Component $ScriptName -LogFile $LogFile -LogPath $LogPath

    if ($postStatus.PerProduct.Contains($TargetProduct) -and $postStatus.PerProduct[$TargetProduct]) {
        $exit = 17002
        $summary = ("setup.exe returned 0 but language pack '{0}' is still present for {1}. Treating as silent failure." -f $LanguageID, $TargetProduct)
        Write-ODTLog -Message $summary -Severity 3 -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
        throw $summary
    }

    if ($result.ExitCode -in 3010, 1641) { $summary = 'Language pack removed. Reboot required.' }
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
