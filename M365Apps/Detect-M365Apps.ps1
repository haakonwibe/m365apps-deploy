#Requires -Version 5.1
<#
.SYNOPSIS
    Intune Win32 detection script for Microsoft 365 Apps for Enterprise.

.DESCRIPTION
    Detection logic: the ProductReleaseIds value under
    HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration contains
    'O365ProPlusRetail'.

    This is the authoritative Click-to-Run source. We deliberately avoid
    DisplayName scans in the Uninstall hive because those false-positive on
    legacy MSI entries.

    Intune contract:
        - Write a marker string to stdout on detection.
        - Exit 0 on detection, exit 1 on non-detection.
        - Any write to stdout on the "detected" path is sufficient; the
          exit code is what Intune reads.

    Standalone by design: this script does NOT Import-Module from Common/.
    Intune's detection-script execution model does not reliably give access
    to relative module paths, so the minimum needed logging is inlined.
    See docs/architecture.md for the tradeoff.

.NOTES
    Script  : Detect-M365Apps.ps1
    Project : m365apps-deploy
    Version : <see Common/ODTVersion.psm1>
#>
[CmdletBinding()]
param(
    [string] $LogPath = 'C:\ProgramData\M365AppsDeploy\Logs',
    [string] $LogFile = 'M365Apps-Detection.log'
)

function Write-CMTraceLine {
    param(
        [Parameter(Mandatory)][string] $Message,
        [ValidateSet(1,2,3)][int] $Severity = 1,
        [string] $Component = 'Detect-M365Apps',
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
        $line = '<![LOG[{0}]LOG]!><time="{1}{2}" date="{3}" component="{4}" context="{5}" type="{6}" thread="{7}" file="Detect-M365Apps.ps1:0">' -f `
                $Message, $now.ToString('HH:mm:ss.fff'), $bias, $now.ToString('MM-dd-yyyy'), $Component, $user, $Severity, $PID
        Add-Content -LiteralPath $FullLogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # Never let a logging failure affect the detection verdict.
    }
}

# Inline GUID -> friendly channel-name lookup. Mirrors the canonical map in
# Common\ODTOfficeState.psm1 (Get-OfficeChannelName); duplicated here per the
# "detection scripts are standalone" architectural rule. Keep both copies in
# sync. See docs/architecture.md#detection-scripts-are-standalone.
$OfficeChannelMap = @{
    '492350f6-3a01-4f97-b9c0-c7c6ddf67d60' = 'Current'
    '55336b82-a18d-4dd6-b5f6-9e5095c314a6' = 'MonthlyEnterprise'
    '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114' = 'SemiAnnual'
    'b8f9b850-328d-4355-9145-c59439a0c4cf' = 'SemiAnnualPreview'
    '64256afe-f5d9-4f86-8936-8840a6a4f5be' = 'CurrentPreview'
    '5440fd1f-7ecb-4221-8110-145efaa6372f' = 'Beta'
    'f2e724c1-748f-4b47-8fb8-8e0d210e9208' = 'PerpetualVL2021'
}

function Resolve-OfficeChannelName {
    param([string] $UpdateChannel)
    if ([string]::IsNullOrWhiteSpace($UpdateChannel)) { return 'unknown' }
    $m = [regex]::Match($UpdateChannel, '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})', 'IgnoreCase')
    if ($m.Success -and $OfficeChannelMap.ContainsKey($m.Value.ToLowerInvariant())) {
        return $OfficeChannelMap[$m.Value.ToLowerInvariant()]
    }
    return $UpdateChannel
}

$ProductId = 'O365ProPlusRetail'
$FullLog = Join-Path -Path $LogPath -ChildPath $LogFile

# Open registry via the explicit 64-bit view. Intune Management Extension
# is a 32-bit binary (C:\Program Files (x86)\Microsoft Intune Management
# Extension\), so default HKLM:\SOFTWARE access from a script it launches
# gets redirected to WOW6432Node where the C2R Configuration key does not
# exist. See docs/architecture.md rule #3.
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
        Write-CMTraceLine -Message 'ProductReleaseIds value is empty. Detection: NOT installed.' -Severity 2 -FullLogPath $FullLog
        exit 1
    }

    $products = $raw -split ',' | ForEach-Object { $_.Trim() }
    $match = $products | Where-Object { $_ -ieq $ProductId }

    if ($match) {
        $version = [string]$configKey.GetValue('VersionToReport', 'unknown')
        $channelRaw = [string]$configKey.GetValue('UpdateChannel', '')
        $channel = Resolve-OfficeChannelName -UpdateChannel $channelRaw
        Write-CMTraceLine -Message ("Detected {0}. Version={1} Channel={2}. ProductReleaseIds=[{3}]." -f $ProductId, $version, $channel, $raw) -FullLogPath $FullLog
        # Intune marker: any stdout write is sufficient.
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
