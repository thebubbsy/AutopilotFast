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
        if (-not $Quiet) {
            $tokenLen = $token.Length
            $tokenPreview = if ($tokenLen -gt 16) { "$($token.Substring(0, 8))...$($token.Substring($tokenLen - 6)) ($tokenLen chars)" } else { "($tokenLen chars)" }
            $scopeSummary = ($Scopes | ForEach-Object { $_ -replace '^https?://graph\.microsoft\.com/', '' }) -join ', '
            if ($scopeSummary.Length -gt 44) { $scopeSummary = $scopeSummary.Substring(0, 41) + '...' }

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
        return $token
    } else {
        throw "Failed to obtain Microsoft Graph access token."
    }
}
