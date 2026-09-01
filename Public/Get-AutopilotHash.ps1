<#
.SYNOPSIS
    Extracts the genuine Windows Autopilot 4K-8K hardware hash and device telemetry.
.DESCRIPTION
    Queries the official MDM WMI provider (root/cimv2/mdm/dmmap:MDM_DevDetail_Ext01) for the
    complete hardware hash. Supports validated manual hash override (-ManualHash) for VMs and lab testing,
    automatic dmwappushservice recovery, and a 10-attempt backoff loop.
#>
function Get-AutopilotHash {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$GroupTag = '',

        [Parameter()]
        [string]$AssignedUser = '',

        [Parameter()]
        [string]$ManualHash = '',

        [Parameter()]
        [ValidateSet('Object', 'Csv', 'Json')]
        [string]$Format = 'Object'
    )

    $isAdmin = $false
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { }

    # Validate ManualHash format if provided
    if ($ManualHash) {
        $cleanHash = $ManualHash.Trim()
        $isBase64 = ($cleanHash -match '^[A-Za-z0-9+/=]+$')
        $isValidLength = ($cleanHash.Length -ge 500 -and $cleanHash.Length -le 16000)

        if (-not $isBase64 -or -not $isValidLength) {
            throw "Invalid ManualHash format. Autopilot 4K/8K hardware hashes must be valid Base64 strings between 500 and 16,000 characters (Received: $($cleanHash.Length) chars)."
        }
        $hardwareHash = $cleanHash
        $statusMessage = 'ManualOverride (Validated)'
    } else {
        $hardwareHash = ''
        $statusMessage = 'Captured'
    }

    $serial = ''
    $uuid = ''
    $model = ''
    $manufacturer = ''
    $pkid = ''

    # 1. Ensure dmwappushservice is enabled and running
    try {
        $svc = Get-Service -Name 'dmwappushservice' -ErrorAction SilentlyContinue
        if ($svc) {
            if ($svc.StartType -eq 'Disabled') {
                Write-Host "  [+] Configuring dmwappushservice startup to Automatic..." -ForegroundColor Cyan
                Set-Service -Name 'dmwappushservice' -StartupType Automatic -ErrorAction SilentlyContinue
            }
            if ($svc.Status -ne 'Running') {
                Write-Host "  [+] Starting dmwappushservice for MDM WMI provider initialization..." -ForegroundColor Cyan
                Start-Service -Name 'dmwappushservice' -ErrorAction SilentlyContinue
            }
        }
    } catch { }

    # 2. Retrieve BIOS and System Product info via CIM
    try {
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
        $serial = $bios.SerialNumber
    } catch {
        $serial = (Get-WmiObject -Class Win32_BIOS -ErrorAction SilentlyContinue).SerialNumber
    }

    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $model = $cs.Model
        $manufacturer = $cs.Manufacturer
    } catch { }

    try {
        $csp = Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop
        $uuid = $csp.UUID
    } catch { }

    # 3. Retrieve Product ID from Registry
    try {
        $regKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $pkid = (Get-ItemProperty -Path $regKey -Name ProductId -ErrorAction SilentlyContinue).ProductId
    } catch { }

    # 4. Retrieve Hardware Hash with 10-Attempt Backoff Loop (if not manual)
    if (-not $hardwareHash) {
        $maxAttempts = 10
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            try {
                $devDetail = Get-CimInstance -Namespace 'root/cimv2/mdm/dmmap' -ClassName 'MDM_DevDetail_Ext01' -Filter "InstanceID='Ext01' AND ParentID='./DevDetail'" -ErrorAction Stop
                $hardwareHash = $devDetail.DeviceHardwareData
                if ($hardwareHash) { break }
            }
            catch {
                try {
                    $devDetailWmi = Get-WmiObject -Namespace 'root/cimv2/mdm/dmmap' -Class 'MDM_DevDetail_Ext01' -Filter "InstanceID='Ext01' AND ParentID='./DevDetail'" -ErrorAction Stop
                    $hardwareHash = $devDetailWmi.DeviceHardwareData
                    if ($hardwareHash) { break }
                }
                catch {
                    if ($attempt -lt $maxAttempts) {
                        Start-Sleep -Seconds 5
                    } else {
                        $isVm = ($model -match 'Virtual|VMware|Hyper-V|KVM|QEMU' -or $manufacturer -match 'Microsoft Corporation|VMware|QEMU')
                        if ($isVm) {
                            $statusMessage = "VirtualMachine_NonOA3 (VM detected without OEM OA3 injection. Use -ManualHash or enable Virtual TPM 2.0 / Autopilot v2 Device Preparation)"
                        } elseif (-not $isAdmin) {
                            $statusMessage = "AccessDenied (Administrator privileges required to query MDM WMI provider)"
                        } else {
                            $statusMessage = "MDM_Provider_Uninitialized (MDM stack not yet initialized after $maxAttempts attempts: $($_.Exception.Message))"
                        }
                    }
                }
            }
        }
    }

    # 5. Cache Captured Hash Locally (Capture Once, Never Lose)
    if ($hardwareHash) {
        try {
            $cacheDir = Join-Path $env:TEMP "AutopilotFast"
            if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }
            $cacheFile = Join-Path $cacheDir "last_hardware_hash.bin"
            [System.IO.File]::WriteAllText($cacheFile, $hardwareHash)
        } catch { }
    }

    $result = [PSCustomObject]@{
        SerialNumber       = $serial
        SmbiosUuid         = $uuid
        Manufacturer       = $manufacturer
        Model              = $model
        WindowsProductID   = $pkid
        GroupTag           = $GroupTag
        AssignedUser       = $AssignedUser
        HardwareHash       = $hardwareHash
        HardwareHashStatus = $statusMessage
        HashLengthBytes    = if ($hardwareHash) { $hardwareHash.Length } else { 0 }
        IsElevated         = $isAdmin
        CaptureTimestamp   = (Get-Date).ToString('o')
    }

    switch ($Format) {
        'Csv' {
            return "$serial,$pkid,$hardwareHash,$GroupTag,$AssignedUser"
        }
        'Json' {
            return ($result | ConvertTo-Json -Depth 5)
        }
        Default {
            return $result
        }
    }
}
