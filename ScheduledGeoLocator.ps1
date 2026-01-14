## Schedule Geo Location Script
## -- Classes --
Class LocationEvent {
    [int]$EventId
    [string]$EventSource
    [string]$EventLog
    [string]$EventTitle
    [LocationEventInfo]$EventInfo

    LocationEvent(){
        $this.EventInfo = [LocationEventInfo]::new()
    }
    
    [string] ToWinlog() {
        $messages = $This.EventInfo.PSObject.Properties | ForEach-Object { "$($_.Name): $($_.Value)" }
        return ($messages -join "`n") + "`n"
    }
}
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

    [string] ToWinlog() {
        $excludedProperties = @('IPLatitude', 'IPLongitude', 'MachineLatitude', 'MachineLongitude')
        $messages = $This.PSObject.Properties | Where-Object { $excludedProperties -notcontains $_.Name } | 
                   ForEach-Object { "$($_.Name): $($_.Value)" }
        return ($messages -join "`n") + "`n"
    }

    GetIpData() {
        try {
            $ipApiUrl = "http://ip-api.com/json/?fields=query,countryCode,regionName,lat,lon,isp,mobile,proxy,hosting"
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
            $EndTime = (Get-Date).AddSeconds($TimeoutSeconds)
            
            while ((Get-Date) -le $EndTime -and $GeoLocator.Status -ne 'Ready') {
                Start-Sleep -Milliseconds 250
            }
            
            if ($GeoLocator.Status -eq 'Ready') {
                $location = $GeoLocator.Position.Location
                if ($null -ne $location -and $location.IsUnknown -eq $false) {
                    $this.MachineLatitude = $location.Latitude
                    $this.MachineLongitude = $location.Longitude
                    $this.MachineCoordinates = "$($location.Latitude),$($location.Longitude)"
                    $this.TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    $GeoLocator.Stop()
                }
            }
        } catch {
            $this.MachineLatitude = "Unknown"
            $this.MachineLongitude = "Unknown"
            $this.MachineCoordinates = "Unknown"
            $this.TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
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
            }
        }
    }

    ScanGeoData() {
        $this.GetIpData()
        $this.GetGeoData()
        $this.GetMapData()
    }
}

