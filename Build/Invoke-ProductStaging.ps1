#Requires -Version 5.1
<#
.SYNOPSIS
    Shared product-staging helper used by Build-IntuneWinPackages.ps1.

.DESCRIPTION
    Dot-source this file to gain two functions:

        Get-ProductDefinitions  - canonical product map
                                  (name -> SourceFolder, SetupScript,
                                   DisplayName, RequiresBase, ...).
        Invoke-ProductStaging   - assemble a self-contained product
                                  folder at <OutputRoot>\<Product>\.

    Build-IntuneWinPackages.ps1 invokes this with
    -OutputRoot Build\Staging so the staged result lands at
    Build\Staging\<Product>\. In a full build, IntuneWinAppUtil.exe
    then wraps each staged folder and the final .intunewin plus a
    matching <Product>-IntuneConfig.md land in Build\Output\<Product>\.
    With -StagingOnly, Staging is the terminal output and Build\Output\
    is skipped.

    The staged layout mirrors exactly what Intune extracts on a client
    when it delivers the corresponding .intunewin:

        <OutputRoot>/<Product>/
        +-- <Install|Uninstall|Detect>-*.ps1
        +-- Configurations/
        |   +-- *.xml
        +-- Tools/
        |   +-- setup.exe    (staged from -SetupExeSource, or kept if
        |                     a per-product copy was already present)
        +-- Common/
            +-- ODT*.psm1    (staged from <RepositoryRoot>\Common)

    The Install / Uninstall scripts probe for Common/ at
    $PSScriptRoot\Common first, falling back to
    $PSScriptRoot\..\Common. Both the staged/Intune layout (first branch)
    and the repo-dev layout (second branch) therefore work without any
    environment-specific configuration.

.NOTES
    Library : Invoke-ProductStaging.ps1
    Project : m365apps-deploy
    Version : 1.0.0

    Do not run this file directly; dot-source it from a build script:

        . (Join-Path $PSScriptRoot 'Invoke-ProductStaging.ps1')
#>

Set-StrictMode -Version Latest

function Get-DefaultBuildTokens {
<#
.SYNOPSIS
    Return the canonical token registration table for build-time XML
    substitution.

.DESCRIPTION
    The build pipeline replaces `{{TokenName}}` placeholders in staged
    Configurations\*.xml files. Tokens come in three flavours:

      Mode = 'BuildTime'        Scalar. Resolved at build time. If Value
                                is set, `{{Token}}` is substituted in
                                place. If Value is $null / empty /
                                whitespace, the entire LINE containing
                                the placeholder is removed from the
                                staged file. Mirrors how
                                config.office.com treats blank fields
                                (the setting simply isn't applied).
      Mode = 'ArrayExpansion'   Array. The source XML wraps a default
                                block in marker comments
                                `<!-- {{TokenName:begin}} -->` and
                                `<!-- {{TokenName:end}} -->`. The
                                engine parses the default array out of
                                the block content; if the caller has
                                supplied an override Value (a
                                non-$null array), the override replaces
                                the default. Either way the resolved
                                array is sorted, validated against
                                KnownValues, and rendered as one
                                element per entry using the indentation
                                of the begin marker. Empty array
                                renders zero elements; the surrounding
                                XML stays intact. Override does not
                                supplement - it replaces.
      Mode = 'Runtime'          Passes through unchanged. Used for
                                tokens resolved later by an install
                                script. Today the only consumers are
                                the LanguagePack template's
                                `{{OfficeClientEdition}}`, `{{Channel}}`,
                                `{{LanguageID}}` which
                                Install-LanguagePack.ps1 substitutes
                                against the live device state.

    After substitution the engine scans the staged content for any
    remaining `{{...}}` patterns and hard-fails if a placeholder name
    is not registered here - the registration table is the single
    source of truth for what tokens may exist anywhere in the source
    XMLs.

.OUTPUTS
    [System.Collections.Specialized.OrderedDictionary] keyed on token
    name (without the curly braces). Each entry is a hashtable with
    Mode plus mode-specific keys (Value for BuildTime / ArrayExpansion;
    KnownValues / ElementName / IDAttribute for ArrayExpansion).
#>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()

    [ordered]@{
        'CompanyName'         = @{ Mode = 'BuildTime'; Value = $null }
        'ExcludedApps'        = @{
            Mode         = 'ArrayExpansion'
            Value        = $null   # $null = use default block from XML; array = override.
            ElementName  = 'ExcludeApp'
            IDAttribute  = 'ID'
            # Canonical Microsoft Office Deployment Tool ExcludeApp ID values.
            # Source: learn.microsoft.com/microsoft-365-apps/deploy/office-deployment-tool-configuration-options#excludeapp-element
            # 'Bing' is also accepted (Microsoft Search in Bing extension; documented in
            # the Intune excludedApps Graph resource and accepted by ODT in practice).
            KnownValues  = @(
                'Access','Bing','Excel','Groove','Lync','OneDrive','OneNote',
                'Outlook','OutlookForWindows','PowerPoint','Publisher','Teams','Word'
            )
        }
        'OfficeClientEdition' = @{ Mode = 'Runtime' }
        'Channel'             = @{ Mode = 'Runtime' }
        'LanguageID'          = @{ Mode = 'Runtime' }
    }
}

function Get-ArrayTokenDefaults {
<#
.SYNOPSIS
    Resolve the default array for an ArrayExpansion-mode token by
    reading the marker block out of source XMLs (pre-staging).

.DESCRIPTION
    The build banner needs to show what an ArrayExpansion token will
    resolve to when no override is set, so admins reading a build log
    can see the actual IDs being applied without cross-referencing
    the XML. This function does a one-shot regex scan of every source
    XML under <RepositoryRoot>\<Product>\Configurations\, finds the
    first matching `<!-- {{TokenName:begin}} --> ... :end -->` block,
    and returns the sorted list of IDs from elements that match the
    token's ElementName / IDAttribute.

    Source-of-truth note: this duplicates the regex shape from
    Expand-XmlArrayTokens. Acceptable because the cost is six lines
    of regex; if a third caller appears, factor a shared helper.

.PARAMETER TokenName
    Token name (e.g. 'ExcludedApps').

.PARAMETER TokenSpec
    The token entry from $Tokens (provides ElementName / IDAttribute).

.PARAMETER RepositoryRoot
    Repository root. Source XMLs are searched under
    <root>\<Product>\Configurations\*.xml; Build\Staging and Build\Output
    are excluded.

.OUTPUTS
    [string[]] sorted (case-insensitive) list of IDs from the first
    matching block. Empty array if no block found.
#>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $TokenName,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        $TokenSpec,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $RepositoryRoot
    )

    $element = [string]$TokenSpec.ElementName
    $idAttr  = [string]$TokenSpec.IDAttribute
    if ([string]::IsNullOrWhiteSpace($element) -or [string]::IsNullOrWhiteSpace($idAttr)) { return @() }

    $beginPattern = '\{\{\s*' + [regex]::Escape($TokenName) + '\s*:\s*begin\s*\}\}'
    $endPattern   = '\{\{\s*' + [regex]::Escape($TokenName) + '\s*:\s*end\s*\}\}'
    $blockRegex   = [regex]::new('(?ms)<!--\s*' + $beginPattern + '\s*-->\s*\r?\n(?<body>.*?)<!--\s*' + $endPattern + '\s*-->', 'IgnoreCase')
    $idRegex      = [regex]::new('<\s*' + [regex]::Escape($element) + '\b[^>]*\b' + [regex]::Escape($idAttr) + '\s*=\s*"(?<id>[^"]+)"', 'IgnoreCase')

    $candidates = @()
    foreach ($product in (Get-ProductDefinitions).Keys) {
        $configDir = Join-Path -Path $RepositoryRoot -ChildPath ((Get-ProductDefinitions)[$product].SourceFolder + '\Configurations')
        if (-not (Test-Path -LiteralPath $configDir -PathType Container)) { continue }
        $candidates += Get-ChildItem -LiteralPath $configDir -Filter '*.xml' -File -ErrorAction SilentlyContinue
    }

    foreach ($xml in $candidates) {
        $content = [System.IO.File]::ReadAllText($xml.FullName)
        $bm = $blockRegex.Match($content)
        if (-not $bm.Success) { continue }
        $ids = @()
        foreach ($m in $idRegex.Matches($bm.Groups['body'].Value)) { $ids += $m.Groups['id'].Value }
        return @($ids | Sort-Object -Property @{ Expression = { $_.ToLowerInvariant() } })
    }
    return @()
}

