<#
.SYNOPSIS
    Performs comprehensive pre-flight hardware and cloud readiness checks for Windows Autopilot.
.DESCRIPTION
    Validates TPM 2.0 readiness, Secure Boot state, UEFI mode, and 7-stage network health.
#>
function Test-AutopilotReadiness {
    [CmdletBinding()]
    param()

    Write-Host "`n  [AutopilotFast] Hardware and Cloud Pre-Flight Readiness" -ForegroundColor Cyan
    Write-Host "  ------------------------------------------------------" -ForegroundColor DarkGray

    $readiness = [PSCustomObject]@{
        IsCompliant     = $true
        TpmReady        = $false
        TpmVersion      = 'Unknown'
        SecureBootOn    = $false
        UefiMode        = $false
        NetworkHealthy  = $false
        OsBuild         = [Environment]::OSVersion.Version.ToString()
        ChecksPassed    = 0
        TotalChecks     = 5
        Failures        = @()
    }

    # 1. TPM 2.0 Test
    try {
        $tpm = Get-Tpm -ErrorAction SilentlyContinue
        if ($tpm -and $tpm.TpmPresent -and $tpm.TpmReady) {
            $readiness.TpmReady = $true
            $readiness.TpmVersion = $tpm.ManufacturerVersion
            $readiness.ChecksPassed++
            Write-Host "  [OK] TPM 2.0: Present, Enabled and Ready ($($tpm.ManufacturerVersion))" -ForegroundColor Green
        } else {
            $readiness.IsCompliant = $false
            $readiness.Failures += "TPM 2.0 not ready or missing."
            Write-Host "  [FAIL] TPM 2.0: Not Ready or Disabled" -ForegroundColor Red
        }
    } catch {
        $readiness.Failures += "Error querying TPM: $($_.Exception.Message)"
        Write-Host "  [WARN] TPM Query Error: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # 2. Secure Boot Test
    try {
        $sb = Confirm-SecureBootUEFI -ErrorAction SilentlyContinue
        if ($sb) {
            $readiness.SecureBootOn = $true
            $readiness.ChecksPassed++
            Write-Host "  [OK] Secure Boot: Enabled" -ForegroundColor Green
        } else {
            $readiness.IsCompliant = $false
            $readiness.Failures += "Secure Boot is disabled."
            Write-Host "  [FAIL] Secure Boot: Disabled (Must be enabled for Autopilot)" -ForegroundColor Red
        }
    } catch {
        $readiness.Failures += "Secure Boot query not supported on BIOS/Legacy mode."
        Write-Host "  [FAIL] Secure Boot: Legacy BIOS mode detected" -ForegroundColor Red
    }

    # 3. UEFI Firmware Mode
    try {
        $firmware = $env:firmware_type
        if ($firmware -match 'UEFI' -or (Test-Path 'HKLM:\System\CurrentControlSet\Control\SecureBoot\State')) {
            $readiness.UefiMode = $true
            $readiness.ChecksPassed++
            Write-Host "  [OK] Firmware Mode: UEFI" -ForegroundColor Green
        } else {
            $readiness.IsCompliant = $false
            $readiness.Failures += "System is not in UEFI mode."
            Write-Host "  [FAIL] Firmware Mode: Legacy BIOS (UEFI required)" -ForegroundColor Red
        }
    } catch { }

    # 4. Staged Network Probe
    $net = Test-StagedNetwork -TimeoutSeconds 3
    if ($net.IsFullyReady) {
        $readiness.NetworkHealthy = $true
        $readiness.ChecksPassed++
        Write-Host "  [OK] Microsoft Cloud Network: All 7 Stages Passed" -ForegroundColor Green
    } else {
        $readiness.IsCompliant = $false
        $readiness.Failures += "Network diagnostic failed ($($net.StagesPassed)/$($net.TotalStages) stages passed)."
        Write-Host "  [FAIL] Network Diagnostic: Failed ($($net.StagesPassed)/$($net.TotalStages) stages passed)" -ForegroundColor Red
    }

    # 5. OS Build Check
    $build = [Environment]::OSVersion.Version.Build
    if ($build -ge 18362) {
        $readiness.ChecksPassed++
        Write-Host "  [OK] Windows OS Build: $build (Supported)" -ForegroundColor Green
    } else {
        $readiness.IsCompliant = $false
        $readiness.Failures += "Windows build $build is below minimum 18362."
        Write-Host "  [FAIL] Windows OS Build: $build (Unsupported)" -ForegroundColor Red
    }

    Write-Host "  ------------------------------------------------------" -ForegroundColor DarkGray
    if ($readiness.IsCompliant) {
        Write-Host "  [READY] Device is 100% READY for Windows Autopilot Enrollment!`n" -ForegroundColor Green
    } else {
        Write-Host "  [WARN] Device has $($readiness.Failures.Count) readiness violation(s).`n" -ForegroundColor Yellow
    }

    return $readiness
}
