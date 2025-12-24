param(
    [string]$ProcessedRoot = "C:\Users\Peter Teehan\OneDrive - COS Tesla LLC\MobilityOS\Uber Tracking\2025\Processed",
    [string]$Date = "2025-12-12"
)

Write-Host "=== MobilityOS Stage 5: Advanced Reporting (Split Stream) ===" -ForegroundColor Cyan

$uberRows = @()
$privateRows = @()

# Get all Processed Folders for Date
$folders = Get-ChildItem -Path $ProcessedRoot -Directory | Where-Object { $_.Name -match $Date }

foreach ($folder in $folders) {
    $jsonPath = Join-Path $folder.FullName "tessie_data.json"
    if (-not (Test-Path $jsonPath)) { continue }
    
    $json = Get-Content $jsonPath | ConvertFrom-Json
    
    # 1. Classification Logic (Content Awareness)
    $files = Get-ChildItem -Path $folder.FullName -File
    $hasUber = $files | Where-Object { $_.Name -match "(?i)Uber" }
    $hasPayment = $files | Where-Object { $_.Name -match "(?i)Zelle|Venmo|CashApp" }
    
    # "Private" if Payment found OR if it's explicitly identified as the Return Trip (Event 7 or 8 context)
    # Default to Uber if Uber screenshots exist, unless Payment overrides.
    
    $category = "Uber"
    if ($hasPayment) { $category = "Private" }
    elseif (-not $hasUber) { $category = "Private/Other" }
    
    # 2. Extract Deep Drive Datasets
    # We will grab the PRIMARY matched drive (longest distance) for the main metrics
    $primaryDrive = $null
    $totalDriveMiles = 0
    $driveDetails = ""
    
    
    function Parse-Address($addr) {
        if (-not $addr) { return @{ Street = ""; City = ""; Zip = "" } }
        
        # Regex to split typical Tessie format: 
        # "23 East Tyler Street, Colorado Springs, Colorado 80907, United States"
        # Group 1: Street, Group 2: City, Group 3: State, Group 4: Zip
        if ($addr -match "^(.*),\s*([^,]+),\s*([^,]+)\s+(\d{5})") {
            return @{
                Street = $matches[1].Trim()
                City   = $matches[2].Trim()
                Zip    = $matches[4].Trim()
            }
        }
        # Fallback if format is weird
        return @{ Street = $addr; City = ""; Zip = "" }
    }

    $sAddr = @{ Street = ""; City = ""; Zip = "" }
    $eAddr = @{ Street = ""; City = ""; Zip = "" }

    if ($json.Tessie_Drives) {
        # Filter out nulls/empties if any
        $validDrives = $json.Tessie_Drives | Where-Object { $_.distance_miles -gt 0 }
        
        if ($validDrives) {
            $totalDriveMiles = ($validDrives | Measure-Object -Property distance_miles -Sum).Sum
            $primaryDrive = $validDrives | Sort-Object distance_miles -Descending | Select-Object -First 1
            
            # Start/End Parsing
            $sAddr = Parse-Address $primaryDrive.start_location
            $eAddr = Parse-Address $primaryDrive.end_location
            
            # Create a string summary of legs
            $driveDetails = ($validDrives | ForEach-Object { "$($_.start_location) -> $($_.end_location) ($($_.distance_miles) mi)" }) -join " | "
        }
    }
    
    # 3. Extract Charge Datasets
    $chargeCost = 0
    $chargeKwh = 0
    if ($json.Tessie_Charges) {
        $json.Tessie_Charges | ForEach-Object { 
            $chargeCost += $_.cost
            $chargeKwh += $_.energy_added
        }
    }

    # 4. Build Row
    $row = [PSCustomObject]@{
        "Time"           = [DateTime]::Parse($json.Timestamp).ToShortTimeString()
        "Event ID"       = $json.EventID
        "Category"       = $category
        "Drive Miles"    = if ($totalDriveMiles -gt 0) { [math]::Round($totalDriveMiles, 1) } else { 0 }
        "Start Street"   = $sAddr.Street
        "Start City"     = $sAddr.City
        "Start Zip"      = $sAddr.Zip
        "End Street"     = $eAddr.Street
        "End City"       = $eAddr.City
        "End Zip"        = $eAddr.Zip
        "Efficiency (%)" = if ($primaryDrive) { $primaryDrive.efficiency } else { "" }
        "Charge Cost"    = if ($chargeCost -gt 0) { $chargeCost } else { 0 }
        "kWh Added"      = if ($chargeKwh -gt 0) { $chargeKwh } else { 0 }
        "Drive Datasets" = $driveDetails
        "Image Count"    = $json.ImageCount
    }
    
    if ($category -eq "Uber") { $uberRows += $row }
    else { $privateRows += $row }
}

# 5. Export Two Streams
$uberPath = Join-Path $ProcessedRoot "Report_Uber_Trips_$Date.csv"
$privatePath = Join-Path $ProcessedRoot "Report_Private_Trips_$Date.csv"

$uberRows | Export-Csv -Path $uberPath -NoTypeInformation -Encoding UTF8
$privateRows | Export-Csv -Path $privatePath -NoTypeInformation -Encoding UTF8

Write-Host "REPORT GENERATION COMPLETE" -ForegroundColor Green
Write-Host "1. Uber Trips: $uberPath"
Write-Host "2. Private/Other: $privatePath"

Write-Host "`nPREVIEW (Uber):"
$uberRows | Format-Table "Time", "Drive Miles", "Start Street", "Start City", "End Street", "End City", "Charge Cost" -AutoSize

Write-Host "`nPREVIEW (Private):"
$privateRows | Format-Table "Time", "Drive Miles", "Start Street", "Start City", "End Street", "End City", "Charge Cost" -AutoSize