function Expand-XmlArrayTokens {
<#
.SYNOPSIS
    Pre-pass for ArrayExpansion-mode tokens. Mutates `$XmlContent` by
    locating each registered ArrayExpansion token's begin/end marker
    block, resolving the effective array (override Value or default
    extracted from the block content), validating IDs, sorting, and
    rendering one element per entry.

.DESCRIPTION
    Marker shape (case-insensitive on the marker name; whitespace
    around the curly braces is tolerant):

        <!-- {{TokenName:begin}} -->
        <ElementName IDAttribute="Foo" />
        <ElementName IDAttribute="Bar" />
        <!-- {{TokenName:end}} -->

    The engine:
      1. Captures the indentation prefix on the begin-marker line and
         re-uses it for every emitted element.
      2. Extracts the default array from the lines between the markers
         by looking for `<ElementName IDAttribute="..." />` shapes.
      3. If `$Tokens[$name].Value` is $null, uses the extracted
         defaults. If it is an array (including an empty one), the
         array overrides the defaults entirely - this is replacement
         semantics, not supplementation.
      4. Validates every value against KnownValues and throws on
         unknowns (ODT silently ignores invalid IDs, so a typo would
         otherwise ship a working-looking package that doesn't apply
         the exclusion).
      5. Sorts the resolved array (case-insensitive ordinal) for
         deterministic output across runs.
      6. Replaces the entire begin..end block (markers and all) with
         the rendered elements. Empty array renders nothing - just the
         block disappears, leaving the parent element well-formed.

    Throws if a begin marker has no matching end (or vice versa).

.PARAMETER XmlContent
    Raw text of the XML file (post file-read, pre line-by-line scalar
    substitution).

.PARAMETER Tokens
    Token registration table from Get-DefaultBuildTokens.

.PARAMETER FilePath
    Path of the source file, used in error messages only.

.OUTPUTS
    [pscustomobject] with:
        Content   [string]              - $XmlContent with all ArrayExpansion blocks resolved
        Expansions [pscustomobject[]]  - one entry per resolved token (Token, ResolvedFrom, ItemCount)
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $XmlContent,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        $Tokens,

        [Parameter(Mandatory)]
        [string] $FilePath
    )

    $result     = $XmlContent
    $expansions = New-Object System.Collections.Generic.List[pscustomobject]

    foreach ($name in $Tokens.Keys) {
        $token = $Tokens[$name]
        if ([string]$token.Mode -ne 'ArrayExpansion') { continue }

        $beginPattern = '\{\{\s*' + [regex]::Escape($name) + '\s*:\s*begin\s*\}\}'
        $endPattern   = '\{\{\s*' + [regex]::Escape($name) + '\s*:\s*end\s*\}\}'
        # Whole-block regex: capture leading indent on the begin-marker line
        # plus everything up to and including the end-marker line.
        # `(?ms)` enables singleline-dot + multiline ^/$.
        $blockRegex = [regex]::new(
            '(?ms)^(?<indent>[ \t]*)<!--\s*' + $beginPattern + '\s*-->[ \t]*\r?\n(?<body>.*?)^[ \t]*<!--\s*' + $endPattern + '\s*-->[ \t]*$',
            'IgnoreCase'
        )

        # Sanity check: orphan markers (one without the other) are a hard
        # error - the source XML is malformed and the build should refuse.
        # Multiple begin/end pairs for the same token are also a hard error -
        # the operational marker block is unique per file. A common cause is
        # the source XML's descriptive header quoting the marker syntax in
        # prose; the fix there is to describe the markers without writing
        # them literally.
        $beginCount = ([regex]::Matches($result, '<!--\s*' + $beginPattern + '\s*-->', 'IgnoreCase')).Count
        $endCount   = ([regex]::Matches($result, '<!--\s*' + $endPattern   + '\s*-->', 'IgnoreCase')).Count
        if ($beginCount -ne $endCount) {
            throw ("Expand-XmlArrayTokens: token '{0}' has {1} begin marker(s) and {2} end marker(s) in '{3}'. They must come in matched pairs." -f $name, $beginCount, $endCount, $FilePath)
        }
        if ($beginCount -gt 1) {
            throw ("Expand-XmlArrayTokens: token '{0}' has {1} begin/end marker pair(s) in '{2}'. Only one operational pair per file is allowed; if the descriptive header quotes the marker syntax, reword it to avoid the literal `<!-- {{$name`:begin}} -->` shape." -f $name, $beginCount, $FilePath)
        }

        $blockMatch = $blockRegex.Match($result)
        if (-not $blockMatch.Success) {
            # Token registered but no marker block found in this file.
            # That is fine - not every XML uses every array token.
            continue
        }

        $indent      = $blockMatch.Groups['indent'].Value
        $body        = $blockMatch.Groups['body'].Value
        $elementName = [string]$token.ElementName
        $idAttribute = [string]$token.IDAttribute
        if ([string]::IsNullOrWhiteSpace($elementName) -or [string]::IsNullOrWhiteSpace($idAttribute)) {
            throw ("Expand-XmlArrayTokens: token '{0}' is ArrayExpansion mode but lacks ElementName / IDAttribute in registration." -f $name)
        }

        # Default array: parse <ElementName IDAttribute="Foo" /> shapes out of the block body.
        $defaultRegex = [regex]::new(
            '<\s*' + [regex]::Escape($elementName) + '\b[^>]*\b' + [regex]::Escape($idAttribute) + '\s*=\s*"(?<id>[^"]+)"[^>]*/?\s*>',
            'IgnoreCase'
        )
        $defaultArray = @()
        foreach ($m in $defaultRegex.Matches($body)) {
            $defaultArray += $m.Groups['id'].Value
        }

        $effective = $null
        $source    = 'default'
        if ($null -ne $token.Value) {
            # Override path - even an empty array counts as an explicit override.
            $effective = @($token.Value)
            $source    = 'override'
        }
        else {
            $effective = $defaultArray
        }

        # Validate every value against KnownValues. Unknowns are a build error.
        $known = @($token.KnownValues)
        $unknowns = @($effective | Where-Object { $_ -and ($known -inotcontains $_) })
        if ($unknowns.Count -gt 0) {
            throw ("Expand-XmlArrayTokens: token '{0}' contains unknown value(s) [{1}] in '{2}'. Allowed values: {3}." -f $name, ($unknowns -join ', '), $FilePath, ($known -join ', '))
        }

        # Sort case-insensitively for deterministic output across runs.
        $sorted = @($effective | Sort-Object -Property @{ Expression = { $_.ToLowerInvariant() } })

        if ($sorted.Count -eq 0) {
            $rendered = ''
        }
        else {
            $renderedLines = $sorted | ForEach-Object {
                ('{0}<{1} {2}="{3}" />' -f $indent, $elementName, $idAttribute, $_)
            }
            $rendered = ($renderedLines -join "`r`n")
        }

        # Replace the whole block (begin marker through end marker) with the
        # rendered text. Use a MatchEvaluator delegate so the replacement
        # string is treated as a literal (no `\` / `$` escaping required for
        # the ID values). Operate on the running `$result` so successive
        # ArrayExpansion tokens compose correctly.
        $captured = $rendered
        $result = $blockRegex.Replace($result, { param($m) $captured }, 1)

        $expansions.Add([pscustomobject]@{
            Token        = $name
            ResolvedFrom = $source
            ItemCount    = $sorted.Count
        })
    }

    [pscustomobject]@{
        Content    = $result
        Expansions = @($expansions)
    }
}

