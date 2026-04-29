#Requires -Version 5.1
<#
.SYNOPSIS
    End-to-end deployment test harness for the m365apps-deploy toolkit.

.DESCRIPTION
    Drives the full install / detect / uninstall lifecycle against a test
    machine. This is NOT a unit test - it installs real Click-to-Run Office
    bits against the CDN and expects to run on a throwaway lab VM.

    Workflow:
        1. Verify a setup.exe is available (bundled or -UseEvergreenSetup).
        2. Install M365 Apps, then verify via Detect-M365Apps.ps1.
        3. Install Visio, verify.
        4. Install Project, verify.
        5. Install an additional language pack (default nb-no), verify.
        6. Uninstall everything in reverse order, verifying at each step.

    Each step prints a PASS/FAIL marker and appends a line to a summary
    table at the end. The script exits non-zero if any step fails.

    **WARNING**: this script mutates the machine state. Run only on a
    disposable lab VM or Autopilot reset target.

.PARAMETER RepositoryRoot
    Root of the m365apps-deploy repo. Defaults to the parent of this file's
    directory.

.PARAMETER LogPath
    Root log directory to pass to every script. Defaults to
    C:\ProgramData\M365AppsDeploy\Logs.

.PARAMETER UseEvergreenSetup
    Download setup.exe from Microsoft for every step (pass-through to
    the Install / Uninstall scripts).

.PARAMETER LanguageToInstall
    Language code to use for the LanguagePacks step. Must be a language
    supported by the base Office UI. Defaults to nb-no.

.PARAMETER SkipVisio
    Skip the Visio install / uninstall steps. Useful when the test tenant
    does not license Visio.

.PARAMETER SkipProject
    Skip the Project install / uninstall steps.

.PARAMETER KeepInstalled
    Skip the final uninstall phase. Leaves Office installed so an operator
    can inspect state after the run.

.PARAMETER FromLocalBuild
    Invoke the product scripts staged at
    <RepositoryRoot>\Build\Staging\<Product>\ instead of the repo
    tree. Use this to validate that the staged / Intune-deployed
    layout behaves identically to the repo layout. Run
    Build-IntuneWinPackages.ps1 (with or without -StagingOnly) first.

.PARAMETER LocalBuildPath
    Directory that contains the staged product folders. Only used
    when -FromLocalBuild is set. Defaults to
    <RepositoryRoot>\Build\Staging.

.EXAMPLE
    .\Invoke-DeploymentTest.ps1 -UseEvergreenSetup -SkipProject

.EXAMPLE
    # Validate the staged / Intune-deployed layout:
    .\Build\Build-IntuneWinPackages.ps1 -StagingOnly
    .\Tests\Invoke-DeploymentTest.ps1 -FromLocalBuild

.NOTES
    Script  : Invoke-DeploymentTest.ps1
    Project : m365apps-deploy
    Version : <see Common/ODTVersion.psm1>
#>
[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Split-Path -Path $PSScriptRoot -Parent),

    [string] $LogPath = 'C:\ProgramData\M365AppsDeploy\Logs',

    [switch] $UseEvergreenSetup,

    [ValidatePattern('^[a-zA-Z]{2,3}(-[a-zA-Z]{2,8}){1,3}$')]
    [string] $LanguageToInstall = 'nb-no',

    [switch] $SkipVisio,

    [switch] $SkipProject,

    [switch] $KeepInstalled,

    [switch] $FromLocalBuild,

    [string] $LocalBuildPath
)

$ErrorActionPreference = 'Stop'
$Results = New-Object System.Collections.Generic.List[pscustomobject]

# Where the harness invokes product scripts from.
#   Default: the repo tree, so Install-M365Apps.ps1 lives at
#            $RepositoryRoot\M365Apps\Install-M365Apps.ps1.
#   -FromLocalBuild: the staged layout (Build\Staging\), at
#            $LocalBuildPath\M365Apps\Install-M365Apps.ps1.
# The two layouts have identical sub-paths, so switching is a single
# base-directory change.
if ($FromLocalBuild) {
    if ([string]::IsNullOrWhiteSpace($LocalBuildPath)) {
        $LocalBuildPath = Join-Path -Path $RepositoryRoot -ChildPath 'Build\Staging'
    }
    if (-not (Test-Path -LiteralPath $LocalBuildPath -PathType Container)) {
        throw "Invoke-DeploymentTest.ps1: -FromLocalBuild was set but '$LocalBuildPath' does not exist. Run Build\Build-IntuneWinPackages.ps1 -StagingOnly first."
    }
    $productRoot = (Resolve-Path -LiteralPath $LocalBuildPath).ProviderPath
    Write-Output ("Product source  : LOCAL BUILD at {0}" -f $productRoot)
}
else {
    $productRoot = $RepositoryRoot
    Write-Output ("Product source  : REPO TREE at {0}" -f $productRoot)
}

