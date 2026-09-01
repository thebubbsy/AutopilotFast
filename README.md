# ⚡ AutopilotFast

> **High-Speed Windows Autopilot Hardware Hash Harvester & Direct Microsoft Graph Cloud Device Registrar for Windows OOBE (`Shift+F10`) powered by PowerShell 7+ (LTS).**

[![PowerShell Gallery](https://img.shields.io/badge/PowerShell%20Gallery-AutopilotFast-blue.svg)](https://www.powershellgallery.com/packages/AutopilotFast)
[![PowerShell Version](https://img.shields.io/badge/PowerShell-7.2%2B%20LTS-blue)](https://github.com/PowerShell/PowerShell)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Windows%2011%20%7C%2010-lightgrey.svg)](https://learn.microsoft.com/en-us/autopilot/requirements)

---

## 🎯 The Problem: Why Microsoft's Standard Workflow Breaks in Production

The standard Microsoft workflow for registering bare-metal devices into Windows Autopilot relies on the legacy `Get-WindowsAutopilotInfo.ps1` script. In real enterprise and MSP deployments, this approach suffers from major operational gaps:

1. **The Multi-Step USB & Portal Bottleneck**:
   Technicians must boot a device into OOBE, press `Shift+F10`, run an un-optimized script to export a CSV to a USB drive, walk over to a technician workstation, log into the Intune Admin Portal, upload the CSV, wait for processing, assign GroupTags, and wait another 15–45 minutes before returning to the device to wipe and reboot.
   *Reference:* [Microsoft Learn — Manually register devices with Windows Autopilot](https://learn.microsoft.com/en-us/autopilot/add-devices)

2. **WMI Provider Latency & "Invalid Namespace" Failures**:
   In early OOBE, the `dmwappushservice` service is frequently still starting up. Querying `root/cimv2/mdm/dmmap:MDM_DevDetail_Ext01` immediately throws `Invalid Namespace` or `Access Denied`, causing technicians to falsely assume the hardware is broken.
   *Reference:* [Microsoft Learn — Windows Autopilot device guidelines](https://learn.microsoft.com/en-us/autopilot/requirements)

3. **The "Registration Success" vs. "Profile Assignment" Trap**:
   Posting a hardware hash to Microsoft Graph only registers the *identity*. Intune can take anywhere from 5 to 45 minutes to process the hash, match Entra ID dynamic groups, and assign the Autopilot deployment profile. If a technician reboots immediately after upload, the device boots into standard consumer OOBE instead of corporate Autopilot.
   *Reference:* [Microsoft Graph API — importedWindowsAutopilotDeviceIdentity](https://learn.microsoft.com/en-us/graph/api/resources/intune-devices-importedwindowsautopilotdeviceidentity)

4. **Silent Network & Captive Portal Failures**:
   Staging networks often have captive portals (requiring web login), strict DNS filtering, or Deep Packet Inspection (DPI) proxies. Standard PowerShell network checks report "Connected" while Autopilot attestation endpoints (`ztd.dds.microsoft.com`) and TPM endorsement checks fail silently.
   *Reference:* [Microsoft Learn — Windows Autopilot networking requirements](https://learn.microsoft.com/en-us/autopilot/networking-requirements)

5. **Legacy Windows PowerShell 5.1 Fragility**:
   Windows PowerShell 5.1 in OOBE defaults to Windows-1252 ANSI encoding, lacks modern TLS 1.3 / HTTP/2 optimizations, and fails with token timeouts during high-latency network drops.

---

## 🛡️ How AutopilotFast Solves It

`AutopilotFast` transforms device onboarding into a **single command execution** in OOBE:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                               AUTOPILOTFAST OOBE PIPELINE                              │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ 1. [Shift+F10] ──► Bootstrap-Pwsh7.cmd (Installs PowerShell 7 LTS in 10s over HTTPS)   │
│ 2. PRE-FLIGHT  ──► 7-Stage Diagnostic Ladder (Interface -> Gateway -> DNS -> TLS)     │
│ 3. HARVEST     ──► MDM WMI Provider Spooling Loop (Genuine 4K-8K OA3 Hardware Hash)   │
│ 4. AUTH        ──► Terminal ASCII QR Code (Device Code Flow or App Secret)             │
│ 5. GRAPH POST  ──► Direct Upload to /importedWindowsAutopilotDeviceIdentities          │
│ 6. SYNC GATE   ──► Live Polling until deploymentProfileAssignmentStatus == 'assigned' │
│ 7. FALLBACK    ──► Auto-detects USB flash drive and saves CSV if network is offline    │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 🚀 Quick Start in Windows OOBE (Shift + F10)

### 1-Line Bootstrap & Registration (Zero Pre-Installation)
At the Windows 11 / Windows 10 OOBE setup screen, press **`Shift + F10`** to open the `SYSTEM` command prompt and run:

```cmd
msiexec.exe /i https://github.com/PowerShell/PowerShell/releases/download/v7.4.5/PowerShell-7.4.5-win-x64.msi /qn /norestart && "C:\Program Files\PowerShell\7\pwsh.exe" -NoProfile -Command "Install-Module AutopilotFast -Force; Register-AutopilotDevice -GroupTag 'Corporate-Laptops' -WaitForSync"
```

### Or using `Bootstrap-Pwsh7.cmd` (USB / Network Share)
Place `Bootstrap-Pwsh7.cmd` on a USB drive. In OOBE (`Shift+F10`), simply run:
```cmd
D:\Bootstrap-Pwsh7.cmd
```

---

## 📦 Exported Cmdlets & Architecture

### `Register-AutopilotDevice` (Alias: `Import-AutopilotDevice`)
Uploads the local device hardware hash directly to Microsoft Intune via Microsoft Graph.
```powershell
Register-AutopilotDevice -GroupTag "DevOps-Workstations" -AssignedUser "user@domain.com" -WaitForSync
```
- **`-WaitForSync`**: Automatically polls Graph until the Autopilot profile is confirmed assigned before telling the technician to reboot.
- **`-FallbackToUsb`**: If network or cloud authentication fails, immediately discovers connected USB removable media and dumps `Autopilot-Hashes.csv`.

### `Get-AutopilotHash`
Captures the genuine 4K–8K hardware hash via the official `MDM_DevDetail_Ext01` WMI provider with automatic `dmwappushservice` service spin-up.
```powershell
$info = Get-AutopilotHash -GroupTag "Finance"
```
*Enforces the **Capture Once, Never Lose** invariant by caching the binary hash locally to `$env:TEMP\AutopilotFast`.*

### `Test-AutopilotReadiness`
Executes a 5-point hardware and cloud compliance check:
- **TPM 2.0 State**: Present, enabled, and ready.
- **Secure Boot**: Verified active.
- **Firmware Mode**: UEFI confirmed (Legacy BIOS rejected).
- **7-Stage Network Diagnostic**: Probes Interface $\to$ Gateway $\to$ DNS $\to$ TCP 443 $\to$ TLS Handshake $\to$ Captive Portal $\to$ `ztd.dds.microsoft.com`.
- **Windows OS Build**: Verifies minimum supported build (Build 18362+).

### `Export-AutopilotCsv`
Exports device records into standard Microsoft Intune CSV format (`Device Serial Number,Windows Product ID,Hardware Hash,Group Tag,Assigned User`).
```powershell
Get-AutopilotHash | Export-AutopilotCsv -AutoDetectUsb
```

### `Set-AutopilotGroupTag`
Updates the cloud `GroupTag` / `OrderIdentifier` for an existing registered device directly in Microsoft Graph.
```powershell
Set-AutopilotGroupTag -SerialNumber "6BYQJW2" -GroupTag "Kiosk-Devices"
```

---

## 🔗 Official Microsoft Reference Links & Documentation

- [Windows Autopilot Overview](https://learn.microsoft.com/en-us/autopilot/windows-autopilot)
- [Manually register devices with Windows Autopilot](https://learn.microsoft.com/en-us/autopilot/add-devices)
- [Windows Autopilot device guidelines & hardware requirements](https://learn.microsoft.com/en-us/autopilot/requirements)
- [Windows Autopilot networking requirements](https://learn.microsoft.com/en-us/autopilot/networking-requirements)
- [Microsoft Graph API — Windows Autopilot Device Identities](https://learn.microsoft.com/en-us/graph/api/resources/intune-devices-windowsautopilotdeviceidentity)
- [Troubleshooting Windows Autopilot](https://learn.microsoft.com/en-us/autopilot/troubleshooting-overview)

---

## 📄 License
MIT © 2026 [Matthew Bubb](https://github.com/thebubbsy) | [OnYaChamp.com](https://onyachamp.com)