function Invoke-XmlTokenSubstitution {
<#
.SYNOPSIS
    Apply build-time token substitution to a single XML file in place.

.DESCRIPTION
    Reads the file, processes line-by-line:
      - For each registered BuildTime token whose Value is a non-empty
        string: replace `{{Token}}` with that value.
      - For each registered BuildTime token whose Value is $null /
        empty / whitespace: drop the entire line containing the
        placeholder. This is the "leave it blank, don't apply"
        semantic that mirrors config.office.com / OCT.
      - Runtime tokens are left untouched.

    After all line-level edits, an empty `<AppSettings></AppSettings>`
    or `<AppSettings />` block (which can result from removing the only
    child line inside it) is stripped from the output for tidy XML.

    Finally the result is scanned for any `{{...}}` left over. If the
    captured name is not present in the token table, the function
    throws - this catches typos in source XMLs and tokens that were
    referenced but never registered.

.PARAMETER Path
    Absolute path to the XML file to rewrite in place.

.PARAMETER Tokens
    Token table from Get-DefaultBuildTokens, possibly with BuildTime
    Values populated from CLI / config-file resolution.

.PARAMETER PreserveLineEndings
    Honour the file's existing line endings. CRLF is preserved if any
    were observed in the source. Default is $true.

.OUTPUTS
    [pscustomobject] with:
        Path             [string]   - the file rewritten
        Substituted      [int]      - number of `{{Token}}` substitutions made
        LinesRemoved     [int]      - number of lines dropped due to unset BuildTime tokens
        EmptyBlocksStripped [int]   - number of empty <AppSettings/> blocks stripped
        BuildTokens      [string[]] - distinct BuildTime token names processed
        RuntimeTokens    [string[]] - distinct Runtime token names left intact
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        $Tokens,

        [bool] $PreserveLineEndings = $true
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Invoke-XmlTokenSubstitution: file not found: '$Path'."
    }

    $raw      = [System.IO.File]::ReadAllText($Path)
    $usedCrlf = ($raw -match "`r`n")
    $newline  = if ($PreserveLineEndings -and $usedCrlf) { "`r`n" } else { "`n" }

    # Phase 1: ArrayExpansion tokens. Resolve marker blocks
    # (<!-- {{TokenName:begin}} --> ... <!-- {{TokenName:end}} -->) into
    # rendered child elements, sorted, validated. Done before the line-by-line
    # scalar pass so the post-substitution unregistered-token scan never sees
    # the markers.
    $arrayPass    = Expand-XmlArrayTokens -XmlContent $raw -Tokens $Tokens -FilePath $Path
    $raw          = $arrayPass.Content
    $arrayResults = $arrayPass.Expansions

    # Split preserving line content (but discard line terminators); we re-join below.
    $lines = $raw -split "`r?`n"

    $output       = New-Object System.Collections.Generic.List[string]
    $substituted  = 0
    $linesRemoved = 0
    $buildSeen    = New-Object System.Collections.Generic.HashSet[string]
    $runtimeSeen  = New-Object System.Collections.Generic.HashSet[string]

    foreach ($line in $lines) {
        $modified = $line
        $dropLine = $false

        foreach ($name in $Tokens.Keys) {
            $token = $Tokens[$name]
            $mode  = [string]$token.Mode
            # ArrayExpansion tokens are handled in the pre-pass, above.
            # Their markers are <!-- {{Name:begin}} -->, never bare `{{Name}}`,
            # so there is nothing for the scalar pass to match.
            if ($mode -eq 'ArrayExpansion') { continue }

            $placeholder = '{{' + $name + '}}'
            if ($modified.IndexOf($placeholder, [System.StringComparison]::Ordinal) -lt 0) { continue }

            if ($mode -eq 'Runtime') {
                [void]$runtimeSeen.Add($name)
                # Leave the placeholder for the runtime install script.
            }
            elseif ($mode -eq 'BuildTime') {
                [void]$buildSeen.Add($name)
                $value = $null
                if ($token.Contains('Value')) { $value = $token.Value }
                if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
                    # Count placeholder occurrences in the line before substituting.
                    $count = 0
                    $idx = 0
                    while (($idx = $modified.IndexOf($placeholder, $idx, [System.StringComparison]::Ordinal)) -ge 0) {
                        $count++
                        $idx += $placeholder.Length
                    }
                    $modified = $modified.Replace($placeholder, [string]$value)
                    $substituted += $count
                }
                else {
                    $dropLine = $true
                    break  # No point examining other tokens; the line is going away.
                }
            }
            else {
                throw "Invoke-XmlTokenSubstitution: token '$name' has unknown Mode '$mode'. Expected 'BuildTime' or 'Runtime'."
            }
        }

        if ($dropLine) {
            $linesRemoved++
        }
        else {
            $output.Add($modified)
        }
    }

    $result = $output -join $newline

    # Strip empty <AppSettings>...</AppSettings> blocks (any whitespace /
    # newlines between the open and close tags) and self-closing empty
    # <AppSettings/>. Both shapes can result from removing the only child
    # line inside an AppSettings block. Count first, then strip - cheap
    # because the result file is small.
    $emptyBlockPatterns = @(
        '\r?\n[ \t]*<AppSettings>\s*</AppSettings>',
        '\r?\n[ \t]*<AppSettings\s*/>'
    )
    $emptyBlocks = 0
    foreach ($pattern in $emptyBlockPatterns) {
        $rx = [regex]::new($pattern, 'IgnoreCase')
        $emptyBlocks += $rx.Matches($result).Count
        $result = $rx.Replace($result, '')
    }

    # Collapse runs of 2+ blank (whitespace-only) lines down to a single
    # blank line. Removing an AppSettings block or its only inner <Setup>
    # line often leaves a double-blank gap; this keeps staged XMLs visually
    # tidy. Done line-by-line so the next non-blank line's leading
    # indentation is preserved exactly.
    $cleaned = New-Object System.Collections.Generic.List[string]
    $consecutiveBlanks = 0
    foreach ($line in ($result -split "`r?`n")) {
        if ($line -match '^\s*$') {
            $consecutiveBlanks++
            if ($consecutiveBlanks -le 1) { $cleaned.Add('') }
        }
        else {
            $consecutiveBlanks = 0
            $cleaned.Add($line)
        }
    }
    $result = $cleaned -join $newline

    # Hard-fail on any remaining {{...}} that isn't a registered Runtime token.
    foreach ($match in [regex]::Matches($result, '\{\{([^{}]+)\}\}')) {
        $name = $match.Groups[1].Value.Trim()

        # An ArrayExpansion marker (`Name:begin` / `Name:end`) here means the
        # pre-pass didn't consume it. Either the markers are unmatched, or
        # the source XML used the wrong shape (`{{Name}}` bare, or
        # `{{Name:something-else}}`). Surface a specific error.
        $colonMatch = [regex]::Match($name, '^(?<token>[A-Za-z][A-Za-z0-9_-]*)\s*:\s*(?<part>begin|end)$', 'IgnoreCase')
        if ($colonMatch.Success) {
            $arrayToken = $colonMatch.Groups['token'].Value
            if ($Tokens.Contains($arrayToken) -and [string]$Tokens[$arrayToken].Mode -eq 'ArrayExpansion') {
                throw "Invoke-XmlTokenSubstitution: ArrayExpansion marker '{{$name}}' in '$Path' was not consumed by the pre-pass. Begin/end markers must come in matched pairs and live inside an XML comment (<!-- {{$arrayToken`:begin}} --> ... <!-- {{$arrayToken`:end}} -->)."
            }
            throw "Invoke-XmlTokenSubstitution: unregistered ArrayExpansion-style marker '{{$name}}' in '$Path' references token '$arrayToken' which is not in the build-token table."
        }

        if (-not $Tokens.Contains($name)) {
            throw "Invoke-XmlTokenSubstitution: unregistered token '{{$name}}' in '$Path'. Add it to the build-token table or remove from source."
        }
        $mode = [string]$Tokens[$name].Mode
        if ($mode -eq 'Runtime') { continue }
        if ($mode -eq 'ArrayExpansion') {
            throw "Invoke-XmlTokenSubstitution: token '{{$name}}' is ArrayExpansion mode but appears as a bare placeholder in '$Path'. ArrayExpansion tokens must be referenced via begin/end markers, not as `{{$name}}`."
        }
        throw "Invoke-XmlTokenSubstitution: token '{{$name}}' is registered as $mode but was not substituted in '$Path'. Engine bug."
    }

    # Preserve trailing newline if the source ended with one.
    if ($raw.EndsWith("`r`n") -or $raw.EndsWith("`n")) {
        if (-not $result.EndsWith($newline)) { $result += $newline }
    }

    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($Path, $result, $utf8Bom)

    [pscustomobject]@{
        Path                = $Path
        Substituted         = $substituted
        LinesRemoved        = $linesRemoved
        EmptyBlocksStripped = $emptyBlocks
        BuildTokens         = @($buildSeen)
        RuntimeTokens       = @($runtimeSeen)
        ArrayExpansions     = @($arrayResults)
    }
}