Class SystemConfigInfo {
    [string]$LocationPermission = 'Disabled'
    [bool]$LocationServiceStatus = $False
    [string]$ConsentStoreLocation = 'Not Found'
    [string]$WifiStatus = 'Not Present'
    [int]$SSIDCount = 0
    [bool]$AirplaneMode = $False
  
   
    GetLocationStatus() {
        $locationReg = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors'
        $this.LocationPermission = 'Unknown'
        
        $locRegVal = Get-ItemProperty -Path $locationReg -Name 'DisableLocation' -ErrorAction SilentlyContinue
        if ($null -ne $locRegVal) {
            if ($locRegVal.DisableLocation -eq 0) {
                $this.LocationPermission = 'Enabled'
            } else {
                $this.LocationPermission = 'Disabled'
            }
        }
    }

    #Note: Location Service Status requires admin to check. Will return false otherwise. 
    #Not really an issue as this should run scheduled as SYSTEM/Admin, just worth noting
    GetLocationServiceStatus() {
        $locationRegPath = "HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc\Service\Configuration"
        $locationReg = Get-ItemProperty -Path $locationRegPath -Name "Status" -ErrorAction SilentlyContinue

        if ($null -ne $locationReg -and $locationReg.Status -eq 1) {
            $this.LocationServiceStatus = $True
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
        }
    }

    GetWiFiStatus() {
        $wifiAdapter = Get-NetAdapter -Name "*Wi-Fi*" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($wifiAdapter) {
            $this.WifiStatus = $wifiAdapter.Status
        } else {
            $this.WifiStatus = 'Not Present'
        }
    }

    GetSsidCount() {
        $this.SSIDCount = (netsh wlan show networks 2>$null | Select-String -Pattern '^SSID\s+\d+\s+:').Count
    }

    GetAirplaneStatus() {
        $RadioMgmtKey = "HKLM:\SYSTEM\CurrentControlSet\Control\RadioManagement\SystemRadioState"
        $RadioMgmtState = Get-ItemProperty $RadioMgmtKey

        if ($RadioMgmtState.'(default)' -eq 1 ) {
            $this.AirplaneMode = $True 
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

     [string] ToWinlog() {
        $messages = $This.PSObject.Properties | ForEach-Object { "$($_.Name): $($_.Value)" }
        return ($messages -join "`n") + "`n"
    }
}

## -- Functions --
Function Set-LoggingConfiguration {
    param(
        $EventSource,
        $EventLog
    )

    Write-Output "Checking for Event Log Source: $EventSource"
    if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
        Write-Output "Creating Event Log Source: $EventSource"
        [System.Diagnostics.EventLog]::CreateEventSource($EventSource, $EventLog)
    }
}
function Copy-LocationProperties($from, $to) {
    $to.IPAddress = $from.IPAddress
    $to.ISP = $from.ISP
    $to.Latitude = $from.Latitude
    $to.Longitude = $from.Longitude
    $to.TimeStamp = $from.TimeStamp
    $to.ResolvedAddress = $from.ResolvedAddress
    $to.MapLink = $from.MapLink
}

function Save-LocationToFile($locationInfo, $path) {
    $locationInfo | ConvertTo-Json | Set-Content $path
}

function Get-RiskAssessment($eventInfo) {
    $risks = @()
    
    # Check connection types
    if ($eventInfo.Mobile) { $risks += "Mobile/Hotspot Connection" }
    if ($eventInfo.Proxy) { $risks += "Known Proxy/VPN Connection" }
    if ($eventInfo.Hosting) { $risks += "Possible Proxy/VPN Connection" }
    
    # Check coordinate mismatch between IP and machine location
    if ($eventInfo.IPLatitude -ne "Unknown" -and $eventInfo.IPLongitude -ne "Unknown" -and 
        $eventInfo.MachineLatitude -ne "Unknown" -and $eventInfo.MachineLongitude -ne "Unknown") {
        try {
            $ipLat = [decimal]$eventInfo.IPLatitude
            $ipLon = [decimal]$eventInfo.IPLongitude
            $machineLat = [decimal]$eventInfo.MachineLatitude
            $machineLon = [decimal]$eventInfo.MachineLongitude
            
            $latDifference = [Math]::Abs($ipLat - $machineLat)
            $lonDifference = [Math]::Abs($ipLon - $machineLon)
            
            if ($latDifference -gt 0.2500 -or $lonDifference -gt 0.2500) {
                $risks += "IP & Machine Location Do Not Match"
            }
        } catch {
            # Ignore coordinate comparison errors
        }
    }
    
    # Check country locations
    if ($eventInfo.CountryCode -notin @("Unknown", "US")) { $risks += "IP Out of Country" }
    if ($eventInfo.AddressCountryCode -notin @("Unknown", "US")) { $risks += "Machine Out of Country" }
    
    return $risks
}

function Write-LocationEvent($eventInfo, $systemConfig, $previousInfo = $null) {
    $message = "Current Location Info`r`n$($eventInfo.ToWinlog())"
    if ($previousInfo) {
        $excludedProperties = @('IPLatitude', 'IPLongitude', 'MachineLatitude', 'MachineLongitude')
        $prevMessages = $previousInfo.PSObject.Properties | 
                       Where-Object { $excludedProperties -notcontains $_.Name } |
                       ForEach-Object { "$($_.Name): $($_.Value)" }
        $message += "`r`nPrevious Location`r`n" + ($prevMessages -join "`n") + "`n"
    }
    $message += "`r`nDiagnostics`r`n$($systemConfig.ToWinlog())"
    
    # Add risk assessment section
    $risks = Get-RiskAssessment $eventInfo
    $message += "`r`nRisks Noted`r`n"
    if ($risks.Count -gt 0) {
        $risks | ForEach-Object { $message += "$_`n" }
    } else {
        $message += "No risks identified`n"
    }
    
    if ($previousInfo) {
        Set-LoggingConfiguration -EventSource "LocationChange" -EventLog "Application"
        Write-EventLog -LogName "Application" -Source "LocationChange" -EntryType Information -EventId 2002 -Message $message
    } else {
        Set-LoggingConfiguration -EventSource "ScheduledGeoWatcher" -EventLog "Application"
        Write-EventLog -LogName "Application" -Source "ScheduledGeoWatcher" -EntryType Information -EventId 2001 -Message $message
    }
}

## Logic
Try {
    # Main logic
    $DailyEvent = [LocationEvent]::new()
    $SystemConfig = [SystemConfigInfo]::new()
    $SystemConfig.ScanConfig()
    Write-Debug $SystemConfig.ToWinlog()

    $lastLocationDir = "C:\\ProgramData\\GeoWatcher"
    if (-not (Test-Path $lastLocationDir)) {
        New-Item -Path $lastLocationDir -ItemType Directory -Force | Out-Null
    }
    $lastLocationPath = Join-Path $lastLocationDir "last_location.json"
    
    # Run full geolocation lookup
    $DailyEvent.EventInfo.ScanGeoData()
    $currentIsp = $DailyEvent.EventInfo.ISP

    $lastLocationJson = if (Test-Path $lastLocationPath) { Get-Content $lastLocationPath -Raw | ConvertFrom-Json } else { $null }
    $ispChanged = $lastLocationJson -and ($currentIsp -ne $lastLocationJson.ISP)
    
    # Check for significant coordinate changes (0.2000 threshold)
    $coordinateChanged = $false
    if ($lastLocationJson -and $DailyEvent.EventInfo.MachineLatitude -ne "Unknown" -and $DailyEvent.EventInfo.MachineLongitude -ne "Unknown" -and 
        $lastLocationJson.MachineLatitude -ne "Unknown" -and $lastLocationJson.MachineLongitude -ne "Unknown") {
        
        try {
            # Convert and round coordinates to 4 decimal places
            $currentLat = [Math]::Round([decimal]$DailyEvent.EventInfo.MachineLatitude, 4, [MidpointRounding]::AwayFromZero)
            $currentLon = [Math]::Round([decimal]$DailyEvent.EventInfo.MachineLongitude, 4, [MidpointRounding]::AwayFromZero)
            $previousLat = [Math]::Round([decimal]$lastLocationJson.MachineLatitude, 4, [MidpointRounding]::AwayFromZero)
            $previousLon = [Math]::Round([decimal]$lastLocationJson.MachineLongitude, 4, [MidpointRounding]::AwayFromZero)
            
            # Check if difference is 0.2000 or greater
            $latDifference = [Math]::Abs($currentLat - $previousLat)
            $lonDifference = [Math]::Abs($currentLon - $previousLon)
            
            if ($latDifference -ge 0.2000 -or $lonDifference -ge 0.2000) {
                $coordinateChanged = $true
                Write-Debug "Coordinate change detected: Lat diff: $latDifference, Lon diff: $lonDifference"
            }
        } catch {
            Write-Debug "Error comparing coordinates: $($_.Exception.Message)"
        }
    }

    # Determine if any change occurred
    $locationChanged = $ispChanged -or $coordinateChanged

    # Always log current location data, but determine event type based on changes
    if ($locationChanged) {
        $changeReason = @()
        if ($ispChanged) { $changeReason += "ISP changed" }
        if ($coordinateChanged) { $changeReason += "coordinates changed significantly" }
        Write-Debug "Location change detected: $($changeReason -join ', ')."
    } else {
        Write-Debug "No significant changes detected, logging current location info."
    }
    
    Write-LocationEvent $DailyEvent.EventInfo $SystemConfig $(if ($locationChanged) { $lastLocationJson } else { $null })
    
    # Always save current location data
    Save-LocationToFile $DailyEvent.EventInfo $lastLocationPath

} Catch {
    Write-Error "Ran into an error...`r`n$_"

} Finally {
    Write-Host "Script execution completed."
}
