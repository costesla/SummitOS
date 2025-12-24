$config = Get-Content "c:\Users\Peter Teehan\OneDrive - COS Tesla LLC\MobilityOS\Scripts\Stage 2\config_tessie.json" | ConvertFrom-Json
$vin = $config.vin
$token = $config.api_token

# Define "Today" (Dec 12, 2025)
$startStr = "2025-12-12 00:00:00"
$endStr = "2025-12-12 23:59:59"

$startDate = Get-Date $startStr
$endDate = Get-Date $endStr

# Convert to Unix Timestamp
$startUnix = [DateTimeOffset]::new($startDate).ToUnixTimeSeconds()
$endUnix = [DateTimeOffset]::new($endDate).ToUnixTimeSeconds()

Write-Host "Checking DRIVES for VIN: $vin"
Write-Host "Window: $startStr to $endStr"

$headers = @{
    "Authorization" = "Bearer $token"
    "Accept"        = "application/json"
}

# Request drives starting a bit before to be safe
$url = "https://api.tessie.com/$vin/drives?from=$($startUnix - 86400)"

try {
    $drives = Invoke-RestMethod -Uri $url -Headers $headers -Method Get
    
    # Normalize results
    if ($drives.results) { $data = $drives.results } else { $data = $drives }

    # Filter strictly for today
    $todaysDrives = $data | Where-Object { 
        $_.started_at -ge $startUnix -and $_.started_at -le $endUnix
    }

    if ($todaysDrives) {
        Write-Host "`nSUCCESS: Found $( $todaysDrives.Count ) drive(s) today."
        $todaysDrives | Sort-Object started_at | ForEach-Object {
            $localTimeStart = [TimeZoneInfo]::ConvertTimeFromUtc([datetimeoffset]::FromUnixTimeSeconds($_.started_at).DateTime, [TimeZoneInfo]::Local)
            $localTimeEnd = [TimeZoneInfo]::ConvertTimeFromUtc([datetimeoffset]::FromUnixTimeSeconds($_.ended_at).DateTime, [TimeZoneInfo]::Local)
            
            [PSCustomObject]@{
                Start_Time   = $localTimeStart
                End_Time     = $localTimeEnd
                Duration_Min = [math]::Round(($_.ended_at - $_.started_at) / 60, 1)
                Distance_Mi  = $_.distance
                Start_Loc    = $_.start_location
                End_Loc      = $_.end_location
                Efficiency   = $_.efficiency
            }
        } | Format-Table -AutoSize
    }
    else {
        Write-Host "No drives found for today."
    }

}
catch {
    Write-Error "API Request Failed: $_"
}
