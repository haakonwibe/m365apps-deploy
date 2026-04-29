#Requires -Version 5.1
<#
.SYNOPSIS
    Intune Win32 detection script for Visio Professional (VisioProRetail).

.DESCRIPTION
    Reads HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration and matches
    ProductReleaseIds -contains 'VisioProRetail'. Standalone: no module imports.

.NOTES
    Script  : Detect-Visio.ps1
    Project : m365apps-deploy
    Version : <see Common/ODTVersion.psm1>
#>
[CmdletBinding()]
param(
    [string] $LogPath = 'C:\ProgramData\M365AppsDeploy\Logs',
    [string] $LogFile = 'Visio-Detection.log'
)

function Write-CMTraceLine {
    param(
        [Parameter(Mandatory)][string] $Message,
        [ValidateSet(1,2,3)][int] $Severity = 1,
        [string] $Component = 'Detect-Visio',
        [Parameter(Mandatory)][string] $FullLogPath
    )
    try {
        $dir = Split-Path -Path $FullLogPath -Parent
        if (-not (Test-Path -LiteralPath $dir)) {
            $null = New-Item -Path $dir -ItemType Directory -Force -ErrorAction Stop
        }
        $now  = Get-Date
        $bias = '{0:+#;-#;+0}' -f [int][System.TimeZoneInfo]::Local.GetUtcOffset($now).TotalMinutes
        $user = try { [System.Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { 'Unknown' }
        $line = '<![LOG[{0}]LOG]!><time="{1}{2}" date="{3}" component="{4}" context="{5}" type="{6}" thread="{7}" file="Detect-Visio.ps1:0">' -f `
                $Message, $now.ToString('HH:mm:ss.fff'), $bias, $now.ToString('MM-dd-yyyy'), $Component, $user, $Severity, $PID
        Add-Content -LiteralPath $FullLogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch { }
}

$ProductId = 'VisioProRetail'
$FullLog = Join-Path -Path $LogPath -ChildPath $LogFile

# Open registry via the explicit 64-bit view (IME is 32-bit; default
# HKLM:\SOFTWARE access gets redirected to WOW6432Node where the C2R
# Configuration key does not exist). See docs/architecture.md rule #3.
$baseKey = $null
try {
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    $configKey = $baseKey.OpenSubKey('SOFTWARE\Microsoft\Office\ClickToRun\Configuration')
    if ($null -eq $configKey) {
        Write-CMTraceLine -Message 'ClickToRun\Configuration key not present (64-bit view). Detection: NOT installed.' -Severity 2 -FullLogPath $FullLog
        exit 1
    }
    $raw = [string]$configKey.GetValue('ProductReleaseIds', '')
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-CMTraceLine -Message 'ProductReleaseIds empty. Detection: NOT installed.' -Severity 2 -FullLogPath $FullLog
        exit 1
    }
    $products = $raw -split ',' | ForEach-Object { $_.Trim() }
    if ($products | Where-Object { $_ -ieq $ProductId }) {
        $version = [string]$configKey.GetValue('VersionToReport', 'unknown')
        Write-CMTraceLine -Message ("Detected {0}. Version={1}." -f $ProductId, $version) -FullLogPath $FullLog
        Write-Output ("{0} detected. Version={1}." -f $ProductId, $version)
        exit 0
    }
    Write-CMTraceLine -Message ("{0} not present in ProductReleaseIds=[{1}]. Detection: NOT installed." -f $ProductId, $raw) -Severity 2 -FullLogPath $FullLog
    exit 1
}
catch {
    Write-CMTraceLine -Message ("Detection error: {0}" -f $_.Exception.Message) -Severity 3 -FullLogPath $FullLog
    exit 1
}
finally {
    if ($baseKey) { $baseKey.Dispose() }
}
