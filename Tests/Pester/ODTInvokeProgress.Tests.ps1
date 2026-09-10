#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 tests for the in-flight progress sampling added to
    Common/ODTInvoke.psm1 in 1.0.9.

.DESCRIPTION
    Two groups of tests:

    1. Pure functions - ConvertTo-ODTScenarioState, Get-ODTPhaseSummary,
       ConvertFrom-ODTC2RFileTime, Get-ODTDisabledSamplerReport. These carry
       the interesting logic and are exercised against data captured from a
       real Click-to-Run installation, with no registry access at all.

    2. The Invoke-ODTSetup sampling loop, driven by a fake process object so
       the tests are deterministic and do not launch anything. The fake is
       scripted as "return $false from WaitForExit N times, then $true",
       which is exactly the shape the loop consumes.

    The overriding contract under test is that sampling can never break an
    install: a sampler that throws, a sampler that is slow, and a callback
    that throws must all leave the install result untouched.

    Run with:
        Invoke-Pester -Path .\Tests\Pester\ODTInvokeProgress.Tests.ps1

    The timeout-inside-the-sampling-loop test costs a real minute (the
    parameter floor is 1 minute) and is tagged Slow:
        Invoke-Pester -Path .\Tests\Pester\ODTInvokeProgress.Tests.ps1 -ExcludeTagFilter Slow
#>

# Imported at script scope rather than only in BeforeAll: the InModuleScope
# block below is evaluated during Pester's discovery phase, which runs before
# any BeforeAll body, so the module must already be loaded by then.
$repoRoot   = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..')
$modulePath = Join-Path -Path $repoRoot -ChildPath 'Common\ODTInvoke.psm1'
Import-Module $modulePath -Force

AfterAll {
    Remove-Module ODTInvoke -ErrorAction SilentlyContinue
}

