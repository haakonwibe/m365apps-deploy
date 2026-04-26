#Requires -Version 5.1
<#
.SYNOPSIS
    Install Microsoft 365 Apps for Enterprise using the Office Deployment Tool.

.DESCRIPTION
    Runs setup.exe /configure against the supplied (or bundled) configuration
    XML, with consolidated logging under C:\ProgramData\M365AppsDeploy\Logs.

    Intended to run under SYSTEM via Intune. Install is silent
    (Display Level="None" in the bundled XML). FORCEAPPSHUTDOWN is set so any
    Office processes are closed before install proceeds.

    Exit codes follow ODT / Windows Installer conventions. 0 = success; 3010
    and 1641 are also treated as success with a reboot. Any other non-zero
    code is treated as failure.

.PARAMETER ConfigurationFile
    Path to a local ODT configuration XML. Defaults to the bundled
    m365apps-base.xml inside this product's Configurations\ folder.

.PARAMETER ConfigurationURL
    HTTPS URL of a configuration XML. Overrides -ConfigurationFile when set.
    Use for centrally managed configurations (e.g. blob storage).

.PARAMETER SetupExePath
    Path to setup.exe (Office Deployment Tool). Defaults to the bundled
    Tools\setup.exe alongside this script.

.PARAMETER UseEvergreenSetup
    Download a fresh ODT from Microsoft instead of using the bundled setup.exe.

.PARAMETER LogPath
    Root directory for script and ODT logs. Defaults to
    C:\ProgramData\M365AppsDeploy\Logs.

.PARAMETER SkipPrerequisiteChecks
    Bypass prerequisite checks (elevation / reboot / disk / running setup).
    Use only for lab troubleshooting.

.EXAMPLE
    .\Install-M365Apps.ps1

.EXAMPLE
    .\Install-M365Apps.ps1 -ConfigurationFile 'C:\M365\custom.xml' -UseEvergreenSetup

.NOTES
    Script  : Install-M365Apps.ps1
    Project : m365apps-deploy
    Version : 1.0.0
#>
[CmdletBinding()]
param(
    [string] $ConfigurationFile,

    [string] $ConfigurationURL,

    [string] $SetupExePath,

    [switch] $UseEvergreenSetup,

    [string] $LogPath = 'C:\ProgramData\M365AppsDeploy\Logs',

    [switch] $SkipPrerequisiteChecks
)

$ErrorActionPreference = 'Stop'

$ScriptName    = 'Install-M365Apps'
$ScriptVersion = '1.0.0'
$LogFile       = 'M365Apps-Install.log'
$ProductId     = 'O365ProPlusRetail'

# Body-time $PSScriptRoot is reliable; param-default-time is not under
# Intune Management Extension or PsExec -s with -File. See
# docs/architecture.md rule #2.
if ([string]::IsNullOrEmpty($SetupExePath)) {
    $SetupExePath = Join-Path -Path $PSScriptRoot -ChildPath 'Tools\setup.exe'
}

if (-not $PSBoundParameters.ContainsKey('ConfigurationFile') -and [string]::IsNullOrWhiteSpace($ConfigurationURL)) {
    $ConfigurationFile = Join-Path -Path $PSScriptRoot -ChildPath 'Configurations\m365apps-base.xml'
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
$summary = 'Install succeeded.'

try {
    if (-not $SkipPrerequisiteChecks) {
        Write-ODTLog -Message 'Running prerequisite checks.' -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
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
    else {
        Write-ODTLog -Message 'Prerequisite checks skipped via -SkipPrerequisiteChecks.' -Severity 2 -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
    }

    $existingConfig = Get-OfficeConfiguration
    if ($null -ne $existingConfig) {
        $existingChannelName = Get-OfficeChannelName -UpdateChannel $existingConfig.UpdateChannel
        $existingChannelDisplay = if ($existingChannelName) { $existingChannelName } else { "<unknown: $($existingConfig.UpdateChannel)>" }
        Write-ODTLog -Message ("Existing C2R installation detected: products=[{0}] platform={1} channel={2} version={3}." -f ($existingConfig.ProductReleaseIds -join ','), $existingConfig.Platform, $existingChannelDisplay, $existingConfig.VersionToReport) -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
    }

    $officeRunning = @(Get-Process -Name 'WINWORD','EXCEL','POWERPNT','OUTLOOK','MSACCESS','ONENOTE','VISIO','WINPROJ','MSPUB' -ErrorAction SilentlyContinue)
    if ($officeRunning.Count -gt 0) {
        Write-ODTLog -Message ("Office processes running: {0}. Install uses FORCEAPPSHUTDOWN." -f (($officeRunning | Select-Object -ExpandProperty Name -Unique) -join ',')) -Severity 2 -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
    }

    $configPath = Resolve-ODTConfigurationPath -ConfigurationFile $ConfigurationFile -ConfigurationURL $ConfigurationURL
    Write-ODTLog -Message ("Resolved configuration XML: {0}" -f $configPath) -Component $ScriptName -LogFile $LogFile -LogPath $LogPath


    $setupPath = Resolve-ODTSetupPath -SetupExePath $SetupExePath -UseEvergreen:$UseEvergreenSetup
    Write-ODTLog -Message ("Using setup.exe: {0}" -f $setupPath) -Component $ScriptName -LogFile $LogFile -LogPath $LogPath

    Write-ODTLog -Message 'Starting setup.exe /configure.' -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
    $result = Invoke-ODTSetup -SetupExePath $setupPath -ConfigurationPath $configPath

    $severity = if ($result.Success) { 1 } else { 3 }
    Write-ODTLog -Message ("setup.exe exit: {0} ({1}s). {2}" -f $result.ExitCode, $result.DurationSeconds, $result.Message) -Severity $severity -Component $ScriptName -LogFile $LogFile -LogPath $LogPath

    if (-not $result.Success) {
        $exit = $result.ExitCode
        $summary = ("Install failed: {0}" -f $result.Message)
        throw $summary
    }

    # Post-install verification: setup.exe has been known to return 0 even
    # when the product was not actually installed. Cross-check the registry
    # via Test-ProductInstalled (which uses the Registry64 helpers — see
    # rule #3 in docs/architecture.md).
    Write-ODTLog -Message ("Verifying {0} installation in the registry." -f $ProductId) -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
    if (-not (Test-ProductInstalled -ProductId $ProductId)) {
        $exit = 17002
        $summary = "setup.exe returned 0 but $ProductId is not present in ClickToRun\Configuration. Treating as silent failure."
        Write-ODTLog -Message $summary -Severity 3 -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
        throw $summary
    }

    $postConfig = Get-OfficeConfiguration
    $postChannelName = Get-OfficeChannelName -UpdateChannel $postConfig.UpdateChannel
    $postChannelDisplay = if ($postChannelName) { $postChannelName } else { "<unknown: $($postConfig.UpdateChannel)>" }
    Write-ODTLog -Message ("Post-install: products=[{0}] platform={1} channel={2} version={3}." -f ($postConfig.ProductReleaseIds -join ','), $postConfig.Platform, $postChannelDisplay, $postConfig.VersionToReport) -Component $ScriptName -LogFile $LogFile -LogPath $LogPath

    if ($result.ExitCode -in 3010, 1641) {
        $summary = 'Install succeeded. Reboot required.'
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
