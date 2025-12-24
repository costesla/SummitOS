$config = Get-Content "c:\Users\Peter Teehan\OneDrive - COS Tesla LLC\MobilityOS\Scripts\Stage 2\config_tessie.json" | ConvertFrom-Json
$vin = $config.vin
$token = $config.api_token

$headers = @{
    "Authorization" = "Bearer $token"
    "Accept"        = "application/json"
}

Write-Host "Fetching All Charges (this might take a moment)..."
$url = "https://api.tessie.com/$vin/charges"
try {
    $charges = Invoke-RestMethod -Uri $url -Headers $headers -Method Get
    # Assuming 'results' is the array or the response is the array
    if ($charges.results) {
        $data = $charges.results
    }
    else {
        $data = $charges
    }

    Write-Host "Total Charges Found: $($data.Count)"
    Write-Host "Most Recent 5 Charges:"
    $data | Sort-Object -Property date | Select-Object -Last 5 | ConvertTo-Json -Depth 5
}
catch {
    Write-Error "Charges Fetch Failed: $_"
}
