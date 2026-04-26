#Requires -Version 5.1
<#
.SYNOPSIS
    Shared primitives for every install / uninstall entry point.

.DESCRIPTION
    This module is not part of the original spec's Common/ list - the spec
    only names ODTLogging, ODTPrerequisites, ODTOfficeState. It is included
    because every Install-*.ps1 and Uninstall-*.ps1 script in this toolkit
    performs the same sequence: resolve configuration, fetch/prepare
    setup.exe, run setup.exe /configure, interpret the exit code.
    Collecting that into one module eliminates a lot of duplication and
    keeps exit-code handling uniform.

    We do NOT inject an ODT <Logging> element into configuration XMLs.
    ODT's native redirection via that element is unreliable on modern
    builds and the output is too verbose to be useful day-to-day. If
    deep ODT debugging is needed, ODT writes native logs to %TEMP% by
    default - see docs/troubleshooting.md.

    If you are adapting this spec to an environment where you want the
    entire flow inside each Install-*.ps1, you can inline these functions
    there instead - the module is a convenience, not a design requirement.

    Functions exported:
        Resolve-ODTConfigurationPath   - local file / URL / default fallback
        Resolve-ODTSetupPath           - bundled / evergreen download
        Invoke-ODTSetup                - run setup.exe and interpret exit code
        Get-ODTExitCodeMessage         - translate numeric exit codes to text
        Get-ODTExitCodeResult          - structured Success/Failed classification

.NOTES
    Module  : ODTInvoke
    Project : m365apps-deploy
    Version : 1.0.0
#>

Set-StrictMode -Version Latest

$script:ODTEvergreenUrl = 'https://officecdn.microsoft.com/pr/wsus/setup.exe'

$script:KnownExitCodes = @{
    0     = 'Success.'
    1602  = 'User cancelled the install.'
    1603  = 'Fatal install failure (generic). Inspect ODT logs for root cause.'
    1618  = 'Another installation is already in progress. Wait and retry.'
    1641  = 'Install succeeded and a reboot was initiated.'
    3010  = 'Install succeeded; a reboot is required to complete.'
    17000 = 'Office Deployment Tool failed to start.'
    17001 = 'ODT failed to parse configuration.xml.'
    17002 = 'ODT reported a failure during install/uninstall. Inspect the ODT log for details.'
    17003 = 'ODT installation queued but could not run. Check network to Office CDN.'
    17004 = 'Unknown ODT exit state.'
}

function Get-ODTExitCodeMessage {
<#
.SYNOPSIS
    Return a long-form diagnostic message for a known setup.exe / MSI
    exit code. Used by Invoke-ODTSetup for log output.

.PARAMETER ExitCode
    Numeric exit code returned by setup.exe or Start-Process.

.OUTPUTS
    [string] - description. Unknown codes return a generic placeholder.

.SEE ALSO
    Get-ODTExitCodeResult - returns a structured result with a concise
    Success / Failed description suitable for summary lines.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [int] $ExitCode
    )

    if ($script:KnownExitCodes.ContainsKey($ExitCode)) {
        return $script:KnownExitCodes[$ExitCode]
    }
    return ("Exit code {0}: no known description. Inspect ODT logs in C:\ProgramData\M365AppsDeploy\Logs\ODT\." -f $ExitCode)
}

