#Requires -Version 5.1
<#
.SYNOPSIS
    Lint test for Install/Uninstall script param blocks.

.DESCRIPTION
    Param-block default expressions are evaluated by PowerShell BEFORE
    $PSScriptRoot is reliably populated when invoked via
    'powershell.exe -File <script>' under certain non-interactive hosts
    (Intune Management Extension, PsExec -s). A default like
        [string] $SetupExePath = (Join-Path -Path $PSScriptRoot -ChildPath ...)
    binds to '' under those hosts; the script then exits 1 with no log,
    because Join-Path throws "Cannot bind argument to parameter 'Path'
    because it is an empty string" before Start-ODTLogSession can run.

    This test enforces "param defaults must not reference $PSScriptRoot"
    via AST inspection. The canonical pattern (see e.g.
    Install-M365Apps.ps1) is to declare the param without a default and
    resolve in the script body where $PSScriptRoot is reliable:

        param( [string] $SetupExePath )
        if ([string]::IsNullOrEmpty($SetupExePath)) {
            $SetupExePath = Join-Path -Path $PSScriptRoot -ChildPath 'Tools\setup.exe'
        }

    Run with:
        Invoke-Pester -Path .\Tests\Pester\ParamBlockHygiene.Tests.ps1
#>

# Discovery-time enumeration. Pester 5 evaluates -ForEach at discovery
# time (before BeforeAll runs), so script-scope variables work here but
# would not if put inside BeforeAll.
$repoRoot = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..')
$productFolders = 'M365Apps','Visio','Project','LanguagePacks'
$deployedScripts = foreach ($folder in $productFolders) {
    $folderPath = Join-Path -Path $repoRoot -ChildPath $folder
    if (Test-Path -LiteralPath $folderPath) {
        Get-ChildItem -Path $folderPath -Filter '*.ps1' |
            Where-Object { $_.Name -match '^(Install|Uninstall)-' } |
            ForEach-Object { @{ Name = $_.Name; FullName = $_.FullName } }
    }
}

Describe 'Install/Uninstall param block hygiene' {

    BeforeAll {
        # Re-discover at run time. Pester 5 does not persist discovery-time
        # variables into the run phase, so the count assertion below cannot
        # rely on the script-top $deployedScripts.
        $script:RepoRoot = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..')
        $script:RuntimeScripts = foreach ($folder in 'M365Apps','Visio','Project','LanguagePacks') {
            $folderPath = Join-Path -Path $script:RepoRoot -ChildPath $folder
            if (Test-Path -LiteralPath $folderPath) {
                Get-ChildItem -Path $folderPath -Filter '*.ps1' |
                    Where-Object { $_.Name -match '^(Install|Uninstall)-' }
            }
        }
    }

    It 'discovers all eight Intune-deployed scripts' {
        # M365Apps + Visio + Project: 2 each (Install, Uninstall) = 6
        # LanguagePacks: 2 (Install, Uninstall)
        # Total: 8
        @($script:RuntimeScripts).Count | Should -Be 8
    }

    It 'param defaults in <Name> do not reference $PSScriptRoot' -ForEach $deployedScripts {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($FullName, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty -Because "the script must parse cleanly"

        $paramBlock = $ast.ParamBlock
        $paramBlock | Should -Not -BeNullOrEmpty -Because "Install/Uninstall scripts must declare param()"

        $offenders = @()
        foreach ($param in $paramBlock.Parameters) {
            if ($null -ne $param.DefaultValue) {
                $defaultText = $param.DefaultValue.Extent.Text
                if ($defaultText -match '\$PSScriptRoot') {
                    $offenders += $param.Name.VariablePath.UserPath
                }
            }
        }
        $offenders | Should -BeNullOrEmpty -Because "param defaults must resolve in the body — see file header for rationale"
    }
}
