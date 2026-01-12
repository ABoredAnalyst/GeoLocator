# GeoWatcher.ps1
In short, the main purpose of this script is to pull a set of geocoordinates from a Windows computer and then map that to a physical address, like so:

<img width="920" height="420" alt="image" src="https://github.com/user-attachments/assets/a678ee28-b066-420d-a704-a86310fe76c2" />

In long, how the GeoLocator script works is relatively simple, utilizing features already built into Windows itself. It starts with a .NET class called [GeoCoordinateWatcher](https://learn.microsoft.com/en-us/dotnet/api/system.device.location.geocoordinatewatcher?view=netframework-4.8.1), which belongs to the System.Device.Location namespace that exposes location data via the system location stack.
Its main purpose is to provide an interface to the platform’s fused location provider, allowing Windows applications to obtain periodic or one-time geographic positions without directly implementing or interacting with low-level sensor logic.

From a conceptual standpoint, here is how the data flow would look when utilizing this class:
* **Initialization**: The script instantiates the GeoCoordinateWatcher and invokes the TryStart() method.
* **Request**: The watcher queries the OS location stack for the most recent and reliable geographic fix.
* **Aggregation**: The OS polls available hardware sensors (Wi-Fi, GPS, Cellular, or IP).
* **Exposure**: The GeoCoordinateWatcher exposes the resulting latitude and longitude via its Position property.

The script’s accuracy is dependent on which hardware sensors are active. The hierarchy of reliability is as follows:
* **Wi-Fi-Based Positioning (WPS)**: The script’s primary weapon against VPNs. By scanning for nearby SSIDs/BSSIDs and their signal strengths, the OS queries the Microsoft Location Service (or a similar backend) to map that unique "radio fingerprint" to known coordinates. Even with only 3-5 visible access points, accuracy can typically be narrowed down to within 100 meters.
* **GPS/GNSS**: If the device is equipped with a dedicated GPS receiver (standard on many "Rugged" or high-end mobile laptops), accuracy is pinpoint, often within a few meters.
* **Cellular Triangulation**: For LTE/5G enabled devices, the service measures signal propagation from nearby towers. Accuracy ranges from 50 to 500 meters depending on tower density.
* **IP Address (Fallback)**: This is the method of last resort. While it provides a city-level approximation, it is the only method susceptible to being misled by a VPN.

Once coordinates are retrieved, the script performs a reverse-geocoding lookup via [Nominatim OpenStreetMap](https://nominatim.openstreetmap.org/). The output provides a structured report including a timestamp, coordinates, a Google Maps hyperlink, and a resolved physical address.

At the beginning of this page is an example of the output when running the script to find my own location.

For obvious reasons, I have redacted the longitude and the resolved address from the output; however, I can confirm that the resolved address matched a house located within 100 meters.

For easier toubleshooting, there is also an integrated a Pre-Flight Diagnostic Check. This verifies the status of:
* **Location Services**: Ensuring the system-wide privacy toggle is enabled.
* **Wi-Fi Status**: Confirming the adapter is active (even if not connected to a network).
* **Airplane Mode**: Verifying that wireless radios are not being suppressed.
<img width="975" height="331" alt="image" src="https://github.com/user-attachments/assets/00de2fb5-db27-4d45-bea5-df3b1b9333ea" />



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

It's worth mentioning that I included multiple versions of the script to choose from. There is no difference in their functionality, just their format.

* GeoLocator.ps1 is the standard powershell script that you can import into your RMM tool and run, or drop on the device and execute remotely.
* GeoLocator.py performs the exact same functionality, but python.
* GeoLocatorXDR.py is a python version that can be ran through various EDR/XDR/RMM tools. I made this because Cortex XDR only allowed python scripts to be ran from their agent library, but it was very limited on the modules you could use.
* ScheduledGeoLocator.ps1 is a powershell script meant to be triggered from a scheduled task to run the GeoLocator script on a daily basis. It logs all results to the Application log beneath event IDs 2001 and 2002. This will receive its own README.
*SuspiciousNetNeighbors.py is a python script for checking a machine's ARP cache table for various suspicious devices, such as GL.iNET routers. Can assist with potentially detecting users that may be hiding their location. Will receive its own README.
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

If not, try running the Toggle-WifiRadio.ps1 script, then check the interface again. I included a one-line version of this script to easily post it straight into the terminal.

This was an issue I experienced where I verified that Airplane Mode was disabled, but I still could not enable Wi-Fi via PowerShell (whether it be lack of skill or a technical error). Since this issue only occurred on a single machine, I was unable to verify the exact cause of the problem, but the script I created seemed to do the trick.

# Who should use this, and why?

Security Analysts and any IT personnel who have a suspicion that one of their remote users may not be exactly where they claim to be (or where their IP says they are…) 

Remote work operates on a high-stakes paradox: it is an organizational infrastructure built almost entirely on blind trust. This foundation is already stretched thin by the inherent risks of a distributed workforce – specifically the practice of shipping hundreds, if not thousands, of dollars in high-end equipment to individuals who may never exist to the company beyond a 2D tile on a Zoom call.

When a company allows an employee to work outside the protection of the company’s physical office, they are essentially offloading a portion of their operational security into an unmonitored environment, relying on a fragile psychological contract between employer and employee.

It isn't just employee's looking to abuse their ability to take their computer on vacation that are the threat. 

Remote work is often exploited by hostile foreign threat actors posing as domestic remote workers to secure a position within American companies. A perfect example of this lies within [Jasper Sleet](https://www.microsoft.com/en-us/security/blog/2025/06/30/jasper-sleet-north-korean-remote-it-workers-evolving-tactics-to-infiltrate-organizations/), Microsoft's project to track North Korean IT remote worker activity as they continuously present themselves as domestic-based teleworkers to generate revenue and support state interests for the DPRK.

If you have the slightest suspicion that a company-owned device is somewhere it shouldn't be, like when noticing it is hiding behind a VPN, this script can help to verify it down to the coordinates.

Detailed below is an incident I experienced that contributed to the creation of this script. 

# Incident Overview

In December 2025, we flagged a suspicious user, who we will refer to as "Allen." The initial red flag was not a security alert, but a performance-based support ticket. Allen’s supervisor reported that he was experiencing persistent latency and network instability issues that hindered his ability to access various clients. 
A diagnostic speed test using the [Ookla CLI tool](https://www.speedtest.net/apps/cli) confirmed elevated latency, attributable to an active VPN connection through ProtonVPN.

Further investigation revealed that the user had a VPN configured on a travel router, specifically the [GL-MT3000](https://www.gl-inet.com/products/gl-mt3000/), a travel router specifically marketed for its ability to run WireGuard or OpenVPN at the hardware level. He was using this to show his computer as residing in Denver, Colorado.

While there was no malicous activity to note within his day-to-day operations, multiple disrepancies were noted that warranted investigating him further, such as:
* His place of residence and shipping address for his equipment was discovered to be a UPS store.
* He provided a passport instead of a driver's license during onboarding. A bit of OSINT on his passport number revealed a 1 year work visa to Brazil.
* The cellphone used for 2FA was also connected to a VPN. On one of his authentication requests, he forgot to connect it to the VPN and was shown as being located in Brazil.
* Location services and Wi-Fi were both found to be disabled on his workstation, along with Airplane Mode enabled to disable all wireless services.

Using the methods previously detailed, we silently enabled his Wi-Fi and location services and ran this script through our XDR service to discover he had exported our equipment to Brazil.

Since then, we have also discovered user's located in Mexico and Grenada as well using the same methodology.

Now I can't guarantee that your endeavors with this will be as interesting, but hopefully this helps someone out there. Happy hunting!

