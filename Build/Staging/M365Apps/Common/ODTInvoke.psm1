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
        Invoke-ODTSetup                - run setup.exe, sample progress while
                                         it runs, and interpret the exit code
        Get-ODTC2RPhaseTimeline        - C2R's own download/apply timings
        Get-ODTExitCodeMessage         - translate numeric exit codes to text
        Get-ODTExitCodeResult          - structured Success/Failed classification

    Invoke-ODTSetup samples the machine while setup.exe runs and hands each
    sample to an optional -ProgressCallback scriptblock. That indirection is
    deliberate: Common/*.psm1 has no cross-module dependencies, so this module
    must not import ODTLogging, and a scriptblock authored in the calling
    script runs in the caller's session state where Write-ODTLog is in scope.
    See docs/architecture.md, "In-flight install progress sampling".

.NOTES
    Module  : ODTInvoke
    Project : m365apps-deploy
    Version : <see Common/ODTVersion.psm1>
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

# --------------------------------------------------------------------------
# Private helpers for in-flight progress sampling.
#
# None of these are exported. They exist so a long setup.exe run is readable
# as a timeline instead of a single duration number: while setup.exe streams
# ~2.8 GB from the Office CDN we sample the Click-to-Run scenario state, the
# C2R processes, machine-wide network receive, and system-drive free space,
# and emit one CMTrace line per interval via the caller's -ProgressCallback.
#
# Two rules govern everything below:
#   1. A sampler must never break or delay the install. Every one is wrapped
#      by Invoke-ODTSafeSampler, which catches, budgets, and permanently
#      disables a misbehaving sampler for the rest of the run.
#   2. Under Set-StrictMode -Version Latest, reading a property that does not
#      exist on a pscustomobject throws. Sample objects are therefore built
#      with every field present, never with a conditional Add-Member.
# --------------------------------------------------------------------------

# Registry reads go through the Registry64 view because IME is a 32-bit
# process and default HKLM:\SOFTWARE access is redirected to WOW6432Node,
# where the C2R keys do not exist. See docs/architecture.md rule #3.
# Duplicated from ODTOfficeState.psm1 on purpose: Common/*.psm1 has no
# cross-module dependencies, and this module must stay importable alone.
function Get-ODTReg64Values {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $baseKey = $null
    $subKey  = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64)
        $subKey = $baseKey.OpenSubKey($Path)
        if ($null -eq $subKey) { return $null }

        $values = @{}
        foreach ($name in $subKey.GetValueNames()) {
            $values[$name] = $subKey.GetValue($name)
        }
        return $values
    }
    catch { return $null }
    finally {
        if ($subKey)  { $subKey.Dispose() }
        if ($baseKey) { $baseKey.Dispose() }
    }
}

# Returns value names in enumeration order alongside the name -> data map.
# Order happens to be chronological for C2R task states, which makes the
# "last task" hint readable - but correctness never depends on it, see
# ConvertTo-ODTScenarioState.
function Get-ODTReg64OrderedValues {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $baseKey = $null
    $subKey  = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64)
        $subKey = $baseKey.OpenSubKey($Path)
        if ($null -eq $subKey) { return $null }

        $names  = @($subKey.GetValueNames())
        $states = @{}
        foreach ($name in $names) { $states[$name] = [string]$subKey.GetValue($name) }

        return [pscustomobject]@{
            ValueNames = $names
            States     = $states
        }
    }
    catch { return $null }
    finally {
        if ($subKey)  { $subKey.Dispose() }
        if ($baseKey) { $baseKey.Dispose() }
    }
}

function Get-ODTReg64SubKeyNames {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $baseKey = $null
    $subKey  = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64)
        $subKey = $baseKey.OpenSubKey($Path)
        if ($null -eq $subKey) { return @() }
        return @($subKey.GetSubKeyNames())
    }
    catch { return @() }
    finally {
        if ($subKey)  { $subKey.Dispose() }
        if ($baseKey) { $baseKey.Dispose() }
    }
}

function ConvertTo-ODTScenarioState {
<#
.SYNOPSIS
    Reduce a C2R scenario TasksState value set to "which task is running".

.DESCRIPTION
    Pure function - no registry, no I/O - so the interesting logic is
    unit-testable against captured data.

    A C2R scenario key (HKLM\SOFTWARE\Microsoft\Office\ClickToRun\Scenario\
    <NAME>\TasksState) holds one REG_SZ per pipeline task, named
    "<TASKNAME>:{GUID}", whose data is a TASKSTATE_* string. For the INSTALL
    scenario the task list runs roughly CREATEWORKINGCONFIGURATION -> STREAM
    (the CDN download, and the long pole) -> STAGEREGISTRY ->
    APPLYCONFIGURATION -> INTEGRATE_INSTALL.

    The active task is determined as "not TASKSTATE_COMPLETED", which is
    order-independent and therefore correct even though value enumeration
    order is not a documented contract.

.PARAMETER ValueNames
    Value names as enumerated from the key, e.g. 'STREAM:{GUID}'.

.PARAMETER States
    Map of value name -> TASKSTATE_* string.

.OUTPUTS
    [pscustomobject] with Active, Completed, Total, LastName.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [string[]] $ValueNames,

        [AllowNull()]
        [hashtable] $States
    )

    $names = @()
    if ($null -ne $ValueNames) { $names = @($ValueNames) }
    $map = if ($null -eq $States) { @{} } else { $States }

    $active    = $null
    $completed = 0
    $lastName  = $null

    foreach ($name in $names) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        # 'STREAM:{4A5B...}' -> 'STREAM'. A name without a colon is used whole.
        $taskName = ($name -split ':', 2)[0]
        $lastName = $taskName

        $state = [string]$map[$name]
        if ($state -eq 'TASKSTATE_COMPLETED') {
            $completed++
        }
        elseif ($null -eq $active) {
            # First non-completed task wins. If several are outstanding the
            # earliest-enumerated is the best available guess, and the counts
            # still tell the reader how far through the pipeline we are.
            $active = $taskName
        }
    }

    return [pscustomobject]@{
        Active    = $active
        Completed = [int]$completed
        Total     = [int]$names.Count
        LastName  = $lastName
    }
}

function Get-ODTC2RScenarioSnapshot {
<#
.SYNOPSIS
    Read the live Click-to-Run scenario state.

.DESCRIPTION
    LastScenario names the scenario C2R is running (INSTALL, UPDATE,
    UPDATEONLYAPPLY, ...). We read that scenario's TasksState first. If it
    reports everything completed - which happens when LastScenario is stale,
    for instance early in a run before C2R switches it - we scan the other
    scenarios and prefer one with work outstanding.

    On a device with no Office at all the ClickToRun key does not exist yet;
    Scenario is then '<key-absent>', which is itself the signal that setup.exe
    is still bootstrapping the C2R client rather than streaming payload.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $result = [pscustomobject]@{
        Scenario  = '<key-absent>'
        Active    = $null
        Completed = 0
        Total     = 0
        Version   = $null
    }

    $root = Get-ODTReg64Values -Path 'SOFTWARE\Microsoft\Office\ClickToRun'
    if ($null -eq $root) { return $result }

    $result.Scenario = '<unknown>'

    $config = Get-ODTReg64Values -Path 'SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    if ($null -ne $config -and $null -ne $config['VersionToReport']) {
        $result.Version = [string]$config['VersionToReport']
    }

    $candidates = @()
    $lastScenario = [string]$root['LastScenario']
    if (-not [string]::IsNullOrWhiteSpace($lastScenario)) { $candidates += $lastScenario }
    foreach ($name in (Get-ODTReg64SubKeyNames -Path 'SOFTWARE\Microsoft\Office\ClickToRun\Scenario')) {
        if ($name -notin $candidates) { $candidates += $name }
    }

    $firstSeen = $null
    foreach ($scenario in $candidates) {
        $tasksPath = 'SOFTWARE\Microsoft\Office\ClickToRun\Scenario\{0}\TasksState' -f $scenario
        $tasks = Get-ODTReg64OrderedValues -Path $tasksPath
        if ($null -eq $tasks) { continue }

        $state = ConvertTo-ODTScenarioState -ValueNames $tasks.ValueNames -States $tasks.States
        if ($null -eq $firstSeen) {
            $firstSeen = [pscustomobject]@{ Scenario = $scenario; State = $state }
        }
        if ($null -ne $state.Active) {
            # A scenario with outstanding work is the one actually running.
            $result.Scenario  = $scenario
            $result.Active    = $state.Active
            $result.Completed = $state.Completed
            $result.Total     = $state.Total
            return $result
        }
    }

    if ($null -ne $firstSeen) {
        $result.Scenario  = $firstSeen.Scenario
        $result.Active    = $firstSeen.State.Active
        $result.Completed = $firstSeen.State.Completed
        $result.Total     = $firstSeen.State.Total
    }

    return $result
}

function Get-ODTProcessSnapshot {
<#
.SYNOPSIS
    CPU, working set and IO counters for setup.exe and the C2R processes.

.DESCRIPTION
    Win32_Process rather than Get-Process, for two measured reasons:
    Get-Process exposes no IO counters at all, and its .CPU property returns
    $null *silently* for a service-hosted process such as OfficeClickToRun,
    which makes any arithmetic on it throw. Win32_Process is PID-keyed,
    locale-invariant, and a process that exits between samples simply stops
    appearing rather than raising.

    Costs roughly a second, which is irrelevant here: the sampling loop waits
    on setup.exe itself, so sampler time is never added to install time.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param()

    $filter = "Name='setup.exe' OR Name='OfficeClickToRun.exe' OR Name='OfficeC2RClient.exe' OR Name='Integrator.exe'"
    $rows = @(Get-CimInstance -ClassName Win32_Process -Filter $filter -ErrorAction Stop)

    $out = @()
    foreach ($row in $rows) {
        $kernel = 0.0
        $user   = 0.0
        try { $kernel = [double]$row.KernelModeTime } catch { $kernel = 0.0 }
        try { $user   = [double]$row.UserModeTime }   catch { $user   = 0.0 }

        $out += [pscustomobject]@{
            ProcessId  = [int]$row.ProcessId
            Name       = [string]$row.Name
            # 100-nanosecond units -> seconds.
            CpuSeconds = [double](($kernel + $user) / 1e7)
            WorkingSet = [double]$row.WorkingSetSize
            ReadBytes  = [double]$row.ReadTransferCount
            WriteBytes = [double]$row.WriteTransferCount
        }
    }
    return ,$out
}

function Get-ODTNetworkRxSnapshot {
<#
.SYNOPSIS
    Machine-wide bytes received, as a cumulative counter.

.DESCRIPTION
    Uses the BCL NetworkInterface API rather than Get-NetAdapterStatistics.
    The cmdlet is a CDXML function over root/StandardCimv2, so it needs module
    autoload plus a CIM provider - both slow or flaky on a cold device still
    in OOBE, which is exactly when this has to work. The BCL call is roughly
    36x cheaper and has no such dependencies.

    Filter-driver pseudo-adapters mirror the counters of the adapter they sit
    on, so one physical NIC can appear several times with identical byte
    counts and a naive sum over-counts several-fold. Keying on MAC and taking
    the maximum per MAC removes the duplicates; measured against
    Get-NetAdapterStatistics the two agree to within about 0.2%.

    This is machine-wide receive, not setup.exe's - during ESP, with little
    else running, it is a good proxy for CDN download throughput.
#>
    [CmdletBinding()]
    [OutputType([double])]
    param()

    $byMac = @{}
    foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
        if ($nic.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback) { continue }

        $mac = ''
        try { $mac = $nic.GetPhysicalAddress().ToString() } catch { continue }
        # Virtual adapters without a MAC (tunnels, some VPN clients) cannot be
        # de-duplicated safely, so they are left out rather than double-counted.
        if ([string]::IsNullOrEmpty($mac)) { continue }

        $rx = $null
        try { $rx = [double]$nic.GetIPStatistics().BytesReceived }
        catch {
            try { $rx = [double]$nic.GetIPv4Statistics().BytesReceived } catch { continue }
        }
        if ($null -eq $rx) { continue }

        if (-not $byMac.ContainsKey($mac) -or $rx -gt $byMac[$mac]) { $byMac[$mac] = $rx }
    }

    $total = 0.0
    foreach ($value in $byMac.Values) { $total += $value }
    return $total
}

function Get-ODTDiskFreeSnapshot {
<#
.SYNOPSIS
    Free bytes on the system drive.

.DESCRIPTION
    Pure BCL, about 2 ms. Win32_LogicalDisk would cost 13x as much and drags
    in WMI for a number we sample every 30 seconds.

    The caller reports the delta as bytes *written*, which is deliberately
    signed: C2R deletes the streamed package after applying it, so the figure
    swings strongly negative near the end of an install. That sign change is
    the download -> apply -> cleanup boundary, not a bug.
#>
    [CmdletBinding()]
    [OutputType([double])]
    param()

    $drive = $env:SystemDrive
    if ([string]::IsNullOrWhiteSpace($drive)) { $drive = 'C:' }
    return [double]([System.IO.DriveInfo]::new($drive).AvailableFreeSpace)
}

function Invoke-ODTSafeSampler {
<#
.SYNOPSIS
    Run one sampler with a circuit breaker and a time budget.

.DESCRIPTION
    Failure isolation layer 1. A sampler that throws is disabled for the rest
    of the run on its first failure - there is no value in raising the same
    error 40 times, and a disabled sampler is named once in the log line.

    The budget is checked after the fact rather than enforced by pre-emption,
    because PowerShell 5.1 cannot cancel a synchronous call without a second
    runspace. That trade is acceptable here precisely because the sampling
    loop never blocks setup.exe: a slow sampler delays the next *log line*,
    never the install. One slow sample is tolerated, then the sampler is
    dropped for the rest of the run.

.PARAMETER Disabled
    Shared hashtable of sampler name -> reason. Mutated in place, so the
    disabled state persists across samples for the whole run.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [scriptblock] $Sampler,

        [Parameter(Mandatory)]
        [hashtable] $Disabled,

        [int] $BudgetMs = 3000
    )

    if ($Disabled.ContainsKey($Name)) { return $null }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $value = & $Sampler
        $sw.Stop()
        if ($sw.ElapsedMilliseconds -gt $BudgetMs) {
            $Disabled[$Name] = 'over budget ({0} ms > {1} ms)' -f $sw.ElapsedMilliseconds, $BudgetMs
        }
        return $value
    }
    catch {
        $sw.Stop()
        $Disabled[$Name] = $_.Exception.Message
        return $null
    }
}

function Format-ODTNumber {
<#
.SYNOPSIS
    Format a number for the log, independently of the machine's locale.

.DESCRIPTION
    The -f operator formats using the current culture, so 'N1' renders as
    "41,2" in one locale and "41.2" in another, and 'N0' adds
    a locale-specific group separator (a non-breaking space in nb-NO) that
    makes log lines hard to grep and hard to parse.

    Fixed-point invariant formatting keeps every device's log identical and
    machine-readable: no group separators, always a '.' decimal point.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [double] $Value,

        [ValidateRange(0, 6)]
        [int] $Decimals = 0
    )

    return $Value.ToString('F' + $Decimals, [System.Globalization.CultureInfo]::InvariantCulture)
}

function New-ODTProgressSample {
<#
.SYNOPSIS
    Take one sample of install progress and render it as a log line.

.DESCRIPTION
    Failure isolation layer 2. Every field of the returned object is
    initialised up front, because under StrictMode reading a property that
    was never added throws - so a sampler that returned $null must still
    leave a readable object behind.

    Deltas are computed against -Previous, so the first sample of a run shows
    cumulative figures with no rate.

.PARAMETER Previous
    The preceding sample, or $null for the first one.

.PARAMETER Disabled
    Shared sampler name -> reason hashtable (see Invoke-ODTSafeSampler).

.OUTPUTS
    [pscustomobject] including a preformatted .Line ready for the log.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [double] $ElapsedSeconds = 0,

        [AllowNull()]
        [pscustomobject] $Previous,

        [Parameter(Mandatory)]
        [hashtable] $Disabled,

        [int] $BudgetMs = 3000
    )

    $sample = [pscustomobject]@{
        ElapsedSeconds  = [int][math]::Round($ElapsedSeconds)
        TimestampUtc    = [datetime]::UtcNow
        Scenario        = $null
        ActiveTask      = $null
        CompletedTasks  = 0
        TotalTasks      = 0
        Version         = $null
        NetRxTotalBytes = $null
        NetRxDeltaBytes = $null
        NetMbps         = $null
        DiskFreeBytes   = $null
        DiskWrittenBytes = $null
        Processes       = @()
        Line            = ''
    }

    $parts = @('Progress t={0}s' -f $sample.ElapsedSeconds)

    # --- Click-to-Run scenario ------------------------------------------------
    $c2r = Invoke-ODTSafeSampler -Name 'c2r' -Disabled $Disabled -BudgetMs $BudgetMs -Sampler {
        Get-ODTC2RScenarioSnapshot
    }
    if ($null -ne $c2r) {
        $sample.Scenario       = $c2r.Scenario
        $sample.ActiveTask     = $c2r.Active
        $sample.CompletedTasks = $c2r.Completed
        $sample.TotalTasks     = $c2r.Total
        $sample.Version        = $c2r.Version

        $activeText  = if ($null -eq $c2r.Active) { '<idle>' } else { $c2r.Active }
        $versionText = if ([string]::IsNullOrWhiteSpace([string]$c2r.Version)) { '<pending>' } else { $c2r.Version }
        $parts += 'c2r: scenario={0} active={1} done={2}/{3} ver={4}' -f `
            $c2r.Scenario, $activeText, $c2r.Completed, $c2r.Total, $versionText
    }
    else {
        $parts += 'c2r: {0}' -f (Get-ODTSamplerUnavailableText -Name 'c2r' -Disabled $Disabled)
    }

    # --- Network receive ------------------------------------------------------
    $rx = Invoke-ODTSafeSampler -Name 'net' -Disabled $Disabled -BudgetMs $BudgetMs -Sampler {
        Get-ODTNetworkRxSnapshot
    }
    if ($null -ne $rx) {
        $sample.NetRxTotalBytes = [double]$rx
        if ($null -ne $Previous -and $null -ne $Previous.NetRxTotalBytes) {
            $deltaBytes   = [double]$rx - [double]$Previous.NetRxTotalBytes
            $deltaSeconds = $ElapsedSeconds - [double]$Previous.ElapsedSeconds
            $sample.NetRxDeltaBytes = $deltaBytes
            if ($deltaSeconds -gt 0) {
                $sample.NetMbps = [double](($deltaBytes * 8) / ($deltaSeconds * 1e6))
            }
        }

        $deltaText = if ($null -eq $sample.NetRxDeltaBytes) { 'n/a' } else { (Format-ODTNumber -Value ($sample.NetRxDeltaBytes / 1MB) -Decimals 1) + 'MB' }
        $rateText  = if ($null -eq $sample.NetMbps) { 'n/a' } else { (Format-ODTNumber -Value $sample.NetMbps -Decimals 1) + 'Mbit/s' }
        $parts += 'net: +{0} {1} (tot {2}MB)' -f $deltaText, $rateText, (Format-ODTNumber -Value ([double]$rx / 1MB))
    }
    else {
        $parts += 'net: {0}' -f (Get-ODTSamplerUnavailableText -Name 'net' -Disabled $Disabled)
    }

    # --- System drive ---------------------------------------------------------
    $free = Invoke-ODTSafeSampler -Name 'disk' -Disabled $Disabled -BudgetMs $BudgetMs -Sampler {
        Get-ODTDiskFreeSnapshot
    }
    if ($null -ne $free) {
        $sample.DiskFreeBytes = [double]$free
        if ($null -ne $Previous -and $null -ne $Previous.DiskFreeBytes) {
            # Signed on purpose: negative once C2R starts reclaiming the
            # streamed package, which marks the apply/cleanup boundary.
            $sample.DiskWrittenBytes = [double]$Previous.DiskFreeBytes - [double]$free
        }

        $writtenText = 'n/a'
        if ($null -ne $sample.DiskWrittenBytes) {
            $writtenMB = [int][math]::Round($sample.DiskWrittenBytes / 1MB)
            $sign = if ($writtenMB -ge 0) { '+' } else { '' }
            $writtenText = '{0}{1}MB' -f $sign, $writtenMB
        }
        $parts += 'disk: {0} {1}GB free ({2})' -f $env:SystemDrive, (Format-ODTNumber -Value ([double]$free / 1GB) -Decimals 1), $writtenText
    }
    else {
        $parts += 'disk: {0}' -f (Get-ODTSamplerUnavailableText -Name 'disk' -Disabled $Disabled)
    }

    # --- Processes ------------------------------------------------------------
    $procs = Invoke-ODTSafeSampler -Name 'proc' -Disabled $Disabled -BudgetMs $BudgetMs -Sampler {
        Get-ODTProcessSnapshot
    }
    if ($null -ne $procs) {
        $sample.Processes = @($procs)
        foreach ($proc in $sample.Processes) {
            $prior = $null
            if ($null -ne $Previous) {
                foreach ($candidate in @($Previous.Processes)) {
                    if ($candidate.ProcessId -eq $proc.ProcessId) { $prior = $candidate; break }
                }
            }

            $cpuText = if ($null -eq $prior) { (Format-ODTNumber -Value $proc.CpuSeconds -Decimals 1) + 's' }
                       else { '+' + (Format-ODTNumber -Value ($proc.CpuSeconds - $prior.CpuSeconds) -Decimals 1) + 's' }
            $rdText  = if ($null -eq $prior) { (Format-ODTNumber -Value ($proc.ReadBytes / 1MB)) + 'MB' }
                       else { '+' + (Format-ODTNumber -Value (($proc.ReadBytes - $prior.ReadBytes) / 1MB)) + 'MB' }
            $wrText  = if ($null -eq $prior) { (Format-ODTNumber -Value ($proc.WriteBytes / 1MB)) + 'MB' }
                       else { '+' + (Format-ODTNumber -Value (($proc.WriteBytes - $prior.WriteBytes) / 1MB)) + 'MB' }

            $shortName = $proc.Name -replace '\.exe$', ''
            $parts += '{0}({1}) cpu={2} ws={3}MB rd={4} wr={5}' -f `
                $shortName, $proc.ProcessId, $cpuText, (Format-ODTNumber -Value ($proc.WorkingSet / 1MB)), $rdText, $wrText
        }
    }
    else {
        $parts += 'proc: {0}' -f (Get-ODTSamplerUnavailableText -Name 'proc' -Disabled $Disabled)
    }

    $sample.Line = $parts -join ' | '
    return $sample
}

# Renders the reason a sampler produced nothing. The reason is emitted once,
# on the sample where the sampler was disabled; later samples just say n/a so
# the same stack trace is not repeated forty times down the log.
function Get-ODTSamplerUnavailableText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [hashtable] $Disabled
    )

    $reason = $Disabled[$Name]
    if ([string]::IsNullOrWhiteSpace([string]$reason)) { return 'n/a' }
    if ($Disabled.ContainsKey($Name + ':reported')) { return 'n/a' }

    $Disabled[$Name + ':reported'] = $true
    $text = [string]$reason
    if ($text.Length -gt 160) { $text = $text.Substring(0, 160) + '...' }
    return 'n/a (disabled: {0})' -f $text
}

function Get-ODTPhaseSummary {
<#
.SYNOPSIS
    Collapse a run of progress samples into per-task spans.

.DESCRIPTION
    Pure function over the sample list, so it is unit-testable and costs no
    extra registry work.

    Boundaries are attributed conservatively: a task is credited from the
    timestamp of the *previous* sample (the last moment we know it had not
    started) to the timestamp of the first sample showing a different task.
    Spans are therefore contiguous and non-overlapping, and resolution is one
    sampling interval - which is why -ProgressIntervalSeconds 15 is worth
    using on the first diagnostic runs.

.OUTPUTS
    [pscustomobject[]] with Task, FirstSeenSeconds, LastSeenSeconds,
    DurationSeconds, in the order the tasks ran.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [AllowNull()]
        [pscustomobject[]] $Samples
    )

    $ordered = @()
    if ($null -ne $Samples) { $ordered = @($Samples | Where-Object { $null -ne $_ }) }
    # Return arrays unwrapped, not via the unary comma: callers collect with
    # @(Get-ODTPhaseSummary ...), and a comma-wrapped array arrives there as a
    # single element rather than as N.
    if ($ordered.Count -eq 0) { return @() }

    $summary = @()
    $runStart = 0
    $index = 0

    while ($index -lt $ordered.Count) {
        $task = $ordered[$index].ActiveTask

        $last = $index
        while (($last + 1) -lt $ordered.Count -and $ordered[$last + 1].ActiveTask -eq $task) { $last++ }

        $runEnd = if (($last + 1) -lt $ordered.Count) {
            [int]$ordered[$last + 1].ElapsedSeconds
        } else {
            [int]$ordered[$last].ElapsedSeconds
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$task)) {
            $summary += [pscustomobject]@{
                Task             = [string]$task
                FirstSeenSeconds = [int]$runStart
                LastSeenSeconds  = [int]$runEnd
                DurationSeconds  = [int]($runEnd - $runStart)
            }
        }

        $runStart = $runEnd
        $index = $last + 1
    }

    return $summary
}

function ConvertFrom-ODTC2RFileTime {
<#
.SYNOPSIS
    Decode a Click-to-Run UpdateStatus timestamp.

.DESCRIPTION
    C2R stores these as REG_SZ decimal strings in milliseconds-since-1601,
    i.e. a Windows FILETIME divided by 10,000. Multiplying back and calling
    FromFileTimeUtc recovers the UTC instant.

    Returns $null - never throws - for absent, empty, zero or non-numeric
    input, and for values outside the range FromFileTimeUtc accepts.

.OUTPUTS
    [datetime] in UTC, or $null.
#>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        $Value
    )

    if ($null -eq $Value) { return $null }

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    $raw = [long]0
    if (-not [long]::TryParse($text, [ref]$raw)) { return $null }
    if ($raw -le 0) { return $null }

    try { return [datetime]::FromFileTimeUtc($raw * 10000) }
    catch { return $null }
}

function Invoke-ODTSetup {
<#
.SYNOPSIS
    Run setup.exe /configure against a prepared configuration XML and return
    a structured result, sampling progress while it runs.

.DESCRIPTION
    Launches setup.exe hidden and waits for it, but instead of one blocking
    wait it waits in -ProgressIntervalSeconds slices and takes a sample of the
    machine between slices. Each sample is rendered as a single line and handed
    to -ProgressCallback, so an install that used to be a 15-minute silence in
    the log becomes a readable timeline of Click-to-Run phases, download
    throughput and disk growth.

    Sampling adds no time to the install: the interval wait *is* the wait on
    setup.exe, and it returns the instant the process exits.

    The sample schedule is absolute rather than "sleep N", because the process
    snapshot costs about a second and a relative sleep would accumulate that
    drift across a long run.

.PARAMETER SetupExePath
    Absolute path to setup.exe.

.PARAMETER ConfigurationPath
    Absolute path to a configuration.xml.

.PARAMETER TimeoutMinutes
    How long to wait for the process to exit before killing it. Defaults to
    60 minutes, which covers realistic install + download times. The lower
    bound is 1 minute so the timeout path can be exercised in a lab without a
    five-minute wait.

.PARAMETER ProgressIntervalSeconds
    Seconds between samples. 0 disables sampling entirely and restores the
    single-blocking-wait behaviour exactly. Use 15 when actively diagnosing a
    slow install - phase resolution is one interval.

.PARAMETER ProgressCallback
    Scriptblock invoked as & $ProgressCallback $line $severity for each sample.

    Author it in the calling script, not here: a scriptblock runs in the
    session state it was defined in, which is how the callback can reach
    Write-ODTLog and the caller's $LogFile / $LogPath without this module
    taking a dependency on ODTLogging. A scriptblock created inside this
    module would run in module scope, where those are invisible.

    A callback that throws is caught and ignored - logging must never break
    the install.

.PARAMETER SamplerBudgetMilliseconds
    Wall-clock budget per individual sampler. A sampler that exceeds it is
    disabled for the rest of the run.

.PARAMETER MaxRetainedSamples
    Cap on samples kept in the returned object. Past the cap the callback
    still fires (so the log stays complete) but nothing more is retained in
    memory - relevant only for pathological interval/timeout combinations.

.OUTPUTS
    PSCustomObject. ExitCode, DurationSeconds, Success and Message keep their
    original names, types and meanings; TimedOut, StartedUtc, EndedUtc,
    SampleCount, Samples, PhaseSummary and DisabledSamplers are additions.

.EXAMPLE
    $cb = { param($line, $severity) Write-ODTLog -Message $line -Severity $severity -Component 'Install-M365Apps' -LogFile 'M365Apps-Install.log' }
    Invoke-ODTSetup -SetupExePath $setup -ConfigurationPath $xml -ProgressCallback $cb
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $SetupExePath,

        [Parameter(Mandatory)]
        [string] $ConfigurationPath,

        [ValidateRange(1, 240)]
        [int] $TimeoutMinutes = 60,

        [ValidateRange(0, 600)]
        [int] $ProgressIntervalSeconds = 30,

        [scriptblock] $ProgressCallback,

        [ValidateRange(250, 30000)]
        [int] $SamplerBudgetMilliseconds = 3000,

        [ValidateRange(10, 20000)]
        [int] $MaxRetainedSamples = 2000
    )

    $argumentList = @('/configure', ('"{0}"' -f $ConfigurationPath))

    $startUtc  = [datetime]::UtcNow
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $process   = Start-Process -FilePath $SetupExePath -ArgumentList $argumentList -PassThru -WindowStyle Hidden

    $timeoutMs   = [double]$TimeoutMinutes * 60.0 * 1000.0
    $samples     = New-Object System.Collections.Generic.List[pscustomobject]
    $disabled    = @{}
    $previous    = $null
    $sampleIndex = 0
    $timedOut    = $false

    if ($ProgressIntervalSeconds -le 0) {
        if (-not $process.WaitForExit([int]$timeoutMs)) { $timedOut = $true }
    }
    else {
        while ($true) {
            $elapsedMs   = $stopwatch.Elapsed.TotalMilliseconds
            $remainingMs = $timeoutMs - $elapsedMs
            if ($remainingMs -le 0) { $timedOut = $true; break }

            $sampleIndex++
            $nextAtMs = [double]$sampleIndex * [double]$ProgressIntervalSeconds * 1000.0
            $waitMs   = [int][math]::Min($remainingMs, [math]::Max(1.0, $nextAtMs - $elapsedMs))

            if ($process.WaitForExit($waitMs)) { break }

            # Failure isolation layer 3: nothing in here may escape.
            try {
                $sample = New-ODTProgressSample -ElapsedSeconds $stopwatch.Elapsed.TotalSeconds `
                                                -Previous $previous `
                                                -Disabled $disabled `
                                                -BudgetMs $SamplerBudgetMilliseconds
                if ($null -ne $sample) {
                    if ($samples.Count -lt $MaxRetainedSamples) { $samples.Add($sample) }
                    $previous = $sample
                    if ($null -ne $ProgressCallback) {
                        try { & $ProgressCallback $sample.Line 1 } catch { }
                    }
                }
            }
            catch { }
        }
    }

    if ($timedOut) {
        try { $process.Kill() } catch { }
        # Let it actually die before the caller reads post-run state.
        try { $null = $process.WaitForExit(10000) } catch { }
        $stopwatch.Stop()

        # ExitCode is deliberately hard-coded rather than read back: reading it
        # after Kill() can throw, and docs/troubleshooting.md keys a section off
        # this exact message string.
        return [pscustomobject]@{
            ExitCode         = -1
            DurationSeconds  = [int]$stopwatch.Elapsed.TotalSeconds
            Success          = $false
            Message          = "Invoke-ODTSetup: setup.exe did not exit within $TimeoutMinutes minutes and was terminated."
            TimedOut         = $true
            StartedUtc       = $startUtc
            EndedUtc         = [datetime]::UtcNow
            SampleCount      = $samples.Count
            Samples          = @($samples)
            PhaseSummary     = @(Get-ODTPhaseSummary -Samples @($samples))
            DisabledSamplers = @(Get-ODTDisabledSamplerReport -Disabled $disabled)
        }
    }

    # The parameterless overload settles the process object so ExitCode is
    # reliably populated; the timed overload can return before that. Assigned
    # to $null because the real overload returns void but a test double does
    # not, and a stray Boolean here would pollute the function's output.
    try { $null = $process.WaitForExit() } catch { }
    $stopwatch.Stop()

    $exit = $process.ExitCode
    $success = ($exit -eq 0 -or $exit -eq 3010 -or $exit -eq 1641)

    [pscustomobject]@{
        ExitCode         = $exit
        DurationSeconds  = [int]$stopwatch.Elapsed.TotalSeconds
        Success          = [bool]$success
        Message          = Get-ODTExitCodeMessage -ExitCode $exit
        TimedOut         = $false
        StartedUtc       = $startUtc
        EndedUtc         = [datetime]::UtcNow
        SampleCount      = $samples.Count
        Samples          = @($samples)
        PhaseSummary     = @(Get-ODTPhaseSummary -Samples @($samples))
        DisabledSamplers = @(Get-ODTDisabledSamplerReport -Disabled $disabled)
    }
}

# Flattens the sampler circuit-breaker state into reportable records. The
# ':reported' bookkeeping keys used by Get-ODTSamplerUnavailableText are
# internal and filtered out here.
function Get-ODTDisabledSamplerReport {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Disabled
    )

    $out = @()
    foreach ($key in $Disabled.Keys) {
        if ($key -like '*:reported') { continue }
        $out += [pscustomobject]@{
            Name   = [string]$key
            Reason = [string]$Disabled[$key]
        }
    }
    return $out
}

function Get-ODTC2RPhaseTimeline {
<#
.SYNOPSIS
    Click-to-Run's own record of how long download and apply took.

.DESCRIPTION
    After a run, C2R leaves timestamps under
    HKLM\SOFTWARE\Microsoft\Office\ClickToRun\UpdateStatus. This is the only
    machine-readable download-vs-apply split Click-to-Run publishes, and it is
    ground truth rather than the sampler's one-interval approximation.

    Registry only. No log files are read, copied or redirected, and this does
    not revisit the decision documented at the top of this module not to inject
    an ODT <Logging> element - it just reads state C2R already wrote.

    The key is populated for update-shaped scenarios. A first install on a
    device with no prior Office may leave it absent or stale, which is why the
    caller treats a $null result as unremarkable and falls back to the
    sampler's own phase summary.

.PARAMETER SinceUtc
    Discard spans that ended before this instant, so a previous run's
    timestamps are not reported as if they belonged to this one.

.OUTPUTS
    [pscustomobject[]] with Phase, StartUtc, EndUtc, DurationSeconds -
    or $null when the key is absent or holds nothing usable.
#>
    [CmdletBinding()]
    param(
        [datetime] $SinceUtc = [datetime]::MinValue
    )

    $values = Get-ODTReg64Values -Path 'SOFTWARE\Microsoft\Office\ClickToRun\UpdateStatus'
    if ($null -eq $values) { return $null }

    $phases = [ordered]@{
        Detection      = @('UpdateDetectionStartTime',      'UpdateDetectionEndTime')
        ClientDownload = @('UpdateClientDownloadStartTime', 'UpdateClientDownloadEndTime')
        Download       = @('UpdateDownloadStartTime',       'UpdateDownloadEndTime')
        Apply          = @('UpdateApplyStartTime',          'UpdateApplyEndTime')
        Finalize       = @('UpdateFinalizeStartTime',       'UpdateFinalizeEndTime')
    }

    $out = @()
    foreach ($phase in $phases.Keys) {
        $names = $phases[$phase]
        $start = ConvertFrom-ODTC2RFileTime -Value $values[$names[0]]
        $end   = ConvertFrom-ODTC2RFileTime -Value $values[$names[1]]
        if ($null -eq $start -or $null -eq $end) { continue }
        if ($end -lt $SinceUtc) { continue }

        $out += [pscustomobject]@{
            Phase           = [string]$phase
            StartUtc        = $start
            EndUtc          = $end
            DurationSeconds = [int]([math]::Max(0, ($end - $start).TotalSeconds))
        }
    }

    if ($out.Count -eq 0) { return $null }
    return $out
}

Export-ModuleMember -Function @(
    'Get-ODTExitCodeMessage',
    'Get-ODTExitCodeResult',
    'Get-ODTC2RPhaseTimeline',
    'Resolve-ODTConfigurationPath',
    'Resolve-ODTSetupPath',
    'Invoke-ODTSetup'
)
