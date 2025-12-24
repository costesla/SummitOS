param (
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true)]
    [string]$ProcessDate
)

# ───── CONFIG LOAD ─────
Write-Host "`n[MobilityOS Stage 2] 🟢 LIVE RUN: Starting image routing..." -ForegroundColor Green
Write-Host "📁 Loading config from: $ConfigPath" -ForegroundColor Cyan
$config = Get-Content $ConfigPath | ConvertFrom-Json
Write-Host "[SUCCESS] ✅ Config loaded." -ForegroundColor Green

# ───── DATE PARSING ─────
$parsedDate = [datetime]::ParseExact($ProcessDate, $config.dateFormat, $null)
$year = $parsedDate.Year
$month = $parsedDate.Month
$monthName = $parsedDate.ToString("MMMM")
$folderDate = $parsedDate.ToString($config.folderDateFormat)

# ───── CALENDAR-ALIGNED WEEK CALCULATION ─────
$firstOfMonth = Get-Date -Year $year -Month $month -Day 1
$firstSunday = $firstOfMonth.AddDays((7 - [int]$firstOfMonth.DayOfWeek) % 7)
$firstSunday = [datetime]::ParseExact($firstSunday.ToString("yyyy-MM-dd"), "yyyy-MM-dd", $null)

if ($parsedDate -lt $firstSunday) {
    $weekNumber = 1
} else {
    $daysSinceFirstSunday = [math]::Floor(($parsedDate - $firstSunday).TotalDays)
    $weekNumber = [math]::Floor($daysSinceFirstSunday / 7) + 1
}

$weekFolder = "Week $weekNumber"
Write-Host "`n📆 Week resolved: $weekFolder" -ForegroundColor Yellow

# ───── PATH RESOLUTION ─────
$bucketPath = Join-Path -Path $config.destinationBaseFolder -ChildPath "$monthName\$weekFolder\$folderDate\Bucket"
Write-Host "📂 Scanning bucket folder: $bucketPath" -ForegroundColor Yellow

if (-not (Test-Path $bucketPath)) {
    Write-Host "❌ ERROR: Bucket folder does not exist. Exiting." -ForegroundColor Red
    return
}

# ───── FILE ENUMERATION ─────
$files = Get-ChildItem -Path $bucketPath -Filter *.jpg -File
if ($files.Count -eq 0) {
    Write-Host "⚠️ No .jpg files found in bucket. Exiting." -ForegroundColor Red
    return
}

# ───── FILE ROUTING ─────
foreach ($file in $files) {
    if ($file.Name -match "^B(\d+)_") {
        $blockNum = $matches[1]
        $blockFolder = "Block $blockNum"
        $destPath = Join-Path -Path (Split-Path $bucketPath -Parent) -ChildPath $blockFolder

        if (-not (Test-Path $destPath)) {
            New-Item -Path $destPath -ItemType Directory | Out-Null
        }

        Move-Item -Path $file.FullName -Destination $destPath
    }
}

Write-Host "`n✅ Routing complete. All B{X}_ files sorted into dynamic block folders.`n" -ForegroundColor Cyan
