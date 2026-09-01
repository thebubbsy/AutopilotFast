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

set "PWSH_EXE=C:\Program Files\PowerShell\7\pwsh.exe"

if exist "%PWSH_EXE%" (
    echo  [OK] PowerShell 7 detected at: "%PWSH_EXE%"
    goto :Launch
)

:: 1. Detect Architecture (ARM64 vs x64)
set "ARCH=win-x64"
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "ARCH=win-arm64"
if /i "%PROCESSOR_ARCHITEW6432%"=="ARM64" set "ARCH=win-arm64"

echo  [+] Detected Hardware Architecture: %ARCH%

:: 2. Search for Local / USB Offline MSI Installer
set "OFFLINE_MSI="
for %%D in (D E F G H I J K C) do (
    if exist "%%D:\PowerShell-7.4.5-%ARCH%.msi" (
        set "OFFLINE_MSI=%%D:\PowerShell-7.4.5-%ARCH%.msi"
        goto :InstallOffline
    )
    if exist "%%D:\AutopilotFast\PowerShell-7.4.5-%ARCH%.msi" (
        set "OFFLINE_MSI=%%D:\AutopilotFast\PowerShell-7.4.5-%ARCH%.msi"
        goto :InstallOffline
    )
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
    if (Test-Path 'C:\src\AutopilotFast\AutopilotFast.psd1') {
        Import-Module 'C:\src\AutopilotFast\AutopilotFast.psd1' -Force
        Register-AutopilotDevice -FallbackToUsb
    }
}"
pause
exit /b 0

:Launch
echo.
echo  [+] Launching AutopilotFast in native PowerShell 7...
echo.

"%PWSH_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "& {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $moduleRoot = if (Test-Path 'C:\src\AutopilotFast') { 'C:\src\AutopilotFast' } else { $scriptDir }
    
    Import-Module (Join-Path $moduleRoot 'AutopilotFast.psd1') -Force
    
    Write-Host '===================================================' -ForegroundColor Cyan
    Write-Host '   AUTOPILOTFAST IS LIVE IN POWERSHELL 7!          ' -ForegroundColor Green
    Write-Host '===================================================' -ForegroundColor Cyan
    
    $readiness = Test-AutopilotReadiness
    if ($readiness.IsCompliant) {
        Register-AutopilotDevice -FallbackToUsb
    } else {
        Write-Warning 'Hardware readiness check reported violations. Review diagnostics above.'
    }
}"

pause
