$config = Get-Content "c:\Users\Peter Teehan\OneDrive - COS Tesla LLC\MobilityOS\Scripts\Stage 2\config_tessie.json" | ConvertFrom-Json
$vin = $config.vin
$token = $config.api_token

$headers = @{
    "Authorization" = "Bearer $token"
    "Accept"        = "application/json"
}

# 1. Get Current State (might contain last charge info)
$url_state = "https://api.tessie.com/$vin/state"
try {
    Write-Host "Fetching State..."
    $state = Invoke-RestMethod -Uri $url_state -Headers $headers -Method Get
    $state.charge_state | ConvertTo-Json -Depth 5
}
catch {
    Write-Host "State Fetch Failed: $_"
}

# 2. Try to get charges with a specific filter to find the one today
Write-Host "`nFetching Recent Charges..."
# Timestamp for Dec 12, 2025 start: 1765497600
$url_charges = "https://api.tessie.com/$vin/charges?from=1765497600" 
try {
    $charges = Invoke-RestMethod -Uri $url_charges -Headers $headers -Method Get
    $charges.results | ConvertTo-Json -Depth 5
}
catch {
    Write-Host "Charges Fetch Failed: $_"
}
