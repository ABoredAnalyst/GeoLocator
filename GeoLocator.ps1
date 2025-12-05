# -----------------------------------------------------------------------------
# SCRIPT: GeoWatcherandDiag.ps1
# DESCRIPTION: Combines diagnostic checks with geolocation retrieval.
#              First validates that location is enabled, checks Wi-Fi and 
#              Airplane Mode status, then retrieves geolocation and reverse
#              geocodes the coordinates into a human-readable address.
# REQUIREMENTS: Windows Location Services must be enabled and permission granted.
# -----------------------------------------------------------------------------

# 1. Diagnostic Checks - Verify prerequisites
Write-Host "Running diagnostic checks..."

# Check Location Enable/Disable status
$locPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors'
$locationEnabled = $true
if (Test-Path $locPath) {
    $locProps = Get-ItemProperty -Path $locPath -ErrorAction SilentlyContinue
    if ($null -ne $locProps -and $locProps.PSObject.Properties.Name -contains 'DisableLocation') {
        $disable = [int]$locProps.DisableLocation
        if ($disable -eq 0) {
            Write-Host "Location services: Enabled"
        }
        else {
            Write-Error "Location services: Disabled (DisableLocation=$disable)"
            exit 1
        }
    }
}

# Check AppPrivacy LetAppsAccessLocation
$appPrivPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
if (Test-Path $appPrivPath) {
    $appProps = Get-ItemProperty -Path $appPrivPath -ErrorAction SilentlyContinue
    if ($null -ne $appProps -and $appProps.PSObject.Properties.Name -contains 'LetAppsAccessLocation') {
        $val = [int]$appProps.LetAppsAccessLocation
        if ($val -eq 1) {
            Write-Host "LetAppsAccessLocation: Enabled"
        }
        else {
            Write-Warning "LetAppsAccessLocation is set to $val. Apps may be blocked from accessing location."
        }
    }
}

# Check Wi-Fi status
$wifiEnabled = $false
try {
    $netshOutput = netsh wlan show interfaces 2>$null
    if ($LASTEXITCODE -eq 0 -and $netshOutput) {
        if ($netshOutput -match 'Radio status' -and $netshOutput -match 'Hardware On' -and $netshOutput -match 'Software On') {
            $wifiEnabled = $true
        }
        elseif ($netshOutput -match 'State\s*:\s*connected') {
            $wifiEnabled = $true
        }
    }
}
catch { }
if (-not $wifiEnabled) {
    $adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -match 'Wireless' -or $_.Name -match 'Wi-Fi' -or $_.Name -match 'Wireless' }
    if ($null -ne $adapters) {
        foreach ($a in $adapters) {
            if ($a.Status -eq 'Up') {
                $wifiEnabled = $true
                break
            }
        }
    }
}

if ($wifiEnabled) {
    Write-Host "Wi-Fi: Enabled/Available"
}
else {
    Write-Host "Wi-Fi: Not available or disabled"
}

# Check Airplane Mode status
$radioReg = 'HKLM:\System\CurrentControlSet\Control\RadioManagement\SystemRadioState'
$airplaneOn = $false
if (Test-Path $radioReg) {
    $reg = Get-ItemProperty -Path $radioReg -ErrorAction SilentlyContinue
    if ($null -ne $reg) {
        if ($reg.PSObject.Properties.Name -contains '(default)') {
            $val = $reg.'(default)'
        }
        elseif ($reg.PSObject.Properties.Name -contains '') {
            $val = $reg.''
        }
        else {
            $val = $null
        }
        if ($null -ne $val -and [int]$val -eq 1) {
            $airplaneOn = $true
        }
    }
}

if ($airplaneOn) {
    Write-Host "Airplane Mode: Enabled"
}
else {
    Write-Host "Airplane Mode: Disabled"
}

# Warn if Wi-Fi is disabled or Airplane Mode is enabled
if (-not $wifiEnabled -or $airplaneOn) {
    Write-Warning "Unable to perform Wi-Fi triangulation. GeoLocation will be based off of IP address. Accuracy may vary."
}