InModuleScope ODTInvoke {

    # Value names captured from a live device's
    # HKLM\SOFTWARE\Microsoft\Office\ClickToRun\Scenario\INSTALL\TasksState.
    # Duplicated BRANCH / GROUP / PROMPTUSER entries are real: C2R repeats
    # them at different points in the pipeline, each with its own GUID.
    BeforeAll {
        $script:InstallTaskNames = @(
            'SCENARIO:{00000000-0000-0000-0000-000000000001}'
            'PROMPTUSER:{00000000-0000-0000-0000-000000000002}'
            'BRANCH:{00000000-0000-0000-0000-000000000003}'
            'GROUP:{00000000-0000-0000-0000-000000000004}'
            'CREATEWORKINGCONFIGURATION:{00000000-0000-0000-0000-000000000005}'
            'STREAM:{00000000-0000-0000-0000-000000000006}'
            'STAGEREGISTRY:{00000000-0000-0000-0000-000000000007}'
            'UNINSTALLCENTENNIAL:{00000000-0000-0000-0000-000000000008}'
            'APPLYCONFIGURATION:{00000000-0000-0000-0000-000000000009}'
            'BRANCH:{00000000-0000-0000-0000-00000000000a}'
            'GROUP:{00000000-0000-0000-0000-00000000000b}'
            'GROUP:{00000000-0000-0000-0000-00000000000c}'
            'MIGRATE:{00000000-0000-0000-0000-00000000000d}'
            'FONTS:{00000000-0000-0000-0000-00000000000e}'
            'INITUPDATES:{00000000-0000-0000-0000-00000000000f}'
            'INTEGRATE_INSTALL:{00000000-0000-0000-0000-000000000010}'
            'BRANCH:{00000000-0000-0000-0000-000000000011}'
            'BRANCH:{00000000-0000-0000-0000-000000000012}'
            'BRANCH:{00000000-0000-0000-0000-000000000013}'
            'PROMPTUSER:{00000000-0000-0000-0000-000000000014}'
        )

        function New-TaskStateMap {
            param([hashtable] $Override = @{})
            $map = @{}
            foreach ($name in $script:InstallTaskNames) { $map[$name] = 'TASKSTATE_COMPLETED' }
            foreach ($key in $Override.Keys) { $map[$key] = $Override[$key] }
            return $map
        }

        function New-Sample {
            param([int] $ElapsedSeconds, $ActiveTask)
            return [pscustomobject]@{ ElapsedSeconds = $ElapsedSeconds; ActiveTask = $ActiveTask }
        }

        # Minimal stand-in for System.Diagnostics.Process. A ScriptMethod takes
        # optional arguments, so a single WaitForExit definition serves both the
        # timed overload the loop uses and the parameterless settling call.
        function New-FakeProcess {
            param(
                [int]    $WaitsBeforeExit = 0,
                [int]    $ExitCode        = 0,
                [switch] $NeverExits,
                [int]    $SleepPerWaitMs  = 0,
                [switch] $KillThrows
            )

            $fake = [pscustomobject]@{
                Id             = 4242
                ExitCode       = $ExitCode
                WaitCalls      = 0
                TimedWaitCalls = 0
                KillCalls      = 0
                Remaining      = $WaitsBeforeExit
                NeverExits     = [bool]$NeverExits
                SleepPerWaitMs = $SleepPerWaitMs
                KillThrows     = [bool]$KillThrows
            }

            $fake | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
                param($milliseconds)
                $this.WaitCalls++
                if ($null -ne $milliseconds) { $this.TimedWaitCalls++ }
                if ($this.SleepPerWaitMs -gt 0) { Start-Sleep -Milliseconds $this.SleepPerWaitMs }
                if ($this.NeverExits) { return $false }
                if ($this.Remaining -le 0) { return $true }
                $this.Remaining--
                return $false
            }

            $fake | Add-Member -MemberType ScriptMethod -Name Kill -Value {
                $this.KillCalls++
                if ($this.KillThrows) { throw 'Access is denied.' }
            }

            return $fake
        }

        # Neutralise every real sampler so loop tests never touch the machine.
        function Disable-RealSamplers {
            Mock Get-ODTC2RScenarioSnapshot {
                [pscustomobject]@{ Scenario = 'INSTALL'; Active = 'STREAM'; Completed = 5; Total = 20; Version = '16.0.0.0' }
            }
            Mock Get-ODTNetworkRxSnapshot  { 1000000.0 }
            Mock Get-ODTDiskFreeSnapshot   { 50000000000.0 }
            Mock Get-ODTProcessSnapshot    { ,@() }
        }
    }

    Describe 'ConvertTo-ODTScenarioState' {

        It 'reports no active task when every task is completed' {
            $state = ConvertTo-ODTScenarioState -ValueNames $script:InstallTaskNames -States (New-TaskStateMap)
            $state.Active    | Should -BeNullOrEmpty
            $state.Completed | Should -Be 20
            $state.Total     | Should -Be 20
        }

        It 'identifies STREAM as the active task while the payload is downloading' {
            $map = New-TaskStateMap -Override @{
                'STREAM:{00000000-0000-0000-0000-000000000006}' = 'TASKSTATE_EXECUTING'
            }
            $state = ConvertTo-ODTScenarioState -ValueNames $script:InstallTaskNames -States $map
            $state.Active    | Should -Be 'STREAM'
            $state.Completed | Should -Be 19
            $state.Total     | Should -Be 20
        }

        It 'strips the GUID suffix from the task name' {
            $map = New-TaskStateMap -Override @{
                'APPLYCONFIGURATION:{00000000-0000-0000-0000-000000000009}' = 'TASKSTATE_NOTSTARTED'
            }
            (ConvertTo-ODTScenarioState -ValueNames $script:InstallTaskNames -States $map).Active |
                Should -Be 'APPLYCONFIGURATION'
        }

        It 'picks the earliest outstanding task when several are not completed' {
            $map = New-TaskStateMap -Override @{
                'STREAM:{00000000-0000-0000-0000-000000000006}'             = 'TASKSTATE_EXECUTING'
                'APPLYCONFIGURATION:{00000000-0000-0000-0000-000000000009}' = 'TASKSTATE_NOTSTARTED'
            }
            (ConvertTo-ODTScenarioState -ValueNames $script:InstallTaskNames -States $map).Active |
                Should -Be 'STREAM'
        }

        It 'treats any non-COMPLETED state as outstanding' {
            foreach ($taskState in 'TASKSTATE_EXECUTING','TASKSTATE_NOTSTARTED','TASKSTATE_FAILED','TASKSTATE_CANCELLED','') {
                $map = New-TaskStateMap -Override @{ 'STREAM:{00000000-0000-0000-0000-000000000006}' = $taskState }
                (ConvertTo-ODTScenarioState -ValueNames $script:InstallTaskNames -States $map).Active |
                    Should -Be 'STREAM' -Because "state '$taskState' is not TASKSTATE_COMPLETED"
            }
        }

        It 'handles a value name with no GUID suffix' {
            $state = ConvertTo-ODTScenarioState -ValueNames @('STREAM') -States @{ 'STREAM' = 'TASKSTATE_EXECUTING' }
            $state.Active | Should -Be 'STREAM'
            $state.Total  | Should -Be 1
        }

        It 'does not throw on empty or null input under StrictMode' {
            foreach ($names in @(, @()), @($null)) {
                $state = ConvertTo-ODTScenarioState -ValueNames $names[0] -States $null
                $state.Active    | Should -BeNullOrEmpty
                $state.Completed | Should -Be 0
                $state.Total     | Should -Be 0
            }
        }

        It 'ignores blank value names' {
            $state = ConvertTo-ODTScenarioState -ValueNames @('', '   ') -States @{}
            $state.Completed | Should -Be 0
            $state.LastName  | Should -BeNullOrEmpty
        }
    }

    Describe 'Get-ODTPhaseSummary' {

        It 'collapses contiguous samples of the same task into one span' {
            $samples = @(
                (New-Sample 15 'CREATEWORKINGCONFIGURATION')
                (New-Sample 30 'CREATEWORKINGCONFIGURATION')
                (New-Sample 45 'STREAM')
                (New-Sample 60 'STREAM')
                (New-Sample 75 'STREAM')
                (New-Sample 90 'APPLYCONFIGURATION')
            )
            $summary = @(Get-ODTPhaseSummary -Samples $samples)
            $summary.Count | Should -Be 3
            $summary[0].Task | Should -Be 'CREATEWORKINGCONFIGURATION'
            $summary[1].Task | Should -Be 'STREAM'
            $summary[2].Task | Should -Be 'APPLYCONFIGURATION'
        }

        It 'attributes STREAM the longest span for a download-dominated run' {
            $samples = @(
                (New-Sample 30 'CREATEWORKINGCONFIGURATION')
                (New-Sample 60  'STREAM')
                (New-Sample 90  'STREAM')
                (New-Sample 120 'STREAM')
                (New-Sample 150 'STREAM')
                (New-Sample 180 'APPLYCONFIGURATION')
            )
            $summary = @(Get-ODTPhaseSummary -Samples $samples)
            $longest = $summary | Sort-Object DurationSeconds -Descending | Select-Object -First 1
            $longest.Task | Should -Be 'STREAM'
        }

        It 'produces contiguous, non-overlapping spans starting at zero' {
            $samples = @(
                (New-Sample 30 'A')
                (New-Sample 60 'B')
                (New-Sample 90 'C')
            )
            $summary = @(Get-ODTPhaseSummary -Samples $samples)
            $summary[0].FirstSeenSeconds | Should -Be 0
            for ($i = 1; $i -lt $summary.Count; $i++) {
                $summary[$i].FirstSeenSeconds | Should -Be $summary[$i - 1].LastSeenSeconds
            }
        }

        It 'reports DurationSeconds as LastSeen minus FirstSeen' {
            $summary = @(Get-ODTPhaseSummary -Samples @((New-Sample 30 'A'), (New-Sample 60 'B')))
            foreach ($span in $summary) {
                $span.DurationSeconds | Should -Be ($span.LastSeenSeconds - $span.FirstSeenSeconds)
            }
        }

        It 'skips idle samples where no task is active' {
            $samples = @(
                (New-Sample 30 $null)
                (New-Sample 60 'STREAM')
                (New-Sample 90 $null)
            )
            $summary = @(Get-ODTPhaseSummary -Samples $samples)
            @($summary | Where-Object { $_.Task -eq 'STREAM' }).Count | Should -Be 1
            $summary.Count | Should -Be 1
        }

        It 'returns an empty collection - not a one-element one - for empty and null input' {
            @(Get-ODTPhaseSummary -Samples @()).Count   | Should -Be 0
            @(Get-ODTPhaseSummary -Samples $null).Count | Should -Be 0
        }
    }

    Describe 'ConvertFrom-ODTC2RFileTime' {

        It 'decodes a captured UpdateStatus timestamp to the expected UTC instant' {
            $decoded = ConvertFrom-ODTC2RFileTime -Value '13433428243978'
            $decoded | Should -BeOfType ([datetime])
            $decoded.ToString('yyyy-MM-ddTHH:mm:ssZ') | Should -Be '2026-09-09T11:50:43Z'
        }

        It 'returns null without throwing for unusable input' {
            foreach ($value in $null, '', '   ', '0', '-1', 'nope', '999999999999999999') {
                ConvertFrom-ODTC2RFileTime -Value $value | Should -BeNullOrEmpty -Because "input '$value' is not a usable timestamp"
            }
        }

        It 'tolerates surrounding whitespace' {
            (ConvertFrom-ODTC2RFileTime -Value '  13433428243978  ').ToString('yyyy-MM-dd') | Should -Be '2026-09-09'
        }
    }

    Describe 'Get-ODTDisabledSamplerReport' {

        It 'returns an empty collection when nothing was disabled' {
            @(Get-ODTDisabledSamplerReport -Disabled @{}).Count | Should -Be 0
        }

        It 'reports each disabled sampler once and hides the internal reported flag' {
            $report = @(Get-ODTDisabledSamplerReport -Disabled @{
                net            = 'boom'
                'net:reported' = $true
                disk           = 'over budget (5000 ms > 3000 ms)'
            })
            $report.Count | Should -Be 2
            ($report.Name | Sort-Object) -join ',' | Should -Be 'disk,net'
            ($report | Where-Object { $_.Name -eq 'net' }).Reason | Should -Be 'boom'
        }
    }

    Describe 'Invoke-ODTSafeSampler' {

        It 'returns the sampler value on the happy path' {
            $disabled = @{}
            Invoke-ODTSafeSampler -Name 'x' -Disabled $disabled -Sampler { 42 } | Should -Be 42
            $disabled.Count | Should -Be 0
        }

        It 'disables a sampler on its first throw and never calls it again' {
            $disabled = @{}
            $calls = 0
            $sampler = { $script:SafeSamplerCalls++; throw 'boom' }
            $script:SafeSamplerCalls = 0
            for ($i = 0; $i -lt 5; $i++) {
                Invoke-ODTSafeSampler -Name 'x' -Disabled $disabled -Sampler $sampler | Should -BeNullOrEmpty
            }
            $script:SafeSamplerCalls | Should -Be 1
            $disabled['x'] | Should -Be 'boom'
        }

        It 'disables a sampler that exceeds its budget, after letting the first call finish' {
            $disabled = @{}
            $script:SlowSamplerCalls = 0
            $sampler = { $script:SlowSamplerCalls++; Start-Sleep -Milliseconds 400; 'value' }
            Invoke-ODTSafeSampler -Name 'slow' -Disabled $disabled -BudgetMs 250 -Sampler $sampler | Should -Be 'value'
            $disabled.ContainsKey('slow') | Should -BeTrue
            $disabled['slow'] | Should -Match 'over budget'
            Invoke-ODTSafeSampler -Name 'slow' -Disabled $disabled -BudgetMs 250 -Sampler $sampler | Should -BeNullOrEmpty
            $script:SlowSamplerCalls | Should -Be 1
        }
    }

    Describe 'New-ODTProgressSample' {

        BeforeEach { Disable-RealSamplers }

        It 'renders a line with every section present' {
            $sample = New-ODTProgressSample -ElapsedSeconds 630 -Previous $null -Disabled @{}
            $sample.Line | Should -Match '^Progress t=630s '
            $sample.Line | Should -Match 'c2r: scenario=INSTALL active=STREAM done=5/20'
            $sample.Line | Should -Match 'net: '
            $sample.Line | Should -Match 'disk: '
        }

        It 'formats numbers invariantly so logs read the same on any locale' {
            Mock Get-ODTDiskFreeSnapshot { 44234567890.0 }
            $sample = New-ODTProgressSample -ElapsedSeconds 1 -Previous $null -Disabled @{}
            # A decimal point, never a comma, and no group separators.
            $sample.Line | Should -Match 'disk: \S+ 41\.2GB free'
            $sample.Line | Should -Not -Match '41,2GB'
        }

        It 'reports throughput once a previous sample exists' {
            $disabled = @{}
            Mock Get-ODTNetworkRxSnapshot { 0.0 }
            $first = New-ODTProgressSample -ElapsedSeconds 0 -Previous $null -Disabled $disabled
            Mock Get-ODTNetworkRxSnapshot { 125000000.0 }   # +125 MB over 10s = 100 Mbit/s
            $second = New-ODTProgressSample -ElapsedSeconds 10 -Previous $first -Disabled $disabled

            $first.NetMbps  | Should -BeNullOrEmpty
            [math]::Round($second.NetMbps) | Should -Be 100
            $second.Line | Should -Match '100\.0Mbit/s'
        }

        It 'reports disk delta signed, so cleanup after apply reads as negative' {
            $disabled = @{}
            Mock Get-ODTDiskFreeSnapshot { 50000000000.0 }
            $first = New-ODTProgressSample -ElapsedSeconds 0 -Previous $null -Disabled $disabled
            Mock Get-ODTDiskFreeSnapshot { 52000000000.0 }  # freed 2 GB
            $second = New-ODTProgressSample -ElapsedSeconds 30 -Previous $first -Disabled $disabled

            $second.DiskWrittenBytes | Should -BeLessThan 0
            $second.Line | Should -Match 'free \(-\d+MB\)'
        }

        It 'renders an idle marker rather than blank when no C2R task is outstanding' {
            Mock Get-ODTC2RScenarioSnapshot {
                [pscustomobject]@{ Scenario = 'INSTALL'; Active = $null; Completed = 20; Total = 20; Version = '16.0.0.0' }
            }
            (New-ODTProgressSample -ElapsedSeconds 1 -Previous $null -Disabled @{}).Line |
                Should -Match 'active=<idle>'
        }

        It 'renders a pending marker before C2R publishes a version' {
            Mock Get-ODTC2RScenarioSnapshot {
                [pscustomobject]@{ Scenario = '<key-absent>'; Active = $null; Completed = 0; Total = 0; Version = $null }
            }
            (New-ODTProgressSample -ElapsedSeconds 1 -Previous $null -Disabled @{}).Line |
                Should -Match 'scenario=<key-absent>.*ver=<pending>'
        }

        It 'survives every sampler throwing, and names each one once' {
            Mock Get-ODTC2RScenarioSnapshot { throw 'c2r exploded' }
            Mock Get-ODTNetworkRxSnapshot   { throw 'net exploded' }
            Mock Get-ODTDiskFreeSnapshot    { throw 'disk exploded' }
            Mock Get-ODTProcessSnapshot     { throw 'proc exploded' }

            $disabled = @{}
            $first = New-ODTProgressSample -ElapsedSeconds 30 -Previous $null -Disabled $disabled

            $first | Should -Not -BeNullOrEmpty
            $first.Line | Should -Match 'c2r: n/a \(disabled: c2r exploded\)'
            $first.Line | Should -Match 'net: n/a \(disabled: net exploded\)'
            $first.Line | Should -Match 'disk: n/a \(disabled: disk exploded\)'
            $first.Line | Should -Match 'proc: n/a \(disabled: proc exploded\)'

            # Second sample: still readable, but the reason is not repeated.
            $second = New-ODTProgressSample -ElapsedSeconds 60 -Previous $first -Disabled $disabled
            $second.Line | Should -Match 'c2r: n/a'
            $second.Line | Should -Not -Match 'disabled:'
        }

        It 'leaves every field readable under StrictMode when samplers fail' {
            Mock Get-ODTC2RScenarioSnapshot { throw 'x' }
            Mock Get-ODTNetworkRxSnapshot   { throw 'x' }
            Mock Get-ODTDiskFreeSnapshot    { throw 'x' }
            Mock Get-ODTProcessSnapshot     { throw 'x' }

            $sample = New-ODTProgressSample -ElapsedSeconds 5 -Previous $null -Disabled @{}
            foreach ($field in 'ElapsedSeconds','TimestampUtc','Scenario','ActiveTask','CompletedTasks',
                               'TotalTasks','Version','NetRxTotalBytes','NetRxDeltaBytes','NetMbps',
                               'DiskFreeBytes','DiskWrittenBytes','Processes','Line') {
                { $sample.$field } | Should -Not -Throw -Because "$field must be pre-initialised"
            }
        }
    }

    Describe 'Invoke-ODTSetup result contract' {

        BeforeEach {
            Disable-RealSamplers
            $script:Fake = New-FakeProcess -ExitCode 0
            Mock Start-Process { $script:Fake }
        }

        It 'still exposes the four original fields with their original meanings' {
            $result = Invoke-ODTSetup -SetupExePath 'setup.exe' -ConfigurationPath 'c.xml' -ProgressIntervalSeconds 0
            foreach ($name in 'ExitCode','DurationSeconds','Success','Message') {
                $result.PSObject.Properties.Name | Should -Contain $name
            }
            $result.ExitCode        | Should -Be 0
            $result.Success         | Should -BeTrue
            $result.DurationSeconds | Should -BeOfType ([int])
            $result.Message         | Should -Be 'Success.'
        }

        It 'exposes the new diagnostic fields' {
            $result = Invoke-ODTSetup -SetupExePath 'setup.exe' -ConfigurationPath 'c.xml' -ProgressIntervalSeconds 0
            foreach ($name in 'TimedOut','StartedUtc','EndedUtc','SampleCount','Samples','PhaseSummary','DisabledSamplers') {
                $result.PSObject.Properties.Name | Should -Contain $name
            }
        }

        It 'treats 0, 3010 and 1641 as success and anything else as failure' {
            foreach ($pair in @(@(0,$true), @(3010,$true), @(1641,$true), @(1603,$false), @(17002,$false), @(1618,$false))) {
                $script:Fake = New-FakeProcess -ExitCode $pair[0]
                Mock Start-Process { $script:Fake }
                $result = Invoke-ODTSetup -SetupExePath 'setup.exe' -ConfigurationPath 'c.xml' -ProgressIntervalSeconds 0
                $result.ExitCode | Should -Be $pair[0]
                $result.Success  | Should -Be $pair[1]
            }
        }

        It 'keeps every new parameter optional, so the existing call sites are unaffected' {
            $params = (Get-Command Invoke-ODTSetup).Parameters
            foreach ($name in 'TimeoutMinutes','ProgressIntervalSeconds','ProgressCallback','SamplerBudgetMilliseconds','MaxRetainedSamples') {
                $attr = $params[$name].Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }
                @($attr).Mandatory | Should -Not -Contain $true -Because "$name must be optional"
            }
            { Invoke-ODTSetup -SetupExePath 'setup.exe' -ConfigurationPath 'c.xml' } | Should -Not -Throw
        }

        It 'emits nothing besides the result object' {
            $output = @(Invoke-ODTSetup -SetupExePath 'setup.exe' -ConfigurationPath 'c.xml' -ProgressIntervalSeconds 0)
            $output.Count | Should -Be 1
        }

        It 'passes /configure and the quoted configuration path to setup.exe' {
            Invoke-ODTSetup -SetupExePath 'setup.exe' -ConfigurationPath 'C:\x\c.xml' -ProgressIntervalSeconds 0 | Out-Null
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
                $ArgumentList[0] -eq '/configure' -and $ArgumentList[1] -eq '"C:\x\c.xml"'
            }
        }
    }

    Describe 'Invoke-ODTSetup sampling loop' {

        BeforeEach { Disable-RealSamplers }

        It 'takes no samples and waits exactly once when sampling is disabled' {
            $script:Fake = New-FakeProcess -WaitsBeforeExit 0
            Mock Start-Process { $script:Fake }
            $result = Invoke-ODTSetup -SetupExePath 's.exe' -ConfigurationPath 'c.xml' -ProgressIntervalSeconds 0
            $result.SampleCount | Should -Be 0
            @($result.Samples).Count | Should -Be 0
            $result.TimedOut | Should -BeFalse
            # One timed wait for the whole run - no interval slicing at all.
            $script:Fake.TimedWaitCalls | Should -Be 1
        }

        It 'takes no samples when the process exits during the first interval' {
            $script:Fake = New-FakeProcess -WaitsBeforeExit 0
            Mock Start-Process { $script:Fake }
            $result = Invoke-ODTSetup -SetupExePath 's.exe' -ConfigurationPath 'c.xml' -ProgressIntervalSeconds 30
            $result.SampleCount | Should -Be 0
        }

        It 'takes one sample per elapsed interval' {
            $script:Fake = New-FakeProcess -WaitsBeforeExit 3
            Mock Start-Process { $script:Fake }
            $result = Invoke-ODTSetup -SetupExePath 's.exe' -ConfigurationPath 'c.xml' -ProgressIntervalSeconds 30
            $result.SampleCount | Should -Be 3
            @($result.Samples).Count | Should -Be 3
        }

        It 'invokes the callback once per sample with a non-empty line' {
            $script:Fake = New-FakeProcess -WaitsBeforeExit 4
            Mock Start-Process { $script:Fake }
            $script:Captured = New-Object System.Collections.Generic.List[string]
            $callback = { param($line, $severity) $script:Captured.Add($line) }

            $result = Invoke-ODTSetup -SetupExePath 's.exe' -ConfigurationPath 'c.xml' `
                                      -ProgressIntervalSeconds 30 -ProgressCallback $callback
            $result.SampleCount    | Should -Be 4
            $script:Captured.Count | Should -Be 4
            foreach ($line in $script:Captured) { $line | Should -Match '^Progress t=\d+s ' }
        }

        It 'does not fail the install when the callback throws' {
            $script:Fake = New-FakeProcess -WaitsBeforeExit 3 -ExitCode 0
            Mock Start-Process { $script:Fake }
            $result = Invoke-ODTSetup -SetupExePath 's.exe' -ConfigurationPath 'c.xml' `
                                      -ProgressIntervalSeconds 30 -ProgressCallback { throw 'callback exploded' }
            $result.ExitCode | Should -Be 0
            $result.Success  | Should -BeTrue
        }

        It 'does not fail the install when every sampler throws' {
            Mock Get-ODTC2RScenarioSnapshot { throw 'boom' }
            Mock Get-ODTNetworkRxSnapshot   { throw 'boom' }
            Mock Get-ODTDiskFreeSnapshot    { throw 'boom' }
            Mock Get-ODTProcessSnapshot     { throw 'boom' }

            $script:Fake = New-FakeProcess -WaitsBeforeExit 3
            Mock Start-Process { $script:Fake }
            $result = Invoke-ODTSetup -SetupExePath 's.exe' -ConfigurationPath 'c.xml' -ProgressIntervalSeconds 30

            $result.Success     | Should -BeTrue
            $result.SampleCount | Should -Be 3
            @($result.DisabledSamplers).Count | Should -Be 4
            $result.Samples[0].Line | Should -Match 'n/a'
        }

        It 'calls a throwing sampler only once across many samples' {
            $script:C2RCalls = 0
            Mock Get-ODTC2RScenarioSnapshot { $script:C2RCalls++; throw 'boom' }
            $script:Fake = New-FakeProcess -WaitsBeforeExit 5
            Mock Start-Process { $script:Fake }
            Invoke-ODTSetup -SetupExePath 's.exe' -ConfigurationPath 'c.xml' -ProgressIntervalSeconds 30 | Out-Null
            $script:C2RCalls | Should -Be 1
        }

        It 'stops retaining samples past MaxRetainedSamples but keeps calling back' {
            $script:Fake = New-FakeProcess -WaitsBeforeExit 15
            Mock Start-Process { $script:Fake }
            $script:Captured = New-Object System.Collections.Generic.List[string]
            $result = Invoke-ODTSetup -SetupExePath 's.exe' -ConfigurationPath 'c.xml' `
                                      -ProgressIntervalSeconds 30 -MaxRetainedSamples 10 `
                                      -ProgressCallback { param($l, $s) $script:Captured.Add($l) }
            @($result.Samples).Count | Should -Be 10
            $script:Captured.Count   | Should -Be 15
        }

        It 'builds a phase summary from the samples it took' {
            $script:Calls = 0
            Mock Get-ODTC2RScenarioSnapshot {
                $script:Calls++
                $task = if ($script:Calls -le 2) { 'STREAM' } else { 'APPLYCONFIGURATION' }
                [pscustomobject]@{ Scenario = 'INSTALL'; Active = $task; Completed = 5; Total = 20; Version = '16.0.0.0' }
            }
            $script:Fake = New-FakeProcess -WaitsBeforeExit 4
            Mock Start-Process { $script:Fake }
            $result = Invoke-ODTSetup -SetupExePath 's.exe' -ConfigurationPath 'c.xml' -ProgressIntervalSeconds 30

            $tasks = @($result.PhaseSummary).Task
            $tasks | Should -Contain 'STREAM'
            $tasks | Should -Contain 'APPLYCONFIGURATION'
        }
    }

    Describe 'Invoke-ODTSetup timeout' {

        BeforeEach { Disable-RealSamplers }

        It 'reports the documented timeout result and kills the process' {
            $script:Fake = New-FakeProcess -NeverExits
            Mock Start-Process { $script:Fake }

            $result = Invoke-ODTSetup -SetupExePath 's.exe' -ConfigurationPath 'c.xml' `
                                      -TimeoutMinutes 1 -ProgressIntervalSeconds 0

            $result.ExitCode | Should -Be -1
            $result.Success  | Should -BeFalse
            $result.TimedOut | Should -BeTrue
            # docs/troubleshooting.md keys a section off this exact wording.
            $result.Message  | Should -Be 'Invoke-ODTSetup: setup.exe did not exit within 1 minutes and was terminated.'
            $script:Fake.KillCalls | Should -Be 1
        }

        It 'still returns a result when Kill itself throws' {
            $script:Fake = New-FakeProcess -NeverExits -KillThrows
            Mock Start-Process { $script:Fake }
            $result = Invoke-ODTSetup -SetupExePath 's.exe' -ConfigurationPath 'c.xml' `
                                      -TimeoutMinutes 1 -ProgressIntervalSeconds 0
            $result.ExitCode | Should -Be -1
            $result.TimedOut | Should -BeTrue
        }

        It 'accepts a 1-minute timeout so the path is testable' {
            (Get-Command Invoke-ODTSetup).Parameters['TimeoutMinutes'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] } |
                ForEach-Object { $_.MinRange | Should -Be 1 }
        }

        It 'times out from inside the sampling loop and keeps the samples taken so far' -Tag 'Slow' {
            # The parameter floor is 1 minute, so this costs a real minute.
            $script:Fake = New-FakeProcess -NeverExits -SleepPerWaitMs 0
            Mock Start-Process { $script:Fake }
            $result = Invoke-ODTSetup -SetupExePath 's.exe' -ConfigurationPath 'c.xml' `
                                      -TimeoutMinutes 1 -ProgressIntervalSeconds 30
            $result.TimedOut       | Should -BeTrue
            $result.ExitCode       | Should -Be -1
            $script:Fake.KillCalls | Should -Be 1
        }
    }
}
