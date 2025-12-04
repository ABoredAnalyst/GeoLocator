# GeoWatcher.ps1
The purpose of this powershell script is to track down a Windows machine's geolocation using the GeoLocator Class. For detailed information on the full specifics regarding this class, please refer to the Microsoft Documentation [here](https://learn.microsoft.com/en-us/uwp/api/windows.devices.geolocation.geolocator?view=winrt-26100).

In short, the Geolocator class is a Windows-Specific API used to retrieve the geographic location of a device through a couple of different methods, such as:

- Wi-Fi Triangulation
  - Scans surrounding Wi-Fi access points and references their SSIDs and MACs against a location database.
- GPS
  - Although uncommon, if the device has a GPS receiver, the service should be able to determine the location within a few meters.
- Cell Tower Triangulation
  - If the device has cellular capabilities (hybrid tablets or mobile-enabled laptops) the service can measure the signal strength from nearby cell towers to calculate the machine's position.
- IP Address
  - A fallback if none of the other methods are available. IP geocoordinates can pinpoint the city, but they are not always accurate, depending on the database. They can also easily be spoofed or thrown off by a VPN.

This powerhsell script essentially asks the Windows GeoLocator service, _"Tell me the best location data you have right now."_ The service then provides the most recent and reliable coordinate fix that the machine was able to acquire using any of the listed methods.

It then runs those coordinates through [Nominatim OpenStreetMap](https://nominatim.openstreetmap.org) to retrieve an approximate address, providing an output with the Timestamp, Latitude, Longitude, a Google Maps link to the location, and a possible address.

As for accuracy, when testing this method on devices with known locations in urban areas and Wi-Fi enabled, I found that the coordinates were consistently within a few hundred meters. If a machine only had one Wi-Fi access point available (or no Wi-Fi at all), the accuracy would be questionable, as it may have to use the IP's geocoordinates as a reference.

To guage potential accuracy, I recommend performing a scan of available networks before running this script with the following command:
```powershell
netsh wlan networks
```
If you see 3+ separate available networks, you can pretty much guarantee the results will be in the ballpark you are looking for.

# Who should use this, and why?

Security Analysts and any IT personnel who have a suspicion that one of their remote users may not be exactly where they claim to be (or where their IP says they are…) Many foreign adversaries have began using VPNs to mask their location so that they can infiltrate US Remote jobs. Matter of fact, this year alone, my team has uncovered four individuals who managed to take our company computers out of country for remote work, two of which were located in Pakistan and confirmed to be working on behalf of the DPRK.

Below is a very brief overview of one of my incidents for reference where a user claimed to be in Colorado, but was discovered to actually reside in Brazil.

## Incident Overview

A member of my IT team reported a suspicious user to me. The user was experiencing massive latency issues, so IT ran a speed test on their machine using Ookla. They found it odd that the user's ISP came back as ProtonVPN. It turns out that the user had a VPN configured on their home router.

Not necessarily a policy violation, but still suspicious.

When reviewing their authentication logs, we found no anomalies indicating malicious intent. However, upon reviewing their 2FA logs, I noticed that the IP address for the approval device, their cell phone, was also on a VPN for all of their authentication attempts. That is, all except for two instances, where they forgot to connect to the VPN on their cell phone, revealing a residential IP address in Brazil.

It turned out that the user had started in America, but migrated to Brazil shortly after starting. To avoid detection, they configured a VPN on their router and hardened the machine by disabling all location permissions, turning off Wi-Fi, and then enabling Airplane Mode, as the internet still functions with an Ethernet connection.

Through a remote PowerShell session, I was able to enable each of these permissions, disable airplane mode, turn his Wi-Fi adapter back on, and run this script to determine that he was in São Paulo, Região Sudeste, 01424-003, Brazil.

Now I can't guarantee that your endeavors with this will be as interesting, but hopefully this helps someone out there. Happy hunting!

# How to use this script

The script requires Location permissions to be enabled on the machine for this to work.

I highly recommend ensuring Wi-Fi is enabled as well, as without it, the geocoordinates will be based solely on the IP address (unless the device actually has GPS or Cellular capabilities). I included instructions in the troubleshooting notes for the Wi-Fi if you face issues.

To check location permissions, you can run this PowerShell command:
```powershell
Get-ItemProperty -Path "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\LocationAndSensors" -Name "DisableLocation"
```
Value 0 means that your location is enabled. If it is disabled, run:
```powershell
Set-ItemProperty -Path "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\LocationAndSensors" -Name "DisableLocation" -Value 0
```
This is the equivalent of going into Settings > Privacy & security > Location and enabling Location Services. You should now be able to copy the script to your machine and run via Powershell.

It's worth mentioning that I included two versions of the script to choose from. There is no difference in their functionality, just their format.

GeoWatcher.ps1 is the standard powershell script that you can import into your RMM tool and run, or drop on the device and execute remotely.

GeoWatcherOneLine.ps1 is the same script, but formatted as a single line, allowing you to copy and paste it directly into a terminal. When using PowerShell through Cortex XDR Live Terminal, it didn't seem to like scripts, so this was the easiest way for me to get around that issue.

# Troubleshooting

The main purpose of these troubleshooting notes is for when you are trying to run this script on a machine where you do not have physical access to it and can only access the machine via a remote PowerShell terminal.

If you have access to the desktop, this can all be summarized to ensure your Wi-Fi is on, that location settings are enabled (Settings > Privacy & security > Location), and that Airplane Mode is not enabled.

**Location Permissions**

Check main location permissions:
```powershell
Get-ItemProperty -Path "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\LocationAndSensors" -Name "DisableLocation"
```
Value 0 means location is enabled. If disabled, run:
```powershell
Set-ItemProperty -Path "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\LocationAndSensors" -Name "DisableLocation" -Value 0
```
If you still receive location permission errors, you may need to check the AppPrivacyKey:
```powershell
Get-ItemProperty -Path "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\AppPrivacy" -Name "LetAppsAccessLocation"
```
The value should be set to 1. If the value is zero, or the key doesn't exist, run the following:
```powershell
Set-ItemProperty -Path "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\AppPrivacy" -Name "LetAppsAccessLocation" -Type DWord -Value 1 -Force
```
**Wi-Fi Connectivity**

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
_(\[int\](Get-ItemProperty "HKLM:\\System\\CurrentControlSet\\Control\\RadioManagement\\SystemRadioState").'(default)' -eq 1)_
```
If results return true, you can try to disable airplane mode by running:
```powershell
_Set-ItemProperty -Path "HKLM:\\System\\CurrentControlSet\\Control\\RadioManagement\\SystemRadioState" -Name "(default)" -Value 0_
```
Then either reboot the machine run this to try and force your network adapters to enable:
```powershell
Get-NetAdapter | Enable-NetAdapter -Confirm:\$false
```
Check your adapters and verify that the Software shows as 'On' for the Wi-Fi. If so, you should now be able to scan the network and run the script.

If not, try running the Toggle-WifiRadio.ps1 script, then check the interface again. 

This was an issue I experienced where I verified that Airplane Mode was disabled, but I still could not enable Wi-Fi via PowerShell. Since this issue only occurred on a single machine, I was unable to verify the exact cause of the problem. 
What ultimately worked was creating a script that forces the Wi-Fi radio on using some low-level Windows APIs. I will attach it separately in both script and one-line format for usage as a last resort.
