#Same functionality as GeoLocator.ps1. Script basically acts as a python wrapper to initiate the powershell script.
#Created because Cortex XDR only supports python scripts in their Script Agent Library.

import subprocess
import sys

# Embed the full PowerShell script as a string
ps_script = r'''
## -- Classes --
Class LocationEventInfo {
    [string]$IPAddress = "Unknown"
    [string]$ISP = "Unknown"
    [string]$Latitude = "Unknown"
    [string]$Longitude = "Unknown"
    [string]$TimeStamp = "Unknown"
    [string]$ResolvedAddress = "Unknown"
    [string]$MapLink = "Unknown"
    
    LocationEventInfo(){}

    GetIpData() {
        try {
            $ipinfo = Invoke-RestMethod -Uri "https://ipinfo.io/json" -ErrorAction Stop
            $this.IPAddress = $ipinfo.ip
            if ($ipinfo.org) { 
                $this.ISP = $ipinfo.org 
            } 
        } catch {
            $this.IPAddress = "Error retrieving IP"
            $this.ISP = "Error retrieving ISP"
        }
    }

    GetGeoData() {
        try {
            Add-Type -AssemblyName System.Device
            $GeoLocator = New-Object System.Device.Location.GeoCoordinateWatcher
            $GeoLocator.Start()
            $TimeoutSeconds = 5
            $StartTime = Get-Date
            $IsReady = $false
            while ((Get-Date) -le ($StartTime).AddSeconds($TimeoutSeconds)) {
                if ($GeoLocator.Status -eq 'Ready') {
                    $IsReady = $true
                    break
                }
                Start-Sleep -Milliseconds 250
            }
            if ($IsReady) {
                $location = $GeoLocator.Position.Location
                if ($null -ne $location -and $location.IsUnknown -eq $false) {
                    $this.Latitude = $location.Latitude
                    $this.Longitude = $location.Longitude
                    $this.TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    $GeoLocator.Stop()
                } else {
                    Write-Warning 'GPS coordinates could not be resolved or are unknown.'
                }
            } else {
                Write-Warning "Timed out waiting for GPS coordinates. Status: $($GeoLocator.Status)"
            }
        } catch {
            $this.Latitude = "Unknown"
            $this.Longitude = "Unknown"
            $this.TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Write-Warning "Error during geolocation: $($_.Exception.Message)"
        }
    }

    GetMapData() {
        if ($this.Latitude -ne "Unknown" -and $this.Longitude -ne "Unknown") {
            $Lat = $this.Latitude
            $Long = $this.Longitude
            try {
                $nominatimUrl = "https://nominatim.openstreetmap.org/reverse?format=json&lat=$Lat&lon=$Long"
                $headers = @{ 'User-Agent' = 'PowerShell Script (Personal Use)' }
                $locationData = Invoke-RestMethod -Uri $nominatimUrl -Headers $headers -ErrorAction Stop
                $this.ResolvedAddress = $locationData.display_name
                $this.MapLink = "https://www.google.com/maps?q=$Lat,$Long"
            } catch {
                $this.ResolvedAddress = "Address resolution failed (API error)."
                $this.MapLink = "https://www.google.com/maps?q=$Lat,$Long"
                Write-Warning "Could not resolve address via Nominatim API. Error: $($_.Exception.Message)"
            }
        }
    }
}

Class SystemConfigInfo {
    [string]$LocationPermission
    [bool]$LocationServiceStatus
    [string]$ConsentStoreLocation
    [string]$WifiStatus
    [int]$SSIDCount
    [bool]$AirplaneMode
   
    GetLocationStatus() {
        $locationReg = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors'
        $this.LocationPermission = 'Unknown'
        if (Test-Path $locationReg) {
            $locRegVal = Get-ItemProperty -Path $locationReg -ErrorAction SilentlyContinue
            if ($null -ne $locRegVal -and $locRegVal.PSObject.Properties.Name -contains 'DisableLocation') {
                $disableLocation = $locRegVal.DisableLocation
                if ($disableLocation -eq 0) {
                    $this.LocationPermission = 'Enabled'
                } elseif ($disableLocation -eq 1) {
                    $this.LocationPermission = 'Disabled'
                }
            }
        }
    }

    GetLocationServiceStatus() {
        $locationRegPath = "HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc\Service\Configuration"
        try {
            $locationReg = Get-ItemProperty -Path $locationRegPath -Name "Status" -ErrorAction Stop
            if ($locationReg.Status -eq 1) {
                $this.LocationServiceStatus = $True
            } else {
                $this.LocationServiceStatus = $False
            }
        } catch {
            $this.LocationServiceStatus = $False
        }
    }

    GetConsentStore() {
        $consentReg = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'
        $this.ConsentStoreLocation = 'Unknown'
        if (Test-Path $consentReg) {
            try {
                $val = Get-ItemProperty -Path $consentReg -Name 'Value' -ErrorAction Stop
                $this.ConsentStoreLocation = $val.Value
            } catch {
                $this.ConsentStoreLocation = 'Error reading registry'
            }
        } else {
            $this.ConsentStoreLocation = 'Not Found'
        }
    }

    GetWifiStatus() {
        try {
            $netshOutput = netsh wlan show interfaces 2>$null
            if ($LASTEXITCODE -eq 0 -and $netshOutput) {
                $lines = $netshOutput -split "`n"
                $radioStatusFound = $false
                
                for ($i = 0; $i -lt $lines.Length; $i++) {
                    if ($lines[$i] -match "Radio status") {
                        $radioStatusFound = $true
                        # Look for software radio status in the next few lines
                        for ($j = $i + 1; $j -lt [Math]::Min($i + 11, $lines.Length); $j++) {
                            $line = $lines[$j].Trim()
                            if ($line -match "^\s*Software") {
                                if ($line -match ":") {
                                    $radioSw = ($line -split ":", 2)[1].Trim()
                                } else {
                                    $parts = $line -split "\s+", 2
                                    if ($parts.Length -gt 1) {
                                        $radioSw = $parts[1].Trim()
                                    } else {
                                        $radioSw = "Unknown"
                                    }
                                }
                                $this.WifiStatus = if ($radioSw -eq "On") { "Enabled" } else { "Disabled" }
                                return
                            }
                        }
                        break
                    }
                }
                
                if ($radioStatusFound) {
                    $this.WifiStatus = "Unknown"
                } else {
                    $this.WifiStatus = "Not Present"
                }
            } else {
                $this.WifiStatus = "Not Present"
            }
        } catch {
            $this.WifiStatus = "Error"
        }
    }

    GetSsidCount() {
        try {
            $netshNetworks = netsh wlan show networks 2>$null
            if ($netshNetworks) {
                $this.SSIDCount = ($netshNetworks | Select-String -Pattern '^SSID\s+\d+\s+:' | Measure-Object).Count
            } else {
                $this.SSIDCount = 0
            }
        } catch { $this.SSIDCount = 0 }
    }

    GetAirplaneStatus() {
        $RadioMgmtKey = "HKLM:\SYSTEM\CurrentControlSet\Control\RadioManagement\SystemRadioState"
        try {
            $RadioMgmtState = Get-ItemProperty $RadioMgmtKey -ErrorAction Stop
            if ($RadioMgmtState.'(default)' -eq 0 ) {
                $this.AirplaneMode = $False 
            } else {
                $this.AirplaneMode = $True 
            }
        } catch {
            $this.AirplaneMode = $False
        }
    }

    ScanConfig() {
        $this.GetLocationStatus()
        $this.GetConsentStore()
        $this.GetLocationServiceStatus()
        $this.GetWiFiStatus()
        $this.GetSSIDCount()
        $this.GetAirplaneStatus()
    }
}

## -- Functions --
function Write-DiagnosticsOutput($systemConfig) {
    Write-Host ""
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host "           Diagnostics         " -ForegroundColor Cyan
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host ""
    
    $locationColor = if ($systemConfig.LocationPermission -eq 'Enabled') { 'Green' } else { 'Red' }
    $serviceColor = if ($systemConfig.LocationServiceStatus -eq $true) { 'Green' } else { 'Red' }
    $consentColor = if ($systemConfig.ConsentStoreLocation -eq 'Allow') { 'Green' } else { 'Red' }
    $wifiColor = if ($systemConfig.WifiStatus -eq 'Enabled') { 'Green' } else { 'Yellow' }
    $airplaneColor = if ($systemConfig.AirplaneMode) { 'Red' } else { 'Green' }
    
    Write-Host ("{0,-25}: {1}" -f 'Location Permission', $systemConfig.LocationPermission) -ForegroundColor $locationColor
    Write-Host ("{0,-25}: {1}" -f 'Location Service Status', $systemConfig.LocationServiceStatus) -ForegroundColor $serviceColor
    Write-Host ("{0,-25}: {1}" -f 'Consent Store Location', $systemConfig.ConsentStoreLocation) -ForegroundColor $consentColor
    Write-Host ("{0,-25}: {1}" -f 'Wi-Fi Status', $systemConfig.WifiStatus) -ForegroundColor $wifiColor
    Write-Host ("{0,-25}: {1}" -f 'Visible Network Count', $systemConfig.SSIDCount) -ForegroundColor Green
    Write-Host ("{0,-25}: {1}" -f 'Airplane Mode', $systemConfig.AirplaneMode) -ForegroundColor $airplaneColor
    Write-Host ""
}

function Write-LocationOutput($locationInfo) {
    Write-Host ""
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host "      GeoLocator Results       " -ForegroundColor Cyan
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host ""
    
    Write-Host ("{0,-22}: {1}" -f 'IP Address', $locationInfo.IPAddress) -ForegroundColor White
    Write-Host ("{0,-22}: {1}" -f 'ISP', $locationInfo.ISP) -ForegroundColor White
    Write-Host ("{0,-22}: {1}" -f 'Latitude', $locationInfo.Latitude) -ForegroundColor Magenta
    Write-Host ("{0,-22}: {1}" -f 'Longitude', $locationInfo.Longitude) -ForegroundColor Magenta
    Write-Host ("{0,-22}: {1}" -f 'Timestamp', $locationInfo.TimeStamp) -ForegroundColor Magenta
    Write-Host ("{0,-22}: {1}" -f 'Resolved Address', $locationInfo.ResolvedAddress) -ForegroundColor Cyan
    Write-Host ("{0,-22}: {1}" -f 'Google Maps Link', $locationInfo.MapLink) -ForegroundColor Cyan
    Write-Host ""
}

## Main Logic
try {
    # Initialize classes and scan system configuration
    $SystemConfig = [SystemConfigInfo]::new()
    $SystemConfig.ScanConfig()
    
    # Display diagnostics
    Write-DiagnosticsOutput $SystemConfig
    
    # Check if location services are properly configured
    $canProceed = $true
    if ($SystemConfig.LocationPermission -eq 'Disabled') {
        Write-Host "Location services are disabled by policy. Cannot proceed with geolocation." -ForegroundColor Red
        $canProceed = $false
    }
    
    if ($SystemConfig.ConsentStoreLocation -eq 'Deny') {
        Write-Host "Location access is denied in consent store. Cannot proceed with geolocation." -ForegroundColor Red
        $canProceed = $false
    }
    
    # Warn about potential issues
    if ($SystemConfig.WifiStatus -eq 'Disabled' -or $SystemConfig.AirplaneMode) {
        Write-Host "Warning: Wi-Fi is disabled or Airplane Mode is enabled. Location accuracy may be reduced." -ForegroundColor Yellow
    }
    
    if ($canProceed) {
        # Get location information
        $LocationInfo = [LocationEventInfo]::new()
        Write-Host "Retrieving IP information..." -ForegroundColor Yellow
        $LocationInfo.GetIpData()
        
        Write-Host "Attempting to get GPS coordinates (timeout: 5 seconds)..." -ForegroundColor Yellow
        $LocationInfo.GetGeoData()
        
        if ($LocationInfo.Latitude -ne "Unknown" -and $LocationInfo.Longitude -ne "Unknown") {
            Write-Host "Resolving address from coordinates..." -ForegroundColor Yellow
            $LocationInfo.GetMapData()
        }
        
        # Display results
        Write-LocationOutput $LocationInfo
    } else {
        Write-Host "Cannot proceed with geolocation due to permission/policy issues." -ForegroundColor Red
    }
    
} catch {
    Write-Error "An error occurred during execution: $($_.Exception.Message)"
} finally {
    Write-Host "Script execution completed." -ForegroundColor Green
}
'''

try:
    completed = subprocess.run(
        ["powershell", "-NoProfile", "-NonInteractive", "-Command", ps_script],
        capture_output=True, text=True, timeout=60
    )
    stdout = completed.stdout.strip()
    if not stdout:
        stdout = completed.stderr.strip()

    print(stdout)
except subprocess.TimeoutExpired:
    print("PowerShell command timed out.")
    sys.exit(1)
except Exception as e:
    print(f"Failed to get location: {e}")
    sys.exit(1)
