<#
.SYNOPSIS
    Extracts the genuine Windows Autopilot 4K-8K hardware hash and device telemetry.
.DESCRIPTION
    Queries the official MDM WMI provider (root/cimv2/mdm/dmmap:MDM_DevDetail_Ext01) for the
    complete hardware hash. Captures Serial Number, SMBIOS UUID, and Windows Product ID.
    Enforces the "Capture Once, Never Lose" invariant: caches to local disk on successful harvest.
.PARAMETER GroupTag
    Optional Autopilot GroupTag / OrderIdentifier.
.PARAMETER AssignedUser
    Optional UPN to assign to this hardware in Intune.
.PARAMETER Format
    Output format: Object, Csv, or Json.
.EXAMPLE
    Get-AutopilotHash -GroupTag "Dev-Laptops"
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

    # 1. Retrieve BIOS and System Product info via CIM
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

    # 2. Retrieve Product ID from Registry
    try {
        $regKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $pkid = (Get-ItemProperty -Path $regKey -Name ProductId -ErrorAction SilentlyContinue).ProductId
    } catch { }

    # 3. Retrieve Hardware Hash from MDM DevDetail
    try {
        $devDetail = Get-CimInstance -Namespace 'root/cimv2/mdm/dmmap' -ClassName 'MDM_DevDetail_Ext01' -Filter "InstanceID='Ext01' AND ParentID='./DevDetail'" -ErrorAction Stop
        $hardwareHash = $devDetail.DeviceHardwareData
    }
    catch {
        # Fallback to WmiObject if CIM namespace needs legacy binding
        try {
            $devDetailWmi = Get-WmiObject -Namespace 'root/cimv2/mdm/dmmap' -Class 'MDM_DevDetail_Ext01' -Filter "InstanceID='Ext01' AND ParentID='./DevDetail'" -ErrorAction Stop
            $hardwareHash = $devDetailWmi.DeviceHardwareData
        }
        catch {
            if (-not $isAdmin) {
                $statusMessage = "AccessDenied (Administrator privileges required to query MDM WMI provider)"
            } else {
                $statusMessage = "MDM_Provider_Uninitialized (MDM stack not yet initialized in current boot state: $($_.Exception.Message))"
            }
        }
    }

    # 4. Cache Captured Hash Locally (Capture Once, Never Lose)
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
