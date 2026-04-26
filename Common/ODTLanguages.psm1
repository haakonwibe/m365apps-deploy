#Requires -Version 5.1
<#
.SYNOPSIS
    Per-product language matrix used by the toolkit's language-pack workflows.

.DESCRIPTION
    Visio and Project support a narrower set of languages than Office. We
    validate the combination of (TargetProduct, LanguageID) BEFORE launching
    setup.exe so administrators see a clear error rather than the cryptic
    ODT failure ("Language not available").

    The matrix below is a conservative intersection compiled from the
    Microsoft Learn pages:

        https://learn.microsoft.com/microsoft-365-apps/deploy/overview-deploying-languages-microsoft-365-apps

    Microsoft updates language availability over time. If you hit a
    "Language not available" failure for a combination marked valid here,
    compare against the live Microsoft documentation and update this module
    + docs/language-matrix.md accordingly.

.NOTES
    Module  : ODTLanguages
    Project : m365apps-deploy
    Version : 1.0.0
#>

Set-StrictMode -Version Latest

# Full Office UI language list (M365 Apps, aka O365ProPlusRetail).
$script:OfficeLanguages = @(
    'af-za','am-et','ar-sa','as-in','az-latn-az','be-by','bg-bg','bn-bd','bn-in',
    'bs-latn-ba','ca-es','ca-es-valencia','chr-cher-us','cs-cz','cy-gb','da-dk',
    'de-de','el-gr','en-gb','en-us','es-es','es-mx','et-ee','eu-es','fa-ir',
    'fi-fi','fil-ph','fr-ca','fr-fr','ga-ie','gd-gb','gl-es','gu-in','ha-latn-ng',
    'he-il','hi-in','hr-hr','hu-hu','hy-am','id-id','ig-ng','is-is','it-it',
    'iu-latn-ca','ja-jp','ka-ge','kk-kz','km-kh','kn-in','ko-kr','kok-in','ku-arab-iq',
    'ky-kg','lb-lu','lo-la','lt-lt','lv-lv','mi-nz','mk-mk','ml-in','mn-mn','mr-in',
    'ms-my','mt-mt','my-mm','nb-no','ne-np','nl-nl','nn-no','nso-za','or-in','pa-in',
    'pl-pl','prs-af','ps-af','pt-br','pt-pt','quc-latn-gt','quz-pe','rm-ch','ro-ro',
    'ru-ru','rw-rw','sd-arab-pk','si-lk','sk-sk','sl-si','sq-al','sr-cyrl-ba',
    'sr-cyrl-rs','sr-latn-rs','sv-se','sw-ke','ta-in','te-in','tg-cyrl-tj','th-th',
    'ti-et','tk-tm','tn-za','tr-tr','tt-ru','ug-cn','uk-ua','ur-pk','uz-latn-uz',
    'vi-vn','wo-sn','xh-za','yo-ng','zh-cn','zh-tw','zu-za'
)

# Visio supports a subset of the full Office language list.
# Note: en-gb in particular has been known to fail for Visio even though it's
# documented as supported on some builds. Admins should test Visio language
# installs before broad deployment.
$script:VisioLanguages = @(
    'ar-sa','bg-bg','cs-cz','da-dk','de-de','el-gr','en-gb','en-us','es-es','es-mx',
    'et-ee','fi-fi','fr-ca','fr-fr','he-il','hi-in','hr-hr','hu-hu','id-id','it-it',
    'ja-jp','kk-kz','ko-kr','lt-lt','lv-lv','nb-no','nl-nl','pl-pl','pt-br','pt-pt',
    'ro-ro','ru-ru','sk-sk','sl-si','sr-latn-rs','sv-se','th-th','tr-tr','uk-ua',
    'vi-vn','zh-cn','zh-tw'
)

# Project supports the same subset as Visio on Click-to-Run.
$script:ProjectLanguages = @(
    'ar-sa','bg-bg','cs-cz','da-dk','de-de','el-gr','en-gb','en-us','es-es','es-mx',
    'et-ee','fi-fi','fr-ca','fr-fr','he-il','hi-in','hr-hr','hu-hu','id-id','it-it',
    'ja-jp','kk-kz','ko-kr','lt-lt','lv-lv','nb-no','nl-nl','pl-pl','pt-br','pt-pt',
    'ro-ro','ru-ru','sk-sk','sl-si','sr-latn-rs','sv-se','th-th','tr-tr','uk-ua',
    'vi-vn','zh-cn','zh-tw'
)

function Get-ODTSupportedLanguages {
<#
.SYNOPSIS
    Return the array of supported language codes for a given Click-to-Run product.

.PARAMETER TargetProduct
    Click-to-Run product ID. One of:
      O365ProPlusRetail, VisioProRetail, VisioStdRetail, ProjectProRetail, ProjectStdRetail.

.OUTPUTS
    [string[]] - all lower-case BCP-47 codes supported for that product.
#>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $TargetProduct
    )

    switch ($TargetProduct) {
        'O365ProPlusRetail' { return $script:OfficeLanguages }
        'VisioProRetail'    { return $script:VisioLanguages }
        'VisioStdRetail'    { return $script:VisioLanguages }
        'ProjectProRetail'  { return $script:ProjectLanguages }
        'ProjectStdRetail'  { return $script:ProjectLanguages }
        default {
            # Unknown product; fall back to the Office list but make it visible.
            Write-Warning "Get-ODTSupportedLanguages: unknown product '$TargetProduct'. Falling back to Office language list."
            return $script:OfficeLanguages
        }
    }
}

function Test-ODTLanguageSupported {
<#
.SYNOPSIS
    Return $true if the supplied language code is supported for the product.

.PARAMETER LanguageID
    BCP-47 code (e.g. 'nb-no').

.PARAMETER TargetProduct
    Click-to-Run product ID.
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[a-zA-Z]{2}(-[a-zA-Z]{2,8}){1,3}$')]
        [string] $LanguageID,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $TargetProduct
    )

    $normalized = $LanguageID.ToLowerInvariant()
    $supported  = Get-ODTSupportedLanguages -TargetProduct $TargetProduct
    return ($supported -contains $normalized)
}

function Assert-ODTLanguageSupported {
<#
.SYNOPSIS
    Throw a clear error if a (LanguageID, TargetProduct) pair is unsupported.

.DESCRIPTION
    Used by Install-LanguagePack.ps1 to surface invalid combinations
    early, rather than letting ODT fail cryptically.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $LanguageID,

        [Parameter(Mandatory)]
        [string] $TargetProduct
    )

    if (-not (Test-ODTLanguageSupported -LanguageID $LanguageID -TargetProduct $TargetProduct)) {
        $examples = (Get-ODTSupportedLanguages -TargetProduct $TargetProduct | Select-Object -First 10) -join ', '
        throw "Language '$LanguageID' is not supported for product '$TargetProduct'. See docs/language-matrix.md. Supported examples: $examples..."
    }
}

Export-ModuleMember -Function @(
    'Get-ODTSupportedLanguages',
    'Test-ODTLanguageSupported',
    'Assert-ODTLanguageSupported'
)
