#Requires -Version 5.1
<#
.SYNOPSIS
    Single source of truth for the toolkit's version string.

.DESCRIPTION
    Every install/uninstall script reads this value via Get-ToolkitVersion
    and passes it to Start-ODTLogSession, so CMTrace / IME log session
    headers always print the same version this module declares. The
    `.NOTES Version` blocks in every other source file point here rather
    than carrying their own literal — bumping a release is a one-line
    edit in this module (plus the matching CHANGELOG entry, which a
    Pester test cross-checks).

    The constant must match the most recent `## [x.y.z]` heading in
    CHANGELOG.md. Tests/Pester/ODTVersion.Tests.ps1 enforces that
    invariant.

.NOTES
    Module  : ODTVersion
    Project : m365apps-deploy
    Version : 1.0.9
#>

Set-StrictMode -Version Latest

# Single source of truth for the toolkit's version string. Update this on
# every release — the matching CHANGELOG.md heading is required, the Pester
# test enforces it.
$script:ToolkitVersion = '1.0.9'

function Get-ToolkitVersion {
<#
.SYNOPSIS
    Return the toolkit's current version string.

.OUTPUTS
    [string] - SemVer triple, e.g. '1.0.9'.

.EXAMPLE
    $ScriptVersion = Get-ToolkitVersion
    Start-ODTLogSession -ScriptName $ScriptName -ScriptVersion $ScriptVersion ...
#>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:ToolkitVersion
}

Export-ModuleMember -Function 'Get-ToolkitVersion'