function Invoke-Step {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $ScriptPath,
        [string[]] $Arguments = @(),
        [int[]] $ExpectedExitCodes = @(0, 3010, 1641)
    )

    Write-Output ''
    Write-Output ('==================================================================')
    Write-Output ('  STEP: {0}' -f $Name)
    Write-Output ('  Script: {0}' -f $ScriptPath)
    Write-Output ('  Args  : {0}' -f ($Arguments -join ' '))
    Write-Output ('==================================================================')

    $psExe = if ($PSVersionTable.PSEdition -eq 'Core') {
        (Get-Command pwsh -ErrorAction SilentlyContinue).Path
    } else { $null }
    if (-not $psExe) { $psExe = (Get-Command powershell.exe).Path }

    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"{0}"' -f $ScriptPath)) + $Arguments
    $proc = Start-Process -FilePath $psExe -ArgumentList $argList -NoNewWindow -Wait -PassThru
    $exit = $proc.ExitCode
    $passed = $ExpectedExitCodes -contains $exit

    $Script:Results.Add([pscustomobject]@{
        Step        = $Name
        ExitCode    = $exit
        Passed      = $passed
        Expected    = ($ExpectedExitCodes -join ',')
    })

    if ($passed) { Write-Output ("  PASS (exit {0})" -f $exit) }
    else         { Write-Output ("  FAIL (exit {0}; expected {1})" -f $exit, ($ExpectedExitCodes -join ',')) }

    return $passed
}

$evergreenArgs = @()
if ($UseEvergreenSetup) { $evergreenArgs += '-UseEvergreenSetup' }

$commonLogArgs = @('-LogPath', ('"{0}"' -f $LogPath))

# --- Phase 1: Install ---
Invoke-Step -Name 'Install M365 Apps' `
    -ScriptPath (Join-Path $productRoot 'M365Apps\Install-M365Apps.ps1') `
    -Arguments ($commonLogArgs + $evergreenArgs)

Invoke-Step -Name 'Detect M365 Apps (should be installed)' `
    -ScriptPath (Join-Path $productRoot 'M365Apps\Detect-M365Apps.ps1') `
    -Arguments $commonLogArgs -ExpectedExitCodes @(0)

if (-not $SkipVisio) {
    Invoke-Step -Name 'Install Visio' `
        -ScriptPath (Join-Path $productRoot 'Visio\Install-Visio.ps1') `
        -Arguments ($commonLogArgs + $evergreenArgs)
    Invoke-Step -Name 'Detect Visio (should be installed)' `
        -ScriptPath (Join-Path $productRoot 'Visio\Detect-Visio.ps1') `
        -Arguments $commonLogArgs -ExpectedExitCodes @(0)
}

if (-not $SkipProject) {
    Invoke-Step -Name 'Install Project' `
        -ScriptPath (Join-Path $productRoot 'Project\Install-Project.ps1') `
        -Arguments ($commonLogArgs + $evergreenArgs)
    Invoke-Step -Name 'Detect Project (should be installed)' `
        -ScriptPath (Join-Path $productRoot 'Project\Detect-Project.ps1') `
        -Arguments $commonLogArgs -ExpectedExitCodes @(0)
}

Invoke-Step -Name ("Install Language Pack {0}" -f $LanguageToInstall) `
    -ScriptPath (Join-Path $productRoot 'LanguagePacks\Install-LanguagePack.ps1') `
    -Arguments ($commonLogArgs + $evergreenArgs + @('-LanguageID', $LanguageToInstall))
Invoke-Step -Name ("Detect Language Pack {0} (should be installed)" -f $LanguageToInstall) `
    -ScriptPath (Join-Path $productRoot 'LanguagePacks\Detect-LanguagePack.ps1') `
    -Arguments ($commonLogArgs + @('-LanguageID', $LanguageToInstall)) -ExpectedExitCodes @(0)

# --- Phase 2: Uninstall (reverse order) ---
if (-not $KeepInstalled) {
    Invoke-Step -Name ("Uninstall Language Pack {0}" -f $LanguageToInstall) `
        -ScriptPath (Join-Path $productRoot 'LanguagePacks\Uninstall-LanguagePack.ps1') `
        -Arguments ($commonLogArgs + $evergreenArgs + @('-LanguageID', $LanguageToInstall))
    if (-not $SkipProject) {
        Invoke-Step -Name 'Uninstall Project' `
            -ScriptPath (Join-Path $productRoot 'Project\Uninstall-Project.ps1') `
            -Arguments ($commonLogArgs + $evergreenArgs)
    }
    if (-not $SkipVisio) {
        Invoke-Step -Name 'Uninstall Visio' `
            -ScriptPath (Join-Path $productRoot 'Visio\Uninstall-Visio.ps1') `
            -Arguments ($commonLogArgs + $evergreenArgs)
    }
    Invoke-Step -Name 'Uninstall M365 Apps (all products)' `
        -ScriptPath (Join-Path $productRoot 'M365Apps\Uninstall-M365Apps.ps1') `
        -Arguments ($commonLogArgs + $evergreenArgs)
    Invoke-Step -Name 'Detect M365 Apps (should be gone)' `
        -ScriptPath (Join-Path $productRoot 'M365Apps\Detect-M365Apps.ps1') `
        -Arguments $commonLogArgs -ExpectedExitCodes @(1)
}

# --- Summary ---
Write-Output ''
Write-Output '==================================================================='
Write-Output 'Deployment test summary'
Write-Output '==================================================================='
$Results | Format-Table -AutoSize | Out-String | Write-Output

$failed = @($Results | Where-Object { -not $_.Passed })
if ($failed.Count -gt 0) {
    Write-Output ("{0} step(s) failed." -f $failed.Count)
    exit 1
}
Write-Output 'All steps passed.'
exit 0
