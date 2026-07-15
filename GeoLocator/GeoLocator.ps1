## -- Classes --
Class LocationEventInfo {
    [string]$IPAddress = "Unknown"
    [string]$ISP = "Unknown"
    [string]$IPLatitude = "Unknown"
    [string]$IPLongitude = "Unknown"
    [string]$IPCoordinates = "Unknown"
    [string]$CountryCode = "Unknown"
    [string]$RegionName = "Unknown"
    [bool]$Mobile = $false
    [bool]$Proxy = $false
    [bool]$Hosting = $false
    [string]$MachineLatitude = "Unknown"
    [string]$MachineLongitude = "Unknown"
    [string]$MachineCoordinates = "Unknown"
    [string]$TimeStamp = "Unknown"
    [string]$ResolvedAddress = "Unknown"
    [string]$AddressCountryCode = "Unknown"
    [string]$MapLink = "Unknown"

    LocationEventInfo(){}

    GetIpData() {
        try {
            # ip-api.com returns ISP plus mobile/proxy/hosting flags used for risk scoring.
            $ipApiUrl = "http://ip-api.com/json/?fields=status,message,query,countryCode,regionName,lat,lon,isp,mobile,proxy,hosting"
            $ipinfo = Invoke-RestMethod -Uri $ipApiUrl -ErrorAction Stop

            if ($ipinfo.status -ne "fail") {
                $this.IPAddress = $ipinfo.query
                if ($ipinfo.isp) { $this.ISP = $ipinfo.isp }
                if ($null -ne $ipinfo.lat -and $null -ne $ipinfo.lon) {
                    $this.IPLatitude = $ipinfo.lat.ToString()
                    $this.IPLongitude = $ipinfo.lon.ToString()
                    $this.IPCoordinates = "$($ipinfo.lat),$($ipinfo.lon)"
                }
                if ($ipinfo.countryCode) { $this.CountryCode = $ipinfo.countryCode }
                if ($ipinfo.regionName) { $this.RegionName = $ipinfo.regionName }
                $this.Mobile = [bool]$ipinfo.mobile
                $this.Proxy = [bool]$ipinfo.proxy
                $this.Hosting = [bool]$ipinfo.hosting
            } else {
                $this.IPAddress = "Error: API request failed"
                $this.ISP = "Error retrieving ISP"
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
                    $this.MachineLatitude = $location.Latitude
                    $this.MachineLongitude = $location.Longitude
                    $this.MachineCoordinates = "$($location.Latitude),$($location.Longitude)"
                    $this.TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    $GeoLocator.Stop()
                } else {
                    Write-Warning 'GPS coordinates could not be resolved or are unknown.'
                }
            } else {
                Write-Warning "Timed out waiting for GPS coordinates. Status: $($GeoLocator.Status)"
            }
        } catch {
            $this.MachineLatitude = "Unknown"
            $this.MachineLongitude = "Unknown"
            $this.MachineCoordinates = "Unknown"
            $this.TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Write-Warning "Error during geolocation: $($_.Exception.Message)"
        }
    }

    GetMapData() {
        if ($this.MachineLatitude -ne "Unknown" -and $this.MachineLongitude -ne "Unknown") {
            $Lat = $this.MachineLatitude
            $Long = $this.MachineLongitude
            try {
                $nominatimUrl = "https://nominatim.openstreetmap.org/reverse?format=json&lat=$Lat&lon=$Long"
                $headers = @{ 'User-Agent' = 'PowerShell Script (Personal Use)' }
                $locationData = Invoke-RestMethod -Uri $nominatimUrl -Headers $headers -ErrorAction Stop
                $this.ResolvedAddress = $locationData.display_name
                if ($locationData.address -and $locationData.address.country_code) {
                    $this.AddressCountryCode = $locationData.address.country_code.ToUpper()
                }
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
        $this.LocationPermission = 'Unknown'

        # Legacy group-policy hard override. When present and set to 1, location is forcibly
        # disabled regardless of the master toggle. This key is absent on Windows 24H2+,
        # which is why relying on it alone reported 'Unknown'.
        $policyReg = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors'
        $policyVal = Get-ItemProperty -Path $policyReg -Name 'DisableLocation' -ErrorAction SilentlyContinue
        if ($null -ne $policyVal -and ($policyVal.PSObject.Properties.Name -contains 'DisableLocation') -and $policyVal.DisableLocation -eq 1) {
            $this.LocationPermission = 'Disabled'
            return
        }

        # Authoritative source: the "Location services" master toggle in the
        # CapabilityAccessManager consent store. This is exactly what the remediation sets
        # via 'SystemSettingsAdminFlows.exe SetCamSystemGlobal location 1' (Value => Allow).
        $consentReg = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'
        $consentVal = Get-ItemProperty -Path $consentReg -Name 'Value' -ErrorAction SilentlyContinue
        if ($null -ne $consentVal) {
            if ($consentVal.Value -eq 'Allow') {
                $this.LocationPermission = 'Enabled'
            } elseif ($consentVal.Value -eq 'Deny') {
                $this.LocationPermission = 'Disabled'
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
        # Authoritative source: the undocumented Radio Management COM API (radiomgmt.dll /
        # rmsvc). The SystemRadioState registry value is NOT reliable -- the RadioManagement
        # service owns the live state and the registry can read stale/wrong -- so it is only
        # used as a fallback below. GetSystemRadioState pbEnabled: 1 = radios enabled
        # (airplane OFF), 0 = airplane ON. The type is loaded lazily and referenced via a
        # string cast so a PS class method (which resolves [Type] tokens at parse time) can
        # still use an Add-Type'd type.
        try {
            if (-not ('RmApi' -as [type])) {
                Add-Type -Language CSharp -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class RmApi {
    [ComImport, Guid("db3afbfb-08e6-46c6-aa70-bf9a34c30ab7"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IRadioManager {
        void IsRMSupported(out uint pdwState);
        void GetUIRadioInstances(out object param1);
        void GetSystemRadioState(out int pbEnabled, out int param2, out uint param3);
        void SetSystemRadioState(int bEnabled);
        void Refresh();
        void OnHardwareSliderChange(int param1, int param2);
    }
    static IRadioManager Create() {
        Type t = Type.GetTypeFromCLSID(new Guid("581333f6-28db-41be-bc7a-ff201f12f3f6"));
        return (IRadioManager)Activator.CreateInstance(t);
    }
    // Returns 1 if radios are enabled (airplane OFF), 0 if airplane mode is ON.
    public static int GetState() {
        var m = Create(); int e; int p2; uint p3;
        m.GetSystemRadioState(out e, out p2, out p3); return e;
    }
}
"@ -ErrorAction Stop
            }
            $this.AirplaneMode = (([type]'RmApi')::GetState() -eq 0)
            return
        } catch {
            # COM API unavailable/failed -- fall back to the (less reliable) registry value.
        }

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

    $mobileColor = if ($locationInfo.Mobile) { 'Yellow' } else { 'White' }
    $proxyColor = if ($locationInfo.Proxy) { 'Red' } else { 'White' }
    $hostingColor = if ($locationInfo.Hosting) { 'Red' } else { 'White' }
    $ipCountryColor = if ($locationInfo.CountryCode -notin @('Unknown', 'US')) { 'Yellow' } else { 'White' }
    $addrCountryColor = if ($locationInfo.AddressCountryCode -notin @('Unknown', 'US')) { 'Yellow' } else { 'White' }

    Write-Host ("{0,-22}: {1}" -f 'IP Address', $locationInfo.IPAddress) -ForegroundColor White
    Write-Host ("{0,-22}: {1}" -f 'ISP', $locationInfo.ISP) -ForegroundColor White
    Write-Host ("{0,-22}: {1}" -f 'IP Coordinates', $locationInfo.IPCoordinates) -ForegroundColor White
    Write-Host ("{0,-22}: {1}" -f 'Country Code', $locationInfo.CountryCode) -ForegroundColor $ipCountryColor
    Write-Host ("{0,-22}: {1}" -f 'Region Name', $locationInfo.RegionName) -ForegroundColor White
    Write-Host ("{0,-22}: {1}" -f 'Mobile', $locationInfo.Mobile) -ForegroundColor $mobileColor
    Write-Host ("{0,-22}: {1}" -f 'Proxy', $locationInfo.Proxy) -ForegroundColor $proxyColor
    Write-Host ("{0,-22}: {1}" -f 'Hosting', $locationInfo.Hosting) -ForegroundColor $hostingColor
    Write-Host ("{0,-22}: {1}" -f 'Machine Coordinates', $locationInfo.MachineCoordinates) -ForegroundColor Magenta
    Write-Host ("{0,-22}: {1}" -f 'Timestamp', $locationInfo.TimeStamp) -ForegroundColor Magenta
    Write-Host ("{0,-22}: {1}" -f 'Resolved Address', $locationInfo.ResolvedAddress) -ForegroundColor Cyan
    Write-Host ("{0,-22}: {1}" -f 'Address Country Code', $locationInfo.AddressCountryCode) -ForegroundColor $addrCountryColor
    Write-Host ("{0,-22}: {1}" -f 'Google Maps Link', $locationInfo.MapLink) -ForegroundColor Cyan
    Write-Host ""
}

function Get-RiskAssessment($locationInfo) {
    $risks = @()

    # Connection-type risks (from ip-api flags)
    if ($locationInfo.Mobile) { $risks += "Mobile/Hotspot Connection" }
    if ($locationInfo.Proxy) { $risks += "Known Proxy/VPN Connection" }
    if ($locationInfo.Hosting) { $risks += "Possible Proxy/VPN Connection" }

    # Coordinate mismatch between IP-derived and machine-reported location
    if ($locationInfo.IPLatitude -ne "Unknown" -and $locationInfo.IPLongitude -ne "Unknown" -and
        $locationInfo.MachineLatitude -ne "Unknown" -and $locationInfo.MachineLongitude -ne "Unknown") {
        try {
            $ipLat = [decimal]$locationInfo.IPLatitude
            $ipLon = [decimal]$locationInfo.IPLongitude
            $machineLat = [decimal]$locationInfo.MachineLatitude
            $machineLon = [decimal]$locationInfo.MachineLongitude

            $latDifference = [Math]::Abs($ipLat - $machineLat)
            $lonDifference = [Math]::Abs($ipLon - $machineLon)

            if ($latDifference -gt 0.2500 -or $lonDifference -gt 0.2500) {
                $risks += "IP & Machine Location Do Not Match"
            }
        } catch {
            # Ignore coordinate comparison errors
        }
    }

    # Country checks (US-based baseline; adjust the allow-list as needed)
    if ($locationInfo.CountryCode -notin @("Unknown", "US")) { $risks += "IP Out of Country" }
    if ($locationInfo.AddressCountryCode -notin @("Unknown", "US")) { $risks += "Machine Out of Country" }

    return $risks
}

function Write-RiskAssessment($locationInfo) {
    Write-Host ""
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host "       Risk Assessment         " -ForegroundColor Cyan
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host ""

    $risks = @(Get-RiskAssessment $locationInfo)
    if ($risks.Count -gt 0) {
        $risks | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    } else {
        Write-Host "No risks identified" -ForegroundColor Green
    }
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
    
    # IP-based lookup, ISP lookup, and risk assessment run regardless of location-service
    # state -- they need no location permission and are valuable for investigation (a
    # "hardened" machine with location disabled still reveals VPN/proxy usage via its IP).
    # Machine geolocation still requires the permission/consent checks above.
    $LocationInfo = [LocationEventInfo]::new()
    Write-Host "Retrieving IP information..." -ForegroundColor Yellow
    $LocationInfo.GetIpData()

    if ($canProceed) {
        Write-Host "Attempting to get GPS coordinates (timeout: 5 seconds)..." -ForegroundColor Yellow
        $LocationInfo.GetGeoData()

        if ($LocationInfo.MachineLatitude -ne "Unknown" -and $LocationInfo.MachineLongitude -ne "Unknown") {
            Write-Host "Resolving address from coordinates..." -ForegroundColor Yellow
            $LocationInfo.GetMapData()
        }
    } else {
        Write-Host "Skipping machine geolocation due to permission/policy issues; showing IP-based data only." -ForegroundColor Red
    }

    # Display results and risk assessment
    Write-LocationOutput $LocationInfo
    Write-RiskAssessment $LocationInfo
    
} catch {
    Write-Error "An error occurred during execution: $($_.Exception.Message)"
} finally {
    Write-Host "Script execution completed." -ForegroundColor Green
}
