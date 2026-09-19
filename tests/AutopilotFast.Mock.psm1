<#
.SYNOPSIS
    AutopilotFast Test Mock Module for isolated unit and CI test execution.
.DESCRIPTION
    Provides mock state injection and synthetic OA3 hardware hash generator
    utilities, allowing test harnesses to supply valid, boundary, and corrupted
    payloads without requiring live MDM WMI providers or administrative elevation.
#>

$script:MockHardwareHash = $null

function Set-AutopilotMockHardwareHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Hash
    )
    $script:MockHardwareHash = $Hash
    $global:__AutopilotMockHardwareHash = $Hash
    $env:AUTOPILOT_MOCK_HARDWARE_HASH = $Hash
}

function Get-AutopilotMockHardwareHash {
    [CmdletBinding()]
    param()
    if ($null -ne $script:MockHardwareHash) {
        return $script:MockHardwareHash
    }
    if ($null -ne $global:__AutopilotMockHardwareHash) {
        return $global:__AutopilotMockHardwareHash
    }
    if ($null -ne $env:AUTOPILOT_MOCK_HARDWARE_HASH) {
        return $env:AUTOPILOT_MOCK_HARDWARE_HASH
    }
    return $null
}

function Clear-AutopilotMockHardwareHash {
    [CmdletBinding()]
    param()
    $script:MockHardwareHash = $null
    $global:__AutopilotMockHardwareHash = $null
    Remove-Item -Path 'env:AUTOPILOT_MOCK_HARDWARE_HASH' -ErrorAction SilentlyContinue
}

function New-AutopilotSyntheticHardwareHash {
    <#
    .SYNOPSIS
        Builds a Base64 blob shaped like a real OA3 hardware hash: 4-byte magic 'OA3\0' + deterministic body.
    .PARAMETER LengthBytes
        Total decoded length in bytes (magic included). Real devices produce ~4096 (4K) or ~8192 (8K).
    .PARAMETER HeaderByte
        Overrides the first magic byte (0x4F) to fabricate an invalid header, e.g. 0x30 for an ASN.1-looking blob.
    .PARAMETER Variant
        'Valid' (default), 'BadMagic' (all four magic bytes wrong) or 'TruncatedHeader' (3-byte stream).
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [int]$LengthBytes = 4096,

        [Parameter()]
        [byte]$HeaderByte = 0x4F,

        [Parameter()]
        [ValidateSet('Valid', 'BadMagic', 'TruncatedHeader')]
        [string]$Variant = 'Valid'
    )

    [System.Collections.Generic.List[byte]]$blob = [System.Collections.Generic.List[byte]]::new()

    switch ($Variant) {
        'TruncatedHeader' {
            $blob.AddRange([byte[]](0x4F, 0x41, 0x33))
        }
        'BadMagic' {
            $blob.AddRange([byte[]](0xDE, 0xAD, 0xBE, 0xEF))
            for ($i = 4; $i -lt $LengthBytes; $i++) { $blob.Add([byte](($i * 31 + 17) % 256)) }
        }
        Default {
            # magic + little-endian version word 0x0001, as real blobs carry (Base64 prefix "T0EzAAEA")
            $blob.AddRange([byte[]]($HeaderByte, 0x41, 0x33, 0x00, 0x01, 0x00))
            for ($i = 6; $i -lt $LengthBytes; $i++) { $blob.Add([byte](($i * 31 + 17) % 256)) }
        }
    }

    return [Convert]::ToBase64String($blob.ToArray())
}

# Backward-compatible name from the earlier (incorrect) ASN.1 DER model
Set-Alias -Name New-AutopilotSyntheticDerHash -Value New-AutopilotSyntheticHardwareHash

Export-ModuleMember -Function @(
    'Set-AutopilotMockHardwareHash',
    'Get-AutopilotMockHardwareHash',
    'Clear-AutopilotMockHardwareHash',
    'New-AutopilotSyntheticHardwareHash'
) -Alias @('New-AutopilotSyntheticDerHash')
