$config = Get-Content "c:\Users\Peter Teehan\OneDrive - COS Tesla LLC\MobilityOS\Scripts\Stage 2\config_tessie.json" | ConvertFrom-Json
$token = $config.api_token

$headers = @{
    "Authorization" = "Bearer $token"
    "Accept"        = "application/json"
}

$url = "https://api.tessie.com/vehicles"
try {
    $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Get
    
    $response.results | ForEach-Object {
        [PSCustomObject]@{
            Name     = $_.display_name
            VIN      = $_.vin
            Odometer = $_.vehicle_state.odometer
            Status   = $_.state
            LastSeen = [TimeZoneInfo]::ConvertTimeFromUtc([datetimeoffset]::FromUnixTimeMilliseconds($_.last_state_change).DateTime, [TimeZoneInfo]::Local)
        }
    } | Format-Table -AutoSize
}
catch {
    Write-Error "API Call Failed: $_"
}
