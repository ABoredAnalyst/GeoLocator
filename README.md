# GeoLocator

GeoLocator is an investigative tool that determines the **physical location of a Windows machine**
and returns a set of coordinates, a resolved street address, and a risk assessment. It is
typically run remotely as an on-demand investigative action through an EDR/RMM platform, but it
can be run directly on a host as well.

It ships in two interchangeable forms with **identical functionality**:

- **`GeoLocator.ps1`** — the native PowerShell script. All of the logic lives here. Run it
  directly on a host or push it through any RMM/EDR/XDR that can execute PowerShell.
- **`GeoLocator.py`** — a thin Python wrapper that embeds the exact same PowerShell script and
  executes it via `powershell -NoProfile -NonInteractive -Command`. It exists because some EDR
  modules — notably **Cortex XDR**, whose Script Agent Library accepts Python only — cannot run
  PowerShell scripts directly. The Python wrapper is not a separate implementation; it carries a
  verbatim copy of `GeoLocator.ps1`.

Also included in this repo is `EnableLocation.py`, a script that checks for Wi-Fi, Location Services, App Consent, and Airplane Mode and enables/disables the necessary services for the script to properly geolocate the machine. More details included in the [Troubleshooting](#troubleshooting) section.

---
## Purpose

Throughout 2025-2026, my team discovered several separate users that had successfully exported our equipment overseas and were working remotely in unauthorized countries. Pakistan, Brazil, Grenada, Mexico, and the UK. One of these users was even confirmed by the FBI to be directly associated with the DPRK and working remote US jobs to gain footholds in their company and help fund the North Korean missile research program. 

Despite having proper geolocation policies in place, they were easily evading them by simply placing their machines behind a VPN protected network. The more advanced actors weren't even using a known VPN. They would instead have a proxy established through a reputable network stateside, the only red flag being that they would forget to connect their 2FA device to the same network and reveal their true location.

During my investigations, there became a need to be able to physically prove where our computers were. This script allowed me to do exactly that, helping me quickly determine whether a computer belonged to a standard user who prefers the privacy of a VPN in their home or an insider threat secretly working out of Russia.


---
## How It Geolocates a Machine

The script asks Windows for the device's own position using the .NET
[`System.Device.Location.GeoCoordinateWatcher`](https://learn.microsoft.com/en-us/dotnet/api/system.device.location.geocoordinatewatcher)
class — the same location stack the operating system exposes to apps. Windows resolves that
position from whatever sensors are available, in the following order of reliability:

1. **Wi-Fi Positioning (WPS)** — the primary defense against VPNs. Windows scans for nearby
   access points (SSID/BSSID + signal strength) and sends that "radio fingerprint" to the
   Microsoft Location Service, which maps it to coordinates. Even 3–5 visible access points can
   narrow the location to ~100 meters. **Wi-Fi does not need to be connected — only powered on
   and able to scan.**
2. **GPS/GNSS** — if the device has a dedicated receiver (common on rugged/high-end laptops),
   accuracy is within a few meters.
3. **Cellular triangulation** — on WWAN/LTE/5G devices, signal timing from nearby towers gives
   50–500 m accuracy depending on tower density.
4. **IP address (fallback)** — city-level only, and the one method a VPN can fool.

Because Wi-Fi scanning is the primary source, the machine must have **Location Services enabled,
Wi-Fi powered on, and Airplane Mode disabled** for an accurate result. If those aren't in place,
positioning degrades toward the IP-based fallback. The [Troubleshooting](#troubleshooting)
section covers how to fix each of these.

Independently of the device position, the script always performs an **IP intelligence lookup**
(ISP, VPN/proxy flags, IP-based coordinates) and produces a **risk assessment** that compares the
two. This is what surfaces a suspect who is hiding behind a VPN or has spoofed their location.

---

## Requirements

**On the target machine**
- Windows 10 build 1903+ or Windows 11 (developed/verified against 24H2)
- Windows PowerShell 5.1 or PowerShell 7+
- Location Services enabled, Wi-Fi adapter powered on, Airplane Mode off (for full accuracy)

**Network (outbound)**
- `http://ip-api.com` — IP geolocation, ISP, and VPN/proxy/hosting/mobile flags
- `https://nominatim.openstreetmap.org` — reverse geocoding (coordinates → street address)
- Wi-Fi positioning additionally relies on the machine's normal Microsoft Location Service traffic

> **Note on privileges:** IP lookup, machine geolocation, and the risk assessment work as a
> standard user. One diagnostic — **Location Service Status** — reads a service key that requires
> administrative rights, so it will report `False` when run unprivileged even if the service is
> running. Run as SYSTEM/admin for a fully accurate diagnostics panel.

---

## What the Script Does, Step by Step

### 1. Diagnostics
Before geolocating, the script reports a diagnostics panel so an analyst can see whether the
machine is capable of an accurate result. Threat actors often "harden" a device by disabling
these features specifically to avoid giving away their location, so the panel itself is a signal.

| Field | Source | Meaning |
|-------|--------|---------|
| **Location Permission** | Consent store `Value` at `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location` (with the legacy `DisableLocation` policy honored as a hard-off override when present) | `Enabled` = the system "Location services" master toggle is on |
| **Location Service Status** | `Status` at `HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc\Service\Configuration` | Whether the Windows Location service (`lfsvc`) is running *(requires admin to read)* |
| **Consent Store Location** | Same consent store `Value` (`Allow`/`Deny`) | Raw value of the location consent toggle |
| **Wi-Fi Status** | Parsed from `netsh wlan show interfaces` (software radio state) | `Enabled` / `Disabled` / `Not Present` |
| **Visible Network Count** | Count of SSIDs from `netsh wlan show networks` | More visible APs → higher positioning accuracy |
| **Airplane Mode** | Radio Management COM API (`radiomgmt` / `IRadioManager`), registry as fallback | `True` = airplane mode on (radios suppressed) |

> The **Airplane Mode** reading uses the undocumented Radio Management COM API rather than the
> `SystemRadioState` registry value, because that registry value is **not authoritative** — the
> RadioManagement service owns the live state and the registry can read stale/incorrect.

Machine geolocation is skipped only if Location Permission is `Disabled` or the consent store is
`Deny`. The IP lookup and risk assessment always run regardless, so a locked-down machine still
yields useful intelligence (e.g. it's on a known VPN).

### 2. Machine Geolocation
`GeoCoordinateWatcher` is started and polled for up to 5 seconds for a `Ready` status. On
success the device latitude/longitude and a timestamp are captured. This is the WPS/GPS/cellular
result described above.

### 3. IP Intelligence
A single call to `http://ip-api.com/json/` returns the public **IP address, ISP, IP-based
coordinates, country code, region**, and the boolean flags **Mobile**, **Proxy**, and
**Hosting**. These flags drive the risk assessment.

### 4. Reverse Geocoding
If machine coordinates were obtained, they are reverse-geocoded via the OpenStreetMap
**Nominatim** API to a human-readable street address and country code, plus a Google Maps link.

### 5. Risk Assessment
The script evaluates the collected data and lists any of the following risks:

| Risk | Condition |
|------|-----------|
| `Mobile/Hotspot Connection` | IP flagged `Mobile` |
| `Known Proxy/VPN Connection` | IP flagged `Proxy` |
| `Possible Proxy/VPN Connection` | IP flagged `Hosting` (datacenter) |
| `IP & Machine Location Do Not Match` | IP vs machine coordinates differ by **more than 0.25°** in latitude **or** longitude (~17 miles of latitude; longitude varies) |
| `IP Out of Country` | IP country code is neither `US` nor unknown |
| `Machine Out of Country` | Reverse-geocoded address country is neither `US` nor unknown |

If none apply, it reports `No risks identified`. (The country baseline is US; adjust the
allow-lists in `Get-RiskAssessment` for other regions.)

---

## Sample Output

```
===============================
           Diagnostics
===============================

Location Permission      : Enabled
Location Service Status  : True
Consent Store Location   : Allow
Wi-Fi Status             : Enabled
Visible Network Count    : 5
Airplane Mode            : False

===============================
      GeoLocator Results
===============================

IP Address            : 173.239.196.41
ISP                   : M247 Ltd
IP Coordinates        : 40.7128,-74.0060
Country Code          : US
Region Name           : New York
Mobile                : False
Proxy                 : True
Hosting               : False
Machine Coordinates   : -23.5615,-46.6559
Timestamp             : 2026-01-14 15:30:45
Resolved Address      : Av. Paulista, 1578 - Bela Vista, Sao Paulo - SP, 01310-200, Brazil
Address Country Code  : BR
Google Maps Link      : https://www.google.com/maps?q=-23.5615,-46.6559

===============================
       Risk Assessment
===============================

Known Proxy/VPN Connection
IP & Machine Location Do Not Match
Machine Out of Country
```

The example above shows a classic red flag: a US VPN exit node masking a machine physically
located in Brazil.

---

## Troubleshooting

If the diagnostics panel shows anything other than Location Permission `Enabled`, Wi-Fi
`Enabled`, and Airplane Mode `False`, the machine can't produce an accurate (non-IP) result until
those are corrected.

### Option A — Run the EnableLocation script (recommended)

`EnableLocation.py` automates every fix below. **Run it as SYSTEM** (e.g. via a EDR/RMM remote terminal session) against the target. It will:

1. Enable Location Services via `SystemSettingsAdminFlows.exe SetCamSystemGlobal location 1`,
   and as fallbacks set the `lfsvc` service to automatic + start it, check and enable the
   location service master toggle (`lfsvc\Service\Configuration\Status` = `1` — the ACL-restricted
   value reported as "Location Service Status", writable as SYSTEM), set the consent store to
   `Allow`, and clear the legacy `DisableLocation` policy if it exists.
2. Detect the Wi-Fi adapter and enable it (`Get-NetAdapter | Enable-NetAdapter`).
3. Turn **off Airplane Mode** via the Radio Management COM API, then force the Wi-Fi radio on via
   the WinRT Radio API if needed.
4. Validate by running `netsh wlan show networks` and confirming a network listing is returned.

Re-run `GeoLocator.py` afterward. In rare cases a reboot may be required for the radio state to fully
apply when trying to force the Wi-Fi on, but this was very uncommon dring testing. 

### Option B — Manual remediation via PowerShell

Run these in an **elevated** PowerShell (or as SYSTEM). Each block is check-then-fix.

#### Location Services

Check the master toggle (authoritative on Windows 11 / 24H2):
```powershell
(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location").Value
```
`Allow` = enabled. If it reads `Deny`, enable location and set consent:
```powershell
SystemSettingsAdminFlows.exe SetCamSystemGlobal location 1
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location" -Name "Value" -Value "Allow" -Force
```

Ensure the Location service (`lfsvc`) is enabled and running:
```powershell
Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc" -Name "Start"   # 4 = disabled
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc" -Name "Start" -Value 2
Start-Service -Name "lfsvc"
```

Check and enable the **location service master toggle** — this is the value the diagnostics
panel reports as **Location Service Status** (`1` = on). Its registry key is ACL-restricted, so
reading/writing it requires **admin/SYSTEM** (it reads as `False`/unavailable otherwise), and
setting the service to automatic/running above is *not* sufficient on its own. Run these as
SYSTEM:
```powershell
# Check current status (1 = enabled)
(Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc\Service\Configuration" -Name "Status").Status
# Enable it
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc\Service\Configuration" -Name "Status" -Value 1 -Type DWord
```

**(Believed to only affect pre-24H2 from testing):** if the group-policy key exists and disables location, clear it. If
the key is absent, this Windows build doesn't use it — skip it.
```powershell
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors" -Name "DisableLocation" -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors" -Name "DisableLocation" -Value 0
```

#### Wi-Fi Adapter
>During testing and engagements, forcing the Wi-Fi adapter on was the trickiest part. Remember that the machine itself does not need to be connected to a Wi-Fi network, Wi-Fi simply needs to be enabled so that it can see available networks.

Confirm a Wi-Fi adapter exists and check its radio:
```powershell
netsh wlan show interfaces
```
- No output / "There is no wireless interface on the system" → the machine has no Wi-Fi
  (positioning falls back to IP only).
- `Radio status: Hardware On / Software Off` → the radio is disabled in software. Enable it:
```powershell
Get-NetAdapter | Enable-NetAdapter -Confirm:$false
```
Re-check `netsh wlan show interfaces`. If it still shows `Software Off`, check to see if Airplane Mode is enabled — see below.

#### Airplane Mode

Check airplane mode status:
```powershell
(Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\RadioManagement\SystemRadioState" -Name "(Default)")."(Default)" 
# 0 = Disabled
# 1 = Enabled
```

> During testing, it was noted that the value at `HKLM:\SYSTEM\CurrentControlSet\Control\RadioManagement\SystemRadioState` was frequently stale and would read `0` ("off") while Airplane Mode was actually on. Even if it reads as disabled, I advise still running the script below.

Check and disable Airplane Mode via the COM API (`pbEnabled = 1` means radios enabled / airplane
**off**; `SetSystemRadioState(1)` turns airplane **off**):
```powershell
Add-Type -Language CSharp -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class RmApi { [ComImport, Guid("db3afbfb-08e6-46c6-aa70-bf9a34c30ab7"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] interface IRadioManager { void IsRMSupported(out uint a); void GetUIRadioInstances(out object b); void GetSystemRadioState(out int e, out int p2, out uint p3); void SetSystemRadioState(int v); void Refresh(); void OnHardwareSliderChange(int x, int y); } static IRadioManager C(){ return (IRadioManager)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("581333f6-28db-41be-bc7a-ff201f12f3f6"))); } public static int Get(){ var m=C(); int e; int p2; uint p3; m.GetSystemRadioState(out e,out p2,out p3); return e; } public static int Set(int v){ var m=C(); m.SetSystemRadioState(v); m.Refresh(); int e; int p2; uint p3; m.GetSystemRadioState(out e,out p2,out p3); return e; } }'; if ([RmApi]::Get() -eq 0) { "Airplane mode is ON - disabling..."; [RmApi]::Set(1) | Out-Null }; if ([RmApi]::Get() -eq 1) { "Airplane mode is OFF" } else { "Airplane mode still ON" }
```
After disabling Airplane Mode, re-enable the adapters:
```powershell
Get-NetAdapter | Enable-NetAdapter -Confirm:$false
```

**Last resort — force the Wi-Fi radio on** (if it still shows `Software Off` with Airplane Mode
already off), using the WinRT Radio API (run as a single line):
```powershell
Add-Type -AssemblyName System.Runtime.WindowsRuntime; $asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -match 'IAsyncOperation' })[0]; function Await($WinRtTask,[type]$ResultType){ $as = $asTaskGeneric.MakeGenericMethod($ResultType); $t = $as.Invoke($null, @($WinRtTask)); $t.Wait(-1) | Out-Null; $t.Result }; try { [Windows.Devices.Radios.Radio,Windows.System.Devices,ContentType=WindowsRuntime] | Out-Null; $access = Await ([Windows.Devices.Radios.Radio]::RequestAccessAsync()) ([Windows.Devices.Radios.RadioAccessStatus]); if ($access -ne [Windows.Devices.Radios.RadioAccessStatus]::Allowed) { 'Denied' } else { $wifi = (Await ([Windows.Devices.Radios.Radio]::GetRadiosAsync()) ([System.Collections.Generic.IReadOnlyList[Windows.Devices.Radios.Radio]])) | Where-Object { $_.Kind -eq 'WiFi' } | Select-Object -First 1; if (-not $wifi) { 'NoRadio' } else { Await ($wifi.SetStateAsync([Windows.Devices.Radios.RadioState]::On)) ([Windows.Devices.Radios.RadioAccessStatus]) | Out-Null; if ($wifi.State -eq [Windows.Devices.Radios.RadioState]::On) { 'On' } else { 'Off' } } } } catch { 'Denied' }
```

### Option C — Manual remediation via GUI

The main purpose of this script is to be able to *subtly* geolocate a machine that you do not have physical access to via a remote powershell session through an EDR/RMM tool. In the case that you do have physical access to the desktop (such as when testing the script or subtlety is not needed), you can simply go to the Settings app and verify that:
* Wifi is enabled (Network & internet > Wi-Fi)
* Airplane mode is disabled (Network & internet > Airplane mode)
* Location services is enabled (Privacy & Security > Location services)
* Let apps access your location is enabled (Privacy & Security > Let apps access your location)

#### Validate

Confirm the machine can scan for networks — a successful listing (not "Access is denied" and not
a location-permission/elevation prompt) means it's ready:
```powershell
netsh wlan show networks
```
If you get a network list back, re-run `GeoLocator.py`.

---

