#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only helpers that report current Click-to-Run Office state.

.DESCRIPTION
    Authoritative source for the toolkit: every detection script and
    every install-time sanity check goes through this module rather than
    parsing DisplayName strings in the Uninstall hive (which false-positives
    on legacy MSI entries).

    Functions exported:
        Get-OfficeConfiguration         - parsed view of C2R Configuration keys
        Test-ProductInstalled           - bool check for a given ProductReleaseId
        Get-InstalledLanguages          - array of language codes for a product
        Test-LanguagePackInstalled      - bool check for a language pack per product
        Get-OfficeChannelName           - registry URL form -> channel name
        Get-OfficeChannelGuid           - channel name -> channel GUID

.NOTES
    Module  : ODTOfficeState
    Project : m365apps-deploy
    Version : <see Common/ODTVersion.psm1>
#>

Set-StrictMode -Version Latest

# Private helpers: read registry through the explicit 64-bit view.
# Intune Management Extension is a 32-bit binary
# (C:\Program Files (x86)\Microsoft Intune Management Extension\), so
# install commands and detection scripts that it launches via
# "powershell.exe" inherit 32-bit context. Default HKLM:\SOFTWARE access
# is then silently redirected to WOW6432Node, where the C2R
# Configuration and other 64-bit-only keys do not exist. The .NET
# Microsoft.Win32 API with Registry64 view bypasses redirection.
# See docs/architecture.md rule #3.
function Get-Registry64Item {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [ValidateSet('LocalMachine','CurrentUser')]
        [string] $Hive = 'LocalMachine'
    )

    $hiveEnum = [Microsoft.Win32.RegistryHive]::$Hive
    $baseKey  = $null
    $subKey   = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hiveEnum, [Microsoft.Win32.RegistryView]::Registry64)
        $subKey  = $baseKey.OpenSubKey($Path)
        if ($null -eq $subKey) { return $null }
        $obj = [pscustomobject]@{}
        foreach ($name in $subKey.GetValueNames()) {
            $obj | Add-Member -NotePropertyName $name -NotePropertyValue $subKey.GetValue($name)
        }
        return $obj
    }
    catch { return $null }
    finally {
        if ($subKey)  { $subKey.Dispose() }
        if ($baseKey) { $baseKey.Dispose() }
    }
}

function Get-Registry64SubKeyName {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [ValidateSet('LocalMachine','CurrentUser')]
        [string] $Hive = 'LocalMachine'
    )

    $hiveEnum = [Microsoft.Win32.RegistryHive]::$Hive
    $baseKey  = $null
    $subKey   = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hiveEnum, [Microsoft.Win32.RegistryView]::Registry64)
        $subKey  = $baseKey.OpenSubKey($Path)
        if ($null -eq $subKey) { return @() }
        return @($subKey.GetSubKeyNames())
    }
    catch { return @() }
    finally {
        if ($subKey)  { $subKey.Dispose() }
        if ($baseKey) { $baseKey.Dispose() }
    }
}

# Microsoft 365 Apps / Office channel GUIDs. The registry stores
# UpdateChannel as a URL of the form http://officecdn.microsoft.com/pr/<guid>,
# while ODT configuration XMLs use the friendly name (MonthlyEnterprise,
# Current, etc.). Translating between the two is what Get-OfficeChannelName /
# Get-OfficeChannelGuid exist for. Names match what ODT's <Updates Channel="">
# attribute accepts so that rewriting the XML attribute (Visio / Project
# install scripts) produces a valid configuration. Sources:
#   https://learn.microsoft.com/intune/configmgr/sum/deploy-use/manage-office-365-proplus-updates#update-channels-for-microsoft-365-apps
#   https://learn.microsoft.com/microsoft-365-apps/deploy/office-deployment-tool-configuration-options#updates-element
$script:OfficeChannelMap = @{
    '492350f6-3a01-4f97-b9c0-c7c6ddf67d60' = 'Current'
    '55336b82-a18d-4dd6-b5f6-9e5095c314a6' = 'MonthlyEnterprise'
    '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114' = 'SemiAnnual'
    'b8f9b850-328d-4355-9145-c59439a0c4cf' = 'SemiAnnualPreview'
    '64256afe-f5d9-4f86-8936-8840a6a4f5be' = 'CurrentPreview'
    '5440fd1f-7ecb-4221-8110-145efaa6372f' = 'Beta'
    'f2e724c1-748f-4b47-8fb8-8e0d210e9208' = 'PerpetualVL2021'
}

