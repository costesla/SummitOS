$config = Get-Content "c:\Users\Peter Teehan\OneDrive - COS Tesla LLC\MobilityOS\Scripts\Stage 2\config_tessie.json" | ConvertFrom-Json
$vin = $config.vin
$token = $config.api_token

# Recent drives
$url = "https://api.tessie.com/$vin/drives?limit=1"
$headers = @{ "Authorization" = "Bearer $token" }

try {
    $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Get
    
    if ($response.results) {
        Write-Host "RAW DRIVE OBJECT DUMP:" -ForegroundColor Yellow
        # Convert to JSON with high depth to see nested objects like location
        $response.results[0] | ConvertTo-Json -Depth 5
    }
    else {
        Write-Host "No drives found to debug."
    }
}
catch {
    Write-Error $_
}
