@echo off
:: ============================================================================
:: AutopilotFast - OOBE PowerShell 7 Bootstrapper (ARM64 & x64 Resilient)
:: Run at Windows 11/10 OOBE via Shift + F10
:: ============================================================================
setlocal EnableDelayedExpansion

title AutopilotFast - OOBE Bootstrapper
color 0B

echo.
echo  ================================================================
echo    AUTOPILOTFAST - WINDOWS OOBE POWERSHELL 7 BOOTSTRAPPER
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

echo  [+] Detected Architecture: %ARCH%

:: 2. Pre-download MSI using curl.exe to handle GitHub HTTP 302 Redirects
set "MSI_URL=https://github.com/PowerShell/PowerShell/releases/download/v7.4.5/PowerShell-7.4.5-%ARCH%.msi"
set "MSI_TARGET=%TEMP%\PowerShell-7.4.5-%ARCH%.msi"

echo  [+] Downloading PowerShell 7.4 LTS (%ARCH%) over HTTPS...
curl.exe -fSLo "%MSI_TARGET%" "%MSI_URL%"

if not exist "%MSI_TARGET%" (
    echo  [FAIL] Download failed. Falling back to PowerShell WebClient...
    powershell.exe -NoProfile -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; (New-Object Net.WebClient).DownloadFile('%MSI_URL%', '%MSI_TARGET%')"
)

if not exist "%MSI_TARGET%" (
    echo  [FAIL] Failed to retrieve PowerShell 7 installer package. Check network connection.
    pause
    exit /b 1
)

:: 3. Execute Silent MSI Installation
echo  [+] Installing PowerShell 7 silently...
msiexec.exe /i "%MSI_TARGET%" /qn /norestart

if not exist "%PWSH_EXE%" (
    echo  [FAIL] PowerShell 7 installation did not complete as expected.
    pause
    exit /b 1
)

echo  [OK] PowerShell 7 installed successfully!

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
