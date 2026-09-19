BeforeAll {
    # Sibling checkout when developing locally; installed module in per-repo CI
    $sharedPath = Join-Path $PSScriptRoot '..\..\IntuneShared\IntuneShared.psd1'
    if (Test-Path $sharedPath) {
        Import-Module (Resolve-Path $sharedPath) -Force
    } else {
        Import-Module IntuneShared -Force -ErrorAction Stop
    }
    $modulePath = Resolve-Path (Join-Path $PSScriptRoot '..\AutopilotFast.psd1')
    Import-Module $modulePath -Force
    $mockPath = Resolve-Path (Join-Path $PSScriptRoot 'AutopilotFast.Mock.psm1')
    Import-Module $mockPath -Force
}

Describe 'AutopilotFast Architecture & Governance' {
    AfterEach { Clear-AutopilotMockHardwareHash }

    Context 'Module Exports & Types' {
        It 'Exports all public cmdlets including Sync-AutopilotProfile' {
            $expectedCmds = @(
                'Get-AutopilotHash',
                'Export-AutopilotCsv',
                'Connect-AutopilotGraph',
                'Register-AutopilotDevice',
                'Sync-AutopilotProfile',
                'Set-AutopilotGroupTag',
                'Test-AutopilotReadiness'
            )
            foreach ($cmd in $expectedCmds) {
                $c = Get-Command -Module AutopilotFast -Name $cmd -ErrorAction SilentlyContinue
                $c | Should -Not -BeNullOrEmpty
            }
        }

        It 'Exports alias Import-AutopilotDevice' {
            $alias = Get-Alias -Name 'Import-AutopilotDevice' -ErrorAction SilentlyContinue
            $alias | Should -Not -BeNullOrEmpty
            $alias.Definition | Should -Be 'Register-AutopilotDevice'
        }

        It 'Loads [AutopilotHashParseException] custom exception type' {
            ('AutopilotHashParseException' -as [type]) | Should -Not -BeNullOrEmpty
            $ex = [AutopilotHashParseException]::new("Test parse failure", "TestCode", 100, 2048, [byte]0x02)
            $ex.Message | Should -Be "Test parse failure"
            $ex.ErrorCode | Should -Be "TestCode"
            $ex.ActualLength | Should -Be 100
            $ex.ExpectedLength | Should -Be 2048
            $ex.HeaderByte | Should -Be 0x02
        }

        It 'Does not expose -ManualHash on production Get-AutopilotHash' {
            $params = (Get-Command Get-AutopilotHash).Parameters
            $params.ContainsKey('ManualHash') | Should -Be $false
        }
    }
}

Describe 'AutopilotFast Mock Lifecycle' {
    AfterEach { Clear-AutopilotMockHardwareHash }

    Context 'Mock State Management' {
        It 'Sets and retrieves mock hardware hash via script/global/env' {
            $testHash = New-AutopilotSyntheticHardwareHash -LengthBytes 4096
            Set-AutopilotMockHardwareHash -Hash $testHash
            (Get-AutopilotMockHardwareHash) | Should -Be $testHash

            $res = Get-AutopilotHash
            $res.HardwareHash | Should -Be $testHash
            $res.HardwareHashStatus | Should -Be 'Captured'
        }

        It 'Clears mock hardware hash cleanly' {
            $testHash = New-AutopilotSyntheticHardwareHash -LengthBytes 4096
            Set-AutopilotMockHardwareHash -Hash $testHash
            Clear-AutopilotMockHardwareHash

            (Get-AutopilotMockHardwareHash) | Should -BeNullOrEmpty
            $env:AUTOPILOT_MOCK_HARDWARE_HASH | Should -BeNullOrEmpty
            $global:__AutopilotMockHardwareHash | Should -BeNullOrEmpty
        }
    }
}