function Get-ProductDefinitions {
<#
.SYNOPSIS
    Canonical product map used by the build pipeline.

.OUTPUTS
    [System.Collections.Specialized.OrderedDictionary] keyed on product
    name (M365Apps, Visio, ...). Each value is a hashtable with:

        SourceFolder     [string]  - product folder name under repo root
        SetupScript      [string]  - Install-*.ps1 leaf name
        UninstallScript  [string]  - Uninstall-*.ps1 leaf name
        DetectScript     [string]  - Detect-*.ps1 leaf name
        DisplayName      [string]  - human-friendly name for Intune UI
        Publisher        [string]  - vendor for Intune metadata
        RequiresBase     [bool]    - $true = needs M365 Apps installed first
                                     (Visio, Project, LanguagePacks)
        Parameterised    [bool]    - $true = one .intunewin maps to many
                                     Intune apps via runtime parameters
                                     (LanguagePacks)
#>
    [CmdletBinding()]
    param()

    [ordered]@{
        'M365Apps'      = @{
            SourceFolder    = 'M365Apps'
            SetupScript     = 'Install-M365Apps.ps1'
            UninstallScript = 'Uninstall-M365Apps.ps1'
            DetectScript    = 'Detect-M365Apps.ps1'
            DisplayName     = 'Microsoft 365 Apps for Enterprise'
            Publisher       = 'Microsoft'
            RequiresBase    = $false
            Parameterised   = $false
        }
        'Visio'         = @{
            SourceFolder    = 'Visio'
            SetupScript     = 'Install-Visio.ps1'
            UninstallScript = 'Uninstall-Visio.ps1'
            DetectScript    = 'Detect-Visio.ps1'
            DisplayName     = 'Microsoft Visio Professional'
            Publisher       = 'Microsoft'
            RequiresBase    = $true
            Parameterised   = $false
        }
        'Project'       = @{
            SourceFolder    = 'Project'
            SetupScript     = 'Install-Project.ps1'
            UninstallScript = 'Uninstall-Project.ps1'
            DetectScript    = 'Detect-Project.ps1'
            DisplayName     = 'Microsoft Project Professional'
            Publisher       = 'Microsoft'
            RequiresBase    = $true
            Parameterised   = $false
        }
        'LanguagePacks' = @{
            SourceFolder    = 'LanguagePacks'
            SetupScript     = 'Install-LanguagePack.ps1'
            UninstallScript = 'Uninstall-LanguagePack.ps1'
            DetectScript    = 'Detect-LanguagePack.ps1'
            DisplayName     = 'Microsoft 365 Apps - Language Pack'
            Publisher       = 'Microsoft'
            RequiresBase    = $true
            Parameterised   = $true
        }
    }
}