function Get-OfficeConfiguration {
<#
.SYNOPSIS
    Return the current Click-to-Run Office configuration as a PSCustomObject.

.DESCRIPTION
    Reads HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration and exposes
    the values the toolkit needs. Returns $null if Office C2R is not installed.

.OUTPUTS
    PSCustomObject with properties:
        ProductReleaseIds  [string[]] - e.g. 'O365ProPlusRetail','VisioProRetail'
        Platform           [string]   - 'x64' or 'x86'
        UpdateChannel      [string]   - channel name if present
        CDNBaseUrl         [string]   - raw CDN URL (channel lookup aid)
        VersionToReport    [string]   - installed version
        ClientCulture      [string]   - primary UI language (e.g. 'en-us')
        InstalledLanguages [string[]] - all C2R-registered languages
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $key = Get-Registry64Item -Path 'SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    if ($null -eq $key) { return $null }

    $rawProducts = if ($key.PSObject.Properties['ProductReleaseIds']) { [string]$key.ProductReleaseIds } else { '' }
    $products = if ($rawProducts) {
        $rawProducts -split ',' |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('_') }
    }
    else { @() }

    $rawLanguages = if ($key.PSObject.Properties['ClientCulture']) { [string]$key.ClientCulture } else { '' }
    $languages = @()
    if ($rawLanguages) { $languages += $rawLanguages }

    # ClickToRun\Configuration\ProductReleaseIds sub-key holds per-language
    # enumerations; additional installed UI languages show up as value names.
    # The BCP-47 pattern admits 3-letter primaries (chr-cher-us, prs-af) and
    # script-tag languages (az-latn-az, sr-latn-rs) — narrower regexes silently
    # truncate multi-lingual installs that include those tags.
    $sub = Get-Registry64Item -Path 'SOFTWARE\Microsoft\Office\ClickToRun\Configuration\ProductReleaseIds'
    if ($null -ne $sub) {
        foreach ($prop in $sub.PSObject.Properties) {
            if ($prop.Name -notmatch '^(PS|Active|LastScenario)') {
                if ($prop.Name -match '^[a-z]{2,3}(-[a-z]{2,8}){1,3}$') {
                    $languages += $prop.Name
                }
            }
        }
    }

    [pscustomobject]@{
        ProductReleaseIds  = @($products)
        Platform           = if ($key.PSObject.Properties['Platform']) { [string]$key.Platform } else { $null }
        UpdateChannel      = if ($key.PSObject.Properties['UpdateChannel']) { [string]$key.UpdateChannel } else { $null }
        CDNBaseUrl         = if ($key.PSObject.Properties['CDNBaseUrl']) { [string]$key.CDNBaseUrl } else { $null }
        VersionToReport    = if ($key.PSObject.Properties['VersionToReport']) { [string]$key.VersionToReport } else { $null }
        ClientCulture      = if ($key.PSObject.Properties['ClientCulture']) { [string]$key.ClientCulture } else { $null }
        InstalledLanguages = @($languages | Select-Object -Unique)
    }
}

function Test-ProductInstalled {
<#
.SYNOPSIS
    Returns $true if the specified Click-to-Run product ID is installed.

.PARAMETER ProductId
    A Click-to-Run product release ID, e.g. 'O365ProPlusRetail',
    'VisioProRetail', 'ProjectProRetail'.

.EXAMPLE
    Test-ProductInstalled -ProductId VisioProRetail
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ProductId
    )

    $config = Get-OfficeConfiguration
    if ($null -eq $config) { return $false }

    foreach ($id in $config.ProductReleaseIds) {
        if ($id -ieq $ProductId) { return $true }
    }
    return $false
}

