@{
    RootModule = 'AutopilotFast.psm1'
    ModuleVersion = '1.0.0'
    GUID = '7e3d1a8c-9b2f-410a-8c5e-3d4a6f2b8e10'
    Author = 'Matthew Bubb'
    CompanyName = 'OnYaChamp.com'
    Copyright = '(c) 2026 Matthew Bubb. All rights reserved.'
    Description = 'Lightning-fast Windows Autopilot hardware hash harvester and direct Microsoft Graph cloud device registrar for Windows OOBE (Shift+F10).'
    PowerShellVersion = '5.1'
    RequiredModules = @()
    FunctionsToExport = @(
        'Get-AutopilotHash',
        'Export-AutopilotCsv',
        'Connect-AutopilotGraph',
        'Register-AutopilotDevice',
        'Set-AutopilotGroupTag',
        'Test-AutopilotReadiness'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @('Import-AutopilotDevice')
    PrivateData = @{
        PSData = @{
            Tags = @('autopilot', 'intune', 'hardware-hash', 'oobe', 'entra', 'graph-api', 'zero-touch', 'provisioning')
            LicenseUri = 'https://github.com/thebubbsy/AutopilotFast/blob/main/LICENSE'
            ProjectUri = 'https://github.com/thebubbsy/AutopilotFast'
        }
    }
}
