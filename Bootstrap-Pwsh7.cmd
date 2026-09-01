@echo off
:: ============================================================================
:: AutopilotFast - OOBE PowerShell 7 Bootstrapper & Cloud Device Registrar
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
) else (
    echo  [+] PowerShell 7 not found. Bootstrapping MSI over HTTPS...
    echo  [+] Downloading and installing PowerShell 7.4 LTS silently...
    msiexec.exe /i "https://github.com/PowerShell/PowerShell/releases/download/v7.4.5/PowerShell-7.4.5-win-x64.msi" /qn /norestart
    
    if not exist "%PWSH_EXE%" (
        echo  [FAIL] Failed to install PowerShell 7. Check network connectivity.
        pause
        exit /b 1
    )
    echo  [OK] PowerShell 7 installed successfully!
)

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
        Write-Warning 'Hardware readiness check failed. Review diagnostics above.'
    }
}"

pause
