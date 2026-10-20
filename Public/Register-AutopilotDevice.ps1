<#
.SYNOPSIS
    Uploads device hardware hash directly to Microsoft Intune Autopilot via Graph API with 2-stage verification.
.DESCRIPTION
    Captures the local hardware hash and posts it to Microsoft Graph. Features pre-flight network diagnostics,
    two-stage backoff polling (hash ingestion -> dynamic group profile assignment), and automatic USB/JSON fallback.
.PARAMETER GroupTag
    Autopilot GroupTag / OrderIdentifier (e.g. 'DEV-WORKSTATION', 'FINANCE-LAPTOP').
.PARAMETER AssignedUser
    UPN of the user to pre-assign to this device.
.PARAMETER WaitForSync
    Polls Microsoft Graph with jittered exponential backoff until the deployment profile is fully assigned.
.PARAMETER TimeoutMinutes
    Maximum wait time for -WaitForSync. Default: 45 minutes.
.PARAMETER Reboot
    Automatically reboots the machine upon verified profile assignment to trigger Autopilot OOBE.
.PARAMETER FallbackToUsb
    Automatically exports to USB and checks for offline Autopilot JSON profile if network fails.
.EXAMPLE
    Register-AutopilotDevice -GroupTag "DevOps-Laptops" -WaitForSync -Reboot
