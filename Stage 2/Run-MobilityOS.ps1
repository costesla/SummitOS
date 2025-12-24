param(
    [string]$Date = (Get-Date).ToString("yyyy-MM-dd"),
    [switch]$OpenReport
)

# MobilityOS Master Controller
# Implements the User's 6-Step Logic:
# 1. Pull Images (Ingest)
# 2. Extract Data (Simulated OCR / Parsing)
# 3. Classify (Reasoning)
# 4. Sequence Trips
# 5. Link Tessie Data
# 6. Build Excel

$Stage4Script = "c:\Users\Peter Teehan\OneDrive - COS Tesla LLC\MobilityOS\Scripts\Stage 2\MobilityOS_Stage4_Execute.ps1"
$Stage5Script = "c:\Users\Peter Teehan\OneDrive - COS Tesla LLC\MobilityOS\Scripts\Stage 2\MobilityOS_Stage5_Report.ps1"
$ReportDir = "C:\Users\Peter Teehan\OneDrive - COS Tesla LLC\MobilityOS\Reports"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "   MobilityOS: Automating Your Day" -ForegroundColor Cyan
Write-Host "   Target Date: $Date"
Write-Host "==========================================" -ForegroundColor Cyan

# Step 1-5: Ingest, Link, Classify (Stage 4)
Write-Host "`n[STEP 1-5] Running Core Logic (Ingest -> Link -> Tessie)..." -ForegroundColor Yellow
try {
    & $Stage4Script -Date $Date -ErrorAction Stop
}
catch {
    Write-Warning "Stage 4 reported an issue (or no files found): $_"
}

# Step 6: Reporting (Stage 5)
Write-Host "`n[STEP 6] Building Excel Spreadsheets..." -ForegroundColor Yellow
try {
    & $Stage5Script -Date $Date -ErrorAction Stop
}
catch {
    Write-Error "Failed to generate report: $_"
    exit
}

# Copy to Reports Folder (Availability)
$uberSrc = "C:\Users\Peter Teehan\OneDrive - COS Tesla LLC\MobilityOS\Uber Tracking\2025\Processed\Report_Uber_Trips_$Date.csv"
$privSrc = "C:\Users\Peter Teehan\OneDrive - COS Tesla LLC\MobilityOS\Uber Tracking\2025\Processed\Report_Private_Trips_$Date.csv"

$uberDest = Join-Path $ReportDir "Uber_Trips_${Date}.csv"
$privDest = Join-Path $ReportDir "Private_Trips_${Date}.csv"

if (Test-Path $uberSrc) {
    Copy-Item $uberSrc -Destination $uberDest -Force
    Write-Host "   [+] Uber Report Ready: $uberDest" -ForegroundColor Green
    if ($OpenReport) { Invoke-Item $uberDest }
}
if (Test-Path $privSrc) {
    Copy-Item $privSrc -Destination $privDest -Force
    Write-Host "   [+] Private Report Ready: $privDest" -ForegroundColor Green
}

Write-Host "`nDONE. Workflow Complete." -ForegroundColor Cyan