function Get-ODTExitCodeResult {
<#
.SYNOPSIS
    Classify a toolkit exit code as Success / Failed and return a concise
    description suitable for summary lines (log footers, telemetry, UI).

.DESCRIPTION
    Complements Get-ODTExitCodeMessage (long-form diagnostics). This
    function returns a structured result with three fields:

        ExitCode    [int]
        Succeeded   [bool]   - $true for 0, 3010, 1641; $false otherwise
        Description [string] - concise Success/Failed phrase

    Callers that need the legacy long-form text should keep using
    Get-ODTExitCodeMessage.

.PARAMETER ExitCode
    Numeric exit code.

.OUTPUTS
    [pscustomobject] with ExitCode, Succeeded, Description.

.EXAMPLE
    Get-ODTExitCodeResult -ExitCode 0
    # Succeeded = $true, Description = 'Success.'

.EXAMPLE
    Get-ODTExitCodeResult -ExitCode 1603
    # Succeeded = $false, Description = 'Failed (generic install failure).'

.EXAMPLE
    Get-ODTExitCodeResult -ExitCode 424242
    # Succeeded = $false, Description = 'Failed (exit code 424242).'
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [int] $ExitCode
    )

    switch ($ExitCode) {
        0     { $succeeded = $true;  $description = 'Success.' ; break }
        3010  { $succeeded = $true;  $description = 'Success, reboot required.' ; break }
        1641  { $succeeded = $true;  $description = 'Success, reboot initiated.' ; break }
        1603  { $succeeded = $false; $description = 'Failed (generic install failure).' ; break }
        1618  { $succeeded = $false; $description = 'Failed (another install in progress).' ; break }
        17002 { $succeeded = $false; $description = 'Failed (ODT reported failure).' ; break }
        default {
            $succeeded   = $false
            $description = "Failed (exit code $ExitCode)."
        }
    }

    [pscustomobject]@{
        ExitCode    = $ExitCode
        Succeeded   = $succeeded
        Description = $description
    }
}

function Resolve-ODTConfigurationPath {
<#
.SYNOPSIS
    Materialise a configuration XML path from a local file, URL, or default.

.DESCRIPTION
    Precedence: -ConfigurationURL wins if supplied. Otherwise -ConfigurationFile.
    If neither resolves to a file we fail with a clear error.

.PARAMETER ConfigurationFile
    Path to a local XML file.

.PARAMETER ConfigurationURL
    HTTPS URL to fetch an XML from at runtime.

.PARAMETER WorkingDirectory
    Folder to write fetched XML into. Defaults to $env:TEMP.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string] $ConfigurationFile,

        [string] $ConfigurationURL,

        [string] $WorkingDirectory = $env:TEMP
    )

    if (-not [string]::IsNullOrWhiteSpace($ConfigurationURL)) {
        if (-not ($ConfigurationURL -match '^https://')) {
            throw "Resolve-ODTConfigurationPath: -ConfigurationURL must be HTTPS. Got '$ConfigurationURL'."
        }
        $leaf = [System.IO.Path]::GetFileName(([Uri]$ConfigurationURL).AbsolutePath)
        if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = 'configuration.xml' }
        $destination = Join-Path -Path $WorkingDirectory -ChildPath ("odt-$(Get-Random)-$leaf")

        $attempt = 0
        $maxAttempts = 3
        while ($true) {
            $attempt++
            try {
                Invoke-WebRequest -Uri $ConfigurationURL -OutFile $destination -UseBasicParsing -ErrorAction Stop
                break
            }
            catch {
                if ($attempt -ge $maxAttempts) {
                    throw "Resolve-ODTConfigurationPath: failed to download '$ConfigurationURL' after $maxAttempts attempts: $($_.Exception.Message)"
                }
                Start-Sleep -Seconds ([math]::Pow(2, $attempt))
            }
        }
        return $destination
    }

    if ([string]::IsNullOrWhiteSpace($ConfigurationFile)) {
        throw "Resolve-ODTConfigurationPath: neither -ConfigurationFile nor -ConfigurationURL was supplied."
    }

    if (-not (Test-Path -LiteralPath $ConfigurationFile -PathType Leaf)) {
        throw "Resolve-ODTConfigurationPath: configuration file '$ConfigurationFile' not found."
    }
    return (Resolve-Path -LiteralPath $ConfigurationFile).ProviderPath
}