#>
function Register-AutopilotDevice {
    [CmdletBinding()]
    [Alias('Import-AutopilotDevice')]
    param(
        [Parameter(Position = 0)]
        [string]$GroupTag = '',

        [Parameter()]
        [string]$AssignedUser = '',

        [Parameter()]
        [switch]$WaitForSync,

        [Parameter()]
        [int]$TimeoutMinutes = 45,

        [Parameter()]
        [switch]$Reboot,

        [Parameter()]
        [switch]$FallbackToUsb = $true,

        [Parameter()]
        [switch]$CopyReceipt,

        [Parameter()]
        [switch]$CopyJson,

        [Parameter()]
        [switch]$CopyTsv,

        [Parameter()]
        [switch]$Quiet
    )

    if (-not $Quiet) {
        Write-Host "`n  [AutopilotFast] Direct Cloud Device Registration" -ForegroundColor Cyan
        Write-Host "  ------------------------------------------------" -ForegroundColor DarkGray
    }

    Write-IntuneLog -Message "Starting Autopilot device registration" -Level Info -Component "AutopilotFast" -CustomData @{
        GroupTag     = $GroupTag
        AssignedUser = $AssignedUser
        WaitForSync  = [bool]$WaitForSync
    }

    # 1. Pre-Flight Staged Network Probe with HTTPS Clock Sync
    if (-not $Quiet) {
        Write-Host "  [+] Executing 7-stage network & HTTPS time sync diagnostic..." -ForegroundColor Cyan
    }
    $netCheck = Test-StagedNetwork -TimeoutSeconds 4 -Quiet:$Quiet

    if (-not $netCheck.IsFullyReady) {
        $failedStages = @($netCheck.Details | Where-Object { -not $_.Success })
        Write-Warning ("Network pre-flight failed (" + $netCheck.StagesPassed + "/" + $netCheck.TotalStages + " stages passed):")
        foreach ($st in $failedStages) {
            Write-Warning ("  - Stage " + $st.Stage + " (" + $st.Name + "): " + $st.Description)
        }

        if ($FallbackToUsb) {
            if (-not $Quiet) {
                Write-Host "  [+] Checking for Offline Autopilot JSON and USB export..." -ForegroundColor Yellow
            }
            
            # Search USB for AutopilotConfigurationFile.json
            try {
                $usbDrives = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=2" -ErrorAction SilentlyContinue)
                $destDir = "C:\Windows\Provisioning\Autopilot"
                $destJson = Join-Path $destDir "AutopilotConfigurationFile.json"

                foreach ($drv in $usbDrives) {
                    $candidateJson = Join-Path $drv.DeviceID "AutopilotConfigurationFile.json"
                    if (Test-Path $candidateJson) {
                        if (-not (Test-Path $destDir)) { [System.IO.Directory]::CreateDirectory($destDir) | Out-Null }
                        Copy-Item -Path $candidateJson -Destination $destJson -Force
                        if (-not $Quiet) {
                            Write-Host "  [OK] Injected Offline Autopilot Profile: $destJson" -ForegroundColor Green
                        }
                        Write-IntuneLog -Message "Injected offline Autopilot JSON profile from USB" -Level Info -Component "AutopilotFast" -CustomData @{ Source = $candidateJson }
                        break
                    }
                }
            } catch { }

            if (-not $Quiet) {
                Write-Host "  [+] Exporting hardware identity to USB..." -ForegroundColor Yellow
            }
            return (Export-AutopilotCsv -AutoDetectUsb -GroupTag $GroupTag -AssignedUser $AssignedUser -Quiet:$Quiet)
        } else {
            throw "Registration halted due to network diagnostic failures."
        }
    }

    # 2. Extract Hardware Hash (OA3 structural validation)
    if (-not $Quiet) {
        Write-Host "  [+] Extracting Hardware Hash..." -ForegroundColor Cyan
    }
    $deviceInfo = Get-AutopilotHash -GroupTag $GroupTag -AssignedUser $AssignedUser -Quiet:$Quiet

    if (-not $deviceInfo.HardwareHash) {
        Write-Error ("Failed to extract hardware hash: " + $deviceInfo.HardwareHashStatus)
        if ($FallbackToUsb) {
            if (-not $Quiet) {
                Write-Host "  [+] Saving available device identifiers to USB..." -ForegroundColor Yellow
            }
            Export-AutopilotCsv -AutoDetectUsb -GroupTag $GroupTag -AssignedUser $AssignedUser -Quiet:$Quiet | Out-Null
        }
        throw ("Hardware hash extraction failed: " + $deviceInfo.HardwareHashStatus)
    }

    $hashLen = $deviceInfo.HardwareHash.Length
    if (-not $Quiet) {
        Write-Host ("  [OK] Hash extracted: Serial [" + $deviceInfo.SerialNumber + "] (" + $hashLen + " chars)") -ForegroundColor Green
    }

    # 3. Ensure Authentication
    $token = $script:AutopilotAccessToken
    if (-not $token) {
        if (-not $Quiet) {
            Write-Host "  [+] Authenticating to Microsoft Graph..." -ForegroundColor Cyan
        }
        $token = Connect-AutopilotGraph -Quiet:$Quiet
    }

    $authHeader = @{
        'Authorization' = "Bearer $token"
        'Content-Type'  = 'application/json'
    }

    # 4. Upload Hardware Hash to Microsoft Graph Ingestion Queue
    $uri = "https://graph.microsoft.com/beta/deviceManagement/importedWindowsAutopilotDeviceIdentities"
    $payload = @{
        groupTag           = $GroupTag
        serialNumber       = $deviceInfo.SerialNumber
        productKey         = $deviceInfo.WindowsProductID
        hardwareIdentifier = $deviceInfo.HardwareHash
    }

    if ($AssignedUser) {
        $payload['assignedUserPrincipalName'] = $AssignedUser
    }

    if (-not $Quiet) {
        Write-Host "  [+] Uploading hardware identity to Microsoft Intune..." -ForegroundColor Cyan
    }
    $importId = $null
    try {
        $importResult = Invoke-ResilientGraphRest -Uri $uri -Method POST -Headers $authHeader -Body $payload
        $importId = $importResult.id
        $uploadedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        if (-not $Quiet) {
            $gtDisplay = if ($GroupTag) { $GroupTag } else { '(None)' }
            $usrDisplay = if ($AssignedUser) { $AssignedUser } else { '(Unassigned)' }
            $syncDisplay = if ($WaitForSync) { "2-Stage Poll ($TimeoutMinutes min max)" } else { 'Async Queue Only' }
            Write-Host ("  [OK] Device uploaded successfully! (Import ID: " + $importId + ")") -ForegroundColor Green
            Write-Host ""
            Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkCyan
            Write-Host "  | AUTOPILOT CLOUD REGISTRATION RECEIPT                    [UPLOADED]   |" -ForegroundColor Cyan
            Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkCyan
            Write-Host ("  | Serial Number : {0,-52} |" -f $deviceInfo.SerialNumber) -ForegroundColor White
            Write-Host ("  | Import ID     : {0,-52} |" -f $importId) -ForegroundColor Gray
            Write-Host ("  | Group Tag     : {0,-52} |" -f $gtDisplay) -ForegroundColor Cyan
            Write-Host ("  | Assigned User : {0,-52} |" -f $usrDisplay) -ForegroundColor Gray
            Write-Host ("  | OA3 Payload   : {0,-52} |" -f "$hashLen Base64 chars (OA3 Verified)") -ForegroundColor Green
            Write-Host ("  | Sync Mode     : {0,-52} |" -f $syncDisplay) -ForegroundColor Gray
            Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkCyan
            Write-Host ""
        }
        if ($CopyReceipt) {
            try {
                $mdReceipt = @(
                    "### Autopilot Cloud Registration Receipt",
                    "| Field | Value |",
                    "| :--- | :--- |",
                    "| **Serial Number** | ``$($deviceInfo.SerialNumber)`` |",
                    "| **Import Queue ID** | ``$importId`` |",
                    "| **Group Tag** | ``$(if ($GroupTag) { $GroupTag } else { '(None)' })`` |",
                    "| **Assigned User** | ``$(if ($AssignedUser) { $AssignedUser } else { '(Unassigned)' })`` |",
                    "| **OA3 Hash Length** | $hashLen chars |",
                    "| **Uploaded At (UTC)** | $uploadedAtUtc |"
                ) -join "`r`n"
                Set-Clipboard -Value $mdReceipt -ErrorAction Stop
                if (-not $Quiet) {
                    Write-Host "  [CLIPBOARD] Copied Markdown Cloud Registration Receipt to clipboard." -ForegroundColor Green
                }
            } catch { }
        }
        if ($CopyJson) {
            try {
                $jsonReceipt = [PSCustomObject]@{
                    SerialNumber  = $deviceInfo.SerialNumber
                    ImportQueueId = $importId
                    GroupTag      = if ($GroupTag) { $GroupTag } else { '(None)' }
                    AssignedUser  = if ($AssignedUser) { $AssignedUser } else { '(Unassigned)' }
                    Oa3HashLength = $hashLen
                    UploadedAtUtc = $uploadedAtUtc
                } | ConvertTo-Json -Depth 4
                Set-Clipboard -Value $jsonReceipt -ErrorAction Stop
                if (-not $Quiet) {
                    Write-Host "  [CLIPBOARD] Copied JSON Cloud Registration Receipt to clipboard." -ForegroundColor Green
                }
            } catch { }
        }
        if ($CopyTsv) {
            try {
                $tsvReceipt = @(
                    "SerialNumber`tImportQueueId`tGroupTag`tAssignedUser`tOa3HashLength`tUploadedAtUtc",
                    "$($deviceInfo.SerialNumber)`t$importId`t$(if ($GroupTag) { $GroupTag } else { '(None)' })`t$(if ($AssignedUser) { $AssignedUser } else { '(Unassigned)' })`t$hashLen`t$uploadedAtUtc"
                ) -join "`r`n"
                Set-Clipboard -Value $tsvReceipt -ErrorAction Stop
                if (-not $Quiet) {
                    Write-Host "  [CLIPBOARD] Copied TSV Cloud Registration Receipt to clipboard." -ForegroundColor Green
                }
            } catch { }
        }
        Write-IntuneLog -Message "Hardware hash uploaded to Graph" -Level Info -Component "AutopilotFast" -CustomData @{
            ImportId     = $importId
            SerialNumber = $deviceInfo.SerialNumber
        }
    }
    catch {
        Write-Error ("Failed to upload device to Microsoft Graph: " + $_.Exception.Message)
        if ($FallbackToUsb) {
            if (-not $Quiet) {
                Write-Host "  [+] Saving backup to USB drive..." -ForegroundColor Yellow
            }
            Export-AutopilotCsv -AutoDetectUsb -GroupTag $GroupTag -AssignedUser $AssignedUser -Quiet:$Quiet | Out-Null
        }
        throw $_
    }

    # 5. Two-Stage Polling for Ingestion and Profile Assignment
    if ($WaitForSync -and $importId) {
        Write-Host "`n  [#####-----] 50% | Stage 1/2: Polling Intune Ingestion Queue..." -ForegroundColor Cyan
        $checkUri = "https://graph.microsoft.com/beta/deviceManagement/importedWindowsAutopilotDeviceIdentities/$importId"
        $startTime = [datetime]::UtcNow
        $currentInterval = 5
        $importComplete = $false

        while (([datetime]::UtcNow - $startTime).TotalMinutes -lt $TimeoutMinutes) {
            $jitter = (Get-Random -Minimum 0 -Maximum 1000) / 1000.0
            $sleepSec = [Math]::Min(60, [int][Math]::Ceiling($currentInterval + $jitter))
            Start-Sleep -Seconds $sleepSec
            $currentInterval = [Math]::Min(60, [int][Math]::Ceiling($currentInterval * 1.5))

            try {
                $statusRes = Invoke-ResilientGraphRest -Uri $checkUri -Method GET -Headers $authHeader
                $state = $statusRes.state.deviceImportStatus
                $elapsedSec = [int]([datetime]::UtcNow - $startTime).TotalSeconds

                if ($state -eq 'complete') {
                    $importComplete = $true
                    Write-Host "  [##########] 100% Stage 1/2 Complete: Hardware hash ingested into tenant (${elapsedSec}s)!" -ForegroundColor Green
                    break
                }
                elseif ($state -eq 'error') {
                    $errCode = $statusRes.state.deviceErrorCode
                    $errName = $statusRes.state.deviceErrorName
                    Write-Host ("`n  [FAIL] Ingestion error: $errCode - $errName") -ForegroundColor Red
                    Write-IntuneLog -Message "Hardware hash ingestion error: $errCode - $errName" -Level Error -Component "AutopilotFast"
                    return $statusRes
                }
            } catch { }
        }

        if (-not $importComplete) {
            Write-Warning "Ingestion queue polling timed out."
            return $importResult
        }

        # Stage 2: Profile Assignment Polling
        Write-Host "  [########--] 80% | Stage 2/2: Polling Entra ID Dynamic Group Profile Assignment..." -ForegroundColor Cyan
        $remainingMins = [Math]::Max(1, [int]($TimeoutMinutes - ([datetime]::UtcNow - $startTime).TotalMinutes))
        $syncResult = Sync-AutopilotProfile -SerialNumber $deviceInfo.SerialNumber -WaitForAssignment -TimeoutMinutes $remainingMins -Reboot:$Reboot
        return $syncResult
    }

    return $importResult
}
