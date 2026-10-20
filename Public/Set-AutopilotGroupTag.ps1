<#
.SYNOPSIS
    Updates the Autopilot GroupTag for a registered device in Microsoft Intune.
.DESCRIPTION
    Searches for an Autopilot device in Microsoft Graph by Serial Number or Device ID and updates
    its assigned GroupTag.
#>
function Set-AutopilotGroupTag {
    [CmdletBinding(DefaultParameterSetName = 'Serial')]
    param(
        [Parameter(ParameterSetName = 'Serial', Mandatory = $true, Position = 0)]
        [string]$SerialNumber,

        [Parameter(ParameterSetName = 'Id', Mandatory = $true)]
        [string]$DeviceId,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$GroupTag,

        [Parameter()]
        [switch]$Quiet,

        [Parameter()]
        [switch]$CopyReceipt,

        [Parameter()]
        [switch]$CopyJson,

        [Parameter()]
        [switch]$CopyTsv,

        [Parameter()]
        [switch]$PassThru
    )

    $token = $script:AutopilotAccessToken
    if (-not $token) {
        $token = Connect-AutopilotGraph -Quiet:$Quiet
    }

    $authHeader = @{
        'Authorization' = "Bearer $token"
        'Content-Type'  = 'application/json'
    }

    $targetId = $DeviceId
    $prevGroupTag = $null
    if ($SerialNumber) {
        $filterExpr = "serialNumber eq '" + $SerialNumber + "'"
        $searchUri = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=" + [System.Uri]::EscapeDataString($filterExpr)
        $searchRes = Invoke-ResilientGraphRest -Uri $searchUri -Method GET -Headers $authHeader
        
        if (-not $searchRes.value -or $searchRes.value.Count -eq 0) {
            throw "No Autopilot device found in tenant matching Serial Number: $SerialNumber"
        }
        $targetId = $searchRes.value[0].id
        $prevGroupTag = $searchRes.value[0].groupTag
    }

    $updateUri = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities/" + $targetId + "/updateDeviceProperties"
    $body = @{
        groupTag = $GroupTag
    }

    if (-not $Quiet) {
        Write-Host "  [+] Updating GroupTag for Device ID [$targetId] -> '$GroupTag'..." -ForegroundColor Cyan
    }
    Invoke-ResilientGraphRest -Uri $updateUri -Method POST -Headers $authHeader -Body $body | Out-Null
    $transitionText = if ($prevGroupTag) { "'$prevGroupTag' -> '$GroupTag'" } else { "-> '$GroupTag'" }
    $updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    if (-not $Quiet) {
        Write-Host ""
        Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkGreen
        Write-Host "  | AUTOPILOT GROUP TAG UPDATE RECEIPT                       [UPDATED]   |" -ForegroundColor Green
        Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkGreen
        if ($SerialNumber) {
            Write-Host ("  | Serial Number : {0,-52} |" -f $SerialNumber) -ForegroundColor White
        }
        Write-Host ("  | Device ID     : {0,-52} |" -f $targetId) -ForegroundColor Gray
        Write-Host ("  | Group Tag     : {0,-52} |" -f $transitionText) -ForegroundColor Cyan
        Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkGreen
        Write-Host ""
    }

    if ($CopyReceipt) {
        try {
            $md = @(
                "### Autopilot GroupTag Update Receipt",
                "| Field | Value |",
                "| :--- | :--- |",
                "| **Serial Number** | ``$(if ($SerialNumber) { $SerialNumber } else { 'N/A' })`` |",
                "| **Device ID** | ``$targetId`` |",
                "| **Transition** | ``$transitionText`` |",
                "| **Updated At (UTC)** | ``$updatedUtc`` |"
            ) -join "`r`n"
            Set-Clipboard -Value $md -ErrorAction Stop
            if (-not $Quiet) {
                Write-Host "  [CLIPBOARD] Copied GroupTag Update Receipt (Markdown) to clipboard." -ForegroundColor Green
            }
        } catch { }
    }
    if ($CopyJson) {
        try {
            $jsonReceipt = [PSCustomObject]@{
                DeviceId         = $targetId
                SerialNumber     = if ($SerialNumber) { $SerialNumber } else { 'N/A' }
                PreviousGroupTag = $prevGroupTag
                GroupTag         = $GroupTag
                Transition       = $transitionText
                UpdatedAtUtc     = $updatedUtc
            } | ConvertTo-Json -Depth 4
            Set-Clipboard -Value $jsonReceipt -ErrorAction Stop
            if (-not $Quiet) {
                Write-Host "  [CLIPBOARD] Copied GroupTag Update Receipt (JSON) to clipboard." -ForegroundColor Green
            }
        } catch { }
    }
    if ($CopyTsv) {
        try {
            $tsvReceipt = @(
                "DeviceId`tSerialNumber`tPreviousGroupTag`tGroupTag`tUpdatedAtUtc",
                "$targetId`t$(if ($SerialNumber) { $SerialNumber } else { 'N/A' })`t$prevGroupTag`t$GroupTag`t$updatedUtc"
            ) -join "`r`n"
            Set-Clipboard -Value $tsvReceipt -ErrorAction Stop
            if (-not $Quiet) {
                Write-Host "  [CLIPBOARD] Copied GroupTag Update Receipt (TSV) to clipboard." -ForegroundColor Green
            }
        } catch { }
    }

    if ($PassThru) {
        return [PSCustomObject]@{
            DeviceId         = $targetId
            SerialNumber     = $SerialNumber
            PreviousGroupTag = $prevGroupTag
            GroupTag         = $GroupTag
            UpdatedAtUtc     = $updatedUtc
        }
    }
}
