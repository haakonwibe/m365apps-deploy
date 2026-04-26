#Requires -Version 5.1
<#
.SYNOPSIS
    Lint test for rule #3: registry reads must use the explicit 64-bit
    registry view.

.DESCRIPTION
    Intune Management Extension is a 32-bit binary
    (C:\Program Files (x86)\Microsoft Intune Management Extension\). When
    it spawns powershell.exe to run install commands or detection scripts,
    file system redirection picks up SysWOW64\powershell.exe (32-bit).
    Inside that process, every HKLM:\SOFTWARE\... access is silently
    redirected to HKLM:\SOFTWARE\WOW6432Node\... where the C2R
    Configuration key (and many other Office / Windows keys) does not
    exist. PowerShell cmdlets (Test-Path, Get-ItemProperty, Get-ChildItem)
    over a literal HKLM:\ / HKCU:\ path are subject to that redirection.

    The fix is to read the registry through Microsoft.Win32.RegistryKey
    with Registry64 view explicitly. The toolkit wraps that in private
    helpers (Get-Registry64Item, Get-Registry64SubKeyName,
    Test-Registry64KeyExists) and inlines equivalent code in the
    standalone-by-design detection scripts (rule #1).

    This test enforces the rule via AST inspection. It scans every
    .ps1 / .psm1 in the four product folders and Common\, looks for
    Test-Path / Get-ItemProperty / Get-ChildItem / Set-ItemProperty /
    New-ItemProperty / Remove-ItemProperty / Get-Item CommandAst nodes,
    and fails if any of them carry a literal string argument that
    starts with "HK<HIVE>:\" (e.g. HKLM:\, HKCU:\, HKLM:/, etc.).

    Run with:
        Invoke-Pester -Path .\Tests\Pester\RegistryAccessHygiene.Tests.ps1
#>

# Discovery-time enumeration. Pester 5 evaluates -ForEach at discovery
# time so this must run at script scope.
$repoRoot = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..')
$scanFolders = 'M365Apps','Visio','Project','LanguagePacks','Common'
$scanFiles = foreach ($folder in $scanFolders) {
    $folderPath = Join-Path -Path $repoRoot -ChildPath $folder
    if (Test-Path -LiteralPath $folderPath) {
        Get-ChildItem -Path $folderPath -Include '*.ps1','*.psm1' -Recurse -File |
            ForEach-Object { @{ Name = ($_.FullName.Substring($repoRoot.Path.Length + 1)); FullName = $_.FullName } }
    }
}

$ForbiddenCmdlets = @(
    'Test-Path',
    'Get-ItemProperty',
    'Get-ChildItem',
    'Get-Item',
    'Set-ItemProperty',
    'New-ItemProperty',
    'Remove-ItemProperty',
    'Set-Item',
    'New-Item',
    'Remove-Item'
)

# Match anything that looks like a registry-drive prefix (HKLM:\, HKCU:\,
# HKU:\, HKCR:\, HKCC:\) in either backslash or forward-slash form.
$RegistryPrefixPattern = '^HK(LM|CU|U|CR|CC):[\\/]'

Describe 'Registry access hygiene (rule #3)' {

    BeforeAll {
        $script:RepoRoot = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..')
        $script:RuntimeFiles = foreach ($folder in 'M365Apps','Visio','Project','LanguagePacks','Common') {
            $folderPath = Join-Path -Path $script:RepoRoot -ChildPath $folder
            if (Test-Path -LiteralPath $folderPath) {
                Get-ChildItem -Path $folderPath -Include '*.ps1','*.psm1' -Recurse -File
            }
        }
    }

    It 'discovers a non-trivial number of toolkit files to scan' {
        # At minimum: 4 product folders x ~3 .ps1 + 5 Common .psm1 = 17.
        @($script:RuntimeFiles).Count | Should -BeGreaterThan 15
    }

    It '<Name> contains no PowerShell cmdlet calls against literal HK<HIVE>:\ paths' -ForEach $scanFiles {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($FullName, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty -Because "the file must parse cleanly"

        $forbiddenCmdlets = @(
            'Test-Path','Get-ItemProperty','Get-ChildItem','Get-Item',
            'Set-ItemProperty','New-ItemProperty','Remove-ItemProperty',
            'Set-Item','New-Item','Remove-Item'
        )
        $registryPrefixPattern = '^HK(LM|CU|U|CR|CC):[\\/]'

        $calls = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -in $forbiddenCmdlets
        }, $true)

        $violations = @()
        foreach ($call in $calls) {
            foreach ($element in $call.CommandElements) {
                # Direct string literal argument.
                if ($element -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                    $element.Value -match $registryPrefixPattern) {
                    $violations += "{0} '{1}' at line {2}" -f $call.GetCommandName(), $element.Value, $call.Extent.StartLineNumber
                }
                # Expandable string literal (double-quoted) argument.
                elseif ($element -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -and
                        $element.Value -match $registryPrefixPattern) {
                    $violations += "{0} '{1}' at line {2}" -f $call.GetCommandName(), $element.Value, $call.Extent.StartLineNumber
                }
            }
        }

        $violations | Should -BeNullOrEmpty -Because "registry reads must use Get-Registry64Item / Get-Registry64SubKeyName / Test-Registry64KeyExists, or inline Microsoft.Win32.RegistryKey.OpenBaseKey(Registry64) (rule #3 in docs/architecture.md)"
    }
}
