$config = Get-Content "c:\Users\Peter Teehan\OneDrive - COS Tesla LLC\MobilityOS\Scripts\Stage 2\config_tessie.json" | ConvertFrom-Json
$token = $config.api_token

$headers = @{
    "Authorization" = "Bearer $token"
    "Accept"        = "application/json"
}

# 1. Get All Vehicles and find "Thor"
Write-Host "Looking for vehicle 'Thor'..."
$url_vehicles = "https://api.tessie.com/vehicles"
$vehicles = Invoke-RestMethod -Uri $url_vehicles -Headers $headers -Method Get

$thor = $vehicles.results | Where-Object { $_.display_name -eq "Thor" }

if (-not $thor) {
    Write-Error "Vehicle 'Thor' not found on this account."
    exit
}

$thorVIN = $thor.vin
Write-Host "Found 'Thor'. VIN: $thorVIN"
Write-Host "Odometer: $($thor.vehicle_state.odometer)"

# 2. Get Charges for Thor Today
# Dec 12, 2025 Start: 1765522800 (approx UTC, keeping it loose)
$searchStart = 1765522800 

$url_charges = "https://api.tessie.com/$thorVIN/charges?from=$searchStart"
Write-Host "`nFetching charges for Thor since today 00:00..."

try {
    $charges = Invoke-RestMethod -Uri $url_charges -Headers $headers -Method Get
    
    if ($charges.results) { $data = $charges.results } else { $data = $charges }
    
    if ($data) {
        $data | ForEach-Object {
            $dateStart = [TimeZoneInfo]::ConvertTimeFromUtc([datetimeoffset]::FromUnixTimeSeconds($_.started_at).DateTime, [TimeZoneInfo]::Local)
            [PSCustomObject]@{
                Date      = $dateStart
                Location  = $_.location
                Added_kWh = $_.energy_added
                Cost      = $_.cost
                Start_SOC = $_.starting_battery
                End_SOC   = $_.ending_battery
            }
        } | Format-Table -AutoSize
        
        # Output raw JSON of the Pueblo charge for the user
        $pueblo = $data | Where-Object { $_.location -match "Pueblo" }
        if ($pueblo) {
            Write-Host "`nMATCHED PUEBLO CHARGE JSON:"
            $pueblo | ConvertTo-Json -Depth 5
        }
    }
    else {
        Write-Host "No charges found for Thor today."
    }

}
catch {
    Write-Error "Charges call failed: $_"
}
