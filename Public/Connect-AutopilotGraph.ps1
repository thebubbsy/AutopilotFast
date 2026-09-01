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
        [switch]$Force
    )

    if ($ClientSecret) {
        $token = Connect-GraphToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret -Scopes $Scopes -ForceRefresh:$Force
    } else {
        $token = Connect-GraphToken -TenantId $TenantId -ClientId $ClientId -Scopes $Scopes -ForceRefresh:$Force
    }

    if ($token) {
        $script:AutopilotAccessToken = $token
        Write-Host "  [OK] Connected to Microsoft Graph for Autopilot Management." -ForegroundColor Green
        return $token
    } else {
        throw "Failed to obtain Microsoft Graph access token."
    }
}