function Invoke-ProductStaging {
<#
.SYNOPSIS
    Stage one product into <OutputRoot>\<Product>\ so it is ready for
    packaging or local execution.

.DESCRIPTION
    Idempotent: if <OutputRoot>\<Product>\ already exists, it is
    deleted first. Staging copies every file under the product's
    source folder, ensures Tools\ exists, stages setup.exe, and
    copies Common\*.psm1 alongside.

.PARAMETER Product
    Product key (must be a key returned by Get-ProductDefinitions).

.PARAMETER RepositoryRoot
    Root of the m365apps-deploy repository.

.PARAMETER OutputRoot
    Parent directory for the staged folder. Created if missing. The
    output lands at $OutputRoot\<Product>\.

.PARAMETER SetupExeSource
    Path to a shared setup.exe to stage into <Product>\Tools\. Pass an
    empty string to disable staging and rely on the per-product
    setup.exe (if any) already present inside the product folder.

.OUTPUTS
    [pscustomobject] with:
        Product       [string]
        StagingPath   [string] - absolute path to the staged folder
        SetupSource   [string] - 'source' | 'per-product' | 'none'
        Status        [string] - 'OK' | 'Skipped' | 'Warning'
        Message       [string]
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Product,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $RepositoryRoot,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $OutputRoot,

        [AllowEmptyString()]
        [string] $SetupExeSource = '',

        # Token registration table for build-time XML substitution. Pass
        # $null (default) to skip substitution entirely - sources are then
        # copied verbatim. Use Get-DefaultBuildTokens to start from the
        # canonical table.
        $Tokens = $null
    )

    $definitions = Get-ProductDefinitions
    if (-not $definitions.Contains($Product)) {
        return [pscustomobject]@{
            Product     = $Product
            StagingPath = $null
            SetupSource = 'none'
            Status      = 'Skipped'
            Message     = ("Unknown product '{0}'." -f $Product)
        }
    }

    $spec      = $definitions[$Product]
    $sourceDir = Join-Path -Path $RepositoryRoot -ChildPath $spec.SourceFolder
    $stageDir  = Join-Path -Path $OutputRoot -ChildPath $Product
    $commonSrc = Join-Path -Path $RepositoryRoot -ChildPath 'Common'

    if (-not (Test-Path -LiteralPath $sourceDir -PathType Container)) {
        return [pscustomobject]@{
            Product     = $Product
            StagingPath = $null
            SetupSource = 'none'
            Status      = 'Skipped'
            Message     = ("Source folder '{0}' not found." -f $sourceDir)
        }
    }
    if (-not (Test-Path -LiteralPath $commonSrc -PathType Container)) {
        throw "Invoke-ProductStaging: Common\ folder not found at '$commonSrc'. This is a repository-integrity problem."
    }

    # Reset staging idempotently.
    if (Test-Path -LiteralPath $stageDir) {
        Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction Stop
    }
    if (-not (Test-Path -LiteralPath $OutputRoot)) {
        $null = New-Item -Path $OutputRoot -ItemType Directory -Force
    }
    $null = New-Item -Path $stageDir -ItemType Directory -Force

    # Copy product contents (scripts, Configurations\, any pre-existing Tools\).
    # Use -Path (not -LiteralPath) so the trailing '*' is expanded to the
    # directory contents rather than looked up as a literal filename.
    Copy-Item -Path (Join-Path $sourceDir '*') -Destination $stageDir -Recurse -Force

    # Apply build-time token substitution to every staged XML. Skipped when
    # $Tokens is $null so callers (and tests) can opt out of substitution.
    if ($null -ne $Tokens) {
        $stagedConfigs = Get-ChildItem -LiteralPath $stageDir -Recurse -Filter '*.xml' -File -ErrorAction SilentlyContinue
        foreach ($xml in $stagedConfigs) {
            $null = Invoke-XmlTokenSubstitution -Path $xml.FullName -Tokens $Tokens
        }
    }

    # Ensure Tools\ exists (for cases where product source has no Tools\ yet).
    $stageTools = Join-Path -Path $stageDir -ChildPath 'Tools'
    if (-not (Test-Path -LiteralPath $stageTools -PathType Container)) {
        $null = New-Item -Path $stageTools -ItemType Directory -Force
    }

    # Stage setup.exe (shared source -> per-product override -> warn).
    $stageSetup      = Join-Path -Path $stageTools -ChildPath 'setup.exe'
    $sourceAvailable = (-not [string]::IsNullOrWhiteSpace($SetupExeSource)) -and `
                      (Test-Path -LiteralPath $SetupExeSource -PathType Leaf)

    if ($sourceAvailable) {
        Copy-Item -LiteralPath $SetupExeSource -Destination $stageSetup -Force
        $setupSource = 'source'
        $message     = ("Staged setup.exe from shared source: {0}" -f $SetupExeSource)
    }
    elseif (Test-Path -LiteralPath $stageSetup -PathType Leaf) {
        # Survivor from the product-folder Copy-Item (per-product override).
        $setupSource = 'per-product'
        $message     = ("Using per-product setup.exe at {0}" -f $stageSetup)
    }
    else {
        $setupSource = 'none'
        $message     = 'No setup.exe available. Install/Uninstall scripts will need -UseEvergreenSetup at deploy time.'
    }

    # Stage Common\ into <Product>\Common\ so Install/Uninstall scripts work
    # both when run from this staged folder and when Intune extracts the
    # resulting .intunewin on a client.
    $stageCommon = Join-Path -Path $stageDir -ChildPath 'Common'
    if (-not (Test-Path -LiteralPath $stageCommon)) {
        $null = New-Item -Path $stageCommon -ItemType Directory -Force
    }
    Copy-Item -Path (Join-Path $commonSrc '*.psm1') -Destination $stageCommon -Force

    $status = if ($setupSource -eq 'none') { 'Warning' } else { 'OK' }
    [pscustomobject]@{
        Product     = $Product
        StagingPath = (Resolve-Path -LiteralPath $stageDir).ProviderPath
        SetupSource = $setupSource
        Status      = $status
        Message     = $message
    }
}

function Test-StagedPowerShellFiles {
<#
.SYNOPSIS
    Validate every .ps1 file under a staged product folder so the build
    cannot ship an empty or syntactically broken script.

.DESCRIPTION
    Parses each .ps1 beneath -Path and rejects it if either:
      * the parser returns one or more syntax errors, or
      * the AST contains zero CommandAst nodes (i.e. the file is empty,
        comments-only, or BOM-only - nothing actually runs at install
        time).

    Rationale: a zero-byte or comment-only Install-*.ps1 is a valid
    empty script as far as the parser is concerned, and
    IntuneWinAppUtil will happily package it. Client-side, Intune's
    `powershell.exe -File Install-*.ps1` command then exits 0 and
    nothing actually installs - a silent no-op deployment. The
    zero-CommandAst check catches this class of bug before packaging.

.PARAMETER Path
    Directory to scan recursively for .ps1 files.

.OUTPUTS
    [pscustomobject] with:
        Passed [bool]   - $true when every scanned file passed both checks
        Scanned [int]   - number of .ps1 files inspected
        Issues [pscustomobject[]] - one entry per failing file with
                                    File, Size, LineCount, CommandCount,
                                    Problem fields.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Test-StagedPowerShellFiles: path '$Path' does not exist."
    }

    $issues = New-Object System.Collections.Generic.List[pscustomobject]
    $files  = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Filter '*.ps1')

    foreach ($f in $files) {
        # Guard every read against strict-mode quirks: Get-Content on a BOM-only
        # file returns $null, and $null.Count under StrictMode throws - so wrap
        # in @() to coerce to an array and get a safe .Count.
        $lineCount = @(Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue).Count

        $tokens = $null
        $errors = $null
        $ast    = $null
        try {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
        }
        catch {
            $issues.Add([pscustomobject]@{
                File         = $f.FullName
                Size         = $f.Length
                LineCount    = $lineCount
                CommandCount = 0
                Problem      = ("Parser threw: {0}" -f $_.Exception.Message)
            })
            continue
        }

        $errorList = @($errors)
        if ($errorList.Count -gt 0) {
            $first = $errorList[0]
            $issues.Add([pscustomobject]@{
                File         = $f.FullName
                Size         = $f.Length
                LineCount    = $lineCount
                CommandCount = 0
                Problem      = ("{0} parser error(s); first at line {1}: {2}" -f $errorList.Count, $first.Extent.StartLineNumber, $first.Message)
            })
            continue
        }

        $commands = @()
        if ($null -ne $ast) {
            $commands = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true))
        }
        if ($commands.Count -eq 0) {
            $issues.Add([pscustomobject]@{
                File         = $f.FullName
                Size         = $f.Length
                LineCount    = $lineCount
                CommandCount = 0
                Problem      = ("Empty or command-free script: {0} bytes, {1} lines, 0 CommandAst nodes." -f $f.Length, $lineCount)
            })
            continue
        }
    }

    [pscustomobject]@{
        Passed  = ($issues.Count -eq 0)
        Scanned = $files.Count
        Issues  = @($issues)
    }
}

function Get-DetectLanguagePackBodyText {
<#
.SYNOPSIS
    Return the body of LanguagePacks\Detect-LanguagePack.ps1 with the
    param block sliced off, so per-language wrappers can prepend their
    own param block + hard-coded values.

.DESCRIPTION
    Used by Publish-DetectionScripts when generating Intune-ready
    detection wrappers for LanguagePacks. Operates on the AST so the
    slice survives whitespace / comment-header edits to the source
    script.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SourcePath
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw ("Get-DetectLanguagePackBodyText: source not found at '{0}'." -f $SourcePath)
    }

    $src    = [System.IO.File]::ReadAllText($SourcePath)
    $tokens = $null
    $errors = $null
    $ast    = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$tokens, [ref]$errors)
    $errList = @($errors)
    if ($errList.Count -gt 0) {
        throw ("Get-DetectLanguagePackBodyText: source has parse errors; first at line {0}: {1}" -f $errList[0].Extent.StartLineNumber, $errList[0].Message)
    }
    if ($null -eq $ast.ParamBlock) {
        throw "Get-DetectLanguagePackBodyText: source has no param block."
    }

    return $src.Substring($ast.ParamBlock.Extent.EndOffset)
}

function Publish-DetectionScripts {
<#
.SYNOPSIS
    Emit Intune-ready detection scripts to <OutputDir>\DetectionScripts\.

.DESCRIPTION
    Detection scripts must be uploaded to Intune as standalone files
    (the IntuneWinAppUtil package is not available to a custom
    detection script at run time). The build pipeline therefore copies
    each product's Detect-*.ps1 from the staged folder into
    <OutputDir>\DetectionScripts\ alongside the .intunewin, so admins
    can find the upload artefact next to the package.

    For non-parameterised products (M365Apps, Visio, Project) this is
    a straight copy.

    For LanguagePacks - one .intunewin, many Intune apps - this
    generates one wrapper per supported Office language, each with
    -LanguageID hard-coded so it can be uploaded to Intune as-is
    (Intune does not pass parameters to detection scripts). The body
    is taken verbatim from Detect-LanguagePack.ps1 so logic stays in
    one place. TargetProduct is hard-coded to O365ProPlusRetail; the
    primary registry-key check is product-agnostic
    (LanguagePack - <lang>) so the same wrapper detects Visio and
    Project language packs too.

.PARAMETER Product
    Product key. One of M365Apps, Visio, Project, LanguagePacks.

.PARAMETER Spec
    The product hashtable from Get-ProductDefinitions.

.PARAMETER StagingPath
    Absolute path to the staged product folder
    (Build\Staging\<Product>\), where the source Detect-*.ps1 lives.

.PARAMETER OutputDir
    Absolute path to the per-product output folder
    (Build\Output\<Product>\). The DetectionScripts\ subfolder is
    created (or cleared and recreated) here.

.PARAMETER RepositoryRoot
    Repository root, used to import Common\ODTLanguages.psm1 for the
    Office-language matrix when generating LanguagePack wrappers.

.OUTPUTS
    [pscustomobject] with:
        Product       [string]
        DetectionDir  [string]   - full path to the DetectionScripts folder
        ScriptCount   [int]      - number of scripts emitted
        Variants      [string[]] - language codes for parameterised products,
                                   empty for simple products
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Product,

        [Parameter(Mandatory)]
        [hashtable] $Spec,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $StagingPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $OutputDir,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $RepositoryRoot
    )

    if (-not (Test-Path -LiteralPath $StagingPath -PathType Container)) {
        throw ("Publish-DetectionScripts: staging path '{0}' does not exist." -f $StagingPath)
    }
    if (-not (Test-Path -LiteralPath $OutputDir -PathType Container)) {
        $null = New-Item -Path $OutputDir -ItemType Directory -Force
    }

    $detectionDir = Join-Path -Path $OutputDir -ChildPath 'DetectionScripts'
    if (Test-Path -LiteralPath $detectionDir) {
        # Idempotent: clear stale wrappers from prior builds (e.g. languages
        # dropped from the matrix, or a switch from Parameterised to simple).
        Remove-Item -LiteralPath $detectionDir -Recurse -Force -ErrorAction Stop
    }
    $null = New-Item -Path $detectionDir -ItemType Directory -Force

    $utf8Bom = New-Object System.Text.UTF8Encoding($true)

    if (-not $Spec.Parameterised) {
        $srcDetect = Join-Path -Path $StagingPath -ChildPath $Spec.DetectScript
        if (-not (Test-Path -LiteralPath $srcDetect -PathType Leaf)) {
            throw ("Publish-DetectionScripts: '{0}' missing in staging at '{1}'." -f $Spec.DetectScript, $srcDetect)
        }
        $destDetect = Join-Path -Path $detectionDir -ChildPath $Spec.DetectScript
        Copy-Item -LiteralPath $srcDetect -Destination $destDetect -Force
        return [pscustomobject]@{
            Product      = $Product
            DetectionDir = (Resolve-Path -LiteralPath $detectionDir).ProviderPath
            ScriptCount  = 1
            Variants     = @()
        }
    }

    if ($Product -ne 'LanguagePacks') {
        throw ("Publish-DetectionScripts: parameterised product '{0}' not supported." -f $Product)
    }

    $sourceDetect = Join-Path -Path $StagingPath -ChildPath $Spec.DetectScript
    $body         = Get-DetectLanguagePackBodyText -SourcePath $sourceDetect

    # Import the language matrix module from the repository root (not the
    # staged copy) - both contain identical content, but Common\ is the
    # canonical source for the build pipeline.
    $languageModule = Join-Path -Path $RepositoryRoot -ChildPath 'Common\ODTLanguages.psm1'
    if (-not (Test-Path -LiteralPath $languageModule -PathType Leaf)) {
        throw ("Publish-DetectionScripts: language matrix module not found at '{0}'." -f $languageModule)
    }

    $alreadyLoaded = [bool](Get-Module -Name 'ODTLanguages')
    if (-not $alreadyLoaded) {
        Import-Module -Name $languageModule -Force -ErrorAction Stop
    }
    try {
        $languages = @(Get-ODTSupportedLanguages -TargetProduct 'O365ProPlusRetail')
    }
    finally {
        if (-not $alreadyLoaded) {
            Remove-Module -Name 'ODTLanguages' -ErrorAction SilentlyContinue
        }
    }

    if ($languages.Count -eq 0) {
        throw "Publish-DetectionScripts: Get-ODTSupportedLanguages returned no Office languages."
    }

    $generated = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    $emitted   = New-Object System.Collections.Generic.List[string]

    foreach ($lang in $languages) {
        $header = @"
#Requires -Version 5.1
<#
.SYNOPSIS
    Intune Win32 detection wrapper for the Microsoft 365 Apps Language Pack ($lang).

.DESCRIPTION
    Auto-generated by Build\Build-IntuneWinPackages.ps1 - do not hand-edit.
    Source of truth for the detection logic: LanguagePacks\Detect-LanguagePack.ps1.

    Hard-coded for this variant:
        LanguageID    = '$lang'
        TargetProduct = 'O365ProPlusRetail'

    The primary registry-key check (LanguagePack - <lang>) is product-
    agnostic, so the same wrapper detects the language pack regardless
    of which base product (Office, Visio, Project) it was installed
    for. If the deployment uses the alternate per-product key shape
    (e.g. VisioProRetail - $lang) instead of the LanguagePack pseudo-
    product, edit the `$TargetProduct value below.

    Upload this file directly as the custom detection script for the
    Intune Win32 app deploying $lang.

