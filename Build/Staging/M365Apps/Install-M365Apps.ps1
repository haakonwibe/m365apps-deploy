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

.PARAMETER RemovePreinstalledConsumerOffice
    Remove an OEM-preinstalled consumer Click-to-Run Office (Microsoft 365
    Family/Personal, Home & Business, and friends) in its own ODT pass before
    installing the enterprise product.

    Off by default, because removing software is not something this toolkit
    should start doing silently on an upgrade. Turn it on in the Intune
    install command line when your hardware ships with consumer Office.

    Why it matters: <RemoveMSI /> only removes Windows Installer versions of
    Office, so a consumer C2R install survives the enterprise install and
    stays registered alongside it. ODT then has to reconcile the existing
    install onto our channel and build instead of installing cleanly, and the
    device is left carrying two Office product registrations, which causes
    licensing and activation confusion.

.PARAMETER ProgressIntervalSeconds
    Seconds between the progress lines written while setup.exe runs. Drop to
    15 when actively diagnosing a slow install - the C2R phase breakdown
    resolves to one interval. 0 disables progress logging entirely.

.EXAMPLE
    .\Install-M365Apps.ps1

.EXAMPLE
    .\Install-M365Apps.ps1 -ConfigurationFile 'C:\M365\custom.xml' -UseEvergreenSetup

.NOTES
    Script  : Install-M365Apps.ps1
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

    [switch] $RemovePreinstalledConsumerOffice,

    [ValidateRange(0, 600)]
    [int] $ProgressIntervalSeconds = 30
)

$ErrorActionPreference = 'Stop'

$ScriptName    = 'Install-M365Apps'
$LogFile       = 'M365Apps-Install.log'
$ProductId     = 'O365ProPlusRetail'

# Consumer / OEM-preinstall Click-to-Run product IDs, as shipped on some
# vendor images. Kept in one place so adding a SKU is a one-line edit - see
# docs/customization.md.
$ConsumerProductIds = @(
    'O365HomePremRetail'
    'O365SmallBusPremRetail'
    'O365BusinessRetail'
    'HomeBusinessRetail'
    'HomeStudentRetail'
    'PersonalRetail'
)

# Body-time $PSScriptRoot is reliable; param-default-time is not under
# Intune Management Extension or PsExec -s with -File. See
# docs/architecture.md rule #2.
if ([string]::IsNullOrEmpty($SetupExePath)) {
    $SetupExePath = Join-Path -Path $PSScriptRoot -ChildPath 'Tools\setup.exe'
}

if (-not $PSBoundParameters.ContainsKey('ConfigurationFile') -and [string]::IsNullOrWhiteSpace($ConfigurationURL)) {
    $ConfigurationFile = Join-Path -Path $PSScriptRoot -ChildPath 'Configurations\m365apps-base.xml'
}

$RemoveConsumerConfigurationFile = Join-Path -Path $PSScriptRoot -ChildPath 'Configurations\m365apps-remove-consumer.xml'

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
    RemovePreinstalledConsumerOffice = [bool]$RemovePreinstalledConsumerOffice
    ProgressIntervalSeconds          = $ProgressIntervalSeconds
}

Start-ODTLogSession -ScriptName $ScriptName -ScriptVersion $ScriptVersion -Parameters $sessionParams -LogFile $LogFile -LogPath $LogPath

# Surface invocation context so empty $PSScriptRoot is visible in the
# log header (would otherwise show as a downstream "file not found"
# further into the script).
Write-ODTLog -Message ("Invocation context: PSScriptRoot='{0}' PSCommandPath='{1}' Resolved SetupExePath='{2}'" -f $PSScriptRoot, $PSCommandPath, $SetupExePath) -Component $ScriptName -LogFile $LogFile -LogPath $LogPath

# When IME extracted this payload. The window between IME staging content and
# actually running us is invisible from inside the script and can be several
# minutes of an ESP budget, so record what we can see of it: a large age here
# means the content was ready and IME did not run us, a near-zero age means
# IME had only just finished delivering it. The rest of that window is only
# visible in C:\ProgramData\Microsoft\IntuneManagementExtension\Logs.
try {
    $stagedAt = (Get-Item -LiteralPath $PSScriptRoot -ErrorAction Stop).CreationTimeUtc
    $stagedAge = ([datetime]::UtcNow - $stagedAt).TotalSeconds
    Write-ODTLog -Message ("Payload staged at {0:o} ({1:N0}s before this session started)." -f $stagedAt, $stagedAge) -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
}
catch {
    Write-ODTLog -Message ("Could not read payload staging time from '{0}': {1}" -f $PSScriptRoot, $_.Exception.Message) -Severity 2 -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
}

# Every phase marker and progress line shares this destination.
$logTarget = @{ Component = $ScriptName; LogFile = $LogFile; LogPath = $LogPath }

# Authored here, not inside ODTInvoke: a scriptblock runs in the session state
# it was defined in, so this one can see Write-ODTLog and $logTarget while the
# module stays free of any dependency on ODTLogging.
$progressCallback = {
    param($line, $severity)
    Write-ODTLog -Message $line -Severity $severity @logTarget
}

