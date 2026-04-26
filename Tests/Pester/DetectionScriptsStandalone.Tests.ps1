#Requires -Version 5.1
<#
.SYNOPSIS
    Lint test for rule #1: detection scripts are standalone (no
    Import-Module from Common/).

.DESCRIPTION
    Intune's Win32 detection-script execution model does not reliably
    expose product-folder siblings (Common/), so Import-Module from a
    relative path is fragile. Detection scripts must inline the small
    helpers they need.

    See docs/architecture.md "Enforced architectural invariants" for
    the full rationale.

    Run with:
        Invoke-Pester -Path .\Tests\Pester\DetectionScriptsStandalone.Tests.ps1
#>

# Discovery-time enumeration. Pester 5 evaluates -ForEach at discovery
# time so this must run at script scope.
$repoRoot = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..')
$productFolders = 'M365Apps','Visio','Project','LanguagePacks'
$detectionScripts = foreach ($folder in $productFolders) {
    $folderPath = Join-Path -Path $repoRoot -ChildPath $folder
    if (Test-Path -LiteralPath $folderPath) {
        Get-ChildItem -Path $folderPath -Filter 'Detect-*.ps1' |
            ForEach-Object { @{ Name = $_.Name; FullName = $_.FullName } }
    }
}

Describe 'Detection scripts are standalone' {

    BeforeAll {
        $script:RepoRoot = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..')
        $script:RuntimeScripts = foreach ($folder in 'M365Apps','Visio','Project','LanguagePacks') {
            $folderPath = Join-Path -Path $script:RepoRoot -ChildPath $folder
            if (Test-Path -LiteralPath $folderPath) {
                Get-ChildItem -Path $folderPath -Filter 'Detect-*.ps1'
            }
        }
    }

    It 'discovers all four detection scripts' {
        # M365Apps, Visio, Project, LanguagePacks: 1 each = 4
        @($script:RuntimeScripts).Count | Should -Be 4
    }

    It '<Name> contains no Import-Module call' -ForEach $detectionScripts {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($FullName, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty -Because "the script must parse cleanly"

        $imports = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Import-Module'
        }, $true) | ForEach-Object {
            "Import-Module at line {0}" -f $_.Extent.StartLineNumber
        }

        $imports | Should -BeNullOrEmpty -Because "detection scripts must be standalone (rule #1 in docs/architecture.md)"
    }
}
