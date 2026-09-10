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
    $script:ReadmePath    = Join-Path -Path $repoRoot -ChildPath 'README.md'
    $script:SitePath      = Join-Path -Path $repoRoot -ChildPath 'site\index.html'
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

Describe 'Published version strings track the constant' {
    # The version is surfaced in several human-facing places that are easy to
    # forget on a release. Each is pinned here so a bump in ODTVersion.psm1
    # that misses one fails the suite rather than shipping a stale badge.

    It 'README shields.io badge matches Get-ToolkitVersion' {
        $readme = Get-Content -LiteralPath $script:ReadmePath -Raw
        $match = [regex]::Match($readme, 'img\.shields\.io/badge/version-(\d+\.\d+\.\d+)-')
        $match.Success | Should -BeTrue -Because 'README carries a version badge'
        $match.Groups[1].Value | Should -Be (Get-ToolkitVersion)
    }

    It 'README "Current version" line matches Get-ToolkitVersion' {
        $readme = Get-Content -LiteralPath $script:ReadmePath -Raw
        $match = [regex]::Match($readme, '\*\*Current version\*\*:\s*`(\d+\.\d+\.\d+)`')
        $match.Success | Should -BeTrue
        $match.Groups[1].Value | Should -Be (Get-ToolkitVersion)
    }

    It 'every version string on the published site matches Get-ToolkitVersion' {
        # site/index.html is deployed to GitHub Pages by .github/workflows/pages.yml,
        # so a stale value here is the most publicly visible kind.
        Test-Path -LiteralPath $script:SitePath | Should -BeTrue
        $site = Get-Content -LiteralPath $script:SitePath -Raw
        $found = @([regex]::Matches($site, 'v(\d+\.\d+\.\d+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        $found.Count | Should -BeGreaterThan 0 -Because 'the site displays the toolkit version'
        foreach ($v in $found) {
            $v | Should -Be (Get-ToolkitVersion)
        }
    }
}
