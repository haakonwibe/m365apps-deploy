#Requires -Version 5.1
<#
.SYNOPSIS
    Pre-flight checks shared by every install / uninstall script.

.DESCRIPTION
    Each check returns a structured result ([pscustomobject] with
    Passed / CheckName / Details) so operators can see exactly what passed
    or failed in the log. The wrapper Invoke-ODTPrerequisiteChecks runs the
    full suite and returns a single aggregate object.

.NOTES
    Module  : ODTPrerequisites
    Project : m365apps-deploy
    Version : 1.0.0
#>

Set-StrictMode -Version Latest

# Private helper: probe the 64-bit registry view for the existence of a
# subkey. Intune Management Extension is a 32-bit binary, so default
# HKLM:\SOFTWARE access from a script it launches gets redirected to
# WOW6432Node where the CBS / Windows Update reboot-pending keys do not
# exist. The .NET Microsoft.Win32 API with Registry64 view bypasses
# redirection. See docs/architecture.md rule #3.
function Test-Registry64KeyExists {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $baseKey = $null
    $subKey  = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        $subKey  = $baseKey.OpenSubKey($Path)
        return $null -ne $subKey
    }
    catch { return $false }
    finally {
        if ($subKey)  { $subKey.Dispose() }
        if ($baseKey) { $baseKey.Dispose() }
    }
}

function New-ODTPrerequisiteResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $CheckName,

        [Parameter(Mandatory)]
        [bool] $Passed,

        [string] $Details
    )

    [pscustomobject]@{
        CheckName = $CheckName
        Passed    = $Passed
        Details   = $Details
    }
}

function Test-RunningAsElevated {
<#
.SYNOPSIS
    Verify the current process runs as SYSTEM or in an elevated administrator context.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    try {
        $identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
        $isAdmin   = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
        $isSystem  = $identity.IsSystem

        if ($isSystem) {
            return New-ODTPrerequisiteResult -CheckName 'Elevation' -Passed $true -Details 'Running as SYSTEM.'
        }
        if ($isAdmin) {
            return New-ODTPrerequisiteResult -CheckName 'Elevation' -Passed $true -Details ("Running elevated as {0}." -f $identity.Name)
        }
        return New-ODTPrerequisiteResult -CheckName 'Elevation' -Passed $false -Details ("User '{0}' is not elevated. Run from SYSTEM or an elevated admin shell." -f $identity.Name)
    }
    catch {
        return New-ODTPrerequisiteResult -CheckName 'Elevation' -Passed $false -Details ("Elevation check failed: {0}" -f $_.Exception.Message)
    }
}

function Test-PendingReboot {
<#
.SYNOPSIS
    Check whether Windows has a pending reboot that could derail the install.

.DESCRIPTION
    Inspects two registry locations that Microsoft documents as authoritative
    "servicing is waiting for a reboot" indicators:

      - HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending
      - HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired

    Both are populated only when Windows Servicing (CBS) or Windows Update
    actually needs a reboot to complete, and both clear after the reboot.

    We intentionally do NOT consult
    HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations.
    Treating a populated value there as "pending reboot" produces false
    positives within minutes of a clean boot: Windows Update, Defender,
    Click-to-Run and many other components queue file-rename operations
    there as normal operation, not as an indication that the box needs a
    reboot. SCCM hardware inventory treats the same signal as unreliable
    for the same reason.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $reasons = @()

    if (Test-Registry64KeyExists -Path 'SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $reasons += 'CBS RebootPending'
    }
    if (Test-Registry64KeyExists -Path 'SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $reasons += 'Windows Update RebootRequired'
    }

    if ($reasons.Count -eq 0) {
        return New-ODTPrerequisiteResult -CheckName 'PendingReboot' -Passed $true -Details 'No pending reboot detected.'
    }
    return New-ODTPrerequisiteResult -CheckName 'PendingReboot' -Passed $false -Details ("Pending reboot indicators: {0}" -f ($reasons -join ', '))
}

function Test-FreeDiskSpace {
<#
.SYNOPSIS
    Verify the system drive has at least the configured amount of free space.

.PARAMETER MinimumFreeGB
    Minimum free space on the system drive, in gibibytes. Default 5.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateRange(1, 500)]
        [int] $MinimumFreeGB = 5
    )

    try {
        $systemDrive = ($env:SystemDrive).TrimEnd(':')
        $drive = Get-PSDrive -Name $systemDrive -PSProvider FileSystem -ErrorAction Stop
        $freeGB = [math]::Round($drive.Free / 1GB, 2)
        if ($freeGB -ge $MinimumFreeGB) {
            return New-ODTPrerequisiteResult -CheckName 'DiskSpace' -Passed $true -Details ("{0}: has {1} GB free (>= {2} GB required)." -f $systemDrive, $freeGB, $MinimumFreeGB)
        }
        return New-ODTPrerequisiteResult -CheckName 'DiskSpace' -Passed $false -Details ("{0}: only {1} GB free (< {2} GB required)." -f $systemDrive, $freeGB, $MinimumFreeGB)
    }
    catch {
        return New-ODTPrerequisiteResult -CheckName 'DiskSpace' -Passed $false -Details ("Disk space check failed: {0}" -f $_.Exception.Message)
    }
}

function Invoke-ODTPrerequisiteChecks {
<#
.SYNOPSIS
    Run all toolkit prerequisites and return an aggregate pass/fail result.

.PARAMETER MinimumFreeGB
    Passed through to Test-FreeDiskSpace. Default 5.

.PARAMETER SkipElevation
    Skip the elevation check. Useful for Pester unit tests only.

.OUTPUTS
    PSCustomObject with properties:
        AllPassed [bool]
        Results   [pscustomobject[]]  - one per individual check
        Summary   [string]            - human-readable summary
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [int] $MinimumFreeGB = 5,

        [switch] $SkipElevation
    )

    # Note: we do NOT pre-check for concurrent ODT / Windows Installer
    # operations. ODT and Windows Installer both use their own global
    # mutex to serialise concurrent runs; when another install is in
    # flight setup.exe returns 1618 (or related codes) and the toolkit
    # translates that through Get-ODTExitCodeResult. Duplicating that
    # check here was false-positive-prone (e.g. OfficeClickToRun.exe is
    # the always-running C2R service, not a concurrent install) and
    # added no value over what ODT already does internally.
    $results = @()
    if (-not $SkipElevation) {
        $results += Test-RunningAsElevated
    }
    $results += Test-PendingReboot
    $results += Test-FreeDiskSpace -MinimumFreeGB $MinimumFreeGB

    $allPassed = -not ($results | Where-Object { -not $_.Passed })

    $failedNames = $results | Where-Object { -not $_.Passed } | ForEach-Object { $_.CheckName }
    $summary = if ($allPassed) { 'All prerequisite checks passed.' }
               else { ("Prerequisite checks failed: {0}" -f ($failedNames -join ', ')) }

    [pscustomobject]@{
        AllPassed = [bool]$allPassed
        Results   = $results
        Summary   = $summary
    }
}

Export-ModuleMember -Function @(
    'Test-RunningAsElevated',
    'Test-PendingReboot',
    'Test-FreeDiskSpace',
    'Invoke-ODTPrerequisiteChecks'
)