function Get-InstalledLanguages {
<#
.SYNOPSIS
    Return the list of language codes installed for a given Click-to-Run product.

.DESCRIPTION
    Walks the 64-bit and 32-bit Uninstall hives looking for keys named
    '<ProductId> - <language>' (e.g. 'O365ProPlusRetail - nb-no'). This is
    how C2R registers per-language sub-packages, and the per-language keys
    are the source of truth: the C2R installer creates one for every
    installed language, including the primary culture. ClientCulture from
    the Configuration registry isn't consulted here — it's a property of
    the M365 Apps install, not of any specific ProductId, and conflating
    the two led to a false-positive idempotency check fixed in v1.0.6.

.PARAMETER ProductId
    Click-to-Run product release ID to enumerate languages for.

.OUTPUTS
    [string[]] - e.g. @('en-us', 'nb-no')
#>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ProductId
    )

    $languages = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $pattern = "$ProductId - "
    $uninstallPaths = @(
        'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $uninstallPaths) {
        foreach ($leaf in (Get-Registry64SubKeyName -Path $root)) {
            if ($leaf -and $leaf.StartsWith($pattern, [System.StringComparison]::OrdinalIgnoreCase)) {
                $lang = $leaf.Substring($pattern.Length).Trim()
                if ($lang -match '^[a-z]{2,3}(-[a-z]{2,8}){1,3}$') {
                    [void]$languages.Add($lang.ToLowerInvariant())
                }
            }
        }
    }

    return @($languages | Sort-Object)
}

function Get-LanguagePackInstallationStatus {
<#
.SYNOPSIS
    Returns the per-product installation status of a language pack across
    every currently installed Click-to-Run product on the machine.

.DESCRIPTION
    Iterates the products listed in ClickToRun\Configuration\ProductReleaseIds
    and reports, per product, whether '<ProductId> - <LanguageID>' exists
    in the Uninstall hive. The aggregate Installed flag is $true only when
    every product has the language.

    Why per-product rather than "is the language anywhere on this machine":
    Microsoft's `Product ID="LanguagePack"` install spreads the language
    across every installed product (creating per-product Uninstall keys
    for each). A naive "language is installed somewhere" check would
    false-positive when the language is present for the base product (e.g.
    M365 Apps installed with -Language nb-no) but not for add-ons (Visio
    or Project installed in en-us, no nb-no per-product key). The naive
    check would skip Install-LanguagePack, leaving the add-on products
    without nb-no rendering — the bug surfaced by v1.0.5 scenario 2 and
    fixed in v1.0.6.

    v1.0.7 promotes that per-product check from an internal bool computation
    to a first-class structured result so the install/uninstall scripts can
    log which products are present/missing — admins reading IME/CMTrace
    logs see exactly why setup.exe ran (or didn't) and which products
    gained/lost the language post-install.

    The per-product check accepts whichever Uninstall-key shape ODT writes
    for each product (the per-product '<ProductId> - <lang>' shape is what
    Get-InstalledLanguages walks; the 'LanguagePack' pseudo-product, if
    registered in ProductReleaseIds, gets the same treatment).

.PARAMETER LanguageID
    BCP-47 language code (e.g. 'nb-no', 'en-us').

.OUTPUTS
    [pscustomobject] with:
        LanguageID  [string]                       - normalized to lower-case
        Installed   [bool]                         - $true iff every product has the language
        PerProduct  [System.Collections.Specialized.OrderedDictionary]
                                                   - keyed on ProductId, value = $true|$false.
                                                     Empty when no C2R config detected or
                                                     ProductReleaseIds is empty.

.EXAMPLE
    $s = Get-LanguagePackInstallationStatus -LanguageID 'nb-no'
    if (-not $s.Installed) {
        $missing = $s.PerProduct.GetEnumerator() |
            Where-Object { -not $_.Value } |
            Select-Object -ExpandProperty Key
        # ... run setup.exe to spread the LP to $missing ...
    }
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[a-zA-Z]{2,3}(-[a-zA-Z]{2,8}){1,3}$')]
        [string] $LanguageID
    )

    $normalized = $LanguageID.ToLowerInvariant()
    $perProduct = [ordered]@{}

    $config = Get-OfficeConfiguration
    if ($null -eq $config) {
        return [pscustomobject]@{
            LanguageID = $normalized
            Installed  = $false
            PerProduct = $perProduct
        }
    }

    $productIds = @($config.ProductReleaseIds)
    if ($productIds.Count -eq 0) {
        return [pscustomobject]@{
            LanguageID = $normalized
            Installed  = $false
            PerProduct = $perProduct
        }
    }

    $allInstalled = $true
    foreach ($productId in $productIds) {
        $langs   = Get-InstalledLanguages -ProductId $productId
        $present = ($langs -icontains $normalized)
        $perProduct[$productId] = $present
        if (-not $present) { $allInstalled = $false }
    }

    return [pscustomobject]@{
        LanguageID = $normalized
        Installed  = $allInstalled
        PerProduct = $perProduct
    }
}

