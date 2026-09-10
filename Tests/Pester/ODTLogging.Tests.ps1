#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 tests for Common/ODTLogging.psm1.

.DESCRIPTION
    Exercises CMTrace line shape, log rotation, session header/footer,
    and path resolution. Runs against a temp directory so tests are
    hermetic.

    Run with:
        Invoke-Pester -Path .\Tests\Pester\ODTLogging.Tests.ps1
#>

BeforeAll {
    $repoRoot = Split-Path -Path (Split-Path -Path $PSCommandPath -Parent) -Parent | Split-Path -Parent
    # PSCommandPath is Tests\Pester\ODTLogging.Tests.ps1; go up two to reach repo root.
    $repoRoot = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..')
    $modulePath = Join-Path -Path $repoRoot -ChildPath 'Common\ODTLogging.psm1'
    Import-Module $modulePath -Force

    $script:TestLogRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("odtlogging-tests-$([Guid]::NewGuid().ToString('N'))")
    $null = New-Item -Path $script:TestLogRoot -ItemType Directory -Force
}

AfterAll {
    if (Test-Path -LiteralPath $script:TestLogRoot) {
        Remove-Item -LiteralPath $script:TestLogRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Module ODTLogging -ErrorAction SilentlyContinue
}

Describe 'Resolve-ODTLogFilePath' {
    It 'joins log path and file name when LogFile is relative' {
        $path = Resolve-ODTLogFilePath -LogFile 'x.log' -LogPath 'C:\Foo'
        $path | Should -Be 'C:\Foo\x.log'
    }

    It 'honours a fully rooted LogFile' {
        $path = Resolve-ODTLogFilePath -LogFile 'C:\Other\y.log' -LogPath 'C:\Foo'
        $path | Should -Be 'C:\Other\y.log'
    }

    It 'falls back to the default log root when LogPath is empty' {
        $path = Resolve-ODTLogFilePath -LogFile 'z.log' -LogPath ''
        $path | Should -Be 'C:\ProgramData\M365AppsDeploy\Logs\z.log'
    }
}

Describe 'Write-ODTLog' {
    It 'creates the log file and writes a CMTrace-shaped line' {
        $logFile = 'write-ok.log'
        Write-ODTLog -Message 'hello world' -Component 'PesterTest' -LogFile $logFile -LogPath $script:TestLogRoot
        $full = Join-Path -Path $script:TestLogRoot -ChildPath $logFile
        Test-Path -LiteralPath $full | Should -BeTrue
        $content = Get-Content -LiteralPath $full -Raw
        $content | Should -Match '<!\[LOG\[hello world\]LOG\]!>'
        $content | Should -Match 'component="PesterTest"'
        $content | Should -Match 'type="1"'
        $content | Should -Match ('thread="{0}"' -f $PID)
    }

    It 'writes warning severity when -Severity 2' {
        $logFile = 'write-warn.log'
        Write-ODTLog -Message 'careful now' -Severity 2 -Component 'PesterTest' -LogFile $logFile -LogPath $script:TestLogRoot
        (Get-Content -LiteralPath (Join-Path $script:TestLogRoot $logFile) -Raw) | Should -Match 'type="2"'
    }

    It 'writes error severity when -Severity 3' {
        $logFile = 'write-err.log'
        Write-ODTLog -Message 'boom' -Severity 3 -Component 'PesterTest' -LogFile $logFile -LogPath $script:TestLogRoot
        (Get-Content -LiteralPath (Join-Path $script:TestLogRoot $logFile) -Raw) | Should -Match 'type="3"'
    }

    It 'splits multi-line messages into one CMTrace line per source line' {
        $logFile = 'multi.log'
        Write-ODTLog -Message "line 1`nline 2" -Component 'PesterTest' -LogFile $logFile -LogPath $script:TestLogRoot
        $lines = Get-Content -LiteralPath (Join-Path $script:TestLogRoot $logFile)
        ($lines | Where-Object { $_ -match '<!\[LOG\[' }).Count | Should -Be 2
    }

    It 'rotates to .old when the existing log exceeds the threshold' {
        $logFile = 'rotate.log'
        $full    = Join-Path -Path $script:TestLogRoot -ChildPath $logFile
        # Pre-create a large log > 10 MB.
        $bytes = New-Object byte[] (11 * 1024 * 1024)
        [System.IO.File]::WriteAllBytes($full, $bytes)
        Write-ODTLog -Message 'trigger rotation' -Component 'PesterTest' -LogFile $logFile -LogPath $script:TestLogRoot
        Test-Path -LiteralPath "$full.old" | Should -BeTrue
        (Get-Content -LiteralPath $full -Raw) | Should -Match 'trigger rotation'
    }
}

Describe 'Start-/Stop-ODTLogSession' {
    It 'writes a header with script name and parameters' {
        $logFile = 'session.log'
        Start-ODTLogSession -ScriptName 'Pester-Session' -ScriptVersion '9.9.9' -Parameters @{ Alpha = 1; Beta = 'two' } -LogFile $logFile -LogPath $script:TestLogRoot
        $content = Get-Content -LiteralPath (Join-Path $script:TestLogRoot $logFile) -Raw
        $content | Should -Match 'Start of session: Pester-Session'
        $content | Should -Match 'Script version : 9.9.9'
        $content | Should -Match 'Alpha = 1'
        $content | Should -Match 'Beta = two'
    }

    It 'writes a footer with exit code and caller-supplied detail' {
        $logFile = 'session.log'
        Stop-ODTLogSession -ScriptName 'Pester-Session' -ExitCode 17002 -Message 'testing footer' -LogFile $logFile -LogPath $script:TestLogRoot
        $content = Get-Content -LiteralPath (Join-Path $script:TestLogRoot $logFile) -Raw
        $content | Should -Match 'End of session : Pester-Session'
        $content | Should -Match 'Exit code      : 17002'
        # Caller-supplied -Message lands on the Detail line, not Result.
        $content | Should -Match 'Detail         : testing footer'
    }
}

Describe 'Stop-ODTLogSession Result line derives from ExitCode' {
    # The Result line is derived from the exit code itself, not from any
    # caller-supplied $summary variable - so a 0 exit always reads as
    # "Success." and a non-zero exit always reads as the matching failure.

    It 'writes Result: Success. for exit code 0' {
        $logFile = 'result-exit-0.log'
        Stop-ODTLogSession -ScriptName 'Pester-Result' -ExitCode 0 -LogFile $logFile -LogPath $script:TestLogRoot
        $content = Get-Content -LiteralPath (Join-Path $script:TestLogRoot $logFile) -Raw
        $content | Should -Match 'Result         : Success\.'
    }

    It 'writes Result: Failed (generic install failure). for exit code 1603' {
        $logFile = 'result-exit-1603.log'
        Stop-ODTLogSession -ScriptName 'Pester-Result' -ExitCode 1603 -LogFile $logFile -LogPath $script:TestLogRoot
        $content = Get-Content -LiteralPath (Join-Path $script:TestLogRoot $logFile) -Raw
        $content | Should -Match 'Result         : Failed \(generic install failure\)\.'
    }

    It 'writes Result: Failed (another install in progress). for exit code 1618' {
        $logFile = 'result-exit-1618.log'
        Stop-ODTLogSession -ScriptName 'Pester-Result' -ExitCode 1618 -LogFile $logFile -LogPath $script:TestLogRoot
        $content = Get-Content -LiteralPath (Join-Path $script:TestLogRoot $logFile) -Raw
        $content | Should -Match 'Result         : Failed \(another install in progress\)\.'
    }

    It 'writes Result: Failed (ODT reported failure). for exit code 17002' {
        $logFile = 'result-exit-17002.log'
        Stop-ODTLogSession -ScriptName 'Pester-Result' -ExitCode 17002 -LogFile $logFile -LogPath $script:TestLogRoot
        $content = Get-Content -LiteralPath (Join-Path $script:TestLogRoot $logFile) -Raw
        $content | Should -Match 'Result         : Failed \(ODT reported failure\)\.'
    }

    It 'writes Result: Success, reboot required. for exit code 3010' {
        $logFile = 'result-exit-3010.log'
        Stop-ODTLogSession -ScriptName 'Pester-Result' -ExitCode 3010 -LogFile $logFile -LogPath $script:TestLogRoot
        $content = Get-Content -LiteralPath (Join-Path $script:TestLogRoot $logFile) -Raw
        $content | Should -Match 'Result         : Success, reboot required\.'
    }

    It 'writes Result: Success, reboot initiated. for exit code 1641' {
        $logFile = 'result-exit-1641.log'
        Stop-ODTLogSession -ScriptName 'Pester-Result' -ExitCode 1641 -LogFile $logFile -LogPath $script:TestLogRoot
        $content = Get-Content -LiteralPath (Join-Path $script:TestLogRoot $logFile) -Raw
        $content | Should -Match 'Result         : Success, reboot initiated\.'
    }

    It 'writes Result: Failed (exit code N). for unknown non-zero exit codes' {
        $logFile = 'result-exit-99999.log'
        Stop-ODTLogSession -ScriptName 'Pester-Result' -ExitCode 99999 -LogFile $logFile -LogPath $script:TestLogRoot
        $content = Get-Content -LiteralPath (Join-Path $script:TestLogRoot $logFile) -Raw
        $content | Should -Match 'Result         : Failed \(exit code 99999\)\.'
    }

    It 'does NOT let a stale -Message ("Install succeeded.") override the Result line when ExitCode is 1603' {
        # Reproduces the original bug: Install-M365Apps.ps1 initialises
        # $summary = 'Install succeeded.' and calls Stop-ODTLogSession
        # with the stale value when a prerequisite check throws.
        $logFile = 'result-bug-repro.log'
        Stop-ODTLogSession -ScriptName 'Pester-Result' -ExitCode 1603 `
            -Message 'Install succeeded.' -LogFile $logFile -LogPath $script:TestLogRoot
        $content = Get-Content -LiteralPath (Join-Path $script:TestLogRoot $logFile) -Raw

        # Authoritative Result line reflects the failure.
        $content | Should -Match 'Result         : Failed \(generic install failure\)\.'
        # Stale message still visible as Detail for forensics, just not as Result.
        $content | Should -Match 'Detail         : Install succeeded\.'
        # Result line must NOT carry the stale success string.
        $content | Should -Not -Match 'Result         : Install succeeded\.'
    }
}

Describe 'Get-ODTSessionElapsed' {
    It 'returns TimeSpan::Zero when no session is open for that log file' {
        $span = Get-ODTSessionElapsed -LogFile 'no-such-session.log' -LogPath $script:TestLogRoot
        $span | Should -BeOfType ([timespan])
        $span.Ticks | Should -Be 0
    }

    It 'returns a small positive span immediately after Start-ODTLogSession' {
        $logFile = 'elapsed.log'
        Start-ODTLogSession -ScriptName 'Pester-Elapsed' -LogFile $logFile -LogPath $script:TestLogRoot
        $span = Get-ODTSessionElapsed -LogFile $logFile -LogPath $script:TestLogRoot
        $span.TotalSeconds | Should -BeGreaterOrEqual 0
        $span.TotalSeconds | Should -BeLessThan 5
        Stop-ODTLogSession -ScriptName 'Pester-Elapsed' -ExitCode 0 -LogFile $logFile -LogPath $script:TestLogRoot
    }

    It 'returns to Zero once the session is stopped' {
        $logFile = 'elapsed-cleared.log'
        Start-ODTLogSession -ScriptName 'Pester-Elapsed' -LogFile $logFile -LogPath $script:TestLogRoot
        Stop-ODTLogSession -ScriptName 'Pester-Elapsed' -ExitCode 0 -LogFile $logFile -LogPath $script:TestLogRoot
        (Get-ODTSessionElapsed -LogFile $logFile -LogPath $script:TestLogRoot).Ticks | Should -Be 0
    }

    It 'keys on the resolved path, so LogFile+LogPath and the full path agree' {
        $logFile = 'elapsed-keyed.log'
        $full    = Join-Path -Path $script:TestLogRoot -ChildPath $logFile
        Start-ODTLogSession -ScriptName 'Pester-Elapsed' -LogFile $logFile -LogPath $script:TestLogRoot
        (Get-ODTSessionElapsed -LogFile $full).Ticks | Should -BeGreaterThan 0
        Stop-ODTLogSession -ScriptName 'Pester-Elapsed' -ExitCode 0 -LogFile $logFile -LogPath $script:TestLogRoot
    }
}

Describe 'Write-ODTPhase' {
    It 'writes exactly one line in PHASE [t+HH:MM:SS] <Name> shape' {
        $logFile = 'phase-basic.log'
        Write-ODTPhase -Phase 'SetupStart' -Component 'Pester-Phase' -LogFile $logFile -LogPath $script:TestLogRoot
        $lines = @(Get-Content -LiteralPath (Join-Path $script:TestLogRoot $logFile) | Where-Object { $_ -match '<!\[LOG\[' })
        $lines.Count | Should -Be 1
        $lines[0] | Should -Match 'PHASE \[t\+\d\d:\d\d:\d\d\] SetupStart'
    }

    It 'honours the caller-supplied Component rather than defaulting to ODTLogging' {
        $logFile = 'phase-component.log'
        Write-ODTPhase -Phase 'SetupStart' -Component 'Install-M365Apps' -LogFile $logFile -LogPath $script:TestLogRoot
        $content = Get-Content -LiteralPath (Join-Path $script:TestLogRoot $logFile) -Raw
        $content | Should -Match 'component="Install-M365Apps"'
    }

    It 'appends -Detail after a dash' {
        $logFile = 'phase-detail.log'
        Write-ODTPhase -Phase 'SetupEnd' -Detail 'exit 0 after 878s' -Component 'Pester-Phase' -LogFile $logFile -LogPath $script:TestLogRoot
        $content = Get-Content -LiteralPath (Join-Path $script:TestLogRoot $logFile) -Raw
        $content | Should -Match 'PHASE \[t\+\d\d:\d\d:\d\d\] SetupEnd - exit 0 after 878s'
    }

    It 'leaves no dangling dash when -Detail is omitted or whitespace' {
        $logFile = 'phase-nodetail.log'
        Write-ODTPhase -Phase 'Done' -Component 'Pester-Phase' -LogFile $logFile -LogPath $script:TestLogRoot
        Write-ODTPhase -Phase 'Done' -Detail '   ' -Component 'Pester-Phase' -LogFile $logFile -LogPath $script:TestLogRoot
        $content = Get-Content -LiteralPath (Join-Path $script:TestLogRoot $logFile) -Raw
        $content | Should -Not -Match 'Done -'
    }

    It 'honours -Severity' {
        $logFile = 'phase-severity.log'
        Write-ODTPhase -Phase 'RemoveFailed' -Severity 2 -Component 'Pester-Phase' -LogFile $logFile -LogPath $script:TestLogRoot
        (Get-Content -LiteralPath (Join-Path $script:TestLogRoot $logFile) -Raw) | Should -Match 'type="2"'
    }

    It 'measures the offset from the open session rather than from zero' {
        $logFile = 'phase-offset.log'
        Start-ODTLogSession -ScriptName 'Pester-Phase' -LogFile $logFile -LogPath $script:TestLogRoot
        Start-Sleep -Milliseconds 1100
        Write-ODTPhase -Phase 'Later' -Component 'Pester-Phase' -LogFile $logFile -LogPath $script:TestLogRoot
        $content = Get-Content -LiteralPath (Join-Path $script:TestLogRoot $logFile) -Raw
        $content | Should -Match 'PHASE \[t\+00:00:0[1-9]\] Later'
        Stop-ODTLogSession -ScriptName 'Pester-Phase' -ExitCode 0 -LogFile $logFile -LogPath $script:TestLogRoot
    }

    It 'rejects an empty Phase name' {
        { Write-ODTPhase -Phase '' -Component 'Pester-Phase' -LogFile 'phase-empty.log' -LogPath $script:TestLogRoot } |
            Should -Throw
    }
}

Describe 'ODTLogging module surface' {
    It 'exports exactly the expected functions' {
        $expected = @(
            'Get-ODTSessionElapsed',
            'Initialize-ODTLogDirectory',
            'Resolve-ODTLogFilePath',
            'Start-ODTLogSession',
            'Stop-ODTLogSession',
            'Write-ODTLog',
            'Write-ODTPhase'
        )
        $actual = @((Get-Module ODTLogging).ExportedFunctions.Keys | Sort-Object)
        $actual | Should -Be $expected
    }
}
