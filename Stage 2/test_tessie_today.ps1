$config = Get-Content "c:\Users\Peter Teehan\OneDrive - COS Tesla LLC\MobilityOS\Scripts\Stage 2\config_tessie.json" | ConvertFrom-Json
$vin = $config.vin
$token = $config.api_token

# Define "Today" (Dec 12, 2025)
$startStr = "2025-12-12 00:00:00"
$endStr = "2025-12-12 23:59:59"

$startDate = Get-Date $startStr
$endDate = Get-Date $endStr

# Convert to Unix Timestamp (DateTimeOffset is reliable in pwsh)
$startUnix = [DateTimeOffset]::new($startDate).ToUnixTimeSeconds()
$endUnix = [DateTimeOffset]::new($endDate).ToUnixTimeSeconds()

Write-Host "Checking charges for VIN: $vin"
Write-Host "Window: $startStr ($startUnix) to $endStr ($endUnix)"

$headers = @{
    "Authorization" = "Bearer $token"
    "Accept"        = "application/json"
}

# Request charges starting a bit before to be safe
$url = "https://api.tessie.com/$vin/charges?from=$($startUnix - 86400)" # 24hr buffer

try {
    $charges = Invoke-RestMethod -Uri $url -Headers $headers -Method Get
    
    # Normalize results
    if ($charges.results) { $data = $charges.results } else { $data = $charges }

    # Filter strictly for the target window
    $todaysSessions = $data | Where-Object { 
        $_.started_at -ge $startUnix -and $_.started_at -le $endUnix
    }

    if ($todaysSessions) {
        Write-Host "`nSUCCESS: Found $( $todaysSessions.Count ) session(s) today."
        $todaysSessions | ForEach-Object {
            $localTime = [TimeZoneInfo]::ConvertTimeFromUtc([datetimeoffset]::FromUnixTimeSeconds($_.started_at).DateTime, [TimeZoneInfo]::Local)
            [PSCustomObject]@{
                Time      = $localTime
                Location  = $_.location
                kWh_Added = $_.energy_added
                Start_SOC = $_.starting_battery
                End_SOC   = $_.ending_battery
                Cost      = $_.cost
                ID        = $_.id
            }
        } | Format-Table -AutoSize
    }
    else {
        Write-Host "`nNo sessions start strictly within 12/12/2025."
        Write-Host "Latest 3 sessions found (for debug):"
        $data | Sort-Object started_at -Descending | Select-Object -First 3 | ForEach-Object {
            [PSCustomObject]@{
                Time = [TimeZoneInfo]::ConvertTimeFromUtc([datetimeoffset]::FromUnixTimeSeconds($_.started_at).DateTime, [TimeZoneInfo]::Local)
                Loc  = $_.location
            }
        } | Format-Table -AutoSize
    }

}
catch {
    Write-Error "API Request Failed: $_"
}