function Test-LanguagePackInstalled {
<#
.SYNOPSIS
    Returns $true when the language pack is installed for EVERY currently
    installed Click-to-Run product on the machine.

.DESCRIPTION
    Thin wrapper around Get-LanguagePackInstallationStatus, retained as a
    convenience for callers that only need the bool answer. See the helper
    function for the full per-product picture.

.PARAMETER LanguageID
    BCP-47 language code (e.g. 'nb-no', 'en-us').

.OUTPUTS
    [bool]
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[a-zA-Z]{2,3}(-[a-zA-Z]{2,8}){1,3}$')]
        [string] $LanguageID
    )

    return (Get-LanguagePackInstallationStatus -LanguageID $LanguageID).Installed
}

function Get-OfficeChannelName {
<#
.SYNOPSIS
    Translate an UpdateChannel registry value (URL form) into the canonical
    channel name used in ODT configuration XMLs.

.DESCRIPTION
    The Click-to-Run configuration key stores UpdateChannel as something like
    `http://officecdn.microsoft.com/pr/55336b82-a18d-4dd6-b5f6-9e5095c314a6`
    while ODT configuration XMLs use names like `MonthlyEnterprise`. Comparing
    the two as-is never matches even when they refer to the same channel -
    which is what this function exists to fix.

    Accepts either form on input:
      - A full URL      -> extracts the GUID, returns the mapped name.
      - A bare GUID     -> returns the mapped name.
      - A channel name  -> returned as-is if recognised.

.PARAMETER UpdateChannel
    Raw registry value, GUID, or channel name.

.OUTPUTS
    [string] channel name, or $null when the input cannot be translated.
    Emits Write-Warning on unknown GUIDs / unrecognised values.

.EXAMPLE
    Get-OfficeChannelName 'http://officecdn.microsoft.com/pr/55336b82-a18d-4dd6-b5f6-9e5095c314a6'
    # MonthlyEnterprise

.EXAMPLE
    Get-OfficeChannelName 'Current'
    # Current   (passed through unchanged)
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $UpdateChannel
    )

    if ([string]::IsNullOrWhiteSpace($UpdateChannel)) { return $null }

    # Caller may already have the friendly name (from an XML, a cache, etc.).
    foreach ($known in $script:OfficeChannelMap.Values) {
        if ($UpdateChannel -ieq $known) { return $known }
    }

    # Otherwise we expect something containing a GUID (URL form or bare).
    $match = [regex]::Match($UpdateChannel, '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})', 'IgnoreCase')
    if (-not $match.Success) {
        Write-Warning ("Get-OfficeChannelName: '{0}' is neither a known channel name nor a GUID-containing URL." -f $UpdateChannel)
        return $null
    }

    $guid = $match.Value.ToLowerInvariant()
    if ($script:OfficeChannelMap.ContainsKey($guid)) {
        return $script:OfficeChannelMap[$guid]
    }

    Write-Warning ("Get-OfficeChannelName: GUID '{0}' is not in the known channel map. Channel unknown." -f $guid)
    return $null
}

function Get-OfficeChannelGuid {
<#
.SYNOPSIS
    Return the CDN GUID for a given Office channel name.

.DESCRIPTION
    Inverse of Get-OfficeChannelName. Useful if you ever need to author the
    registry-form UpdateChannel URL from a config name (for example, to
    stamp a synthetic state value in tests).

.PARAMETER ChannelName
    Canonical channel name: Current, MonthlyEnterprise, SemiAnnual,
    SemiAnnualPreview, CurrentPreview, Beta, PerpetualVL2021.

.OUTPUTS
    [string] GUID, or $null when the name is not in the known set.
    Emits Write-Warning on unknown input.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $ChannelName
    )

    foreach ($kv in $script:OfficeChannelMap.GetEnumerator()) {
        if ($kv.Value -ieq $ChannelName) {
            return $kv.Key
        }
    }
    Write-Warning ("Get-OfficeChannelGuid: channel name '{0}' is not in the known channel map." -f $ChannelName)
    return $null
}

Export-ModuleMember -Function @(
    'Get-OfficeConfiguration',
    'Test-ProductInstalled',
    'Get-InstalledLanguages',
    'Get-LanguagePackInstallationStatus',
    'Test-LanguagePackInstalled',
    'Get-OfficeChannelName',
    'Get-OfficeChannelGuid'
)