function Resolve-ODTSetupPath {
<#
.SYNOPSIS
    Locate setup.exe (bundled) or fetch an evergreen copy from Microsoft.

.PARAMETER SetupExePath
    Absolute path to a bundled setup.exe.

.PARAMETER UseEvergreen
    Download a fresh ODT from Microsoft's CDN to %TEMP% and use that.

.PARAMETER WorkingDirectory
    Where to cache a downloaded setup.exe.

.OUTPUTS
    [string] - absolute path to an executable setup.exe.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string] $SetupExePath,

        [switch] $UseEvergreen,

        [string] $WorkingDirectory = $env:TEMP
    )

    if ($UseEvergreen) {
        $destDir  = Join-Path -Path $WorkingDirectory -ChildPath ("odt-evergreen-$(Get-Random)")
        $destFile = Join-Path -Path $destDir -ChildPath 'setup.exe'
        $null = New-Item -Path $destDir -ItemType Directory -Force -ErrorAction Stop

        $attempt = 0
        $maxAttempts = 3
        while ($true) {
            $attempt++
            try {
                Invoke-WebRequest -Uri $script:ODTEvergreenUrl -OutFile $destFile -UseBasicParsing -ErrorAction Stop
                break
            }
            catch {
                if ($attempt -ge $maxAttempts) {
                    throw "Resolve-ODTSetupPath: failed to download evergreen ODT from '$($script:ODTEvergreenUrl)' after $maxAttempts attempts: $($_.Exception.Message)"
                }
                Start-Sleep -Seconds ([math]::Pow(2, $attempt))
            }
        }

        if (-not (Test-Path -LiteralPath $destFile -PathType Leaf)) {
            throw "Resolve-ODTSetupPath: evergreen download completed but setup.exe not present at '$destFile'."
        }
        return $destFile
    }

    if ([string]::IsNullOrWhiteSpace($SetupExePath)) {
        throw "Resolve-ODTSetupPath: -SetupExePath is required unless -UseEvergreen is set."
    }
    if (-not (Test-Path -LiteralPath $SetupExePath -PathType Leaf)) {
        throw "Resolve-ODTSetupPath: setup.exe not found at '$SetupExePath'. Download the Office Deployment Tool from Microsoft Download Center and place setup.exe in the product's Tools\ folder, or pass -UseEvergreenSetup."
    }
    return (Resolve-Path -LiteralPath $SetupExePath).ProviderPath
}

function Invoke-ODTSetup {
<#
.SYNOPSIS
    Run setup.exe /configure against a prepared configuration XML and return
    a structured result.

.PARAMETER SetupExePath
    Absolute path to setup.exe.

.PARAMETER ConfigurationPath
    Absolute path to a configuration.xml.

.PARAMETER TimeoutMinutes
    How long to wait for the process to exit before giving up. Defaults to
    60 minutes, which covers realistic install + download times.

.OUTPUTS
    PSCustomObject with ExitCode, DurationSeconds, Success, Message.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $SetupExePath,

        [Parameter(Mandatory)]
        [string] $ConfigurationPath,

        [ValidateRange(5, 240)]
        [int] $TimeoutMinutes = 60
    )

    $argumentList = @('/configure', ('"{0}"' -f $ConfigurationPath))

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $process = Start-Process -FilePath $SetupExePath -ArgumentList $argumentList -PassThru -WindowStyle Hidden
    if (-not $process.WaitForExit([int]($TimeoutMinutes * 60 * 1000))) {
        try { $process.Kill() } catch { }
        $stopwatch.Stop()
        return [pscustomobject]@{
            ExitCode        = -1
            DurationSeconds = [int]$stopwatch.Elapsed.TotalSeconds
            Success         = $false
            Message         = "Invoke-ODTSetup: setup.exe did not exit within $TimeoutMinutes minutes and was terminated."
        }
    }
    $stopwatch.Stop()

    $exit = $process.ExitCode
    $success = ($exit -eq 0 -or $exit -eq 3010 -or $exit -eq 1641)

    [pscustomobject]@{
        ExitCode        = $exit
        DurationSeconds = [int]$stopwatch.Elapsed.TotalSeconds
        Success         = [bool]$success
        Message         = Get-ODTExitCodeMessage -ExitCode $exit
    }
}

Export-ModuleMember -Function @(
    'Get-ODTExitCodeMessage',
    'Get-ODTExitCodeResult',
    'Resolve-ODTConfigurationPath',
    'Resolve-ODTSetupPath',
    'Invoke-ODTSetup'
)
