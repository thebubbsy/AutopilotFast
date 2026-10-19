<#
.SYNOPSIS
    Performs comprehensive pre-flight hardware and cloud readiness checks for Windows Autopilot.
.DESCRIPTION
    Validates TPM 2.0 readiness, Secure Boot state, UEFI mode, and 7-stage network health.
#>
function Test-AutopilotReadiness {
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$CopyReport,

        [Parameter()]
        [switch]$Quiet
    )

    if (-not $Quiet) {
        Write-Host "`n  [AutopilotFast] Hardware and Cloud Pre-Flight Readiness" -ForegroundColor Cyan
        Write-Host "  ------------------------------------------------------" -ForegroundColor DarkGray
    }

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
            if (-not $Quiet) { Write-Host "  [OK] TPM 2.0: Present, Enabled and Ready ($($tpm.ManufacturerVersion))" -ForegroundColor Green }
        } else {
            $readiness.IsCompliant = $false
            $readiness.Failures += "TPM 2.0 not ready or missing."
            if (-not $Quiet) { Write-Host "  [FAIL] TPM 2.0: Not Ready or Disabled" -ForegroundColor Red }
        }
    } catch {
        $readiness.Failures += "Error querying TPM: $($_.Exception.Message)"
        if (-not $Quiet) { Write-Host "  [WARN] TPM Query Error: $($_.Exception.Message)" -ForegroundColor Yellow }
    }

    # 2. Secure Boot Test
    try {
        $sb = Confirm-SecureBootUEFI -ErrorAction SilentlyContinue
        if ($sb) {
            $readiness.SecureBootOn = $true
            $readiness.ChecksPassed++
            if (-not $Quiet) { Write-Host "  [OK] Secure Boot: Enabled" -ForegroundColor Green }
        } else {
            $readiness.IsCompliant = $false
            $readiness.Failures += "Secure Boot is disabled."
            if (-not $Quiet) { Write-Host "  [FAIL] Secure Boot: Disabled (Must be enabled for Autopilot)" -ForegroundColor Red }
        }
    } catch {
        $readiness.Failures += "Secure Boot query not supported on BIOS/Legacy mode."
        if (-not $Quiet) { Write-Host "  [FAIL] Secure Boot: Legacy BIOS mode detected" -ForegroundColor Red }
    }

    # 3. UEFI Firmware Mode
    try {
        $firmware = $env:firmware_type
        if ($firmware -match 'UEFI' -or (Test-Path 'HKLM:\System\CurrentControlSet\Control\SecureBoot\State')) {
            $readiness.UefiMode = $true
            $readiness.ChecksPassed++
            if (-not $Quiet) { Write-Host "  [OK] Firmware Mode: UEFI" -ForegroundColor Green }
        } else {
            $readiness.IsCompliant = $false
            $readiness.Failures += "System is not in UEFI mode."
            if (-not $Quiet) { Write-Host "  [FAIL] Firmware Mode: Legacy BIOS (UEFI required)" -ForegroundColor Red }
        }
    } catch { }

    # 4. Staged Network Probe
    $net = Test-StagedNetwork -TimeoutSeconds 3
    if ($net.IsFullyReady) {
        $readiness.NetworkHealthy = $true
        $readiness.ChecksPassed++
        if (-not $Quiet) { Write-Host "  [OK] Microsoft Cloud Network: All 7 Stages Passed" -ForegroundColor Green }
    } else {
        $readiness.IsCompliant = $false
        $readiness.Failures += "Network diagnostic failed ($($net.StagesPassed)/$($net.TotalStages) stages passed)."
        if (-not $Quiet) { Write-Host "  [FAIL] Network Diagnostic: Failed ($($net.StagesPassed)/$($net.TotalStages) stages passed)" -ForegroundColor Red }
    }

    # 5. OS Build Check
    $build = [Environment]::OSVersion.Version.Build
    if ($build -ge 18362) {
        $readiness.ChecksPassed++
        if (-not $Quiet) { Write-Host "  [OK] Windows OS Build: $build (Supported)" -ForegroundColor Green }
    } else {
        $readiness.IsCompliant = $false
        $readiness.Failures += "Windows build $build is below minimum 18362."
        if (-not $Quiet) { Write-Host "  [FAIL] Windows OS Build: $build (Unsupported)" -ForegroundColor Red }
    }

    $pct = [Math]::Round(($readiness.ChecksPassed / $readiness.TotalChecks) * 100)
    $filled = $readiness.ChecksPassed * 2
    $empty = ($readiness.TotalChecks * 2) - $filled
    $bar = ('#' * $filled) + ('-' * $empty)
    $barColor = if ($readiness.IsCompliant) { 'Green' } elseif ($readiness.ChecksPassed -ge 3) { 'Yellow' } else { 'Red' }

    if (-not $Quiet) {
        $verdictStr = if ($readiness.IsCompliant) { 'COMPLIANT (READY FOR AUTOPILOT)' } else { "NON-COMPLIANT ($($readiness.Failures.Count) VIOLATION(S))" }
        $scoreStr = "[$bar] $pct% ($($readiness.ChecksPassed)/$($readiness.TotalChecks) passed)"
        Write-Host ""
        Write-Host "  +------------------------------------------------------------------+" -ForegroundColor DarkCyan
        Write-Host "  |  [AutopilotFast] Pre-Flight Readiness Posture Summary            |" -ForegroundColor Cyan
        Write-Host "  +------------------------------------------------------------------+" -ForegroundColor DarkCyan
        Write-Host ("  |  Verdict         : {0,-46}|" -f $verdictStr) -ForegroundColor $barColor
        Write-Host ("  |  Readiness Score : {0,-46}|" -f $scoreStr) -ForegroundColor $barColor
        Write-Host ("  |  TPM 2.0         : {0,-46}|" -f ("$($readiness.TpmReady) ($($readiness.TpmVersion))")) -ForegroundColor Gray
        Write-Host ("  |  Secure Boot     : {0,-46}|" -f ("$($readiness.SecureBootOn) (UEFI=$($readiness.UefiMode))")) -ForegroundColor Gray
        Write-Host ("  |  Cloud Network   : {0,-46}|" -f ("$($readiness.NetworkHealthy) ($($net.StagesPassed)/$($net.TotalStages) stages)")) -ForegroundColor Gray
        Write-Host ("  |  Windows Build   : {0,-46}|" -f ("$build ($($readiness.OsBuild))")) -ForegroundColor Gray
        Write-Host "  +------------------------------------------------------------------+" -ForegroundColor DarkCyan
        Write-Host "  Posture Summary : UEFI=$($readiness.UefiMode) | SecureBoot=$($readiness.SecureBootOn) | TPM=$($readiness.TpmReady) | Net=$($readiness.NetworkHealthy) | Build=$build" -ForegroundColor Gray
        if ($readiness.IsCompliant) {
            Write-Host "  [READY] Device is 100% READY for Windows Autopilot Enrollment!`n" -ForegroundColor Green
        } else {
            Write-Host "  [WARN] Device has $($readiness.Failures.Count) readiness violation(s).`n" -ForegroundColor Yellow
        }
    }

    if ($CopyReport) {
        $mdReport = @(
            "### AutopilotFast Pre-Flight Readiness Report",
            "| Check | Status | Details |",
            "| :--- | :--- | :--- |",
            "| **Overall Verdict** | $($readiness.IsCompliant) | $pct% ($($readiness.ChecksPassed)/$($readiness.TotalChecks) passed) |",
            "| **TPM 2.0** | $($readiness.TpmReady) | Version: $($readiness.TpmVersion) |",
            "| **Secure Boot** | $($readiness.SecureBootOn) | UEFI Mode: $($readiness.UefiMode) |",
            "| **Cloud Network** | $($readiness.NetworkHealthy) | $($net.StagesPassed)/$($net.TotalStages) Stages Passed |",
            "| **Windows OS Build** | $build | $($readiness.OsBuild) |"
        ) -join [Environment]::NewLine
        try {
            Set-Clipboard -Value $mdReport -ErrorAction Stop
            if (-not $Quiet) {
                Write-Host "  [CLIPBOARD] Copied Markdown Readiness Report to clipboard.`n" -ForegroundColor Cyan
            }
        } catch {
            Write-Verbose "Clipboard copy failed: $($_.Exception.Message)"
        }
    }

    return $readiness
}
