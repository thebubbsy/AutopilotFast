<#
.SYNOPSIS
    Extracts and structurally validates the genuine Windows Autopilot 4K-8K hardware hash.
.DESCRIPTION
    Queries the official MDM WMI provider (root/cimv2/mdm/dmmap:MDM_DevDetail_Ext01) for the
    complete hardware hash. Supports structurally verified manual hash override (-ManualHash)
    for lab testing, automatic dmwappushservice recovery, and a 10-attempt backoff loop.
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

    # Structural Validation of Hardware Hash (Base64 + Binary Length + ASN.1 DER Header Check)
    function Test-AutopilotHashStructure {
        param([string]$HashString)
        if ([string]::IsNullOrWhiteSpace($HashString)) { return $false }
        
        $clean = $HashString.Trim()
        if ($clean -notmatch '^[A-Za-z0-9+/=]+$') {
            throw "Hardware hash failed Base64 charset validation."
        }

        try {
            $bytes = [Convert]::FromBase64String($clean)
            $byteLen = $bytes.Length

            # Valid OA3 / MDM Autopilot hashes are binary blobs between 1KB and 16KB
            if ($byteLen -lt 1024 -or $byteLen -gt 16384) {
                throw "Hardware hash decoded length ($byteLen bytes) is outside valid Autopilot 4K/8K specification (1024 - 16384 bytes)."
            }

            # Verify standard OA3 / ASN.1 DER sequence header (0x30 or device hardware descriptor tag)
            $headerByte = $bytes[0]
            if ($headerByte -ne 0x30 -and $headerByte -ne 0x01 -and $headerByte -ne 0x02) {
                Write-Warning "Hardware hash header byte (0x$($headerByte.ToString('X2'))) does not match standard ASN.1 DER / OA3 descriptor structure."
            }

            return $true
        }
        catch {
            throw "Autopilot hardware hash structural verification failed: $($_.Exception.Message)"
        }
    }

    if ($ManualHash) {
        Test-AutopilotHashStructure -HashString $ManualHash | Out-Null
        $hardwareHash = $ManualHash.Trim()
        $statusMessage = 'ManualOverride (Structurally Verified)'
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
                $rawHash = $devDetail.DeviceHardwareData
                if ($rawHash) {
                    Test-AutopilotHashStructure -HashString $rawHash | Out-Null
                    $hardwareHash = $rawHash
                    break
                }
            }
            catch {
                try {
                    $devDetailWmi = Get-WmiObject -Namespace 'root/cimv2/mdm/dmmap' -Class 'MDM_DevDetail_Ext01' -Filter "InstanceID='Ext01' AND ParentID='./DevDetail'" -ErrorAction Stop
                    $rawHash = $devDetailWmi.DeviceHardwareData
                    if ($rawHash) {
                        Test-AutopilotHashStructure -HashString $rawHash | Out-Null
                        $hardwareHash = $rawHash
                        break
                    }
                }
                catch {
                    if ($attempt -lt $maxAttempts) {
                        Start-Sleep -Seconds 5
                    } else {
                        $isVm = ($model -match 'Virtual|VMware|Hyper-V|KVM|QEMU' -or $manufacturer -match 'Microsoft Corporation|VMware|QEMU')
                        if ($isVm) {
                            $statusMessage = "VirtualMachine_NonOA3 (VM detected without OEM OA3 injection. Use Virtual TPM 2.0 or Autopilot v2 Device Preparation)"
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
