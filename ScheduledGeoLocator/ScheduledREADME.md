# ScheduledGeoLocator.ps1 Setup Guide

This script designed to be ran on a scheduled basis for automated geolocation monitoring that logs location data and changes to Windows Event Logs for easy SIEM integration and alerting.

## Quick Start

1. **Prerequisites Check**: Ensure your system meets the requirements (see below)
2. **Run the script once manually** to test functionality
3. **Set up automated scheduling** using Windows Task Scheduler
4. **Configure SIEM** to ingest the Windows Event Log entries

## System Requirements

- Windows 10 build 1903 or higher
- PowerShell 5.1 or PowerShell 7+
- Administrator privileges (required on the first run for Event Log creation)
- Internet connection for external APIs
- Location services and Wi-Fi enabled (for maximum accuracy)

### Network Access Required
- `ip-api.com` (IP geolocation)
- `nominatim.openstreetmap.org` (address resolution)

## Manual Setup

### 1. Initial Test Run

Run the script manually first to verify functionality:

```powershell
# Run as Administrator
.\ScheduledGeoLocator.ps1
```

The script will:
- Create Event Log sources if they don't exist (`ScheduledGeoWatcher` and `LocationChange`)
- Create a data directory at `C:\ProgramData\GeoWatcher\`
- Log current location information to Windows Event Logs
- Save location data to track future changes

### 2. Verify Event Log Creation

Check that events are being created:

```powershell
# View recent location events
Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='ScheduledGeoWatcher'} -MaxEvents 5 | Format-Table TimeCreated, Id, LevelDisplayName, Message -Wrap

# View location change events
Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='LocationChange'} -MaxEvents 5 | Format-Table TimeCreated, Id, LevelDisplayName, Message -Wrap
```

## Automated Scheduling

### Using Task Scheduler (Recommended)

Create a scheduled task to run the script automatically:

```powershell
# Create a daily scheduled task (run as Administrator)
$action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"C:\projects\GeoWatcher\ScheduledGeoLocator.ps1`""
$trigger = New-ScheduledTaskTrigger -Daily -At "9:00AM"
$principal = New-ScheduledTaskPrincipal -UserID "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

Register-ScheduledTask -TaskName "GeoLocation Monitor" -Action $action -Trigger $trigger -Principal $principal -Settings $settings
```

### Alternative Scheduling Options

**Every 4 hours:**
```powershell
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Hours 4) -RepetitionDuration (New-TimeSpan -Days 365)
```

**On startup and then daily:**
```powershell
$trigger1 = New-ScheduledTaskTrigger -AtStartup
$trigger2 = New-ScheduledTaskTrigger -Daily -At "9:00AM"
# Use both triggers when creating the task
```

## Event Log Details

The script creates two types of events beneath the Application log:

### Event ID 2001 - ScheduledGeoWatcher
- **Source**: `ScheduledGeoWatcher`
- **Frequency**: Every time the script runs
- **Content**: Current location data, system diagnostics, and risk assessment

### Event ID 2002 - LocationChange
- **Source**: `LocationChange`  
- **Frequency**: When a location change is detected during the script run
- **Content**: Current location, previous location, system diagnostics, and risk assessment
- **Triggers**: 
  - ISP change
  - Machine coordinate change ≥ 0.2000 degrees (~22km/14mi)

## SIEM Integration

### Log Parsing

Example of log:
```
Current Location Info
IPAddress: 99.1.123.123
ISP: Example ISP
IPCoordinates: 33.0012,-89.0789
CountryCode: US
RegionName: Georgia
Mobile: False
Proxy: False
Hosting: False
MachineCoordinates: 33.47398,-82.081464
TimeStamp: 2026-01-14 16:05:24
ResolvedAddress: 1000, Example Drive, Springfield, Example County, Arkansas, 123456, United States
AddressCountryCode: US
MapLink: https://www.google.com/maps?q=33.47398,-82.081464

Diagnostics
LocationPermission: Enabled
LocationServiceStatus: False
ConsentStoreLocation: Allow
WifiStatus: Disconnected
SSIDCount: 0
AirplaneMode: True

Risks Noted (Examples)
IP Out of Country
Machine Out of Country
IP and Machine Location Do Not Match
Known Proxy/VPN Connection


```

### Sample SIEM Queries

**High-risk connections:**
```
source="WinEventLog:Application" EventCode=2001 OR EventCode=2002 "Proxy: True" OR "VPN Connection" OR "Out of Country"
```

**Location changes:**
```
source="WinEventLog:Application" EventCode=2002 source="LocationChange"
```

## Configuration Notes

- **Data Storage**: Location data is stored in `C:\ProgramData\GeoWatcher\last_location.json` and used for comparison on each check. When a location change is detected, the data from the previous location check is copied to the eventlog before this file is overwritten with the current location information.
- **Change Threshold**: Coordinate changes of 0.2000 degrees (around 14 miles) or more trigger "Location Change" alerts.
- **Country Monitoring**: Script flags non-US IP addresses and physical locations
- **Risk Assessment**: Automatically identifies VPNs, proxies, and mismatches between IP geolocation and machine geolocation.

## Troubleshooting

### Common Issues

**"Access Denied" when running:**
- Run PowerShell as Administrator
- Event Log source creation requires admin privileges

**No location data found (coordinates show "Unknown"):**
- Check location services are enabled (see [Archive/README-GeoLocator.md](Archive/README-GeoLocator.md) for detailed troubleshooting)
- Verify Wi-Fi is available (doesn't need to be connected)
- Ensure location permissions are granted

**Events not appearing in Event Log:**
- Verify Event Log sources exist: `Get-EventLog -List | Where-Object {$_.Log -eq "Application"}`
- Script must be ran as administrator for initial event log creation.

### Manual Diagnostics

Refer to troubleshooting notes in main README.

## Security Considerations

- Script runs with SYSTEM privileges when scheduled
- Location data is stored locally in plaintext JSON
- Network requests to external APIs for IP and address resolution
- Event logs may contain sensitive location information
