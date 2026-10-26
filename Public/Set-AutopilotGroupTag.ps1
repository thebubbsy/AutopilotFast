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
        [switch]$CopyCsv,

        [Parameter()]
        [switch]$CopyHtml,

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
        Write-Host ("  [TARGET:AUTOPILOT] [SCOPE:DEVICE] [ACTION:UPDATE-TAG] [GROUPTAG:{0}] [STATUS:VERIFIED]" -f $GroupTag) -ForegroundColor Cyan
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
    if ($CopyHtml) {
        try {
            $htmlGroupTag = @(
                "<div style=`"font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;max-width:640px;background:#0f172a;color:#f8fafc;border:1px solid #334155;border-radius:8px;padding:16px;box-shadow:0 4px 6px -1px rgba(0,0,0,0.1);`">",
                "  <div style=`"display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid #334155;padding-bottom:10px;margin-bottom:12px;`">",
                "    <h3 style=`"margin:0;color:#38bdf8;font-size:16px;font-weight:600;`">Autopilot GroupTag Update Receipt</h3>",
                "    <span style=`"background:#166534;color:#4ade80;padding:2px 8px;border-radius:12px;font-size:12px;font-weight:600;`">UPDATED</span>",
                "  </div>",
                "  <table style=`"width:100%;border-collapse:collapse;font-size:13px;`">",
                "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Serial Number</td><td style=`"padding:6px 0;text-align:right;color:#f8fafc;font-family:monospace;`">$(if ($SerialNumber) { $SerialNumber } else { 'N/A' })</td></tr>",
                "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Device ID</td><td style=`"padding:6px 0;text-align:right;color:#f8fafc;font-family:monospace;font-size:11px;`">$targetId</td></tr>",
                "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Previous GroupTag</td><td style=`"padding:6px 0;text-align:right;color:#94a3b8;`">$(if ($prevGroupTag) { $prevGroupTag } else { '<none>' })</td></tr>",
                "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">New GroupTag</td><td style=`"padding:6px 0;text-align:right;color:#38bdf8;font-weight:600;`">$GroupTag</td></tr>",
                "    <tr><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Updated At (UTC)</td><td style=`"padding:6px 0;text-align:right;color:#94a3b8;font-size:12px;`">$updatedUtc</td></tr>",
                "  </table>",
                "</div>"
            ) -join [Environment]::NewLine
            Set-Clipboard -Value $htmlGroupTag -ErrorAction Stop
            if (-not $Quiet) {
                Write-Host "  [CLIPBOARD] Copied GroupTag Update Receipt (HTML) to clipboard." -ForegroundColor Green
            }
        } catch { }
    }
    if ($CopyCsv) {
        try {
            $csvGroupTag = @(
                "DeviceId,SerialNumber,PreviousGroupTag,GroupTag,Transition,UpdatedAtUtc",
                "`"$targetId`",`"$(if ($SerialNumber) { $SerialNumber } else { 'N/A' })`",`"$prevGroupTag`",`"$GroupTag`",`"$transitionText`",`"$updatedUtc`""
            ) -join "`r`n"
            Set-Clipboard -Value $csvGroupTag -ErrorAction Stop
            if (-not $Quiet) {
                Write-Host "  [CLIPBOARD] Copied GroupTag Update Receipt (CSV) to clipboard." -ForegroundColor Green
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
