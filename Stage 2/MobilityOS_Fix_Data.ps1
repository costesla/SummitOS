param(
    [string]$ProcessedRoot = "C:\Users\Peter Teehan\OneDrive - COS Tesla LLC\MobilityOS\Uber Tracking\2025\Processed",
    [string]$Date = "2025-12-12"
)

# 1. Config & Auth
$config = Get-Content "c:\Users\Peter Teehan\OneDrive - COS Tesla LLC\MobilityOS\Scripts\Stage 2\config_tessie.json" | ConvertFrom-Json
$vin = $config.vin
$token = $config.api_token

Write-Host "=== MobilityOS Data Repair: Re-Fetching Metadata ===" -ForegroundColor Cyan
Write-Host "Target: $ProcessedRoot"

# 2. Fetch Global Tessie Data for the Day
$startUnix = [DateTimeOffset]::new((Get-Date "$Date 00:00:00")).ToUnixTimeSeconds()
$endUnix = [DateTimeOffset]::new((Get-Date "$Date 23:59:59")).ToUnixTimeSeconds()
$headers = @{ "Authorization" = "Bearer $token" }

$drivesUrl = "https://api.tessie.com/$vin/drives?from=$($startUnix - 86400)"
$drives = (Invoke-RestMethod -Uri $drivesUrl -Headers $headers).results | Where-Object { $_.started_at -ge $startUnix -and $_.started_at -le $endUnix }

$chargesUrl = "https://api.tessie.com/$vin/charges?from=$($startUnix - 86400)"
$charges = (Invoke-RestMethod -Uri $chargesUrl -Headers $headers).results | Where-Object { $_.started_at -ge $startUnix -and $_.started_at -le $endUnix }

# 3. Process Existing Folders
$folders = Get-ChildItem -Path $ProcessedRoot -Directory | Where-Object { $_.Name -match $Date }

foreach ($folder in $folders) {
    Write-Host "`nUpdating: $($folder.Name)" -NoNewline
    
    if ($folder.Name -match "(\d{4}-\d{2}-\d{2})_(\d{4})") {
        $d = $matches[1]
        $t = $matches[2]
        $tStr = $t.Insert(2, ":")
        $eventTime = Get-Date "$d $tStr"
        
        $windowStart = $eventTime.AddMinutes(-30)
        $windowEnd = $eventTime.AddMinutes(30)
        
        $matchDrive = $drives | Where-Object { 
            $dStart = [TimeZoneInfo]::ConvertTimeFromUtc([datetimeoffset]::FromUnixTimeSeconds($_.started_at).DateTime, [TimeZoneInfo]::Local)
            return ($dStart -ge $windowStart -and $dStart -le $windowEnd)
        }
        
        $matchCharge = $charges | Where-Object { 
            $cStart = [TimeZoneInfo]::ConvertTimeFromUtc([datetimeoffset]::FromUnixTimeSeconds($_.started_at).DateTime, [TimeZoneInfo]::Local)
            return ($cStart -ge $windowStart -and $cStart -le $windowEnd)
        }
        
        $driveList = @()
        if ($matchDrive) {
            $matchDrive | ForEach-Object {
                $driveList += [ordered]@{
                    started_at     = $_.started_at
                    distance_miles = $_.odometer_distance  # CORRECTED PROPERTY
                    efficiency     = $_.energy_used            # CORRECTED PROEPRTY
                    start_location = $_.starting_location  # CORRECTED PROPERTY
                    end_location   = $_.ending_location      # CORRECTED PROPERTY
                    duration_min   = [math]::Round(($_.ended_at - $_.started_at) / 60, 1)
                }
            }
            Write-Host " [Added $( $driveList.Count ) Drives]" -ForegroundColor Green
        }

        $chargeList = @()
        if ($matchCharge) {
            $matchCharge | ForEach-Object {
                $chargeList += [ordered]@{
                    started_at   = $_.started_at
                    energy_added = $_.energy_added
                    cost         = $_.cost
                    location     = $_.location
                    start_soc    = $_.starting_battery
                    end_soc      = $_.ending_battery
                }
            }
            Write-Host " [Added $( $chargeList.Count ) Charges]" -ForegroundColor Magenta
        }

        $imgCount = (Get-ChildItem -Path $folder.FullName -Filter "*.jpg").Count

        $dataObj = [ordered]@{
            EventID        = $folder.Name
            ImageCount     = $imgCount
            Timestamp      = $eventTime
            Tessie_Charges = $chargeList
            Tessie_Drives  = $driveList
        }
        
        $jsonPath = Join-Path $folder.FullName "tessie_data.json"
        $dataObj | ConvertTo-Json -Depth 5 | Out-File $jsonPath
    }
}
Write-Host "`nRepair Complete."
