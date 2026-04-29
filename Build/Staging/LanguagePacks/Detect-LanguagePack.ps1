#Requires -Version 5.1
<#
.SYNOPSIS
    Intune detection script for a specific language pack on a specific product.

.DESCRIPTION
    When deploying a language pack as a Win32 app in Intune, bake the
    -LanguageID and -TargetProduct values into the detection command line
    that Intune sends, e.g.

        powershell.exe -ExecutionPolicy Bypass -File Detect-LanguagePack.ps1 -LanguageID nb-no -TargetProduct O365ProPlusRetail

    Detection is based on the Click-to-Run Uninstall-key convention
    '<ProductId> - <lang>'. This is what C2R registers when it installs a
    secondary language, so it is the authoritative indicator.

.NOTES
    Script  : Detect-LanguagePack.ps1
    Project : m365apps-deploy
    Version : <see Common/ODTVersion.psm1>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-zA-Z]{2,3}(-[a-zA-Z]{2,8}){1,3}$')]
    [string] $LanguageID,

    [ValidateSet('O365ProPlusRetail','VisioProRetail','VisioStdRetail','ProjectProRetail','ProjectStdRetail')]
    [string] $TargetProduct = 'O365ProPlusRetail',

    [string] $LogPath = 'C:\ProgramData\M365AppsDeploy\Logs',

    [string] $LogFile
)

function Write-CMTraceLine {
    param(
        [Parameter(Mandatory)][string] $Message,
        [ValidateSet(1,2,3)][int] $Severity = 1,
        [string] $Component = 'Detect-LanguagePack',
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
        $line = '<![LOG[{0}]LOG]!><time="{1}{2}" date="{3}" component="{4}" context="{5}" type="{6}" thread="{7}" file="Detect-LanguagePack.ps1:0">' -f `
                $Message, $now.ToString('HH:mm:ss.fff'), $bias, $now.ToString('MM-dd-yyyy'), $Component, $user, $Severity, $PID
        Add-Content -LiteralPath $FullLogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch { }
}

$LanguageID = $LanguageID.ToLowerInvariant()
if ([string]::IsNullOrWhiteSpace($LogFile)) {
    $LogFile = ("LanguagePack-{0}-{1}-Detection.log" -f $TargetProduct, $LanguageID)
}
$FullLog = Join-Path -Path $LogPath -ChildPath $LogFile

# Uninstall hive paths in the 64-bit registry view. IME is 32-bit; default
# HKLM:\SOFTWARE access gets redirected to WOW6432Node so we must open the
# base key with Registry64 explicitly. See docs/architecture.md rule #3.
$UninstallPaths = @(
    'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)

# Registry key candidates. Install-LanguagePack.ps1 uses Product ID="LanguagePack"
# (Microsoft's documented pseudo-product) but the resulting Uninstall key name
# depends on ODT build - observed shapes:
#   - "LanguagePack - <lang>"          (pseudo-product key shape)
#   - "<TargetProduct> - <lang>"       (per-product key shape,
#                                       e.g. O365ProPlusRetail - nb-no)
# Accept either so detection stays correct regardless of which shape ODT writes.
$expectedKeyNames = @(
    "LanguagePack - $LanguageID",
    "$TargetProduct - $LanguageID"
)

$baseKey = $null
try {
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    foreach ($path in $UninstallPaths) {
        $rootKey = $baseKey.OpenSubKey($path)
        if ($null -eq $rootKey) { continue }
        try {
            foreach ($leaf in $rootKey.GetSubKeyNames()) {
                if ($expectedKeyNames -icontains $leaf) {
                    $displayName = ''
                    $childKey = $rootKey.OpenSubKey($leaf)
                    if ($null -ne $childKey) {
                        try { $displayName = [string]$childKey.GetValue('DisplayName', '') }
                        finally { $childKey.Dispose() }
                    }
                    Write-CMTraceLine -Message ("Detected language pack '{0}' under key '{1}'. DisplayName='{2}'." -f $LanguageID, $leaf, $displayName) -FullLogPath $FullLog
                    Write-Output ("LanguagePack {0} detected (key '{1}')." -f $LanguageID, $leaf)
                    exit 0
                }
            }
        }
        finally {
            $rootKey.Dispose()
        }
    }
    Write-CMTraceLine -Message ("No language pack registry key found for '{0}' (looked for: {1}). Detection: NOT installed." -f $LanguageID, ($expectedKeyNames -join ', ')) -Severity 2 -FullLogPath $FullLog
    exit 1
}
catch {
    Write-CMTraceLine -Message ("Detection error: {0}" -f $_.Exception.Message) -Severity 3 -FullLogPath $FullLog
    exit 1
}
finally {
    if ($baseKey) { $baseKey.Dispose() }
}
