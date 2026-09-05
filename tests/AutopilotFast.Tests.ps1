BeforeAll {
    $sharedPath = Join-Path $PSScriptRoot '..\..\IntuneShared\IntuneShared.psd1'
    if (Test-Path $sharedPath) {
        Import-Module (Resolve-Path $sharedPath) -Force
    } else {
        Import-Module IntuneShared -Force -ErrorAction SilentlyContinue
    }
    $modulePath = Resolve-Path (Join-Path $PSScriptRoot '..\AutopilotFast.psd1')
    Import-Module $modulePath -Force
}

Describe 'AutopilotFast Architecture Tests' {
    Context 'Module Exports' {
        It 'Exports all public cmdlets' {
            $cmds = @('Get-AutopilotHash', 'Export-AutopilotCsv', 'Connect-AutopilotGraph', 'Register-AutopilotDevice', 'Set-AutopilotGroupTag', 'Test-AutopilotReadiness')
            foreach ($c in $cmds) {
                Get-Command -Module AutopilotFast -Name $c | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context 'Honest Autopilot Harvester' {
        It 'Queries system hardware identity and reports honest MDM status' {
            $testHash = [Convert]::ToBase64String(([byte[]]@(0x30) + [byte[]]::new(1023)))
            $hashObj = Get-AutopilotHash -GroupTag "CI-Tag" -ManualHash $testHash
            $hashObj | Should -Not -BeNullOrEmpty
            $hashObj.SerialNumber | Should -Not -BeNullOrEmpty
            $hashObj.SmbiosUuid | Should -Not -BeNullOrEmpty
            $hashObj.WindowsProductID | Should -Not -BeNullOrEmpty
            $hashObj.GroupTag | Should -Be "CI-Tag"
            $hashObj.HardwareHashStatus | Should -Not -BeNullOrEmpty
        }

        It 'Generates standard Intune CSV formatting' {
            $testHash = [Convert]::ToBase64String(([byte[]]@(0x30) + [byte[]]::new(1023)))
            $hashObj = Get-AutopilotHash -GroupTag "TestGroup" -ManualHash $testHash
            $tempFile = Join-Path $TestDrive "autopilot-test.csv"
            $result = $hashObj | Export-AutopilotCsv -Path $tempFile
            
            Test-Path $tempFile | Should -Be $true
            $lines = Get-Content $tempFile
            $lines[0] | Should -Be 'Device Serial Number,Windows Product ID,Hardware Hash,Group Tag,Assigned User'
            $lines[1] | Should -Match 'TestGroup'
        }
    }
}
