$config = Get-Content "c:\Users\Peter Teehan\OneDrive - COS Tesla LLC\MobilityOS\Scripts\Stage 2\config_tessie.json" | ConvertFrom-Json
$vin = $config.vin
$token = $config.api_token

$headers = @{
    "Authorization" = "Bearer $token"
    "Accept"        = "application/json"
}

$url = "https://api.tessie.com/vehicles"

try {
    $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Get
    if ($response.results) {
        $response.results | ConvertTo-Json -Depth 5
    }
    else {
        "No results found."
        $response | ConvertTo-Json -Depth 5
    }
}
catch {
    Write-Error "API Call Failed: $_"
}
