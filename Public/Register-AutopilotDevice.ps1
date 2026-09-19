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
        [switch]$FallbackToUsb = $true
    )

    Write-Host "`n  [AutopilotFast] Direct Cloud Device Registration" -ForegroundColor Cyan
    Write-Host "  ------------------------------------------------" -ForegroundColor DarkGray

    Write-IntuneLog -Message "Starting Autopilot device registration" -Level Info -Component "AutopilotFast" -CustomData @{
        GroupTag     = $GroupTag
        AssignedUser = $AssignedUser
        WaitForSync  = [bool]$WaitForSync
    }

    # 1. Pre-Flight Staged Network Probe with HTTPS Clock Sync
    Write-Host "  [+] Executing 7-stage network & HTTPS time sync diagnostic..." -ForegroundColor Cyan
    $netCheck = Test-StagedNetwork -TimeoutSeconds 4

    if (-not $netCheck.IsFullyReady) {
        $failedStages = @($netCheck.Details | Where-Object { -not $_.Success })
        Write-Warning ("Network pre-flight failed (" + $netCheck.StagesPassed + "/" + $netCheck.TotalStages + " stages passed):")
        foreach ($st in $failedStages) {
            Write-Warning ("  - Stage " + $st.Stage + " (" + $st.Name + "): " + $st.Description)
        }

        if ($FallbackToUsb) {
            Write-Host "  [+] Checking for Offline Autopilot JSON and USB export..." -ForegroundColor Yellow
            
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
                        Write-Host "  [OK] Injected Offline Autopilot Profile: $destJson" -ForegroundColor Green
                        Write-IntuneLog -Message "Injected offline Autopilot JSON profile from USB" -Level Info -Component "AutopilotFast" -CustomData @{ Source = $candidateJson }
                        break
                    }
                }
            } catch { }

            Write-Host "  [+] Exporting hardware identity to USB..." -ForegroundColor Yellow
            return (Export-AutopilotCsv -AutoDetectUsb -GroupTag $GroupTag -AssignedUser $AssignedUser)
        } else {
            throw "Registration halted due to network diagnostic failures."
        }
    }

    # 2. Extract Hardware Hash (OA3 structural validation)
    Write-Host "  [+] Extracting Hardware Hash..." -ForegroundColor Cyan
    $deviceInfo = Get-AutopilotHash -GroupTag $GroupTag -AssignedUser $AssignedUser

    if (-not $deviceInfo.HardwareHash) {
        Write-Error ("Failed to extract hardware hash: " + $deviceInfo.HardwareHashStatus)
        if ($FallbackToUsb) {
            Write-Host "  [+] Saving available device identifiers to USB..." -ForegroundColor Yellow
            Export-AutopilotCsv -AutoDetectUsb -GroupTag $GroupTag -AssignedUser $AssignedUser | Out-Null
        }
        throw ("Hardware hash extraction failed: " + $deviceInfo.HardwareHashStatus)
    }

    $hashLen = $deviceInfo.HardwareHash.Length
    Write-Host ("  [OK] Hash extracted: Serial [" + $deviceInfo.SerialNumber + "] (" + $hashLen + " chars)") -ForegroundColor Green

    # 3. Ensure Authentication
    $token = $script:AutopilotAccessToken
    if (-not $token) {
        Write-Host "  [+] Authenticating to Microsoft Graph..." -ForegroundColor Cyan
        $token = Connect-AutopilotGraph
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

    Write-Host "  [+] Uploading hardware identity to Microsoft Intune..." -ForegroundColor Cyan
    $importId = $null
    try {
        $importResult = Invoke-ResilientGraphRest -Uri $uri -Method POST -Headers $authHeader -Body $payload
        $importId = $importResult.id
        Write-Host ("  [OK] Device uploaded successfully! (Import ID: " + $importId + ")") -ForegroundColor Green
        Write-IntuneLog -Message "Hardware hash uploaded to Graph" -Level Info -Component "AutopilotFast" -CustomData @{
            ImportId     = $importId
            SerialNumber = $deviceInfo.SerialNumber
        }
    }
    catch {
        Write-Error ("Failed to upload device to Microsoft Graph: " + $_.Exception.Message)
        if ($FallbackToUsb) {
            Write-Host "  [+] Saving backup to USB drive..." -ForegroundColor Yellow
            Export-AutopilotCsv -AutoDetectUsb -GroupTag $GroupTag -AssignedUser $AssignedUser | Out-Null
        }
        throw $_
    }

    # 5. Two-Stage Polling for Ingestion and Profile Assignment
    if ($WaitForSync -and $importId) {
        Write-Host "  [+] Stage 1/2: Polling Ingestion Queue for completion..." -ForegroundColor Cyan
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

                if ($state -eq 'complete') {
                    $importComplete = $true
                    Write-Host "  [OK] Stage 1/2 Complete: Hardware hash ingested into tenant!" -ForegroundColor Green
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
        Write-Host "  [+] Stage 2/2: Polling Entra ID Dynamic Group Profile Assignment..." -ForegroundColor Cyan
        $remainingMins = [Math]::Max(1, [int]($TimeoutMinutes - ([datetime]::UtcNow - $startTime).TotalMinutes))
        $syncResult = Sync-AutopilotProfile -SerialNumber $deviceInfo.SerialNumber -WaitForAssignment -TimeoutMinutes $remainingMins -Reboot:$Reboot
        return $syncResult
    }

    return $importResult
}