Describe 'OA3 Hardware Hash Validator Valid Vectors' {
    AfterEach { Clear-AutopilotMockHardwareHash }

    Context 'Valid Length Bounds' {
        It 'Successfully parses minimum bound 2048-byte DER sequence' {
            $valid2k = New-AutopilotSyntheticHardwareHash -LengthBytes 2048
            Set-AutopilotMockHardwareHash -Hash $valid2k

            $res = Get-AutopilotHash -Format Object
            $res.HardwareHash | Should -Be $valid2k
            $res.HardwareHashStatus | Should -Be 'Captured'
            $res.HashLengthBytes | Should -Be $valid2k.Length
        }

        It 'Successfully parses standard 4096-byte (4K) DER sequence' {
            $valid4k = New-AutopilotSyntheticHardwareHash -LengthBytes 4096
            Set-AutopilotMockHardwareHash -Hash $valid4k

            $res = Get-AutopilotHash -GroupTag 'Finance-Laptops' -AssignedUser 'alice@contoso.com'
            $res.HardwareHash | Should -Be $valid4k
            $res.GroupTag | Should -Be 'Finance-Laptops'
            $res.AssignedUser | Should -Be 'alice@contoso.com'
        }

        It 'Successfully parses standard 8192-byte (8K) DER sequence' {
            $valid8k = New-AutopilotSyntheticHardwareHash -LengthBytes 8192
            Set-AutopilotMockHardwareHash -Hash $valid8k

            $res = Get-AutopilotHash
            $res.HardwareHash | Should -Be $valid8k
        }

        It 'Successfully parses maximum bound 16384-byte DER sequence' {
            $valid16k = New-AutopilotSyntheticHardwareHash -LengthBytes 16384
            Set-AutopilotMockHardwareHash -Hash $valid16k

            $res = Get-AutopilotHash
            $res.HardwareHash | Should -Be $valid16k
            $res.HardwareHashStatus | Should -Be 'Captured'
            $res.HashLengthBytes | Should -Be $valid16k.Length
        }

        It 'Outputs valid CSV format with captured hash' {
            $valid4k = New-AutopilotSyntheticHardwareHash -LengthBytes 4096
            Set-AutopilotMockHardwareHash -Hash $valid4k

            $csv = Get-AutopilotHash -Format Csv -GroupTag 'Dev-Tag' -AssignedUser 'bob@contoso.com'
            $csv | Should -Match 'Dev-Tag'
            $csv | Should -Match 'bob@contoso.com'
            $csv.Contains($valid4k) | Should -BeTrue
        }

        It 'Outputs valid JSON format with captured hash' {
            $valid4k = New-AutopilotSyntheticHardwareHash -LengthBytes 4096
            Set-AutopilotMockHardwareHash -Hash $valid4k

            $jsonStr = Get-AutopilotHash -Format Json
            $parsed = $jsonStr | ConvertFrom-Json
            $parsed.HardwareHash | Should -Be $valid4k
            $parsed.HardwareHashStatus | Should -Be 'Captured'
        }
    }
}

