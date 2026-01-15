# GeoLocator - Geolocation Analysis Scripts

## Overview

The **GeoLocator** scripts are a set of PowerShell scripts designed to assist with the geolocation analysis of an endpoint. To sum up its functionality, it uses the [GeoCoordinateWatcher](https://learn.microsoft.com/en-us/dotnet/api/system.device.location.geocoordinatewatcher?view=netframework-4.8.1) .NET class to retreive a set of coordinates from the computer and then maps that out to a physical address to determine the true location of the device. 
The script’s accuracy is dependent on which hardware sensors are active. The hierarchy of reliability is as follows:
* **Wi-Fi-Based Positioning (WPS)**: The script’s primary weapon against VPNs. By scanning for nearby SSIDs/BSSIDs and their signal strengths, the OS queries the Microsoft Location Service (or a similar backend) to map that unique "radio fingerprint" to known coordinates. Even with only 3-5 visible access points, accuracy can typically be narrowed down to within 100 meters.
* **GPS/GNSS**: If the device is equipped with a dedicated GPS receiver (standard on many "Rugged" or high-end mobile laptops), accuracy is pinpoint, often within a few meters.
* **Cellular Triangulation**: For LTE/5G enabled devices, the service measures signal propagation from nearby towers. Accuracy ranges from 50 to 500 meters depending on tower density.
* **IP Address (Fallback)**: This is the method of last resort. While it provides a city-level approximation, it is the only method susceptible to being misled by a VPN.

The script also checks the machine's IP against [IP-API](https://ip-api.com/) to retrieve the IP's coordinates, ISP, and whether it belong to a known Proxy/VPN service, a datacenter, or a hotspot.

It then provides a risk assessment and looks for disrepencies in the geolocator results, such a the machine being connected to a VPN, a mismatch between the machine's geolocation and the IP's, being located out of country, etc.

```
===============================
           Diagnostics         
===============================

Location Permission      : Enabled
Location Service Status  : True
Consent Store Location   : Allow
Wi-Fi Status            : Enabled
Visible Network Count   : 5
Airplane Mode           : False

===============================
      GeoLocator Results       
===============================

IP Address              : 173.239.196.41
ISP                     : M247 Ltd
IP Coordinates          : 40.7128,-74.0060
Country Code            : US
Region Name             : New York
Mobile                  : False
Proxy                   : True
Hosting                 : False
Machine Coordinates     : -23.5615, -46.6559
Timestamp              : 2026-01-14 15:30:45
Resolved Address       : Av. Paulista, 1578 - Bela Vista, São Paulo - SP, 01310-200, Brazil
Address Country Code   : BR
Google Maps Link       : https://www.google.com/maps?q=-23.5615,-46.6559

===============================
       Risk Assessment         
===============================

Known Proxy/VPN Connection
IP and Machine Location Do Not Match
Machine Out of Country
```

Three scripts are included in this repository:
1. **GeoLocator.ps1** - main script designed for manual analysis during investigations. Can be ran directly on machine or remotely through your preferred RMM/EDR/XDR.
2. **GeoLocator.py** - a python wrapped version of the same script, as Cortex XDR would only allow Python scripts in their Script Agent Library.
3. **ScheduledGeoLocator.ps1** - designed to be ran on an automated basis to monitor machines for risky behavior, such as VPNs, location changes, large differences between IP location and machine location, and more. Outputs results to Windows Event Logs for easy SIEM ingestion.

## Purpose

In 2025 alone, my team discovered 5 separate users that had successfully taken our company equipment overseas, 1 of which was confirmed to be associated with the DPRK. They completely flew under the radar, bypassing our georestriction policies by doing something as simple as hiding behind a VPN and disabling their location services. 

See, remote work operates on a high-stakes paradox: it is an organizational infrastructure built almost entirely on blind trust. This foundation is already stretched thin by the inherent risks of a distributed workforce – specifically the practice of shipping hundreds, if not thousands, of dollars in high-end equipment to individuals who may never exist to the company beyond a 2D tile on a Zoom call and whose location we can only entrust our tools to verify.

When a company allows an employee to work outside the protection of the company’s physical office, they are essentially offloading a portion of their operational security into an unmonitored environment, relying on a fragile psychological contract between employer and employee.

The threat isn't just employees looking to abuse their ability to take their computer on vacation or fulfill their dream of living overseas without losing their income. Remote work is being increasingly exploited by hostile foreign threat actors posing as domestic remote workers to secure a position within American companies. 
A perfect example of this lies within [Jasper Sleet](https://www.microsoft.com/en-us/security/blog/2025/06/30/jasper-sleet-north-korean-remote-it-workers-evolving-tactics-to-infiltrate-organizations/), Microsoft's project to track North Korean IT remote worker activity as they continuously present themselves as domestic-based teleworkers to generate revenue and support state interests for the DPRK.

This script is a simple, no-cost solution for investigating and detecting these actors utilizing nothing more than what comes built into Windows itself.


## How It Functions



#### 1. **Diagnostics**
Before initiating the full geolocation lookup, the script performs a comprehensive system diagnostics check to verify the machine has full location checking capabilities and the proper permissions are in place. 
This isn't just to help with troubleshooting. Threat actors tend to "harden" their computers by disabling these services and enabling Airplane Mode to ensure there are no wireless connections reaching out to give away their location. 
A desktop with permissions denied, airplane mode enabled, and a VPN address would likely be a dead giveaway for a potential suspect.
- **Location Permission**: Checks "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\LocationAndSensors" to verify location permisions are enabled.
- **Location Service Status**: Checks "HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc\Service\Configuration" to verify the location service is running.
- **Consent Store**: Checks "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location" to verify consent for Location Services.
- **Wi-Fi Status**: Checks that Wi-Fi is available. Wi-Fi does **NOT** have to be connected for the script to function accurately, only available.
- **Visible Network Count**: Checks how many Wi-Fi access points are seen by the machine. The more access points available, the higher the accuracy of the script as it uses Wi-Fi triangulation as it's primary source for geolocation.
- **Airplane Mode**: Checks "HKLM:\\System\\CurrentControlSet\\Control\\RadioManagement\\SystemRadioState" to verify if airplane mode is disabled.

The geolocation section of this script will **NOT** function without the location permissions, consent, and service enabled.
If Wi-Fi is disabled, the geolocation check will default to an IP lookup, which is less accurate and easily fooled by VPNs.


#### 2. **GeoLocator Results**

The **GeoLocator Results** section displays the collected geolocation data in a clear, organized format. This output provides both IP-based (utilizing [IP-API](https://ip-api.com/)) and device-based location information, allowing you to compare the external network location with the actual physical location of the machine.

**Key fields include:**
- **IP Address**: The public IP address as seen by external services.
- **ISP**: The Internet Service Provider associated with the IP.
- **IP Coordinates**: Latitude and longitude derived from the IP address.
- **Country Code / Region Name**: Country and region associated with the IP.
- **Mobile / Proxy / Hosting**: Flags indicating if the connection is via mobile, proxy/VPN, or hosting provider.
- **Machine Coordinates**: Actual device-reported latitude and longitude (from Windows location services).
- **Timestamp**: When the machine coordinates were obtained.
- **Resolved Address**: Human-readable address resolved from the device coordinates.
- **Address Country Code**: Country code of the resolved address.
- **Google Maps Link**: Direct link to view the device location on Google Maps.

#### 3. **Risk Assessment**
Automatically evaluates potential security concerns:
- **Connection Type Risks**: Identifies mobile hotspots, proxies, or VPN usage
- **Country Verification**: Flags foreign IP addresses or physical locations
- **Location Spoofing Detection**: Identifies significant coordinate differences between IP coordinates and Machine.
```
===============================
      GeoLocator Results       
===============================

IP Address              : 173.239.196.41
ISP                     : M247 Ltd
IP Coordinates          : 40.7128,-74.0060
Country Code            : US
Region Name             : New York
Mobile                  : False
Proxy                   : True
Hosting                 : False
Machine Coordinates     : -23.5615, -46.6559
Timestamp              : 2026-01-14 15:30:45
Resolved Address       : Av. Paulista, 1578 - Bela Vista, São Paulo - SP, 01310-200, Brazil
Address Country Code   : BR
Google Maps Link       : https://www.google.com/maps?q=-23.5615,-46.6559

===============================
       Risk Assessment         
===============================

Known Proxy/VPN Connection
IP and Machine Location Do Not Match
Machine Out of Country
```


## Troubleshooting
In some cases, you may need to manually enable location permissions or even the Wi-Fi to get the most out of this script. Review the diagnostics output and use the following PowerShell command to troubleshoot.
```
===============================
           Diagnostics         
===============================

Location Permission      : Disabled
Location Service Status  : True
Consent Store Location   : Deny
Wi-Fi Status            : Disabled
Visible Network Count   : 5
Airplane Mode           : True
```


#### Location Permissions
Check main location permissions:
```powershell
Get-ItemProperty -Path "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\LocationAndSensors" -Name "DisableLocation"
```
Value 0 means location is enabled. If disabled, run:
```powershell
Set-ItemProperty -Path "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\LocationAndSensors" -Name "DisableLocation" -Value 0
```
Check that the location service is enabled:
```powershell
Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc" -Name "Start"
```
Value 4 means disabled. Set it to 2 for automatic startup and start the service with:
```powershell
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc" -Name "Start" -Value 2 | Start-Service -Name "lfsvc"
```
Check Consent Store:
```powershell
Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location" -Name "Value"
```
The value should be set to Allow. If the value is Deny, run the following:
```powershell
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location" -Name "Value" -Value "Allow" -Force
```

##### Wi-Fi Connectivity

Check for network interfaces:
```powershell
Netsh wlan show interfaces
```
If you see nothing, the machine is not Wi-Fi capable. If you see the device with Radio Status: Hardware On, Software Off, the Wi-Fi is likely disabled. You can try enabling it with:
```powershell
Enable-netAdapter -Name "Wi-Fi" (may need to replace interface name if different)
```
Check the interface again. If the adapter still shows 'Software Off,' then it is possible that the machine is currently in Airplane Mode. You can check with:
```powershell
(Get-ItemProperty "HKLM:\\System\\CurrentControlSet\\Control\\RadioManagement\\SystemRadioState").'(default)' -eq 1
```
If results return true, you can try to disable airplane mode by running:
```powershell
Set-ItemProperty -Path "HKLM:\\System\\CurrentControlSet\\Control\\RadioManagement\\SystemRadioState" -Name "(default)" -Value 0
```
Then either reboot the machine run this to try and force your network adapters to enable:
```powershell
Get-NetAdapter | Enable-NetAdapter -Confirm:\$false
```
Check your adapters and verify that the Software shows as 'On' for the Wi-Fi. If so, you should now be able to scan the network and run the script.

If not, try running the Toggle-WifiRadio.ps1 script, then check the interface again. I included a one-line version of this script to easily post it straight into the terminal.

This was an issue I experienced where I verified that Airplane Mode was disabled, but I still could not enable Wi-Fi via PowerShell (whether it be lack of skill or a technical error). Since this issue only occurred on a single machine, I was unable to verify the exact cause of the problem, but the script seemed to do the trick.



### Minimum System Requirements
- Windows 10 build 1903 or higher
- PowerShell 5.1 or PowerShell 7+
- Internet connection for external APIs

### Network Requirements
- HTTP/HTTPS access to:
  - `ip-api.com` (IP geolocation)
  - `nominatim.openstreetmap.org` (address resolution)

