#Requires -Version 5.1
<#
.SYNOPSIS
    Uninstall Microsoft 365 Apps for Enterprise. Surgical by default;
    pass -RemoveAll for a nuclear C2R wipe.

.DESCRIPTION
    Two modes, chosen via -RemoveAll:

    Surgical (default, no -RemoveAll):
        Uses m365apps-remove.xml - a scoped <Remove> block targeting
        O365ProPlusRetail plus the LanguagePack pseudo-product only.
        Visio, Project, and any other Click-to-Run products registered
        on the device remain installed. Language packs attached to those
        other products (e.g. VisioProRetail + nb-no) are also preserved.

        This is the common case for Intune deployments: Office rolls off,
        Visio / Project users keep their add-ons.

    Nuclear (-RemoveAll):
        Uses m365apps-removeall.xml with <Remove All="TRUE"/>. Tears down
        the entire Click-to-Run stack on the device - Office, Visio,
        Project, every language pack, and the C2R engine itself.

        Reserve this for full rebuilds / lab cleanup / transitioning a
        device off all Microsoft 365 Apps products at once.

    If the last remaining C2R product is removed surgically (e.g. only
    Office was installed and you uninstall it), the C2R engine may linger
    in a semi-installed state. A follow-up -RemoveAll run cleans it up.
    See docs\architecture.md#uninstall-semantics for details.

.PARAMETER ConfigurationFile
    Path to a removal configuration XML. Defaults to the appropriate
    bundled XML based on -RemoveAll. Passing -ConfigurationFile
    explicitly overrides the default selection.

.PARAMETER ConfigurationURL
    HTTPS URL to a removal configuration XML. Overrides both
    -ConfigurationFile and -RemoveAll.

.PARAMETER RemoveAll
    Switch to nuclear mode (<Remove All="TRUE"/>). Without this switch,
    uninstall is surgical (Office + LanguagePack only).

.PARAMETER SetupExePath
    Path to setup.exe. Defaults to bundled Tools\setup.exe.

.PARAMETER UseEvergreenSetup
    Download a fresh ODT from Microsoft instead of using the bundled setup.exe.

.PARAMETER LogPath
    Root directory for logs. Defaults to C:\ProgramData\M365AppsDeploy\Logs.

.PARAMETER SkipPrerequisiteChecks
    Bypass prerequisite checks. Use only for lab troubleshooting.

.EXAMPLE
    .\Uninstall-M365Apps.ps1

    Surgical default. Removes Office and any Language Pack accessories.
    Visio and Project remain installed and usable.

.EXAMPLE
    .\Uninstall-M365Apps.ps1 -RemoveAll

    Nuclear. Removes every Click-to-Run product on the device and the
    C2R engine itself.

.NOTES
    Script  : Uninstall-M365Apps.ps1
    Project : m365apps-deploy
    Version : 1.0.0
#>
[CmdletBinding()]
param(
    [string] $ConfigurationFile,

    [string] $ConfigurationURL,

    [switch] $RemoveAll,

    [string] $SetupExePath,

    [switch] $UseEvergreenSetup,

    [string] $LogPath = 'C:\ProgramData\M365AppsDeploy\Logs',

    [switch] $SkipPrerequisiteChecks
)

$ErrorActionPreference = 'Stop'

$ScriptName    = 'Uninstall-M365Apps'
$ScriptVersion = '1.0.0'
$LogFile       = 'M365Apps-Uninstall.log'
$ProductId     = 'O365ProPlusRetail'

# Body-time $PSScriptRoot is reliable; param-default-time is not under
# Intune Management Extension or PsExec -s with -File. See
# docs/architecture.md rule #2.
if ([string]::IsNullOrEmpty($SetupExePath)) {
    $SetupExePath = Join-Path -Path $PSScriptRoot -ChildPath 'Tools\setup.exe'
}

