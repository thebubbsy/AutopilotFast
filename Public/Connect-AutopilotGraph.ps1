<#
.SYNOPSIS
    Connects to Microsoft Graph for Autopilot device registration.
.DESCRIPTION
    Wraps Connect-GraphToken with Autopilot specific scopes.
#>
function Connect-AutopilotGraph {
    [CmdletBinding(DefaultParameterSetName = 'DeviceCode')]
    param(
        [Parameter()]
        [string]$TenantId = 'organizations',

        [Parameter()]
        [string]$ClientId = 'd1ddf0e6-50e1-4fb8-8182-76f584d73f3e',

        [Parameter(ParameterSetName = 'Secret', Mandatory = $true)]
        [string]$ClientSecret,

        [Parameter()]
        [string[]]$Scopes = @('https://graph.microsoft.com/DeviceManagementServiceConfig.ReadWrite.All'),

        [Parameter()]
        [switch]$Force,

        [Parameter()]
        [switch]$CopyReceipt,

        [Parameter()]
        [switch]$CopyToken,

        [Parameter()]
        [switch]$CopyJson,

        [Parameter()]
        [switch]$CopyTsv,

        [Parameter()]
        [switch]$CopyCsv,

        [Parameter()]
        [switch]$CopyHtml,

        [Parameter()]
        [switch]$Quiet
    )

    $authMode = if ($ClientSecret) { 'ClientSecret (App-Only)' } else { 'Delegated (Interactive / DeviceCode)' }
    if ($ClientSecret) {
        $token = Connect-GraphToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret -Scopes $Scopes -ForceRefresh:$Force
    } else {
        $token = Connect-GraphToken -TenantId $TenantId -ClientId $ClientId -Scopes $Scopes -ForceRefresh:$Force
    }

    if ($token) {
        $script:AutopilotAccessToken = $token
        $tokenLen = $token.Length
        $tokenPreview = if ($tokenLen -gt 16) { "$($token.Substring(0, 8))...$($token.Substring($tokenLen - 6)) ($tokenLen chars)" } else { "($tokenLen chars)" }
        $scopeSummary = ($Scopes | ForEach-Object { $_ -replace '^https?://graph\.microsoft\.com/', '' }) -join ', '
        if ($scopeSummary.Length -gt 44) { $scopeSummary = $scopeSummary.Substring(0, 41) + '...' }

        if (-not $Quiet) {
            $authModeBadge = if ($ClientSecret) { 'SECRET' } else { 'DELEGATED' }
            Write-Host ""
            Write-Host ("  [GRAPH:CONNECTED] [AUTH:{0}] [TENANT:{1}] [SCOPES:{2}] [TOKEN:{3}-CHARS]" -f $authModeBadge, $TenantId, $Scopes.Count, $tokenLen) -ForegroundColor Cyan
            Write-Host "  +------------------------------------------------------------------+" -ForegroundColor DarkCyan
            Write-Host "  |  [AutopilotFast] Microsoft Graph Session Connected               |" -ForegroundColor Cyan
            Write-Host "  +------------------------------------------------------------------+" -ForegroundColor DarkCyan
            Write-Host ("  |  Auth Mode    : {0,-49}|" -f $authMode) -ForegroundColor Gray
            Write-Host ("  |  Tenant ID    : {0,-49}|" -f $TenantId) -ForegroundColor Gray
            Write-Host ("  |  Client ID    : {0,-49}|" -f $ClientId) -ForegroundColor Gray
            Write-Host ("  |  Scopes       : {0,-49}|" -f $scopeSummary) -ForegroundColor Gray
            Write-Host ("  |  Bearer Token : {0,-49}|" -f $tokenPreview) -ForegroundColor Green
            Write-Host "  +------------------------------------------------------------------+" -ForegroundColor DarkCyan
            Write-Host "  [OK] Connected to Microsoft Graph for Autopilot Management." -ForegroundColor Green
        }

        if ($CopyReceipt) {
            $mdReceipt = @(
                "### AutopilotFast Microsoft Graph Session Receipt",
                "| Field | Value |",
                "| :--- | :--- |",
                "| **Auth Mode** | $authMode |",
                "| **Tenant ID** | ``$TenantId`` |",
                "| **Client ID** | ``$ClientId`` |",
                "| **Scopes** | ``$scopeSummary`` |",
                "| **Bearer Token** | ``$tokenPreview`` |"
            ) -join [Environment]::NewLine
            try {
                Set-Clipboard -Value $mdReceipt -ErrorAction Stop
                if (-not $Quiet) {
                    Write-Host "  [CLIPBOARD] Copied Markdown Graph Session Receipt to clipboard." -ForegroundColor Cyan
                }
            } catch {
                Write-Verbose "Clipboard copy failed: $($_.Exception.Message)"
            }
        }

        if ($CopyJson) {
            $jsonReceipt = [PSCustomObject]@{
                AuthMode      = $authMode
                TenantId      = $TenantId
                ClientId      = $ClientId
                Scopes        = @($Scopes)
                TokenLength   = $tokenLen
                TokenPreview  = $tokenPreview
                ConnectedAtUtc = [DateTime]::UtcNow.ToString('o')
            } | ConvertTo-Json -Depth 4
            try {
                Set-Clipboard -Value $jsonReceipt -ErrorAction Stop
                if (-not $Quiet) {
                    Write-Host "  [CLIPBOARD] Copied Graph Session Receipt JSON to clipboard." -ForegroundColor Cyan
                }
            } catch {
                Write-Verbose "Clipboard copy failed: $($_.Exception.Message)"
            }
        }

        if ($CopyTsv) {
            $tsvHeader = "AuthMode`tTenantId`tClientId`tScopes`tTokenLength`tConnectedAtUtc"
            $tsvRow = "$authMode`t$TenantId`t$ClientId`t$scopeSummary`t$tokenLen`t$([DateTime]::UtcNow.ToString('o'))"
            try {
                Set-Clipboard -Value ("$tsvHeader`r`n$tsvRow") -ErrorAction Stop
                if (-not $Quiet) {
                    Write-Host "  [CLIPBOARD] Copied Graph Session Receipt TSV to clipboard." -ForegroundColor Cyan
                }
            } catch {
                Write-Verbose "Clipboard copy failed: $($_.Exception.Message)"
            }
        }

        if ($CopyToken) {
            try {
                Set-Clipboard -Value $token -ErrorAction Stop
                if (-not $Quiet) {
                    Write-Host "  [CLIPBOARD] Copied raw Graph Bearer Token ($tokenLen chars) to clipboard." -ForegroundColor Cyan
                }
            } catch {
                Write-Verbose "Clipboard copy failed: $($_.Exception.Message)"
            }
        }

        if ($CopyHtml) {
            $htmlSession = @(
                "<div style=`"font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;max-width:640px;background:#0f172a;color:#f8fafc;border:1px solid #334155;border-radius:8px;padding:16px;box-shadow:0 4px 6px -1px rgba(0,0,0,0.1);`">",
                "  <div style=`"display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid #334155;padding-bottom:10px;margin-bottom:12px;`">",
                "    <h3 style=`"margin:0;color:#38bdf8;font-size:16px;font-weight:600;`">AutopilotFast Microsoft Graph Session Receipt</h3>",
                "    <span style=`"background:#166534;color:#4ade80;padding:2px 8px;border-radius:12px;font-size:12px;font-weight:600;`">CONNECTED</span>",
                "  </div>",
                "  <table style=`"width:100%;border-collapse:collapse;font-size:13px;`">",
                "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Auth Mode</td><td style=`"padding:6px 0;text-align:right;color:#f8fafc;`">$authMode</td></tr>",
                "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Tenant ID</td><td style=`"padding:6px 0;text-align:right;color:#f8fafc;font-family:monospace;`">$TenantId</td></tr>",
                "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Client ID</td><td style=`"padding:6px 0;text-align:right;color:#f8fafc;font-family:monospace;font-size:11px;`">$ClientId</td></tr>",
                "    <tr style=`"border-bottom:1px solid #1e293b;`"><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Scopes</td><td style=`"padding:6px 0;text-align:right;color:#38bdf8;font-size:12px;`">$scopeSummary</td></tr>",
                "    <tr><td style=`"padding:6px 0;color:#94a3b8;font-weight:500;`">Bearer Token</td><td style=`"padding:6px 0;text-align:right;color:#4ade80;font-family:monospace;font-size:11px;`">$tokenPreview</td></tr>",
                "  </table>",
                "</div>"
            ) -join [Environment]::NewLine
            try {
                Set-Clipboard -Value $htmlSession -ErrorAction Stop
                if (-not $Quiet) {
                    Write-Host "  [CLIPBOARD] Copied HTML Graph Session Receipt to clipboard." -ForegroundColor Cyan
                }
            } catch {
                Write-Verbose "Clipboard copy failed: $($_.Exception.Message)"
            }
        }

        if ($CopyCsv) {
            $csvSession = @(
                "AuthMode,TenantId,ClientId,Scopes,TokenLength,ConnectedAtUtc",
                "`"$authMode`",`"$TenantId`",`"$ClientId`",`"$scopeSummary`",$tokenLen,`"$([DateTime]::UtcNow.ToString('o'))`""
            ) -join "`r`n"
            try {
                Set-Clipboard -Value $csvSession -ErrorAction Stop
                if (-not $Quiet) {
                    Write-Host "  [CLIPBOARD] Copied CSV Graph Session Receipt to clipboard." -ForegroundColor Cyan
                }
            } catch {
                Write-Verbose "Clipboard copy failed: $($_.Exception.Message)"
            }
        }

        return $token
    } else {
        throw "Failed to obtain Microsoft Graph access token."
    }
}
