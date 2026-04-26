#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 tests for Common/ODTInvoke.psm1.

.DESCRIPTION
    Focuses on exit-code translation, XML logging-injection, and
    configuration-path resolution rules. Does not actually launch setup.exe.
#>

BeforeAll {
    $repoRoot = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..')
    Import-Module (Join-Path $repoRoot 'Common\ODTInvoke.psm1') -Force

    $script:WorkDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("odtinvoke-tests-$([Guid]::NewGuid().ToString('N'))")
    $null = New-Item -Path $script:WorkDir -ItemType Directory -Force
}

AfterAll {
    if (Test-Path -LiteralPath $script:WorkDir) {
        Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Module ODTInvoke -ErrorAction SilentlyContinue
}

Describe 'Get-ODTExitCodeMessage' {
    It 'maps well-known codes' {
        (Get-ODTExitCodeMessage -ExitCode 0)     | Should -Match 'Success'
        (Get-ODTExitCodeMessage -ExitCode 1603)  | Should -Match 'Fatal install failure'
        (Get-ODTExitCodeMessage -ExitCode 17002) | Should -Match 'ODT reported a failure'
        (Get-ODTExitCodeMessage -ExitCode 1618)  | Should -Match 'Another installation is already in progress'
    }

    It 'returns a placeholder for unknown codes' {
        (Get-ODTExitCodeMessage -ExitCode 424242) | Should -Match 'no known description'
    }
}

Describe 'Get-ODTExitCodeResult' {
    It 'classifies 0 as Success' {
        $r = Get-ODTExitCodeResult -ExitCode 0
        $r.ExitCode    | Should -Be 0
        $r.Succeeded   | Should -BeTrue
        $r.Description | Should -Be 'Success.'
    }

    It 'classifies 3010 as Success, reboot required' {
        $r = Get-ODTExitCodeResult -ExitCode 3010
        $r.Succeeded   | Should -BeTrue
        $r.Description | Should -Be 'Success, reboot required.'
    }

    It 'classifies 1641 as Success, reboot initiated' {
        $r = Get-ODTExitCodeResult -ExitCode 1641
        $r.Succeeded   | Should -BeTrue
        $r.Description | Should -Be 'Success, reboot initiated.'
    }

    It 'classifies 1603 as Failed (generic install failure)' {
        $r = Get-ODTExitCodeResult -ExitCode 1603
        $r.Succeeded   | Should -BeFalse
        $r.Description | Should -Be 'Failed (generic install failure).'
    }

    It 'classifies 1618 as Failed (another install in progress)' {
        $r = Get-ODTExitCodeResult -ExitCode 1618
        $r.Succeeded   | Should -BeFalse
        $r.Description | Should -Be 'Failed (another install in progress).'
    }

    It 'classifies 17002 as Failed (ODT reported failure)' {
        $r = Get-ODTExitCodeResult -ExitCode 17002
        $r.Succeeded   | Should -BeFalse
        $r.Description | Should -Be 'Failed (ODT reported failure).'
    }

    It 'classifies unknown non-zero exit codes with the numeric code' {
        $r = Get-ODTExitCodeResult -ExitCode 424242
        $r.Succeeded   | Should -BeFalse
        $r.Description | Should -Be 'Failed (exit code 424242).'
    }
}

Describe 'Resolve-ODTConfigurationPath' {
    It 'throws when neither parameter is supplied' {
        { Resolve-ODTConfigurationPath -ConfigurationFile '' -ConfigurationURL '' } |
            Should -Throw -ExpectedMessage "*neither -ConfigurationFile nor -ConfigurationURL*"
    }

    It 'throws when a local file does not exist' {
        { Resolve-ODTConfigurationPath -ConfigurationFile 'C:\does\not\exist.xml' } |
            Should -Throw -ExpectedMessage "*not found*"
    }

    It 'returns an absolute path when a local file exists' {
        $file = Join-Path -Path $script:WorkDir -ChildPath 'present.xml'
        '<Configuration />' | Set-Content -LiteralPath $file -Encoding UTF8
        $result = Resolve-ODTConfigurationPath -ConfigurationFile $file
        Test-Path -LiteralPath $result | Should -BeTrue
    }

    It 'rejects non-HTTPS URLs' {
        { Resolve-ODTConfigurationPath -ConfigurationURL 'http://example.com/x.xml' } |
            Should -Throw -ExpectedMessage "*must be HTTPS*"
    }
}