# Default XML selection: surgical unless -RemoveAll is set. An explicit
# -ConfigurationFile or -ConfigurationURL overrides both defaults.
if (-not $PSBoundParameters.ContainsKey('ConfigurationFile') -and [string]::IsNullOrWhiteSpace($ConfigurationURL)) {
    $defaultXml = if ($RemoveAll) { 'm365apps-removeall.xml' } else { 'm365apps-remove.xml' }
    $ConfigurationFile = Join-Path -Path $PSScriptRoot -ChildPath ("Configurations\{0}" -f $defaultXml)
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

$sessionParams = @{
    ConfigurationFile      = $ConfigurationFile
    ConfigurationURL       = $ConfigurationURL
    RemoveAll              = [bool]$RemoveAll
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

# Surgical (default) vs. nuclear mode marker in the log so operators can
# tell at a glance which semantic was applied.
$modeLabel = if ($RemoveAll) { 'NUCLEAR (-RemoveAll): full C2R stack including Visio / Project' } else { 'SURGICAL (default): O365ProPlusRetail + LanguagePack only' }
Write-ODTLog -Message ("Uninstall mode: {0}" -f $modeLabel) -Component $ScriptName -LogFile $LogFile -LogPath $LogPath

$exit    = 0
$summary = 'Uninstall succeeded.'

try {
    if (-not $SkipPrerequisiteChecks) {
        $prereq = Invoke-ODTPrerequisiteChecks
        foreach ($r in $prereq.Results) {
            $severity = if ($r.Passed) { 1 } else { 3 }
            $status = if ($r.Passed) { 'PASS' } else { 'FAIL' }
            Write-ODTLog -Message ("Prerequisite {0}: {1} - {2}" -f $r.CheckName, $status, $r.Details) -Severity $severity -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
        }
        if (-not $prereq.AllPassed) {
            throw $prereq.Summary
        }
    }

    if (-not (Test-ProductInstalled -ProductId $ProductId)) {
        Write-ODTLog -Message ("{0} is not installed; uninstall is a no-op." -f $ProductId) -Severity 2 -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
        $summary = 'Uninstall skipped: product not installed.'
        return
    }

    $configPath = Resolve-ODTConfigurationPath -ConfigurationFile $ConfigurationFile -ConfigurationURL $ConfigurationURL
    Write-ODTLog -Message ("Resolved configuration XML: {0}" -f $configPath) -Component $ScriptName -LogFile $LogFile -LogPath $LogPath


    $setupPath = Resolve-ODTSetupPath -SetupExePath $SetupExePath -UseEvergreen:$UseEvergreenSetup
    Write-ODTLog -Message ("Using setup.exe: {0}" -f $setupPath) -Component $ScriptName -LogFile $LogFile -LogPath $LogPath

    Write-ODTLog -Message 'Starting setup.exe /configure (removal).' -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
    $result = Invoke-ODTSetup -SetupExePath $setupPath -ConfigurationPath $configPath

    $severity = if ($result.Success) { 1 } else { 3 }
    Write-ODTLog -Message ("setup.exe exit: {0} ({1}s). {2}" -f $result.ExitCode, $result.DurationSeconds, $result.Message) -Severity $severity -Component $ScriptName -LogFile $LogFile -LogPath $LogPath

    if (-not $result.Success) {
        $exit = $result.ExitCode
        $summary = ("Uninstall failed: {0}" -f $result.Message)
        throw $summary
    }

    # Post-uninstall verification: cross-check that the product is no longer
    # registered. Test-ProductInstalled uses the Registry64 helpers — see
    # rule #3 in docs/architecture.md.
    if (Test-ProductInstalled -ProductId $ProductId) {
        $exit = 17002
        $summary = "setup.exe returned 0 but $ProductId is still registered in ClickToRun\Configuration. Treating as silent failure."
        Write-ODTLog -Message $summary -Severity 3 -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
        throw $summary
    }

    if ($result.ExitCode -in 3010, 1641) {
        $summary = 'Uninstall succeeded. Reboot required.'
    }
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
