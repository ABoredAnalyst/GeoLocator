# -----------------------------------------------------------------------------
# SCRIPT: Toggle-WifiRadio.ps1
# DESCRIPTION: Programmatically sets the Wi-Fi radio state to 'On' using
#              the modern Windows Runtime (WinRT) APIs.
# -----------------------------------------------------------------------------

## 1. WinRT Bridge and Await Function Setup

# Load the necessary .NET assembly to bridge the classic PowerShell/CLR environment
# with the modern Windows Runtime (WinRT) APIs, which control hardware.
Add-Type -AssemblyName System.Runtime.WindowsRuntime

# Find the generic 'AsTask' method used to convert asynchronous WinRT operations
# into synchronous .NET Tasks that PowerShell can wait for.
$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | 
    Where-Object { 
        $_.Name -eq 'AsTask' -and 
        $_.GetParameters().Count -eq 1 -and 
        $_.GetParameters()[0].ParameterType.Name -match 'IAsyncOperation' 
    }
)[0]

# Define the 'Await' function to synchronously wait for a WinRT async operation 
# to complete and return its result.
function Await($WinRtTask, [type]$ResultType) {
    # Create a specific version of AsTask for the expected result type
    $as = $asTaskGeneric.MakeGenericMethod($ResultType)
    # Invoke the conversion to get a standard .NET Task
    $netTask = $as.Invoke($null, @($WinRtTask))
    # Block execution (wait forever, -1) until the task is complete
    $netTask.Wait(-1) | Out-Null
    # Return the result of the completed task
    $netTask.Result
}

## 2. Load Required WinRT Namespaces

# Explicitly load the WinRT classes needed to interact with and control wireless radios.
[Windows.Devices.Radios.Radio,Windows.System.Devices,ContentType=WindowsRuntime] | Out-Null
[Windows.Devices.Radios.RadioAccessStatus,Windows.System.Devices,ContentType=WindowsRuntime] | Out-Null
[Windows.Devices.Radios.RadioState,Windows.System.Devices,ContentType=WindowsRuntime] | Out-Null

## 3. Execute Control Logic

# Request permission from the OS to access the radio hardware. Wait for the result.
Await ([Windows.Devices.Radios.Radio]::RequestAccessAsync()) ([Windows.Devices.Radios.RadioAccessStatus]) | Out-Null

# Get a list of all available wireless radios (Wi-Fi, Bluetooth, etc.).
$radios = Await ([Windows.Devices.Radios.Radio]::GetRadiosAsync()) ([System.Collections.Generic.IReadOnlyList[Windows.Devices.Radios.Radio]])

# Filter the list to find the object representing the Wi-Fi adapter.
$wifi = $radios | Where-Object { $_.Kind -eq 'WiFi' }

if ($wifi) {
    # If the Wi-Fi radio is found:
    # Set the state of the Wi-Fi radio to 'On' (RadioState::On).
    # The result (success/failure) is awaited but discarded.
    Await ($wifi.SetStateAsync([Windows.Devices.Radios.RadioState]::On)) ([Windows.Devices.Radios.RadioAccessStatus]) | Out-Null
    
    # Output the final state of the Wi-Fi radio.
    $wifi.State
} else {
    # Output a failure message if the adapter was not found.
    'No Wi-Fi radio found'
}
