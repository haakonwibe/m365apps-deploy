#Requires -Version 5.1
<#
.SYNOPSIS
    CMTrace-compatible logging for the M365 Apps Deployment toolkit.

.DESCRIPTION
    Provides a consistent, rotating, CMTrace-readable log stream for every
    install / uninstall / detection script in the toolkit.

    Log lines use the ConfigMgr CMTrace format so SCCM-familiar admins can
    open the files in CMTrace.exe (or CMTrace Viewer) and get coloured,
    component-separated output. Plain-text readers also work.

    All logs default to:
        C:\ProgramData\M365AppsDeploy\Logs\

    The module exposes three functions:
        Write-ODTLog           - append a single CMTrace line
        Start-ODTLogSession    - write a header block with script + env info
        Stop-ODTLogSession     - write a footer with duration + exit state

.NOTES
    Module   : ODTLogging
    Project  : m365apps-deploy
    Version  : <see Common/ODTVersion.psm1>
    See CHANGELOG.md for version history.
#>

Set-StrictMode -Version Latest

$script:ODTDefaultLogRoot   = 'C:\ProgramData\M365AppsDeploy\Logs'
$script:ODTDefaultLogFile   = 'M365AppsDeploy.log'
$script:ODTMaxLogBytes      = 10MB
$script:ODTSessionStartTime = @{}

function Get-ODTCurrentUserContext {
    [CmdletBinding()]
    param()

    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        if ($identity.IsSystem) { return 'SYSTEM' }
        return $identity.Name
    }
    catch {
        return 'Unknown'
    }
}

function Initialize-ODTLogDirectory {
<#
.SYNOPSIS
    Ensure the log directory exists with permissions usable by SYSTEM and admins.

.PARAMETER Path
    Directory to create. Created recursively if missing.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        try {
            $null = New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop
        }
        catch [System.UnauthorizedAccessException] {
            throw "ODTLogging: unable to create log directory '$Path' (access denied). Run as SYSTEM or local administrator."
        }
    }
}

function Invoke-ODTLogRotation {
<#
.SYNOPSIS
    Rotate a log file in place when it exceeds the max size.

.DESCRIPTION
    If the file is larger than the configured threshold, rename it to
    `<name>.old` (overwriting any previous .old) and let the caller start
    fresh on the next write.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [long] $MaxBytes = $script:ODTMaxLogBytes
    )

    if (-not (Test-Path -LiteralPath $Path)) { return }

    try {
        $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    }
    catch {
        return
    }

    if ($file.Length -lt $MaxBytes) { return }

    $oldPath = "$Path.old"
    try {
        if (Test-Path -LiteralPath $oldPath) {
            Remove-Item -LiteralPath $oldPath -Force -ErrorAction Stop
        }
        Move-Item -LiteralPath $Path -Destination $oldPath -Force -ErrorAction Stop
    }
    catch {
        # Rotation is best-effort; swallow so the actual log write still runs.
    }
}

function Resolve-ODTLogFilePath {
    [CmdletBinding()]
    param(
        [string] $LogFile,
        [string] $LogPath
    )

    if ([string]::IsNullOrWhiteSpace($LogPath)) {
        $LogPath = $script:ODTDefaultLogRoot
    }

    if ([string]::IsNullOrWhiteSpace($LogFile)) {
        $LogFile = $script:ODTDefaultLogFile
    }

    # If caller passed a full path as -LogFile, honour it.
    if ([System.IO.Path]::IsPathRooted($LogFile)) {
        return $LogFile
    }

    return (Join-Path -Path $LogPath -ChildPath $LogFile)
}

