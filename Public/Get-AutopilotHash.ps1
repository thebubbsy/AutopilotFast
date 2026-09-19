<#
.SYNOPSIS
    Extracts and structurally validates the genuine Windows Autopilot 4K-8K hardware hash.
.DESCRIPTION
    Queries the official MDM WMI provider (root/cimv2/mdm/dmmap:MDM_DevDetail_Ext01) for the
    complete hardware hash. Validates the Base64 payload as an OA3 (OEM Activation 3.0) binary blob:
    the 4-byte magic 'OA3\0' (0x4F 0x41 0x33 0x00 - the familiar "T0EzAA" Base64 prefix) followed by
    a 2048-16384 byte body. The OA3 blob is NOT ASN.1 DER; it is a proprietary Microsoft structure,
    so no deeper parsing is attempted. Throws [AutopilotHashParseException] on any structural violation.
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

    # OA3 Hardware Hash Structural Validator
    function Test-AutopilotHashStructure {
        param(
            [Parameter(Mandatory = $true)]
            [string]$HashString
        )

        # 1. Null / Whitespace check
        if ([string]::IsNullOrWhiteSpace($HashString)) {
            throw [AutopilotHashParseException]::new(
                "Hardware hash string is null, empty, or whitespace.",
                "EmptyPayload"
            )
        }

        $clean = $HashString.Trim()

        # 2. Base64 Charset & Multiple-of-4 Validation
        if ($clean -notmatch '^[A-Za-z0-9+/=]+$' -or ($clean.Length % 4 -ne 0)) {
            throw [AutopilotHashParseException]::new(
                "Hardware hash string failed Base64 validation (invalid character set or length not a multiple of 4).",
                "InvalidBase64Encoding"
            )
        }

        # 3. Base64 Binary Decoding
        [byte[]]$bytes = $null
        try {
            $bytes = [Convert]::FromBase64String($clean)
        }
        catch [System.FormatException] {
            throw [AutopilotHashParseException]::new(
                "Failed to decode Base64 hardware hash: $($_.Exception.Message)",
                "InvalidBase64Encoding",
                $_.Exception
            )
        }

        $totalBytes = $bytes.Length
        $magic = [byte[]](0x4F, 0x41, 0x33, 0x00)   # 'OA3\0'

        # 4. Truncated Header Check
        if ($totalBytes -lt $magic.Length) {
            $firstByte = if ($totalBytes -gt 0) { $bytes[0] } else { [byte]0 }
            throw [AutopilotHashParseException]::new(
                "Hardware hash stream is truncated ($totalBytes bytes); the OA3 header requires at least $($magic.Length) bytes.",
                "TruncatedHeader",
                $totalBytes,
                $magic.Length,
                $firstByte
            )
        }

        # 5. OA3 Magic Validation ('OA3\0' => Base64 prefix "T0EzAA")
        for ($i = 0; $i -lt $magic.Length; $i++) {
            if ($bytes[$i] -ne $magic[$i]) {
                $tagHex = "0x" + $bytes[0].ToString("X2")
                throw [AutopilotHashParseException]::new(
                    "Invalid hardware hash header (first byte $tagHex). Expected OA3 magic bytes 4F 41 33 00 ('OA3'); this is not an OEM Activation 3.0 hardware blob.",
                    "InvalidOA3Magic",
                    $totalBytes,
                    0,
                    $bytes[0]
                )
            }
        }

        # 6. Total Length Bounds (2048 - 16384 bytes; 4K blobs are typical, 8K for TPM-attested devices)
        if ($totalBytes -lt 2048 -or $totalBytes -gt 16384) {
            throw [AutopilotHashParseException]::new(
                "Hardware hash length ($totalBytes bytes) is outside the valid Autopilot 4K/8K range (2048 - 16384 bytes).",
                "PayloadOutOfBounds",
                $totalBytes,
                2048,
                $bytes[0]
            )
        }

        return $true
    }

    $hardwareHash = ''
    $statusMessage = 'Captured'

    # Check for Active Test Mock State
    $mockHash = $null
    if (Get-Command -Name 'Get-AutopilotMockHardwareHash' -ErrorAction SilentlyContinue) {
        $mockHash = Get-AutopilotMockHardwareHash
    }
    if ($null -eq $mockHash -and $null -ne $global:__AutopilotMockHardwareHash) {
        $mockHash = $global:__AutopilotMockHardwareHash
    }
    if ($null -eq $mockHash -and $null -ne $env:AUTOPILOT_MOCK_HARDWARE_HASH) {
        $mockHash = $env:AUTOPILOT_MOCK_HARDWARE_HASH
    }

    if ($null -ne $mockHash) {
        Test-AutopilotHashStructure -HashString $mockHash | Out-Null
        $hardwareHash = $mockHash.Trim()
        $statusMessage = 'Captured'
    }

    $serial = ''
    $uuid = ''
    $model = ''
    $manufacturer = ''
    $pkid = ''

    # 1. Ensure dmwappushservice is enabled and running (if not using mock)
    if (-not $hardwareHash) {
        try {
            $svc = Get-Service -Name 'dmwappushservice' -ErrorAction SilentlyContinue
            if ($svc) {
                if ($svc.StartType -eq 'Disabled') {
                    Set-Service -Name 'dmwappushservice' -StartupType Automatic -ErrorAction SilentlyContinue
                }
                if ($svc.Status -ne 'Running') {
                    Start-Service -Name 'dmwappushservice' -ErrorAction SilentlyContinue
                }
            }
        } catch { }
    }

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

    # 4. Live Hardware Hash Extraction with Backoff Loop (if mock not set)
    if (-not $hardwareHash) {
        $maxAttempts = 10
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            try {
                $devDetail = Get-CimInstance -Namespace 'root/cimv2/mdm/dmmap' -ClassName 'MDM_DevDetail_Ext01' -Filter "InstanceID='Ext01' AND ParentID='./DevDetail'" -ErrorAction Stop
                $rawHash = $devDetail.DeviceHardwareData
                if ($rawHash) {
                    Test-AutopilotHashStructure -HashString $rawHash | Out-Null
                    $hardwareHash = $rawHash.Trim()
                    break
                }
            }
            catch {
                if ($_.Exception -is [AutopilotHashParseException]) {
                    throw $_.Exception
                }
                try {
                    $devDetailWmi = Get-WmiObject -Namespace 'root/cimv2/mdm/dmmap' -Class 'MDM_DevDetail_Ext01' -Filter "InstanceID='Ext01' AND ParentID='./DevDetail'" -ErrorAction Stop
                    $rawHash = $devDetailWmi.DeviceHardwareData
                    if ($rawHash) {
                        Test-AutopilotHashStructure -HashString $rawHash | Out-Null
                        $hardwareHash = $rawHash.Trim()
                        break
                    }
                }
                catch {
                    if ($_.Exception -is [AutopilotHashParseException]) {
                        throw $_.Exception
                    }
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

    # 5. Cache Captured Hash Locally
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
