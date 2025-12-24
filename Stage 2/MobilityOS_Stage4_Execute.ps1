param(
    [string]$SourceFolder = "C:\Users\Peter Teehan\OneDrive - COS Tesla LLC\Pictures\Camera Roll\2025",
    [string]$DestRoot = "C:\Users\Peter Teehan\OneDrive - COS Tesla LLC\MobilityOS\Uber Tracking\2025\Processed",
    [string]$Date = "2025-12-12"
)

# 1. Config & Auth
$config = Get-Content "c:\Users\Peter Teehan\OneDrive - COS Tesla LLC\MobilityOS\Scripts\Stage 2\config_tessie.json" | ConvertFrom-Json
$vin = $config.vin
$token = $config.api_token

# 1b. Helper: Week of Month
function Get-WeekOfMonth {
    param([datetime]$Date)
    $weekOfMonth = [math]::Ceiling($Date.Day / 7.0)
    if ($weekOfMonth -gt 4) { $weekOfMonth = 4 }
    return $weekOfMonth
}

Write-Host "=== MobilityOS Stage 4: EXECUTION ===" -ForegroundColor Cyan

# 2. Path Logic (Year / Month / Week / Day)
$yearStr = $Date.Split("-")[0]      # 2025
$monthStr = (Get-Date $Date).ToString("MMMM") # December
$weekNum = Get-WeekOfMonth (Get-Date $Date)
$weekStr = "Week $weekNum"
$dayStr = (Get-Date $Date).ToString("MM.dd.yy") # 12.15.25

# Construct Target Root: ...\Uber Tracking\2025\December\Week 3\12.15.25
$DayRoot = Join-Path "C:\Users\Peter Teehan\OneDrive - COS Tesla LLC\MobilityOS\Uber Tracking" $yearStr
$DayRoot = Join-Path $DayRoot $monthStr
$DayRoot = Join-Path $DayRoot $weekStr
$DayRoot = Join-Path $DayRoot $dayStr

if (-not (Test-Path $DayRoot)) { 
    Write-Host "Creating Day Folder: $DayRoot" -ForegroundColor Green
    New-Item -ItemType Directory -Path $DayRoot -Force | Out-Null 
}

# 2. Ingest & Cluster
$files = Get-ChildItem -Path $SourceFolder -Filter "*.jpg" | Where-Object { $_.LastWriteTime.Date -eq (Get-Date $Date) } | Sort-Object LastWriteTime
if (-not $files) { Write-Warning "No JPGs found for $Date"; exit }

$clusters = @()
$currentCluster = @($files[0])

for ($i = 1; $i -lt $files.Count; $i++) {
    $diff = ($files[$i].LastWriteTime - $files[$i - 1].LastWriteTime).TotalMinutes
    if ($diff -gt 20) { 
        $clusters += , $currentCluster
        $currentCluster = @($files[$i])
    }
    else {
        $currentCluster += $files[$i]
    }
}
$clusters += , $currentCluster

# 3. Fetch Tessie Data
$startUnix = [DateTimeOffset]::new((Get-Date "$Date 00:00:00")).ToUnixTimeSeconds()
$endUnix = [DateTimeOffset]::new((Get-Date "$Date 23:59:59")).ToUnixTimeSeconds()
$headers = @{ "Authorization" = "Bearer $token" }

$drives = (Invoke-RestMethod -Uri "https://api.tessie.com/$vin/drives?from=$($startUnix - 86400)" -Headers $headers).results | Where-Object { $_.started_at -ge $startUnix -and $_.started_at -le $endUnix }
$charges = (Invoke-RestMethod -Uri "https://api.tessie.com/$vin/charges?from=$($startUnix - 86400)" -Headers $headers).results | Where-Object { $_.started_at -ge $startUnix -and $_.started_at -le $endUnix }

# 4. Process Clusters
$tripIndex = 1
foreach ($cluster in $clusters) {
    $startTime = $cluster[0].LastWriteTime
    $timeStr = $startTime.ToString("HHmm")
    
    # Analyze Cluster for Tessie Matches
    $windowStart = $startTime.AddMinutes(-30)
    $windowEnd = $cluster[-1].LastWriteTime.AddMinutes(30)

    $matchDrive = $drives | Where-Object { $dStart = [TimeZoneInfo]::ConvertTimeFromUtc([datetimeoffset]::FromUnixTimeSeconds($_.started_at).DateTime, [TimeZoneInfo]::Local); return ($dStart -ge $windowStart -and $dStart -le $windowEnd) }
    $matchCharge = $charges | Where-Object { $cStart = [TimeZoneInfo]::ConvertTimeFromUtc([datetimeoffset]::FromUnixTimeSeconds($_.started_at).DateTime, [TimeZoneInfo]::Local); return ($cStart -ge $windowStart -and $cStart -le $windowEnd) }

    # Naming Logic
    $tags = @()
    if ($matchCharge) { $tags += "Charge" }
    if ($matchDrive) { $tags += "Drive" }
    if ($cluster.Count -gt 5) { $tags += "LargeScan" }
    $tagStr = if ($tags) { $tags -join "_" } else { "Scan" }
    
    $folderName = "${Date}_${timeStr}_Event_${tripIndex}_${tagStr}"
    $tripFolder = Join-Path $DayRoot $folderName
    
    Write-Host "Creating: $folderName" -ForegroundColor Green
    New-Item -ItemType Directory -Path $tripFolder -Force | Out-Null
    
    # Link Data
    $dataObj = [ordered]@{
        EventID        = $folderName
        ImageCount     = $cluster.Count
        Timestamp      = $startTime
        Tessie_Charges = @($matchCharge | Select-Object -Property energy_added, cost, location, starting_battery, ending_battery)
        Tessie_Drives  = @($matchDrive | Select-Object -Property distance, efficiency, start_location, end_location)
    }
    
    $jsonPath = Join-Path $tripFolder "tessie_data.json"
    $dataObj | ConvertTo-Json -Depth 5 | Out-File $jsonPath
    
    # Move Images
    foreach ($file in $cluster) {
        $destFile = Join-Path $tripFolder $file.Name
        Move-Item -LiteralPath $file.FullName -Destination $destFile -Force
    }
    
    $tripIndex++
}

Write-Host "`nPROCESSING COMPLETE." -ForegroundColor Cyan