.NOTES
    Variant   : $lang
    Generated : $generated
    Project   : m365apps-deploy
#>
[CmdletBinding()]
param(
    [string] `$LogPath = 'C:\ProgramData\M365AppsDeploy\Logs',
    [string] `$LogFile
)

`$LanguageID    = '$lang'
`$TargetProduct = 'O365ProPlusRetail'
"@

        $wrapperText = $header + "`r`n" + $body

        # Pre-flight: parse-check the generated wrapper before writing it.
        # Mirrors the Test-StagedPowerShellFiles guarantee for ordinary scripts.
        $genErrors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($wrapperText, [ref]$null, [ref]$genErrors) | Out-Null
        $genErrList = @($genErrors)
        if ($genErrList.Count -gt 0) {
            throw ("Publish-DetectionScripts: generated wrapper for '{0}' has parse errors: {1}" -f $lang, $genErrList[0].Message)
        }

        $wrapperPath = Join-Path -Path $detectionDir -ChildPath ("Detect-LanguagePack-{0}.ps1" -f $lang)
        [System.IO.File]::WriteAllText($wrapperPath, $wrapperText, $utf8Bom)
        $emitted.Add($lang)
    }

    [pscustomobject]@{
        Product      = $Product
        DetectionDir = (Resolve-Path -LiteralPath $detectionDir).ProviderPath
        ScriptCount  = $emitted.Count
        Variants     = $emitted.ToArray()
    }
}
