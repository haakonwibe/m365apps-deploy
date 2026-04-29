#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 tests for Common/ODTVersion.psm1.

.DESCRIPTION
    Verifies that Get-ToolkitVersion returns a non-empty SemVer string and
    that the value matches the most recent release heading in CHANGELOG.md.
    The CHANGELOG cross-check pins constant <-> changelog drift: if either
    side is bumped without the other, this test fails.

    Run with:
        Invoke-Pester -Path .\Tests\Pester\ODTVersion.Tests.ps1
#>

BeforeAll {
    $repoRoot = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..')
    $modulePath = Join-Path -Path $repoRoot -ChildPath 'Common\ODTVersion.psm1'
    Import-Module $modulePath -Force

    $script:ChangelogPath = Join-Path -Path $repoRoot -ChildPath 'CHANGELOG.md'
}

AfterAll {
    Remove-Module ODTVersion -ErrorAction SilentlyContinue
}

Describe 'Get-ToolkitVersion' {
    It 'returns a non-empty string' {
        $v = Get-ToolkitVersion
        $v | Should -BeOfType ([string])
        [string]::IsNullOrWhiteSpace($v) | Should -BeFalse
    }

    It 'returns a SemVer-shaped value (Major.Minor.Patch)' {
        Get-ToolkitVersion | Should -Match '^\d+\.\d+\.\d+$'
    }

    It 'matches the most recent release heading in CHANGELOG.md' {
        Test-Path -LiteralPath $script:ChangelogPath | Should -BeTrue
        $lines = Get-Content -LiteralPath $script:ChangelogPath
        $headingMatch = $lines |
            Select-String -Pattern '^##\s*\[(\d+\.\d+\.\d+)\]' |
            Select-Object -First 1
        $headingMatch | Should -Not -BeNullOrEmpty
        $latestChangelogVersion = $headingMatch.Matches[0].Groups[1].Value
        Get-ToolkitVersion | Should -Be $latestChangelogVersion
    }
}
