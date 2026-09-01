<#
.SYNOPSIS
    Uploads device hardware hash directly to Microsoft Intune Autopilot via Graph API.
.DESCRIPTION
    Captures the local hardware hash and posts it directly to Microsoft Graph without manual CSV exports.
    Includes pre-flight captive portal detection, automatic fallback to offline USB capture if offline,
    and optional status polling until the device profile is assigned.
.PARAMETER GroupTag
    Autopilot GroupTag / OrderIdentifier (e.g. 'DEV-WORKSTATION', 'FINANCE-LAPTOP').
.PARAMETER AssignedUser
    UPN of the user to pre-assign to this device.
.PARAMETER WaitForSync
    Polls Microsoft Graph until the device import completes and the profile is assigned.
.PARAMETER TimeoutSeconds
    Timeout for -WaitForSync polling. Default: 300 seconds.
.PARAMETER FallbackToUsb
    Automatically export to USB if network or authentication fails.
.EXAMPLE
    Register-AutopilotDevice -GroupTag "DevOps-Laptops" -WaitForSync
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
        [int]$TimeoutSeconds = 300,

        [Parameter()]
        [switch]$FallbackToUsb = $true
    )

    Write-Host "`n  [AutopilotFast] Direct Cloud Device Registration" -ForegroundColor Cyan
    Write-Host "  ------------------------------------------------" -ForegroundColor DarkGray

    # 1. Pre-Flight Staged Network Probe
    Write-Host "  [+] Executing 7-stage network pre-flight diagnostic..." -ForegroundColor Cyan
    $netCheck = Test-StagedNetwork -TimeoutSeconds 4

    if (-not $netCheck.IsFullyReady) {
        $failedStages = @($netCheck.Details | Where-Object { -not $_.Success })
        Write-Warning ("Network pre-flight failed (" + $netCheck.StagesPassed + "/" + $netCheck.TotalStages + " stages passed):")
        foreach ($st in $failedStages) {
            Write-Warning ("  - Stage " + $st.Stage + " (" + $st.Name + "): " + $st.Description)
        }

        if ($FallbackToUsb) {
            Write-Host "  [+] Gracefully falling back to Offline USB Export..." -ForegroundColor Yellow
            return (Export-AutopilotCsv -AutoDetectUsb -GroupTag $GroupTag -AssignedUser $AssignedUser)
        } else {
            throw "Registration halted due to network diagnostic failures."
        }
    }

    # 2. Extract Hardware Hash
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
    Write-Host ("  [OK] Hash extracted: Serial [" + $deviceInfo.SerialNumber + "] (" + $hashLen + " bytes)") -ForegroundColor Green

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

    # 4. Upload Hardware Hash to Microsoft Graph
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
    try {
        $importResult = Invoke-ResilientGraphRest -Uri $uri -Method POST -Headers $authHeader -Body $payload
        $importId = $importResult.id
        Write-Host ("  [OK] Device uploaded successfully! (Import ID: " + $importId + ")") -ForegroundColor Green
    }
    catch {
        Write-Error ("Failed to upload device to Microsoft Graph: " + $_.Exception.Message)
        if ($FallbackToUsb) {
            Write-Host "  [+] Saving backup to USB drive..." -ForegroundColor Yellow
            Export-AutopilotCsv -AutoDetectUsb -GroupTag $GroupTag -AssignedUser $AssignedUser | Out-Null
        }
        throw $_
    }

    # 5. Wait for Sync / Profile Assignment if requested
    if ($WaitForSync -and $importId) {
        Write-Host "  [+] Waiting for Microsoft Intune Autopilot sync..." -NoNewline -ForegroundColor Cyan
        $checkUri = "https://graph.microsoft.com/beta/deviceManagement/importedWindowsAutopilotDeviceIdentities/$importId"
        $startTime = [datetime]::UtcNow

        while (([datetime]::UtcNow - $startTime).TotalSeconds -lt $TimeoutSeconds) {
            Start-Sleep -Seconds 10
            Write-Host "." -NoNewline -ForegroundColor Cyan

            try {
                $statusRes = Invoke-ResilientGraphRest -Uri $checkUri -Method GET -Headers $authHeader
                $state = $statusRes.state.deviceImportStatus

                if ($state -eq 'complete') {
                    Write-Host "`n  [OK] Device sync complete and assigned to Autopilot profile!" -ForegroundColor Green
                    return $statusRes
                }
                elseif ($state -eq 'error') {
                    Write-Host ("`n  [FAIL] Import error: " + $statusRes.state.deviceErrorCode + " - " + $statusRes.state.deviceErrorName) -ForegroundColor Red
                    return $statusRes
                }
            } catch { }
        }

        Write-Host "`n  [WARN] Polling timed out after $TimeoutSeconds seconds. Intune is still processing in background." -ForegroundColor Yellow
    }

    return $importResult
}