Describe 'OA3 Hardware Hash Validator Rejection & Negative Vectors' {
    AfterEach { Clear-AutopilotMockHardwareHash }

    Context 'Boundary Violations (below 2048 or above 16384 bytes)' {
        It 'Rejects 2047-byte payload (1 byte below minimum bound)' {
            $smallHash = New-AutopilotSyntheticHardwareHash -LengthBytes 2047
            Set-AutopilotMockHardwareHash -Hash $smallHash

            { Get-AutopilotHash } | Should -Throw -ExceptionType ([AutopilotHashParseException])
        }

        It 'Rejects 1024-byte payload' {
            $hash1k = New-AutopilotSyntheticHardwareHash -LengthBytes 1024
            Set-AutopilotMockHardwareHash -Hash $hash1k

            { Get-AutopilotHash } | Should -Throw -ExceptionType ([AutopilotHashParseException])
        }

        It 'Rejects 16385-byte payload (1 byte above maximum bound)' {
            $largeHash = New-AutopilotSyntheticHardwareHash -LengthBytes 16385
            Set-AutopilotMockHardwareHash -Hash $largeHash

            { Get-AutopilotHash } | Should -Throw -ExceptionType ([AutopilotHashParseException])
        }

        It 'Rejects 20000-byte payload' {
            $hugeHash = New-AutopilotSyntheticHardwareHash -LengthBytes 20000
            Set-AutopilotMockHardwareHash -Hash $hugeHash

            { Get-AutopilotHash } | Should -Throw -ExceptionType ([AutopilotHashParseException])
        }
    }

    Context 'Invalid OA3 Magic Header' {
        It 'Rejects an ASN.1-looking blob (first byte 0x30) - real OA3 hashes start with 4F 41 33 00' {
            $asn1Looking = New-AutopilotSyntheticHardwareHash -LengthBytes 4096 -HeaderByte 0x30
            Set-AutopilotMockHardwareHash -Hash $asn1Looking

            $ex = $null
            try { Get-AutopilotHash } catch [AutopilotHashParseException] { $ex = $_.Exception }
            $ex | Should -Not -BeNullOrEmpty
            $ex.ErrorCode | Should -Be 'InvalidOA3Magic'
            $ex.HeaderByte | Should -Be 0x30
        }

        It 'Rejects header byte 0x01' {
            $badTag01 = New-AutopilotSyntheticHardwareHash -LengthBytes 4096 -HeaderByte 0x01
            Set-AutopilotMockHardwareHash -Hash $badTag01

            { Get-AutopilotHash } | Should -Throw -ExceptionType ([AutopilotHashParseException])
        }

        It 'Rejects header byte 0xFF' {
            $badTagFF = New-AutopilotSyntheticHardwareHash -LengthBytes 4096 -HeaderByte 0xFF
            Set-AutopilotMockHardwareHash -Hash $badTagFF

            { Get-AutopilotHash } | Should -Throw -ExceptionType ([AutopilotHashParseException])
        }

        It 'Rejects a blob whose entire magic is wrong' {
            $badMagic = New-AutopilotSyntheticHardwareHash -LengthBytes 4096 -Variant 'BadMagic'
            Set-AutopilotMockHardwareHash -Hash $badMagic

            { Get-AutopilotHash } | Should -Throw -ExceptionType ([AutopilotHashParseException])
        }

        It 'Produces the canonical real-world Base64 prefix T0EzAAEA and passes validation' {
            $valid = New-AutopilotSyntheticHardwareHash -LengthBytes 4096
            $valid.Substring(0, 8) | Should -Be 'T0EzAAEA'
            Set-AutopilotMockHardwareHash -Hash $valid
            (Get-AutopilotHash).HardwareHash | Should -Be $valid
        }
    }

    Context 'Stream Truncation' {
        It 'Rejects a 3-byte stream shorter than the OA3 magic' {
            $truncated = New-AutopilotSyntheticHardwareHash -Variant 'TruncatedHeader'
            Set-AutopilotMockHardwareHash -Hash $truncated

            $ex = $null
            try { Get-AutopilotHash } catch [AutopilotHashParseException] { $ex = $_.Exception }
            $ex | Should -Not -BeNullOrEmpty
            $ex.ErrorCode | Should -Be 'TruncatedHeader'
        }
    }

    Context 'Invalid Strings & Base64 Errors' {
        It 'Rejects non-Base64 string characters' {
            Set-AutopilotMockHardwareHash -Hash 'This is definitely not valid base64!@#$%^&*()'

            { Get-AutopilotHash } | Should -Throw -ExceptionType ([AutopilotHashParseException])
        }

        It 'Rejects Base64 string with invalid padding length' {
            Set-AutopilotMockHardwareHash -Hash 'ABCD==='

            { Get-AutopilotHash } | Should -Throw -ExceptionType ([AutopilotHashParseException])
        }

        It 'Rejects empty or whitespace string' {
            Set-AutopilotMockHardwareHash -Hash '   '

            { Get-AutopilotHash } | Should -Throw -ExceptionType ([AutopilotHashParseException])

            $ex = $null
            try {
                Get-AutopilotHash
            } catch [AutopilotHashParseException] {
                $ex = $_.Exception
            }
            $ex | Should -Not -BeNullOrEmpty
            $ex.ErrorCode | Should -Be 'EmptyPayload'
        }
    }
}

