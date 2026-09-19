<#
.SYNOPSIS
    Synchronizes Autopilot profiles and polls until a device is assigned an Autopilot deployment profile.
.DESCRIPTION
    Triggers tenant-wide Autopilot profile synchronization via Microsoft Graph and executes a resilient,
    jittered exponential backoff polling loop against /beta/deviceManagement/windowsAutopilotDeviceIdentities
    until deploymentProfileAssignmentStatus transitions to 'assigned'.
.PARAMETER SerialNumber
    Device serial number to poll for profile assignment.
.PARAMETER DeviceId
    Graph device identity GUID (windowsAutopilotDeviceIdentity ID).
.PARAMETER WaitForAssignment
    Polls Microsoft Graph until the deployment profile is assigned or timeout is reached.
.PARAMETER TimeoutMinutes
    Maximum duration in minutes to wait for profile assignment. Default: 45 minutes.
.PARAMETER InitialIntervalSeconds
    Initial polling delay in seconds. Default: 5 seconds.
.PARAMETER MaxIntervalSeconds
    Maximum polling delay cap in seconds. Default: 60 seconds.
.PARAMETER BackoffMultiplier
    Exponential growth factor per polling iteration. Default: 1.5.
.PARAMETER TriggerTenantSync
    Whether to invoke POST /deviceManagement/windowsAutopilotSettings/sync prior to polling. Default: $true.
.PARAMETER Reboot
    Reboots the computer automatically once the deployment profile is assigned.
.EXAMPLE
    Sync-AutopilotProfile -SerialNumber "PF123456" -WaitForAssignment -Reboot
