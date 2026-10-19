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
        [switch]$Append,

        [Parameter()]
        [switch]$CopyPath,

        [Parameter()]
        [switch]$CopyReceipt,

        [Parameter()]
        [switch]$CopyTsv,

        [Parameter()]
        [switch]$Quiet
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
        $storageMedia = 'Local Disk'
        if ($AutoDetectUsb) {
            try {
                $usbDrives = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=2" -ErrorAction SilentlyContinue)
                if ($usbDrives.Count -gt 0) {
                    $driveLetter = $usbDrives[0].DeviceID
                    $targetPath = Join-Path $driveLetter "Autopilot-Hashes.csv"
                    $storageMedia = "USB Removable ($driveLetter)"
                    if (-not $Quiet) {
                        Write-Host ("  [+] USB Drive detected (" + $driveLetter + "). Targeting: " + $targetPath) -ForegroundColor Cyan
                    }
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

        $fileItem = Get-Item $targetPath
        $totalRecords = [Math]::Max(0, @(Get-Content -Path $fileItem.FullName -ErrorAction SilentlyContinue).Count - 1)
        $sizeKb = [Math]::Round($fileItem.Length / 1KB, 2)
        $firstSerial = if ($items[0] -and $items[0].SerialNumber) { $items[0].SerialNumber } else { 'N/A' }
        $effectiveTag = if ($items[0] -and $items[0].GroupTag) { $items[0].GroupTag } elseif ($GroupTag) { $GroupTag } else { '(none)' }
        $writeMode = if ($Append -and $fileExists) { 'Appended' } else { 'Created / Overwritten' }

        if ($CopyPath) {
            try { Set-Clipboard -Value $fileItem.FullName -ErrorAction SilentlyContinue } catch { }
        }

        if ($CopyTsv) {
            $tsvLines = [System.Collections.Generic.List[string]]::new()
            $tsvLines.Add("SerialNumber`tProductId`tGroupTag`tAssignedUser`tDestinationCsv")
            foreach ($item in $items) {
                $gt = if ($item.GroupTag) { $item.GroupTag } else { $GroupTag }
                $au = if ($item.AssignedUser) { $item.AssignedUser } else { $AssignedUser }
                $tsvLines.Add("$($item.SerialNumber)`t$($item.WindowsProductID)`t$gt`t$au`t$($fileItem.FullName)")
            }
            try { Set-Clipboard -Value ($tsvLines -join [Environment]::NewLine) -ErrorAction SilentlyContinue } catch { }
        }

        if ($CopyReceipt) {
            $mdLines = @(
                "### Autopilot CSV Harvest Receipt",
                "| Property | Value |",
                "| :--- | :--- |",
                "| **Destination** | ``$($fileItem.FullName)`` |",
                "| **Storage Media** | $storageMedia ($writeMode) |",
                "| **Batch Count** | $($items.Count) device(s) |",
                "| **Total CSV Rows** | $totalRecords row(s) ($sizeKb KB) |",
                "| **Lead Serial** | ``$firstSerial`` |",
                "| **Group Tag** | ``$effectiveTag`` |"
            )
            try { Set-Clipboard -Value ($mdLines -join [Environment]::NewLine) -ErrorAction SilentlyContinue } catch { }
        }

        if (-not $Quiet) {
            Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkCyan
            Write-Host "  | AUTOPILOT CSV HARVEST RECEIPT                                        |" -ForegroundColor Cyan
            Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkCyan
            Write-Host ("  | Destination : {0,-54} |" -f $fileItem.FullName) -ForegroundColor Gray
            Write-Host ("  | Storage     : {0,-24} Mode  : {1,-21} |" -f $storageMedia, $writeMode) -ForegroundColor Gray
            Write-Host ("  | Batch Count : {0,-24} Total : {1,-21} |" -f "$($items.Count) device(s)", "$totalRecords row(s) ($sizeKb KB)") -ForegroundColor Green
            Write-Host ("  | Lead Serial : {0,-24} Tag   : {1,-21} |" -f $firstSerial, $effectiveTag) -ForegroundColor Gray
            if ($CopyPath) {
                Write-Host "  | [CLIPBOARD] Full CSV file path copied to system clipboard.           |" -ForegroundColor Green
            }
            if ($CopyTsv) {
                Write-Host "  | [CLIPBOARD] Tab-separated device rows copied to system clipboard.    |" -ForegroundColor Green
            }
            if ($CopyReceipt) {
                Write-Host "  | [CLIPBOARD] Markdown harvest receipt table copied to clipboard.      |" -ForegroundColor Green
            }
            Write-Host "  +----------------------------------------------------------------------+" -ForegroundColor DarkCyan
        }

        return $fileItem
    }
}