Describe 'Sync-AutopilotProfile Cmdlet' {
    AfterEach { Clear-AutopilotMockHardwareHash }
    BeforeEach {
        # Never let unit tests reach login.microsoftonline.com
        Mock Connect-AutopilotGraph { return 'mock_token' } -ModuleName AutopilotFast
    }

    Context 'Parameter & Trigger Mechanics' {
        It 'Accepts SerialNumber parameter set' {
            $cmd = Get-Command Sync-AutopilotProfile
            $cmd.ParameterSets.Name | Should -Contain 'DeviceBySerial'
            $cmd.Parameters['SerialNumber'].ParameterSets['DeviceBySerial'].IsMandatory | Should -Be $true
        }

        It 'Accepts DeviceId parameter set' {
            $cmd = Get-Command Sync-AutopilotProfile
            $cmd.ParameterSets.Name | Should -Contain 'DeviceById'
            $cmd.Parameters['DeviceId'].ParameterSets['DeviceById'].IsMandatory | Should -Be $true
        }

        It 'Returns immediate sync triggered object when WaitForAssignment is not set' {
            Mock Invoke-ResilientGraphRest { return @{} } -ModuleName AutopilotFast

            $res = Sync-AutopilotProfile -SerialNumber 'PF-TEST-123' -TriggerTenantSync
            $res.TriggeredSync | Should -Be $true
            $res.Status | Should -Be 'SyncTriggered'
        }

        It 'Polls and detects assigned deployment profile' {
            $mockDevice = [PSCustomObject]@{
                id                                        = 'dev-guid-123'
                serialNumber                              = 'PF-TEST-123'
                groupTag                                  = 'DevOps'
                deploymentProfileAssignmentStatus         = 'assigned'
                deploymentProfileAssignmentDetailedStatus = 'none'
                deploymentProfileAssignedDateTime         = '2026-09-01T12:00:00Z'
                assignedDeploymentProfile                 = [PSCustomObject]@{
                    displayName = 'Standard Kiosk Profile'
                }
            }

            Mock Invoke-ResilientGraphRest {
                param($Uri)
                if ($Uri -match 'windowsAutopilotSettings/sync') { return @{} }
                return [PSCustomObject]@{ value = @($mockDevice) }
            } -ModuleName AutopilotFast

            $res = Sync-AutopilotProfile -SerialNumber 'PF-TEST-123' -WaitForAssignment -InitialIntervalSeconds 0 -TimeoutMinutes 1
            $res.IsAssigned | Should -Be $true
            $res.AssignedProfileName | Should -Be 'Standard Kiosk Profile'
            $res.DeploymentProfileAssignmentStatus | Should -Be 'assigned'
        }

        It 'Reports failure when deployment profile assignment fails' {
            $mockFailedDevice = [PSCustomObject]@{
                id                                        = 'dev-guid-123'
                serialNumber                              = 'PF-TEST-123'
                groupTag                                  = 'DevOps'
                deploymentProfileAssignmentStatus         = 'failed'
                deploymentProfileAssignmentDetailedStatus = 'ZtdDeviceProfileAssignmentConflict'
                assignedDeploymentProfile                 = $null
            }

            Mock Invoke-ResilientGraphRest {
                param($Uri)
                if ($Uri -match 'windowsAutopilotSettings/sync') { return @{} }
                return [PSCustomObject]@{ value = @($mockFailedDevice) }
            } -ModuleName AutopilotFast

            $res = Sync-AutopilotProfile -SerialNumber 'PF-TEST-123' -WaitForAssignment -InitialIntervalSeconds 0 -TimeoutMinutes 1
            $res.IsAssigned | Should -Be $false
            $res.DeploymentProfileAssignmentStatus | Should -Be 'failed'
            $res.DeploymentProfileAssignmentDetailedStatus | Should -Be 'ZtdDeviceProfileAssignmentConflict'
        }

        It 'Handles timeout exhaustion when profile assignment does not complete within TimeoutMinutes' {
            $mockPendingDevice = [PSCustomObject]@{
                id                                        = 'dev-guid-123'
                serialNumber                              = 'PF-TIMEOUT-123'
                groupTag                                  = 'DevOps'
                deploymentProfileAssignmentStatus         = 'pending'
                deploymentProfileAssignmentDetailedStatus = 'none'
                assignedDeploymentProfile                 = $null
            }

            Mock Invoke-ResilientGraphRest {
                param($Uri)
                if ($Uri -match 'windowsAutopilotSettings/sync') { return @{} }
                return [PSCustomObject]@{ value = @($mockPendingDevice) }
            } -ModuleName AutopilotFast

            $res = Sync-AutopilotProfile -SerialNumber 'PF-TIMEOUT-123' -WaitForAssignment -InitialIntervalSeconds 0 -TimeoutMinutes 0
            $res.IsAssigned | Should -Be $false
            $res.DeploymentProfileAssignmentDetailedStatus | Should -Be 'TimedOut'
        }

        It 'Recovers from transient Graph API error during polling and succeeds on retry' {
            $mockDevice = [PSCustomObject]@{
                id                                        = 'dev-guid-123'
                serialNumber                              = 'PF-RETRY-123'
                groupTag                                  = 'DevOps'
                deploymentProfileAssignmentStatus         = 'assigned'
                deploymentProfileAssignmentDetailedStatus = 'none'
                deploymentProfileAssignedDateTime         = '2026-09-01T12:00:00Z'
                assignedDeploymentProfile                 = [PSCustomObject]@{
                    displayName = 'Standard Kiosk Profile'
                }
            }

            $script:graphCallCount = 0
            Mock Invoke-ResilientGraphRest {
                param($Uri)
                if ($Uri -match 'windowsAutopilotSettings/sync') { return @{} }
                $script:graphCallCount++
                if ($script:graphCallCount -eq 1) {
                    throw [System.Net.WebException]::new("Transient 503 Service Unavailable")
                }
                return [PSCustomObject]@{ value = @($mockDevice) }
            } -ModuleName AutopilotFast

            $res = Sync-AutopilotProfile -SerialNumber 'PF-RETRY-123' -WaitForAssignment -InitialIntervalSeconds 0 -TimeoutMinutes 1
            $res.IsAssigned | Should -Be $true
            $res.AssignedProfileName | Should -Be 'Standard Kiosk Profile'
            $res.DeploymentProfileAssignmentStatus | Should -Be 'assigned'
        }
    }
}

