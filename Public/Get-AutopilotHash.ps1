<#
.SYNOPSIS
    Extracts the genuine Windows Autopilot 4K-8K hardware hash and device telemetry.
.DESCRIPTION
    Queries the official MDM WMI provider (root/cimv2/mdm/dmmap:MDM_DevDetail_Ext01) for the
    complete hardware hash. Includes automatic dmwappushservice recovery and a 10-attempt backoff loop.
#>
function Get-AutopilotHash {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$GroupTag = '',

        [Parameter()]
        [string]$AssignedUser = '',

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

    $serial = ''
    $uuid = ''
    $model = ''
    $manufacturer = ''
    $hardwareHash = ''
    $pkid = ''
    $statusMessage = 'Captured'

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

    # 4. Retrieve Hardware Hash with 10-Attempt Backoff Loop
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
                    if (-not $isAdmin) {
                        $statusMessage = "AccessDenied (Administrator privileges required to query MDM WMI provider)"
                    } else {
                        $statusMessage = "MDM_Provider_Uninitialized (MDM stack not yet initialized after $maxAttempts attempts: $($_.Exception.Message))"
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
