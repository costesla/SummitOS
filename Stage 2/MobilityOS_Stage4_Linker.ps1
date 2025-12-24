param(
    [string]$SourceFolder = "C:\Users\Peter Teehan\OneDrive - COS Tesla LLC\Pictures\Camera Roll\2025",
    [string]$Date = "2025-12-12"
)

# 1. Config & Auth
$config = Get-Content "c:\Users\Peter Teehan\OneDrive - COS Tesla LLC\MobilityOS\Scripts\Stage 2\config_tessie.json" | ConvertFrom-Json
$vin = $config.vin
$token = $config.api_token

Write-Host "=== MobilityOS Stage 4: Data Fusion ===" -ForegroundColor Cyan
Write-Host "Target Date: $Date"
Write-Host "Source: $SourceFolder"
Write-Host "VIN: $vin"

# 2. Ingest & Cluster Images
$files = Get-ChildItem -Path $SourceFolder -Filter "*.jpg" | Where-Object { $_.LastWriteTime.Date -eq (Get-Date $Date) } | Sort-Object LastWriteTime

if (-not $files) { Write-Warning "No JPGs found for $Date"; exit }

$clusters = @()
$currentCluster = @($files[0])

for ($i = 1; $i -lt $files.Count; $i++) {
    $prev = $files[$i - 1]
    $curr = $files[$i]
    $diff = ($curr.LastWriteTime - $prev.LastWriteTime).TotalMinutes

    if ($diff -gt 20) {
        # New Cluster if gap > 20 mins
        $clusters += , $currentCluster
        $currentCluster = @($curr)
    }
    else {
        $currentCluster += $curr
    }
}
$clusters += , $currentCluster # Add last one

Write-Host "`nFOUND $( $clusters.Count ) TRIP CLUSTERS:" -ForegroundColor Yellow

# 3. Fetch Tessie Data (Global for the Day)
$startUnix = [DateTimeOffset]::new((Get-Date "$Date 00:00:00")).ToUnixTimeSeconds()
$endUnix = [DateTimeOffset]::new((Get-Date "$Date 23:59:59")).ToUnixTimeSeconds()
$headers = @{ "Authorization" = "Bearer $token" }

# Drives
$drivesUrl = "https://api.tessie.com/$vin/drives?from=$($startUnix - 86400)"
$drives = (Invoke-RestMethod -Uri $drivesUrl -Headers $headers).results | Where-Object { $_.started_at -ge $startUnix -and $_.started_at -le $endUnix }

# Charges
$chargesUrl = "https://api.tessie.com/$vin/charges?from=$($startUnix - 86400)"
$charges = (Invoke-RestMethod -Uri $chargesUrl -Headers $headers).results | Where-Object { $_.started_at -ge $startUnix -and $_.started_at -le $endUnix }

# 4. Correlate
$tripIndex = 1
foreach ($cluster in $clusters) {
    $startTime = $cluster[0].LastWriteTime
    $endTime = $cluster[-1].LastWriteTime
    # Buffer window (15 mins before first pic, 15 mins after last pic)
    $windowStart = $startTime.AddMinutes(-30)
    $windowEnd = $endTime.AddMinutes(30)
    
    Write-Host "`n------------------------------------------------"
    Write-Host "TRIP #$tripIndex (Files: $($cluster.Count))" -ForegroundColor Green
    Write-Host "Window: $($startTime.ToString('t')) - $($endTime.ToString('t'))"
    
    # List Files
    $cluster | ForEach-Object { Write-Host "   - $($_.Name) ($($_.LastWriteTime.ToString('t')))" }

    # Find Matching Drive
    $matchDrive = $drives | Where-Object { 
        $dStart = [TimeZoneInfo]::ConvertTimeFromUtc([datetimeoffset]::FromUnixTimeSeconds($_.started_at).DateTime, [TimeZoneInfo]::Local)
        return ($dStart -ge $windowStart -and $dStart -le $windowEnd)
    }

    # Find Matching Charge
    $matchCharge = $charges | Where-Object {
        $cStart = [TimeZoneInfo]::ConvertTimeFromUtc([datetimeoffset]::FromUnixTimeSeconds($_.started_at).DateTime, [TimeZoneInfo]::Local)
        return ($cStart -ge $windowStart -and $cStart -le $windowEnd)
    }

    if ($matchDrive) {
        Write-Host "   [TESLA DRIVE MATCHED]: $($matchDrive.Count) Leg(s)" -ForegroundColor Cyan
        $matchDrive | ForEach-Object { 
            $dur = [math]::Round(($_.ended_at - $_.started_at) / 60, 1)
            Write-Host "      -> Drive: $dur mins, $($_.distance) mi" 
        }
    }
    
    if ($matchCharge) {
        Write-Host "   [TESLA CHARGE MATCHED]: $($matchCharge.Count) Session(s)" -ForegroundColor Magenta
        $matchCharge | ForEach-Object {
            Write-Host "      -> Charge: $($_.location) ($($_.energy_added) kWh) - Cost: `$$($_.cost)"
        }
    }

    $tripIndex++
}
Write-Host "`nDone."