Describe 'Register-AutopilotDevice 2-Stage Polling & Offline Fallback' {
    AfterEach { Clear-AutopilotMockHardwareHash }

    Context 'Offline Fallback Handling' {
        It 'Gracefully falls back to USB export when network diagnostics fail' {
            Mock Test-StagedNetwork {
                return [PSCustomObject]@{
                    IsFullyReady = $false
                    StagesPassed = 2
                    TotalStages  = 7
                    Details      = @(
                        [PSCustomObject]@{ Stage = 1; Name = 'DNS'; Success = $true; Description = 'OK' },
                        [PSCustomObject]@{ Stage = 2; Name = 'CaptivePortal'; Success = $false; Description = 'Blocked' }
                    )
                }
            } -ModuleName AutopilotFast

            $tempDir = Join-Path $TestDrive "UsbFallback"
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            $tempCsv = Join-Path $tempDir "Autopilot.csv"

            Mock Export-AutopilotCsv {
                param($Path, $GroupTag, $AssignedUser)
                return [PSCustomObject]@{
                    Path = $tempCsv
                    Status = 'Exported'
                }
            } -ModuleName AutopilotFast

            $res = Register-AutopilotDevice -GroupTag 'OfflineTag' -FallbackToUsb
            $res | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Two-Stage Verification' {
        It 'Completes stage 1 ingestion and transitions to stage 2 profile sync' {
            $valid4k = New-AutopilotSyntheticHardwareHash -LengthBytes 4096
            Set-AutopilotMockHardwareHash -Hash $valid4k

            Mock Test-StagedNetwork {
                return [PSCustomObject]@{
                    IsFullyReady = $true
                    StagesPassed = 7
                    TotalStages  = 7
                    Details      = @()
                }
            } -ModuleName AutopilotFast

            Mock Connect-AutopilotGraph { return "mock_token" } -ModuleName AutopilotFast

            Mock Invoke-ResilientGraphRest {
                param($Uri, $Method, $Body)
                if ($Method -eq 'POST' -and $Uri -match 'importedWindowsAutopilotDeviceIdentities') {
                    return [PSCustomObject]@{ id = 'import-job-999' }
                }
                if ($Method -eq 'GET' -and $Uri -match 'importedWindowsAutopilotDeviceIdentities/import-job-999') {
                    return [PSCustomObject]@{
                        id = 'import-job-999'
                        state = [PSCustomObject]@{
                            deviceImportStatus = 'complete'
                            deviceErrorCode    = 0
                            deviceErrorName    = 'none'
                        }
                    }
                }
                return @{}
            } -ModuleName AutopilotFast

            Mock Sync-AutopilotProfile {
                param($SerialNumber, $WaitForAssignment, $TimeoutMinutes, $Reboot)
                return [PSCustomObject]@{
                    IsAssigned                        = $true
                    SerialNumber                      = $SerialNumber
                    DeploymentProfileAssignmentStatus = 'assigned'
                    AssignedProfileName               = 'Verified Corporate Profile'
                }
            } -ModuleName AutopilotFast

            $res = Register-AutopilotDevice -GroupTag '2Stage-Tag' -WaitForSync -TimeoutMinutes 5
            $res.IsAssigned | Should -Be $true
            $res.AssignedProfileName | Should -Be 'Verified Corporate Profile'
        }

        It 'Handles stage 1 ingestion error gracefully and returns error response' {
            $valid4k = New-AutopilotSyntheticHardwareHash -LengthBytes 4096
            Set-AutopilotMockHardwareHash -Hash $valid4k

            Mock Test-StagedNetwork {
                return [PSCustomObject]@{
                    IsFullyReady = $true
                    StagesPassed = 7
                    TotalStages  = 7
                    Details      = @()
                }
            } -ModuleName AutopilotFast

            Mock Connect-AutopilotGraph { return "mock_token" } -ModuleName AutopilotFast

            Mock Invoke-ResilientGraphRest {
                param($Uri, $Method, $Body)
                if ($Method -eq 'POST' -and $Uri -match 'importedWindowsAutopilotDeviceIdentities') {
                    return [PSCustomObject]@{ id = 'import-job-err-999' }
                }
                if ($Method -eq 'GET' -and $Uri -match 'importedWindowsAutopilotDeviceIdentities/import-job-err-999') {
                    return [PSCustomObject]@{
                        id = 'import-job-err-999'
                        state = [PSCustomObject]@{
                            deviceImportStatus = 'error'
                            deviceErrorCode    = 800
                            deviceErrorName    = 'DeviceAlreadyAssignedToOtherTenant'
                        }
                    }
                }
                return @{}
            } -ModuleName AutopilotFast

            $res = Register-AutopilotDevice -GroupTag '2Stage-Err-Tag' -WaitForSync -TimeoutMinutes 5
            $res | Should -Not -BeNullOrEmpty
            $res.state.deviceImportStatus | Should -Be 'error'
            $res.state.deviceErrorCode | Should -Be 800
            $res.state.deviceErrorName | Should -Be 'DeviceAlreadyAssignedToOtherTenant'
        }
    }
}

Describe 'Export-AutopilotCsv Format & Structure' {
    AfterEach { Clear-AutopilotMockHardwareHash }

    Context 'CSV Generation' {
        It 'Generates standard 5-column Autopilot CSV' {
            $valid4k = New-AutopilotSyntheticHardwareHash -LengthBytes 4096
            Set-AutopilotMockHardwareHash -Hash $valid4k

            $tempCsv = Join-Path $TestDrive "export-test.csv"
            $result = Export-AutopilotCsv -Path $tempCsv -GroupTag "Batch-2026" -AssignedUser "user@test.org"

            Test-Path $tempCsv | Should -Be $true
            $lines = Get-Content $tempCsv
            $lines[0] | Should -Be 'Device Serial Number,Windows Product ID,Hardware Hash,Group Tag,Assigned User'
            $lines[1] | Should -Match 'Batch-2026'
            $lines[1] | Should -Match 'user@test.org'
        }
    }
}