$exit    = 0
$summary = 'Install succeeded.'
# Initialised before the try so the finally block can test it: if a
# prerequisite check throws, $result is never assigned, and reading a property
# off an unassigned variable throws under StrictMode.
$result  = $null

Write-ODTPhase -Phase 'SessionStart' @logTarget

try {
    if (-not $SkipPrerequisiteChecks) {
        Write-ODTPhase -Phase 'PrereqStart' -Detail 'Running prerequisite checks.' @logTarget
        $prereq = Invoke-ODTPrerequisiteChecks
        foreach ($r in $prereq.Results) {
            $severity = if ($r.Passed) { 1 } else { 3 }
            $status = if ($r.Passed) { 'PASS' } else { 'FAIL' }
            Write-ODTLog -Message ("Prerequisite {0}: {1} - {2}" -f $r.CheckName, $status, $r.Details) -Severity $severity -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
        }
        if (-not $prereq.AllPassed) {
            throw $prereq.Summary
        }
        Write-ODTPhase -Phase 'PrereqEnd' @logTarget
    }
    else {
        Write-ODTPhase -Phase 'PrereqSkipped' -Detail 'Skipped via -SkipPrerequisiteChecks.' -Severity 2 @logTarget
    }

    Write-ODTPhase -Phase 'OfficeStateRead' @logTarget
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

    # Resolved before the configuration XML because the optional consumer
    # removal pass below needs setup.exe too.
    $setupPath = Resolve-ODTSetupPath -SetupExePath $SetupExePath -UseEvergreen:$UseEvergreenSetup
    Write-ODTPhase -Phase 'SetupResolved' -Detail $setupPath @logTarget

    # --- Optional: remove an OEM-preinstalled consumer Click-to-Run Office ---
    #
    # <RemoveMSI /> in the base XML does not cover Click-to-Run, so without
    # this a consumer SKU survives the enterprise install and stays registered
    # beside it. ODT then reconciles the existing install onto our channel and
    # build rather than installing cleanly.
    #
    # ODT documents <Remove> standalone, never alongside <Add>, so this has to
    # be its own setup.exe pass against its own XML.
    if ($RemovePreinstalledConsumerOffice) {
        $preinstalled = @()
        if ($null -ne $existingConfig) {
            $preinstalled = @($existingConfig.ProductReleaseIds | Where-Object { $_ -in $ConsumerProductIds })
        }

        if ($preinstalled.Count -eq 0) {
            Write-ODTPhase -Phase 'ConsumerRemovalSkipped' -Detail 'No preinstalled consumer Office products found.' @logTarget
        }
        elseif (-not (Test-Path -LiteralPath $RemoveConsumerConfigurationFile -PathType Leaf)) {
            Write-ODTPhase -Phase 'ConsumerRemovalSkipped' -Severity 2 `
                -Detail ("Configuration '{0}' not found; leaving [{1}] in place." -f $RemoveConsumerConfigurationFile, ($preinstalled -join ',')) @logTarget
        }
        else {
            Write-ODTPhase -Phase 'ConsumerRemovalStart' -Detail ("Removing preinstalled consumer Office: {0}." -f ($preinstalled -join ',')) @logTarget

            # Deliberately not fatal. A failed removal leaves the device in the
            # state it was already in, which is worse than a clean install but
            # far better than no Office at all - so we log and carry on.
            try {
                $removeResult = Invoke-ODTSetup -SetupExePath $setupPath `
                                                -ConfigurationPath $RemoveConsumerConfigurationFile `
                                                -ProgressIntervalSeconds $ProgressIntervalSeconds `
                                                -ProgressCallback $progressCallback
                $removeSeverity = if ($removeResult.Success) { 1 } else { 2 }
                Write-ODTPhase -Phase 'ConsumerRemovalEnd' -Severity $removeSeverity `
                    -Detail ("exit {0} after {1}s. {2}" -f $removeResult.ExitCode, $removeResult.DurationSeconds, $removeResult.Message) @logTarget
            }
            catch {
                Write-ODTPhase -Phase 'ConsumerRemovalEnd' -Severity 2 `
                    -Detail ("Removal pass threw: {0}. Continuing to install." -f $_.Exception.Message) @logTarget
            }

            $afterRemoval = Get-OfficeConfiguration
            $afterProducts = if ($null -eq $afterRemoval) { '<none>' } else { $afterRemoval.ProductReleaseIds -join ',' }
            Write-ODTLog -Message ("Products present after removal pass: [{0}]." -f $afterProducts) @logTarget
        }
    }

    $configPath = Resolve-ODTConfigurationPath -ConfigurationFile $ConfigurationFile -ConfigurationURL $ConfigurationURL
    Write-ODTPhase -Phase 'ConfigResolved' -Detail $configPath @logTarget

    # Enumerate the languages declared in the staged XML and log them before
    # launching setup.exe, so admins can correlate "this device installed in
    # nb-no" without grepping the configuration file. Tolerant of malformed
    # XML: the install proceeds, with a severity-2 fallback line.
    try {
        [xml]$configDoc = Get-Content -LiteralPath $configPath -Raw
        $langNodes = $configDoc.SelectNodes('//Language')
        $langIds = @()
        foreach ($node in $langNodes) {
            $id = $node.GetAttribute('ID')
            if (-not [string]::IsNullOrWhiteSpace($id)) { $langIds += $id }
        }
        $langIds = @($langIds | Select-Object -Unique)
        if ($langIds.Count -gt 0) {
            Write-ODTLog -Message ("Installing M365 Apps with languages: {0}." -f ($langIds -join ', ')) -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
        } else {
            Write-ODTLog -Message 'Installing M365 Apps with languages: <none declared in XML>.' -Severity 2 -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
        }
    }
    catch {
        Write-ODTLog -Message ("Could not enumerate languages from staged XML ({0}); install will proceed using whatever the XML declares." -f $_.Exception.Message) -Severity 2 -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
    }

    Write-ODTPhase -Phase 'SetupStart' -Detail 'Starting setup.exe /configure.' @logTarget
    $result = Invoke-ODTSetup -SetupExePath $setupPath -ConfigurationPath $configPath `
                              -ProgressIntervalSeconds $ProgressIntervalSeconds `
                              -ProgressCallback $progressCallback

    $severity = if ($result.Success) { 1 } else { 3 }
    Write-ODTPhase -Phase 'SetupEnd' -Severity $severity `
        -Detail ("exit {0} after {1}s. {2}" -f $result.ExitCode, $result.DurationSeconds, $result.Message) @logTarget
    Write-ODTLog -Message ("setup.exe exit: {0} ({1}s). {2}" -f $result.ExitCode, $result.DurationSeconds, $result.Message) -Severity $severity @logTarget

    # Where the time actually went, from the samples taken during the run.
    # Resolution is one sampling interval - use -ProgressIntervalSeconds 15
    # when this is the question being investigated.
    $phaseSummary = @($result.PhaseSummary)
    if ($phaseSummary.Count -gt 0) {
        $phaseText = ($phaseSummary | ForEach-Object { '{0} {1}-{2}s ({3}s)' -f $_.Task, $_.FirstSeenSeconds, $_.LastSeenSeconds, $_.DurationSeconds }) -join ' | '
        Write-ODTLog -Message ("C2R phase summary: {0}" -f $phaseText) @logTarget
    }

    $disabledSamplers = @($result.DisabledSamplers)
    if ($disabledSamplers.Count -gt 0) {
        $disabledText = ($disabledSamplers | ForEach-Object { '{0} ({1})' -f $_.Name, $_.Reason }) -join '; '
        Write-ODTLog -Message ("Progress samplers disabled during this run: {0}" -f $disabledText) -Severity 2 @logTarget
    }

    if (-not $result.Success) {
        $exit = $result.ExitCode
        $summary = ("Install failed: {0}" -f $result.Message)
        throw $summary
    }

    # Post-install verification: setup.exe has been known to return 0 even
    # when the product was not actually installed. Cross-check the registry
    # via Test-ProductInstalled (which uses the Registry64 helpers — see
    # rule #3 in docs/architecture.md).
    Write-ODTPhase -Phase 'RegistryVerifyStart' -Detail ("Verifying {0} installation in the registry." -f $ProductId) @logTarget
    if (-not (Test-ProductInstalled -ProductId $ProductId)) {
        $exit = 17002
        $summary = "setup.exe returned 0 but $ProductId is not present in ClickToRun\Configuration. Treating as silent failure."
        Write-ODTLog -Message $summary -Severity 3 -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
        throw $summary
    }

    Write-ODTPhase -Phase 'RegistryVerifyEnd' @logTarget

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
    Write-ODTLog -Message ("Unhandled error: {0}`nLine: {1}" -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber) -Severity 3 @logTarget
}
finally {
    # Click-to-Run's own download/apply timings, read from the registry - no
    # log files are collected or redirected. Ground truth where the sampler's
    # phase summary is a one-interval approximation, but only populated for
    # update-shaped runs, so an absent result is unremarkable.
    #
    # Guarded on $result because a prerequisite failure throws before it is
    # ever assigned. Runs on the failure path too: that is when it matters.
    if ($null -ne $result) {
        try {
            $c2rTimeline = Get-ODTC2RPhaseTimeline -SinceUtc $result.StartedUtc
            if ($null -ne $c2rTimeline) {
                $timelineText = (@($c2rTimeline) | ForEach-Object { '{0} {1}s' -f $_.Phase, $_.DurationSeconds }) -join ' | '
                Write-ODTLog -Message ("C2R reported timings: {0}" -f $timelineText) @logTarget
            }
        }
        catch {
            Write-ODTLog -Message ("Could not read C2R phase timings: {0}" -f $_.Exception.Message) -Severity 2 @logTarget
        }
    }

    Write-ODTPhase -Phase 'Done' -Detail ("exit {0}" -f $exit) @logTarget
    Stop-ODTLogSession -ScriptName $ScriptName -ExitCode $exit -Message $summary -LogFile $LogFile -LogPath $LogPath
}

exit $exit
