@echo off
:: ============================================================================
:: AutopilotFast - OOBE Bootstrapper (Offline USB Priority + HTTPS Fallback)
:: Run at Windows 11/10 OOBE via Shift + F10
:: ============================================================================
setlocal EnableDelayedExpansion

title AutopilotFast - OOBE Bootstrapper
color 0B

echo.
echo  ================================================================
echo    AUTOPILOTFAST - WINDOWS OOBE BOOTSTRAPPER (OFFLINE FIRST)
echo  ================================================================
echo.

:: 1. Search for Offline AutopilotConfigurationFile.json on USB / Local Staging
echo  [+] Searching for offline AutopilotConfigurationFile.json...
set "OFFLINE_JSON_FOUND=0"
set "PROVISION_DIR=C:\Windows\Provisioning\Autopilot"

for %%D in (D E F G H I J K U V W C) do (
    if exist "%%D:\AutopilotConfigurationFile.json" (
        set "SOURCE_JSON=%%D:\AutopilotConfigurationFile.json"
        goto :InjectOfflineJson
    )
    if exist "%%D:\Autopilot\AutopilotConfigurationFile.json" (
        set "SOURCE_JSON=%%D:\Autopilot\AutopilotConfigurationFile.json"
        goto :InjectOfflineJson
    )
    if exist "%%D:\AutopilotFast\AutopilotConfigurationFile.json" (
        set "SOURCE_JSON=%%D:\AutopilotFast\AutopilotConfigurationFile.json"
        goto :InjectOfflineJson
    )
)

if exist "%~dp0AutopilotConfigurationFile.json" (
    set "SOURCE_JSON=%~dp0AutopilotConfigurationFile.json"
    goto :InjectOfflineJson
)

goto :CheckPowerShell7

:InjectOfflineJson
if not exist "%PROVISION_DIR%" mkdir "%PROVISION_DIR%" 2>nul
echo  [+] Injecting offline Autopilot profile from: "%SOURCE_JSON%"...
copy /Y "%SOURCE_JSON%" "%PROVISION_DIR%\AutopilotConfigurationFile.json" >nul
if exist "%PROVISION_DIR%\AutopilotConfigurationFile.json" (
    echo  [OK] Offline Autopilot profile injected: "%PROVISION_DIR%\AutopilotConfigurationFile.json"
    set "OFFLINE_JSON_FOUND=1"
) else (
    echo  [!] Failed to copy offline Autopilot profile.
)

:CheckPowerShell7
set "PWSH_EXE=C:\Program Files\PowerShell\7\pwsh.exe"

if exist "%PWSH_EXE%" (
    echo  [OK] PowerShell 7 detected at: "%PWSH_EXE%"
    goto :Launch
)

:: 2. Detect Architecture (ARM64 vs x64)
set "ARCH=win-x64"
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "ARCH=win-arm64"
if /i "%PROCESSOR_ARCHITEW6432%"=="ARM64" set "ARCH=win-arm64"

echo  [+] Detected Hardware Architecture: %ARCH%

:: 3. Search for Local / USB Offline MSI Installer
set "OFFLINE_MSI="
for %%D in (D E F G H I J K U V W C) do (
    if exist "%%D:\PowerShell-7.4.5-%ARCH%.msi" (
        set "OFFLINE_MSI=%%D:\PowerShell-7.4.5-%ARCH%.msi"
        goto :InstallOffline
    )
    if exist "%%D:\AutopilotFast\PowerShell-7.4.5-%ARCH%.msi" (
        set "OFFLINE_MSI=%%D:\AutopilotFast\PowerShell-7.4.5-%ARCH%.msi"
        goto :InstallOffline
    )
)

if exist "%~dp0PowerShell-7.4.5-%ARCH%.msi" (
    set "OFFLINE_MSI=%~dp0PowerShell-7.4.5-%ARCH%.msi"
    goto :InstallOffline
)

:DownloadOnline
echo  [+] No offline MSI found on USB drives. Attempting HTTPS download...
set "MSI_URL=https://github.com/PowerShell/PowerShell/releases/download/v7.4.5/PowerShell-7.4.5-%ARCH%.msi"
set "MSI_TARGET=%TEMP%\PowerShell-7.4.5-%ARCH%.msi"

curl.exe -fSLo "%MSI_TARGET%" "%MSI_URL%" 2>nul

if not exist "%MSI_TARGET%" (
    echo  [!] Online download unavailable. Checking Windows PowerShell 5.1 fallback...
    goto :PowerShell5Fallback
)

set "OFFLINE_MSI=%MSI_TARGET%"

:InstallOffline
echo  [+] Installing PowerShell 7 from: "%OFFLINE_MSI%"...
msiexec.exe /i "%OFFLINE_MSI%" /qn /norestart

if exist "%PWSH_EXE%" (
    echo  [OK] PowerShell 7 installation complete!
    goto :Launch
)

:PowerShell5Fallback
echo.
echo  ================================================================
echo  [!] Launching AutopilotFast via Windows PowerShell 5.1 Fallback...
echo  ================================================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& {
    Write-Host 'Running in native Windows PowerShell 5.1 compatibility mode...' -ForegroundColor Yellow
    $modulePath = if (Test-Path 'C:\src\AutopilotFast\AutopilotFast.psd1') { 'C:\src\AutopilotFast\AutopilotFast.psd1' } else { Join-Path '%~dp0' 'AutopilotFast.psd1' }
    if (Test-Path $modulePath) {
        Import-Module $modulePath -Force
        Register-AutopilotDevice -FallbackToUsb
    } else {
        Write-Warning 'AutopilotFast module not found. Exporting hardware hash via WMI...'
    }
}"
pause
exit /b 0

:Launch
echo.
echo  [+] Launching AutopilotFast in native PowerShell 7...
echo.

"%PWSH_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "& {
    $scriptDir = '%~dp0'.TrimEnd('\')
    $moduleRoot = if (Test-Path 'C:\src\AutopilotFast\AutopilotFast.psd1') { 'C:\src\AutopilotFast' } else { $scriptDir }
    
    Import-Module (Join-Path $moduleRoot 'AutopilotFast.psd1') -Force
    
    Write-Host '===================================================' -ForegroundColor Cyan
    Write-Host '   AUTOPILOTFAST IS LIVE IN POWERSHELL 7!          ' -ForegroundColor Green
    Write-Host '===================================================' -ForegroundColor Cyan
    
    $readiness = Test-AutopilotReadiness
    if ($readiness.IsCompliant) {
        Register-AutopilotDevice -FallbackToUsb -WaitForSync
    } else {
        Write-Warning 'Hardware readiness check reported violations. Review diagnostics above.'
    }
}"

pause