Write-Host "Diagnostic checks complete.`n"

# 2. Load the necessary .NET Assembly for Geolocation services
try {
    Add-Type -AssemblyName System.Device
}
catch {
    Write-Error "Failed to load System.Device assembly. Geolocation services may be unavailable."
    exit 1
}

# 3. Initialize the GeoLocator
$GeoLocator = New-Object System.Device.Location.GeoCoordinateWatcher
$TimeoutSeconds = 5 # Set a maximum wait time
$StartTime = Get-Date

Write-Host "Starting location locator. Waiting up to $TimeoutSeconds seconds for coordinates..."

# Start the locator
$GeoLocator.Start()

# 4. Wait for the locator to become ready, checking status and permissions
$IsReady = $false
while ((Get-Date) -le ($StartTime).AddSeconds($TimeoutSeconds)) {
    if ($GeoLocator.Status -eq 'Ready') {
        $IsReady = $true
        break
    }
    if ($GeoLocator.Permission -eq 'Denied') {
        Write-Error 'Location access permission was explicitly denied by the system or user.'
        exit 1
    }
    Start-Sleep -Milliseconds 250
}

# Define status messages for better error reporting
$statusMap = @{
    'Disabled'       = "Location access has been disabled in system settings."
    'NotInitialized' = "Location provider is initializing."
    'NoData'         = "Location provider is not returning data."
    'Unknown'        = "Location status is unknown."
    'Denied'         = "Location access was explicitly denied by the user/system."
}

# 5. Process the Location Data and Resolve Address
if (-not $IsReady) {
    $currentStatus = $GeoLocator.Status
    $errorMessage = $statusMap[$currentStatus]
    if (-not $errorMessage) {
        $errorMessage = "Timed out waiting for GPS coordinates. Status: $currentStatus"
    }
    Write-Warning $errorMessage
}
elseif ($GeoLocator.Permission -eq 'Denied') {
    # Handled above, but a final check for clarity
    Write-Error 'Location access permission was denied.'
}
else {
    $location = $GeoLocator.Position.Location

    if ($null -ne $location -and $location.IsUnknown -eq $false) {
        $latitude = $location.Latitude
        $longitude = $location.Longitude
        # Use ISO 8601 format for robust timestamps
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

        Write-Host "Coordinates found: Lat $latitude, Lon $longitude"

        # 6. Reverse Geocode Coordinates using OpenStreetMap Nominatim
        try {
            # The URL for the Nominatim reverse lookup
            $nominatimUrl = "https://nominatim.openstreetmap.org/reverse?format=json&lat=$latitude&lon=$longitude"

            # Use a User-Agent header as a courtesy to public APIs
            $headers = @{'User-Agent' = 'PowerShell Script (Personal Use)' }

            # Fetch location data from the API
            $locationData = Invoke-RestMethod -Uri $nominatimUrl -Headers $headers -ErrorAction Stop

            $locationName = $locationData.display_name
            $googleMapsUrl = "https://www.google.com/maps?q=$latitude,$longitude"

            # 7. Output the final data as a structured object
            [PSCustomObject]@{
                Timestamp       = $timestamp
                Latitude        = $latitude
                Longitude       = $longitude
                GoogleMapsLink  = $googleMapsUrl
                ResolvedAddress = $locationName
            } | Write-Output
        }
        catch {
            Write-Warning "Could not resolve address via Nominatim API. Error: $($_.Exception.Message)"
            # Fallback output with available data
            [PSCustomObject]@{
                Timestamp       = $timestamp
                Latitude        = $latitude
                Longitude       = $longitude
                GoogleMapsLink  = "https://www.google.com/maps?q=$latitude,$longitude"
                ResolvedAddress = "Address resolution failed (API error)."
            } | Write-Output
        }
    }
    else {
        Write-Warning 'GPS coordinates could not be resolved or are unknown.'
    }
}

# Stop the locator to free resources
$GeoLocator.Stop()
