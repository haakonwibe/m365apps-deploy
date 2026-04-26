#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 tests for Common/ODTPrerequisites.psm1.

.DESCRIPTION
    Uses InModuleScope mocks so the individual check functions do not
    actually talk to the real registry, disk, or process table.
#>

BeforeAll {
    $repoRoot = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..')
    Import-Module (Join-Path $repoRoot 'Common\ODTPrerequisites.psm1') -Force
}

AfterAll {
    Remove-Module ODTPrerequisites -ErrorAction SilentlyContinue
}

Describe 'Test-PendingReboot' {
    It 'returns Passed=$true when no indicator keys are present' {
        InModuleScope ODTPrerequisites {
            Mock Test-Registry64KeyExists { $false }
            $r = Test-PendingReboot
            $r.Passed | Should -BeTrue
            $r.Details | Should -Match 'No pending reboot'
        }
    }

    It 'returns Passed=$false when the CBS reboot key is present' {
        InModuleScope ODTPrerequisites {
            Mock Test-Registry64KeyExists { $true }  -ParameterFilter { $Path -like '*RebootPending*' }
            Mock Test-Registry64KeyExists { $false }
            $r = Test-PendingReboot
            $r.Passed  | Should -BeFalse
            $r.Details | Should -Match 'CBS RebootPending'
        }
    }

    It 'returns Passed=$false when the Windows Update RebootRequired key is present' {
        InModuleScope ODTPrerequisites {
            Mock Test-Registry64KeyExists { $true }  -ParameterFilter { $Path -like '*WindowsUpdate\Auto Update\RebootRequired' }
            Mock Test-Registry64KeyExists { $false }
            $r = Test-PendingReboot
            $r.Passed  | Should -BeFalse
            $r.Details | Should -Match 'Windows Update RebootRequired'
        }
    }

    It 'ignores PendingFileRenameOperations (Windows queues file renames there as normal operation, not a reboot signal)' {
        # PendingFileRenameOperations is populated by Windows Update / Defender /
        # C2R and many other components as a normal queue for "files to rename
        # on next convenient reboot". It is NOT a reboot-required signal -
        # treating it as one would produce constant false FAILs on essentially
        # any running system. Test-PendingReboot deliberately does not probe
        # this value; the check depends only on the two CBS / WU registry keys.
        InModuleScope ODTPrerequisites {
            Mock Test-Registry64KeyExists { $false }

            # Sabotage: if Test-PendingReboot regresses and reads this value,
            # the mock would fire and we would assert against it below. Since
            # the implementation must not probe Session Manager at all, the
            # mock should never be invoked.
            Mock Test-Registry64KeyExists { $true } -ParameterFilter { $Path -like '*Session Manager*' }

            $r = Test-PendingReboot
            $r.Passed  | Should -BeTrue
            $r.Details | Should -Not -Match 'PendingFileRenameOperations'
            Should -Invoke -CommandName Test-Registry64KeyExists -ModuleName ODTPrerequisites -Times 0 -ParameterFilter { $Path -like '*Session Manager*' }
        }
    }
}

Describe 'Test-FreeDiskSpace' {
    It 'passes when free space meets the threshold' {
        InModuleScope ODTPrerequisites {
            Mock Get-PSDrive { [pscustomobject]@{ Name = 'C'; Free = 20GB } }
            $r = Test-FreeDiskSpace -MinimumFreeGB 5
            $r.Passed | Should -BeTrue
        }
    }

    It 'fails when free space is below the threshold' {
        InModuleScope ODTPrerequisites {
            Mock Get-PSDrive { [pscustomobject]@{ Name = 'C'; Free = 1GB } }
            $r = Test-FreeDiskSpace -MinimumFreeGB 5
            $r.Passed | Should -BeFalse
            $r.Details | Should -Match '1 GB free'
        }
    }
}

Describe 'Invoke-ODTPrerequisiteChecks' {
    It 'aggregates individual check results' {
        InModuleScope ODTPrerequisites {
            Mock Test-RunningAsElevated { [pscustomobject]@{ CheckName='Elevation'; Passed=$true;  Details='ok' } }
            Mock Test-PendingReboot     { [pscustomobject]@{ CheckName='PendingReboot'; Passed=$true;  Details='ok' } }
            Mock Test-FreeDiskSpace     { [pscustomobject]@{ CheckName='DiskSpace'; Passed=$false; Details='too small' } } -ParameterFilter { $MinimumFreeGB -eq 5 }

            $agg = Invoke-ODTPrerequisiteChecks -MinimumFreeGB 5
            $agg.AllPassed | Should -BeFalse
            $agg.Summary   | Should -Match 'DiskSpace'
            ($agg.Results | Where-Object { -not $_.Passed }).CheckName | Should -Be 'DiskSpace'
        }
    }

    It 'skips the elevation check when -SkipElevation is set' {
        InModuleScope ODTPrerequisites {
            Mock Test-RunningAsElevated { [pscustomobject]@{ CheckName='Elevation'; Passed=$false; Details='not elevated' } }
            Mock Test-PendingReboot     { [pscustomobject]@{ CheckName='PendingReboot'; Passed=$true;  Details='ok' } }
            Mock Test-FreeDiskSpace     { [pscustomobject]@{ CheckName='DiskSpace'; Passed=$true; Details='ok' } }

            $agg = Invoke-ODTPrerequisiteChecks -SkipElevation
            $agg.AllPassed | Should -BeTrue
            $agg.Results.CheckName | Should -Not -Contain 'Elevation'
        }
    }

    It 'does not include a NoRunningSetup check (concurrency is delegated to ODT via exit codes)' {
        InModuleScope ODTPrerequisites {
            Mock Test-RunningAsElevated { [pscustomobject]@{ CheckName='Elevation'; Passed=$true; Details='ok' } }
            Mock Test-PendingReboot     { [pscustomobject]@{ CheckName='PendingReboot'; Passed=$true; Details='ok' } }
            Mock Test-FreeDiskSpace     { [pscustomobject]@{ CheckName='DiskSpace'; Passed=$true; Details='ok' } }

            $agg = Invoke-ODTPrerequisiteChecks
            $agg.Results.CheckName | Should -Not -Contain 'NoRunningSetup'
            ($agg.Results).Count   | Should -Be 3
        }
    }
}
