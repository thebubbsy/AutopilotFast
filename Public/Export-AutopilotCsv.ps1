<#
.SYNOPSIS
    Exports Autopilot device information into standard Microsoft Intune CSV format.
.DESCRIPTION
    Creates or appends device records to an Intune-compatible Autopilot import CSV file.
    Supports auto-detecting USB flash drives for field technician harvesting in OOBE.
.PARAMETER Path
    Path to destination CSV file.
.PARAMETER Append
    Append to existing CSV without rewriting header.
.PARAMETER GroupTag
    Autopilot GroupTag to assign.
.PARAMETER AssignedUser
    User UPN to assign.
.PARAMETER AutoDetectUsb
    Automatically searches for attached USB removable drives and writes to \Autopilot-Hashes.csv.
.EXAMPLE
    Get-AutopilotHash | Export-AutopilotCsv -Path .\devices.csv
#>
function Export-AutopilotCsv {
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(ParameterSetName = 'Path', Position = 0)]
        [string]$Path = '.\Autopilot-Devices.csv',

        [Parameter(ParameterSetName = 'Usb')]
        [switch]$AutoDetectUsb,

        [Parameter(ValueFromPipeline = $true)]
        [PSCustomObject]$InputObject,

        [Parameter()]
        [string]$GroupTag = '',

        [Parameter()]
        [string]$AssignedUser = '',

        [Parameter()]
        [switch]$Append
    )

    begin {
        $header = 'Device Serial Number,Windows Product ID,Hardware Hash,Group Tag,Assigned User'
        $items = [System.Collections.Generic.List[PSCustomObject]]::new()
    }

    process {
        if ($InputObject) {
            $items.Add($InputObject)
        }
    }

    end {
        if ($items.Count -eq 0) {
            $currentHash = Get-AutopilotHash -GroupTag $GroupTag -AssignedUser $AssignedUser
            $items.Add($currentHash)
        }

        # Handle USB Auto-Detection
        $targetPath = $Path
        if ($AutoDetectUsb) {
            try {
                $usbDrives = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=2" -ErrorAction SilentlyContinue)
                if ($usbDrives.Count -gt 0) {
                    $driveLetter = $usbDrives[0].DeviceID
                    $targetPath = Join-Path $driveLetter "Autopilot-Hashes.csv"
                    Write-Host ("  [+] USB Drive detected (" + $driveLetter + "). Targeting: " + $targetPath) -ForegroundColor Cyan
                    $Append = $true
                } else {
                    Write-Warning ("No USB flash drive detected. Falling back to " + $targetPath)
                }
            } catch { }
        }

        $targetDir = Split-Path -Path $targetPath -Parent
        if ($targetDir -and -not (Test-Path $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }

        $fileExists = Test-Path $targetPath
        $lines = [System.Collections.Generic.List[string]]::new()

        if (-not $fileExists -or -not $Append) {
            $lines.Add($header)
        }

        foreach ($item in $items) {
            $gt = if ($item.GroupTag) { $item.GroupTag } else { $GroupTag }
            $au = if ($item.AssignedUser) { $item.AssignedUser } else { $AssignedUser }
            $line = $item.SerialNumber + "," + $item.WindowsProductID + "," + $item.HardwareHash + "," + $gt + "," + $au
            $lines.Add($line)
        }

        if ($Append -and $fileExists) {
            $lines | Out-File -FilePath $targetPath -Append -Encoding utf8
        } else {
            $lines | Out-File -FilePath $targetPath -Force -Encoding utf8
        }

        Write-Host ("  [OK] Exported " + $items.Count + " device(s) to: " + $targetPath) -ForegroundColor Green
        return (Get-Item $targetPath)
    }
}