#>
function Sync-AutopilotProfile {
    [CmdletBinding(DefaultParameterSetName = 'DeviceBySerial')]
    param(
        [Parameter(ParameterSetName = 'DeviceBySerial', Position = 0, Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [string]$SerialNumber,

        [Parameter(ParameterSetName = 'DeviceById', Mandatory = $true)]
        [string]$DeviceId,

        [Parameter(ParameterSetName = 'DeviceBySerial')]
        [Parameter(ParameterSetName = 'DeviceById')]
        [switch]$WaitForAssignment,

        [Parameter()]
        [int]$TimeoutMinutes = 45,

        [Parameter()]
        [int]$InitialIntervalSeconds = 5,

        [Parameter()]
        [int]$MaxIntervalSeconds = 60,

        [Parameter()]
        [double]$BackoffMultiplier = 1.5,

        [Parameter()]
        [switch]$TriggerTenantSync = $true,

        [Parameter()]
        [switch]$Reboot
    )

    # 1. Ensure Authentication
    $token = $script:AutopilotAccessToken
    if (-not $token) {
        $token = Connect-AutopilotGraph
    }

    $authHeader = @{
        'Authorization' = "Bearer $token"
        'Content-Type'  = 'application/json'
    }

    # 2. Trigger Tenant Autopilot Sync
    if ($TriggerTenantSync) {
        Write-Host "  [+] Triggering Intune Autopilot tenant synchronization..." -ForegroundColor Cyan
        try {
            $syncUri = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotSettings/sync"
            Invoke-ResilientGraphRest -Uri $syncUri -Method POST -Headers $authHeader | Out-Null
            Write-Host "  [OK] Autopilot sync signal acknowledged by Microsoft Graph." -ForegroundColor Green
            Write-IntuneLog -Message "Triggered tenant Autopilot profile sync" -Level Info -Component "AutopilotFast" -CustomData @{ SerialNumber = $SerialNumber; DeviceId = $DeviceId }
        }
        catch {
            Write-Warning "Autopilot tenant sync trigger returned: $($_.Exception.Message)"
            Write-IntuneLog -Message "Tenant sync trigger failed or throttled: $($_.Exception.Message)" -Level Warning -Component "AutopilotFast"
        }
    }

    if (-not $WaitForAssignment) {
        return [PSCustomObject]@{
            TriggeredSync = [bool]$TriggerTenantSync
            Status        = "SyncTriggered"
        }
    }

    # 3. Dynamic Group & Profile Assignment Backoff Poller
    Write-Host "  [+] Polling Intune for profile assignment (Timeout: $TimeoutMinutes mins)..." -ForegroundColor Cyan
    Write-IntuneLog -Message "Initiating profile assignment polling" -Level Info -Component "AutopilotFast" -CustomData @{
        SerialNumber           = $SerialNumber
        DeviceId               = $DeviceId
        TimeoutMinutes         = $TimeoutMinutes
        InitialIntervalSeconds = $InitialIntervalSeconds
    }

    $startTime = [datetime]::UtcNow
    $currentInterval = $InitialIntervalSeconds
    $attempt = 0
    $targetDevice = $null

    while (([datetime]::UtcNow - $startTime).TotalMinutes -lt $TimeoutMinutes) {
        $attempt++

        # Jittered exponential delay
        $jitter = (Get-Random -Minimum 0 -Maximum 1000) / 1000.0
        $sleepDuration = [Math]::Min($MaxIntervalSeconds, [int][Math]::Ceiling($currentInterval + $jitter))
        Start-Sleep -Seconds $sleepDuration
        $currentInterval = [Math]::Min($MaxIntervalSeconds, [int][Math]::Ceiling($currentInterval * $BackoffMultiplier))

        try {
            if ($DeviceId) {
                $devUri = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities/$DeviceId"
                $targetDevice = Invoke-ResilientGraphRest -Uri $devUri -Method GET -Headers $authHeader
            }
            elseif ($SerialNumber) {
                $filterExpr = "serialNumber eq '" + $SerialNumber + "'"
                $searchUri = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=" + [System.Uri]::EscapeDataString($filterExpr)
                $searchRes = Invoke-ResilientGraphRest -Uri $searchUri -Method GET -Headers $authHeader

                if ($searchRes.value -and $searchRes.value.Count -gt 0) {
                    $targetDevice = $searchRes.value[0]
                    $DeviceId = $targetDevice.id
                }
            }

            if ($targetDevice) {
                $assignStatus = $targetDevice.deploymentProfileAssignmentStatus
                $detailedStatus = $targetDevice.deploymentProfileAssignmentDetailedStatus
                $profileName = if ($targetDevice.assignedDeploymentProfile) { $targetDevice.assignedDeploymentProfile.displayName } else { "None" }

                $elapsedSec = [int]([datetime]::UtcNow - $startTime).TotalSeconds
                Write-Host "  [*] [$elapsedSec s] Assignment Status: '$assignStatus' | Profile: '$profileName'" -ForegroundColor DarkGray

                if ($assignStatus -eq 'assigned') {
                    $assignedTime = $targetDevice.deploymentProfileAssignedDateTime
                    Write-Host "`n  [OK] Autopilot Profile Assigned: '$profileName' (Assigned at: $assignedTime)" -ForegroundColor Green
                    Write-IntuneLog -Message "Profile successfully assigned to device" -Level Info -Component "AutopilotFast" -CustomData @{
                        SerialNumber                      = $SerialNumber
                        DeviceId                          = $DeviceId
                        ProfileName                       = $profileName
                        AssignmentStatus                  = $assignStatus
                        ElapsedSeconds                    = $elapsedSec
                    }

                    $resultObj = [PSCustomObject]@{
                        IsAssigned                               = $true
                        SerialNumber                             = $targetDevice.serialNumber
                        DeviceId                                 = $targetDevice.id
                        GroupTag                                 = $targetDevice.groupTag
                        DeploymentProfileAssignmentStatus        = $assignStatus
                        DeploymentProfileAssignmentDetailedStatus= $detailedStatus
                        AssignedProfileName                      = $profileName
                        AssignedDateTime                         = $assignedTime
                        ElapsedSeconds                           = $elapsedSec
                        Attempts                                 = $attempt
                    }

                    if ($Reboot) {
                        Write-Host "  [+] Initiating system reboot to trigger corporate Autopilot OOBE..." -ForegroundColor Cyan
                        Restart-Computer -Force
                    }

                    return $resultObj
                }
                elseif ($assignStatus -eq 'failed' -or $assignStatus -eq 'error') {
                    Write-Host "`n  [FAIL] Deployment profile assignment failed: $detailedStatus" -ForegroundColor Red
                    Write-IntuneLog -Message "Deployment profile assignment failed" -Level Error -Component "AutopilotFast" -CustomData @{
                        SerialNumber   = $SerialNumber
                        DeviceId       = $DeviceId
                        AssignStatus   = $assignStatus
                        DetailedStatus = $detailedStatus
                    }

                    return [PSCustomObject]@{
                        IsAssigned                               = $false
                        SerialNumber                             = $targetDevice.serialNumber
                        DeviceId                                 = $targetDevice.id
                        DeploymentProfileAssignmentStatus        = $assignStatus
                        DeploymentProfileAssignmentDetailedStatus= $detailedStatus
                        AssignedProfileName                      = $profileName
                        ElapsedSeconds                           = $elapsedSec
                        Attempts                                 = $attempt
                    }
                }
            }
        }
        catch {
            Write-Verbose "Graph query attempt $attempt encountered error: $($_.Exception.Message)"
        }
    }

    # Timeout Reached
    $totalElapsedSec = [int]([datetime]::UtcNow - $startTime).TotalSeconds
    Write-Warning "Profile assignment polling timed out after $TimeoutMinutes minutes ($totalElapsedSec seconds)."
    Write-IntuneLog -Message "Profile assignment polling timed out" -Level Warning -Component "AutopilotFast" -CustomData @{
        SerialNumber   = $SerialNumber
        DeviceId       = $DeviceId
        ElapsedSeconds = $totalElapsedSec
        Attempts       = $attempt
    }

    return [PSCustomObject]@{
        IsAssigned                               = $false
        SerialNumber                             = $SerialNumber
        DeviceId                                 = $DeviceId
        DeploymentProfileAssignmentStatus        = if ($targetDevice) { $targetDevice.deploymentProfileAssignmentStatus } else { "Unknown" }
        DeploymentProfileAssignmentDetailedStatus= "TimedOut"
        AssignedProfileName                      = if ($targetDevice -and $targetDevice.assignedDeploymentProfile) { $targetDevice.assignedDeploymentProfile.displayName } else { "None" }
        ElapsedSeconds                           = $totalElapsedSec
        Attempts                                 = $attempt
    }
}
