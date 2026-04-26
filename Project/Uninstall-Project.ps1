#Requires -Version 5.1
<#
.SYNOPSIS
    Uninstall Project (ProjectProRetail) without affecting Office or Visio.

.NOTES
    Script  : Uninstall-Project.ps1
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

$ScriptName    = 'Uninstall-Project'
$ScriptVersion = '1.0.0'
$LogFile       = 'Project-Uninstall.log'
$ProductId     = 'ProjectProRetail'

# Body-time $PSScriptRoot is reliable; param-default-time is not under
# Intune Management Extension or PsExec -s with -File. See
# docs/architecture.md rule #2.
if ([string]::IsNullOrEmpty($SetupExePath)) {
    $SetupExePath = Join-Path -Path $PSScriptRoot -ChildPath 'Tools\setup.exe'
}

if (-not $PSBoundParameters.ContainsKey('ConfigurationFile') -and [string]::IsNullOrWhiteSpace($ConfigurationURL)) {
    $ConfigurationFile = Join-Path -Path $PSScriptRoot -ChildPath 'Configurations\project-remove.xml'
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
$summary = 'Uninstall succeeded.'

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

    if (-not (Test-ProductInstalled -ProductId $ProductId)) {
        Write-ODTLog -Message ("{0} not installed; uninstall is a no-op." -f $ProductId) -Severity 2 -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
        $summary = 'Uninstall skipped: product not installed.'
        return
    }

    $configPath = Resolve-ODTConfigurationPath -ConfigurationFile $ConfigurationFile -ConfigurationURL $ConfigurationURL

    $setupPath = Resolve-ODTSetupPath -SetupExePath $SetupExePath -UseEvergreen:$UseEvergreenSetup

    Write-ODTLog -Message 'Starting setup.exe /configure (removal).' -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
    $result = Invoke-ODTSetup -SetupExePath $setupPath -ConfigurationPath $configPath

    $severity = if ($result.Success) { 1 } else { 3 }
    Write-ODTLog -Message ("setup.exe exit: {0} ({1}s). {2}" -f $result.ExitCode, $result.DurationSeconds, $result.Message) -Severity $severity -Component $ScriptName -LogFile $LogFile -LogPath $LogPath

    if (-not $result.Success) {
        $exit = $result.ExitCode
        $summary = ("Uninstall failed: {0}" -f $result.Message)
        throw $summary
    }

    # Post-uninstall verification (silent-failure catch). Test-ProductInstalled
    # uses Registry64 helpers — see rule #3 in docs/architecture.md.
    if (Test-ProductInstalled -ProductId $ProductId) {
        $exit = 17002
        $summary = "setup.exe returned 0 but $ProductId is still registered. Treating as silent failure."
        Write-ODTLog -Message $summary -Severity 3 -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
        throw $summary
    }

    if ($result.ExitCode -in 3010, 1641) { $summary = 'Uninstall succeeded. Reboot required.' }
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
