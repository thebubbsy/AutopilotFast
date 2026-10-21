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
            Write-Host ""
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

        return $token
    } else {
        throw "Failed to obtain Microsoft Graph access token."
    }
}