function Write-ODTLog {
<#
.SYNOPSIS
    Append a CMTrace-compatible line to the toolkit log.

.PARAMETER Message
    The message to log. Multi-line messages are split into one CMTrace line
    per source line so CMTrace renders each independently.

.PARAMETER Severity
    CMTrace severity: 1 = Info, 2 = Warning, 3 = Error. Default 1.

.PARAMETER Component
    CMTrace component field. Defaults to the calling script's base name.

.PARAMETER LogFile
    Log file name (e.g. 'M365Apps-Install.log') or a full path. Defaults to
    the toolkit-wide log.

.PARAMETER LogPath
    Directory to place the log in. Ignored when -LogFile is a full path.
    Defaults to C:\ProgramData\M365AppsDeploy\Logs.

.EXAMPLE
    Write-ODTLog -Message 'Install completed.' -Component 'Install-M365Apps' -LogFile 'M365Apps-Install.log'

.EXAMPLE
    Write-ODTLog -Message 'Exit code 17002' -Severity 3
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyString()]
        [string] $Message,

        [ValidateSet(1, 2, 3)]
        [int] $Severity = 1,

        [string] $Component,

        [string] $LogFile,

        [string] $LogPath
    )

    begin {
        if ([string]::IsNullOrWhiteSpace($Component)) {
            $invocation = Get-PSCallStack | Select-Object -Skip 1 -First 1
            if ($null -ne $invocation -and $invocation.ScriptName) {
                $Component = [System.IO.Path]::GetFileNameWithoutExtension($invocation.ScriptName)
            }
            else {
                $Component = 'M365AppsDeploy'
            }
        }

        $fullLogPath = Resolve-ODTLogFilePath -LogFile $LogFile -LogPath $LogPath
        $dir = Split-Path -Path $fullLogPath -Parent
        Initialize-ODTLogDirectory -Path $dir
        Invoke-ODTLogRotation -Path $fullLogPath

        $user       = Get-ODTCurrentUserContext
        $processId  = $PID
        $callerInfo = Get-PSCallStack | Select-Object -Skip 1 -First 1
        $callerFile = if ($callerInfo -and $callerInfo.ScriptName) {
            '{0}:{1}' -f (Split-Path -Path $callerInfo.ScriptName -Leaf), $callerInfo.ScriptLineNumber
        }
        else {
            'interactive:0'
        }
    }

    process {
        if ($null -eq $Message) { $Message = '' }

        # CMTrace renders one line per entry; split multi-line messages so each
        # wraps correctly in the viewer.
        $lines = $Message -split "`r`n|`n|`r"

        foreach ($line in $lines) {
            $now         = Get-Date
            $timePart    = $now.ToString('HH:mm:ss.fff')
            $utcOffset   = [System.TimeZoneInfo]::Local.GetUtcOffset($now).TotalMinutes
            $bias        = '{0:+#;-#;+0}' -f [int]$utcOffset
            $timeWithBias = "$timePart$bias"
            $datePart    = $now.ToString('MM-dd-yyyy')

            $logLine = '<![LOG[{0}]LOG]!><time="{1}" date="{2}" component="{3}" context="{4}" type="{5}" thread="{6}" file="{7}">' -f `
                $line, $timeWithBias, $datePart, $Component, $user, $Severity, $processId, $callerFile

            try {
                Add-Content -LiteralPath $fullLogPath -Value $logLine -Encoding UTF8 -ErrorAction Stop
            }
            catch {
                # Fall back to verbose stream rather than throwing. Logging must never
                # break the install, but operators should still see the problem in -Verbose.
                Write-Verbose "ODTLogging: failed to write to '$fullLogPath': $($_.Exception.Message)"
            }
        }
    }
}

function Start-ODTLogSession {
<#
.SYNOPSIS
    Write a session header to a toolkit log file.

.DESCRIPTION
    Records script name, version, parameter values, OS info, user context,
    and starts a stopwatch keyed by log file so Stop-ODTLogSession can compute
    duration.

.PARAMETER ScriptName
    Logical script name for the header and for default Component field.

.PARAMETER ScriptVersion
    Version of the calling script (free-form string).

.PARAMETER Parameters
    Hashtable of parameters the caller was invoked with. Values are
    shallow-stringified; do not pass secrets.

.PARAMETER LogFile
    Log file name or full path.

.PARAMETER LogPath
    Directory for the log.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ScriptName,

        [string] $ScriptVersion = '<unknown>',

        [hashtable] $Parameters,

        [string] $LogFile,

        [string] $LogPath
    )

    $fullLogPath = Resolve-ODTLogFilePath -LogFile $LogFile -LogPath $LogPath
    $script:ODTSessionStartTime[$fullLogPath] = Get-Date

    $os = try {
        (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop)
    }
    catch { $null }

    $header = @()
    $header += '==============================================================================='
    $header += ("Start of session: {0}" -f $ScriptName)
    $header += ("Script version : {0}" -f $ScriptVersion)
    $header += ("Toolkit        : m365apps-deploy")
    $header += ("Started (UTC)  : {0}" -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))
    $header += ("User context   : {0}" -f (Get-ODTCurrentUserContext))
    $header += ("PowerShell     : {0}" -f $PSVersionTable.PSVersion)
    $header += ("Process ID     : {0}" -f $PID)
    $header += ("Computer name  : {0}" -f $env:COMPUTERNAME)
    if ($null -ne $os) {
        $header += ("OS             : {0} ({1})" -f $os.Caption, $os.Version)
    }
    if ($PSBoundParameters.ContainsKey('Parameters') -and $Parameters -and $Parameters.Count -gt 0) {
        $header += 'Parameters     :'
        foreach ($key in ($Parameters.Keys | Sort-Object)) {
            $value = $Parameters[$key]
            if ($null -eq $value) { $valueText = '<null>' }
            elseif ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
                $valueText = ($value | ForEach-Object { $_.ToString() }) -join ', '
            }
            else { $valueText = $value.ToString() }
            $header += ("  - {0} = {1}" -f $key, $valueText)
        }
    }
    $header += '==============================================================================='

    foreach ($line in $header) {
        Write-ODTLog -Message $line -Severity 1 -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
    }
}

function Stop-ODTLogSession {
<#
.SYNOPSIS
    Write a session footer capturing duration and exit state.

.PARAMETER ScriptName
    Same logical script name passed to Start-ODTLogSession.

.PARAMETER ExitCode
    Numeric exit code or status (0 = success).

.PARAMETER Message
    Optional additional context (e.g. 'Install succeeded', 'ODT returned 17002').

.PARAMETER LogFile
    Log file name or full path.

.PARAMETER LogPath
    Directory for the log.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ScriptName,

        [int] $ExitCode = 0,

        [string] $Message,

        [string] $LogFile,

        [string] $LogPath
    )

    $fullLogPath = Resolve-ODTLogFilePath -LogFile $LogFile -LogPath $LogPath
    $start = $script:ODTSessionStartTime[$fullLogPath]
    $durationText = if ($start) {
        $span = (Get-Date) - $start
        ('{0:00}:{1:00}:{2:00}.{3:000}' -f $span.Hours, $span.Minutes, $span.Seconds, $span.Milliseconds)
    }
    else { 'unknown' }

    # Derive the Result line from the authoritative exit code rather than
    # trusting the caller's -Message. Install/Uninstall scripts initialise
    # a $summary like 'Install succeeded.' and only update it on the happy
    # path - if an exception throws before the update, $summary stays stale
    # and the old footer was reporting "Install succeeded" for a 1603 exit.
    # See Get-ODTExitCodeResult (ODTInvoke.psm1) for the canonical public
    # mapping; the switch below is kept local so ODTLogging has no
    # cross-module dependency.
    $resultDescription = switch ($ExitCode) {
        0     { 'Success.' }
        3010  { 'Success, reboot required.' }
        1641  { 'Success, reboot initiated.' }
        1603  { 'Failed (generic install failure).' }
        1618  { 'Failed (another install in progress).' }
        17002 { 'Failed (ODT reported failure).' }
        default { "Failed (exit code $ExitCode)." }
    }
    $severity = if ($ExitCode -in 0, 3010, 1641) { 1 } else { 3 }

    $footer = @()
    $footer += '-------------------------------------------------------------------------------'
    $footer += ("End of session : {0}" -f $ScriptName)
    $footer += ("Exit code      : {0}" -f $ExitCode)
    $footer += ("Result         : {0}" -f $resultDescription)
    if ($PSBoundParameters.ContainsKey('Message') -and $Message) {
        # Caller-supplied context (e.g. 'Install succeeded.' or
        # 'Prerequisite checks failed: ...'). Kept separate from Result so
        # it is obvious which field is authoritative.
        $footer += ("Detail         : {0}" -f $Message)
    }
    $footer += ("Duration       : {0}" -f $durationText)
    $footer += ("Stopped (UTC)  : {0}" -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))
    $footer += '==============================================================================='

    foreach ($line in $footer) {
        Write-ODTLog -Message $line -Severity $severity -Component $ScriptName -LogFile $LogFile -LogPath $LogPath
    }

    if ($start) {
        $script:ODTSessionStartTime.Remove($fullLogPath) | Out-Null
    }
}

Export-ModuleMember -Function @(
    'Write-ODTLog',
    'Start-ODTLogSession',
    'Stop-ODTLogSession',
    'Initialize-ODTLogDirectory',
    'Resolve-ODTLogFilePath'
)
