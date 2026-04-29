#Requires -Version 5.1
<#
.SYNOPSIS
    Install Project (ProjectProRetail) on top of an existing M365 Apps install.

.DESCRIPTION
    Project is an add-on: the base M365 Apps install must already be present,
    and the Project channel / architecture must match it.

.PARAMETER ConfigurationFile
    Path to local configuration XML. Defaults to project-base.xml.

.PARAMETER ConfigurationURL
    HTTPS URL of a configuration XML. Overrides -ConfigurationFile.

.PARAMETER SetupExePath
    Path to setup.exe. Defaults to bundled Tools\setup.exe.

.PARAMETER UseEvergreenSetup
    Download fresh ODT from Microsoft at runtime.

.PARAMETER LogPath
    Root log directory.

.PARAMETER SkipPrerequisiteChecks
    Bypass prerequisite checks.

.PARAMETER SkipBaseInstallCheck
    Skip the "M365 Apps must be present" guardrail.

.NOTES
    Script  : Install-Project.ps1
    Project : m365apps-deploy
    Version : <see Common/ODTVersion.psm1>
#>
[CmdletBinding()]
param(
    [string] $ConfigurationFile,

    [string] $ConfigurationURL,

    [string] $SetupExePath,

    [switch] $UseEvergreenSetup,

    [string] $LogPath = 'C:\ProgramData\M365AppsDeploy\Logs',

    [switch] $SkipPrerequisiteChecks,

    [switch] $SkipBaseInstallCheck
)

$ErrorActionPreference = 'Stop'

$ScriptName    = 'Install-Project'
$LogFile       = 'Project-Install.log'
$ProductId     = 'ProjectProRetail'

# Body-time $PSScriptRoot is reliable; param-default-time is not under
# Intune Management Extension or PsExec -s with -File. See
# docs/architecture.md rule #2.
if ([string]::IsNullOrEmpty($SetupExePath)) {
    $SetupExePath = Join-Path -Path $PSScriptRoot -ChildPath 'Tools\setup.exe'
}

if (-not $PSBoundParameters.ContainsKey('ConfigurationFile') -and [string]::IsNullOrWhiteSpace($ConfigurationURL)) {
    $ConfigurationFile = Join-Path -Path $PSScriptRoot -ChildPath 'Configurations\project-base.xml'
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
    ConfigurationFile      = $ConfigurationFile
    ConfigurationURL       = $ConfigurationURL
    SetupExePath           = $SetupExePath
    UseEvergreenSetup      = [bool]$UseEvergreenSetup
    LogPath                = $LogPath
    SkipPrerequisiteChecks = [bool]$SkipPrerequisiteChecks
    SkipBaseInstallCheck   = [bool]$SkipBaseInstallCheck
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
        $prereq = Invoke-ODTPrerequisiteChecks
        foreach ($r in $prereq.Results) {
            $severity = if ($r.Passed) { 1 } else { 3 }
            $status = if ($r.Passed) { 'PASS' } else { 'FAIL' }
            Write-ODTLog -Message ("Prerequisite {0}: {1} - {2}" -f $r.CheckName, $status, $r.Details) -Severity $severity -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
        }
        if (-not $prereq.AllPassed) { throw $prereq.Summary }
    }

    $existing = Get-OfficeConfiguration
    if (-not $SkipBaseInstallCheck) {
        if ($null -eq $existing -or -not (Test-ProductInstalled -ProductId 'O365ProPlusRetail')) {
            throw "Project is an add-on; M365 Apps (O365ProPlusRetail) must be installed first. Pass -SkipBaseInstallCheck to override."
        }
        $installedChannelName = Get-OfficeChannelName -UpdateChannel $existing.UpdateChannel
        $channelDisplay = if ($installedChannelName) { $installedChannelName } else { "<unknown: $($existing.UpdateChannel)>" }
        Write-ODTLog -Message ("Base Office install detected: platform={0} channel={1}. Project install will match." -f $existing.Platform, $channelDisplay) -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
    }

    $configPath = Resolve-ODTConfigurationPath -ConfigurationFile $ConfigurationFile -ConfigurationURL $ConfigurationURL

    # Reconcile XML with installed Office:
    #   - Channel: compared on canonical names (registry URL -> name via
    #     Get-OfficeChannelName). Real mismatch rewrites the XML Channel
    #     attribute to the installed channel; ODT refuses cross-channel
    #     installs and the rewrite is more robust than per-channel XMLs.
    #   - Architecture: ODT refuses outright on mismatch; we log severity 3
    #     and let ODT surface the error rather than auto-fixing.
    if ($null -ne $existing) {
        try {
            [xml]$doc = Get-Content -LiteralPath $configPath -Raw
            $addNode = $doc.DocumentElement.SelectSingleNode('Add')
            if ($null -ne $addNode) {
                $channelAttr = $addNode.GetAttribute('Channel')
                $installedChannelName = Get-OfficeChannelName -UpdateChannel $existing.UpdateChannel
                if ($channelAttr -and $installedChannelName -and ($channelAttr -ine $installedChannelName)) {
                    Write-ODTLog -Message ("Channel in XML ('{0}') differs from installed channel ('{1}'); rewriting XML Channel attribute to match installed." -f $channelAttr, $installedChannelName) -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
                    $addNode.SetAttribute('Channel', $installedChannelName)
                    $rewrittenPath = Join-Path -Path $env:TEMP -ChildPath ("project-channel-rewrite-$(Get-Random).xml")
                    $doc.Save($rewrittenPath)
                    $configPath = $rewrittenPath
                }

                $archAttr = $addNode.GetAttribute('OfficeClientEdition')
                $existingArch = if ($existing.Platform -eq 'x64') { '64' } elseif ($existing.Platform -eq 'x86') { '32' } else { $null }
                if ($archAttr -and $existingArch -and $archAttr -ne $existingArch) {
                    Write-ODTLog -Message ("Architecture mismatch: existing Office is {0}-bit, Project XML requests {1}-bit. ODT will refuse the install." -f $existingArch, $archAttr) -Severity 3 -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
                }
            }
        }
        catch {
            Write-ODTLog -Message ("Channel/arch reconciliation skipped: {0}" -f $_.Exception.Message) -Severity 2 -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
        }
    }

    $setupPath = Resolve-ODTSetupPath -SetupExePath $SetupExePath -UseEvergreen:$UseEvergreenSetup

    Write-ODTLog -Message 'Starting setup.exe /configure.' -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
    $result = Invoke-ODTSetup -SetupExePath $setupPath -ConfigurationPath $configPath

    $severity = if ($result.Success) { 1 } else { 3 }
    Write-ODTLog -Message ("setup.exe exit: {0} ({1}s). {2}" -f $result.ExitCode, $result.DurationSeconds, $result.Message) -Severity $severity -Component $ScriptName -LogFile $LogFile -LogPath $LogPath

    if (-not $result.Success) {
        $exit = $result.ExitCode
        $summary = ("Install failed: {0}" -f $result.Message)
        throw $summary
    }

    # Post-install verification (silent-failure catch). Test-ProductInstalled
    # uses Registry64 helpers — see rule #3 in docs/architecture.md.
    if (-not (Test-ProductInstalled -ProductId $ProductId)) {
        $exit = 17002
        $summary = "setup.exe returned 0 but $ProductId is not present. Treating as silent failure."
        Write-ODTLog -Message $summary -Severity 3 -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
        throw $summary
    }

    if ($result.ExitCode -in 3010, 1641) { $summary = 'Install succeeded. Reboot required.' }
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
