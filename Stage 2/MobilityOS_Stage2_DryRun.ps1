param (
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true)]
    [string]$ProcessDate # Format: yyyy-MM-dd
)

# ───── CONFIG LOAD ─────
Write-Host "`n[MobilityOS Stage 2] 🔍 Dry Run — Infinite Block Preview Starting..." -ForegroundColor Blue
$config = Get-Content $ConfigPath | ConvertFrom-Json

$baseFolder = $config.destinationBaseFolder
$folderDateFormat = $config.folderDateFormat
$dateFormat = $config.dateFormat

# ───── DATE & WEEK PARSING ─────
$parsedDate = [datetime]::ParseExact($ProcessDate, $dateFormat, $null)
$year = $parsedDate.Year
$monthName = $parsedDate.ToString("MMMM")
$folderDate = $parsedDate.ToString($folderDateFormat)

$firstOfMonth = Get-Date -Year $year -Month $parsedDate.Month -Day 1
$firstSunday = $firstOfMonth.AddDays((7 - [int]$firstOfMonth.DayOfWeek) % 7)
$firstSunday = [datetime]::ParseExact($firstSunday.ToString("yyyy-MM-dd"), "yyyy-MM-dd", $null)

if ($parsedDate -lt $firstSunday) {
    $weekNumber = 1
} else {
    $daysSinceFirstSunday = [math]::Floor(($parsedDate - $firstSunday).TotalDays)
    $weekNumber = [math]::Floor($daysSinceFirstSunday / 7) + 1
}

# ───── PATH SETUP ─────
$bucketPath = Join-Path $baseFolder "$monthName\Week $weekNumber\$folderDate\Bucket"
$logDir = "C:\Users\Peter Teehan\OneDrive - COS Tesla LLC\MobilityOS\Logs\Stage2DryRun"
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory | Out-Null }

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logFile = "DryRun_Stage2_${folderDate}_$timestamp.txt"
$logPath = Join-Path $logDir $logFile

Write-Host "📅 Week resolved: Week $weekNumber" -ForegroundColor Yellow
Write-Host "🧪 Simulating from bucket: $bucketPath" -ForegroundColor DarkYellow
Write-Host "📝 Writing log to: $logPath" -ForegroundColor Gray

if (-not (Test-Path $bucketPath)) {
    Write-Host "❌ Bucket not found: $bucketPath" -ForegroundColor Red
    exit 1
}

# ───── START LOG FILE ─────
"📋 Stage 2 Dry Run Log" | Out-File -FilePath $logPath
"Date: $ProcessDate" | Out-File -FilePath $logPath -Append
"Resolved Week: Week $weekNumber" | Out-File -FilePath $logPath -Append
"Bucket Path: $bucketPath" | Out-File -FilePath $logPath -Append
"" | Out-File -FilePath $logPath -Append

# ───── FILES & BLOCK DETECTION ─────
$totalMoved = 0
$blockFiles = Get-ChildItem -Path $bucketPath -Include *.jpg, *.jpeg -Recurse | Where-Object {
    $_.Name -match "^B\d+_"
}

$blockGroups = $blockFiles | Group-Object {
    if ($_ -match "^B(\d+)_") {
        return $matches[1]
    } else {
        return "Unknown"
    }
}

foreach ($group in $blockGroups) {
    $blockNum = $group.Name
    if ($blockNum -eq "Unknown") { continue }

    $blockFolder = Join-Path $baseFolder "$monthName\Week $weekNumber\$folderDate\Block $blockNum"
    $count = $group.Group.Count
    $totalMoved += $count

    Write-Host "`n📦 Block $blockNum Preview → Target Folder: $blockFolder" -ForegroundColor Cyan
    "📦 Block $blockNum → $count file(s)" | Out-File -FilePath $logPath -Append

    foreach ($file in $group.Group) {
        Write-Host "🟡 Would move: $($file.Name)" -ForegroundColor Gray
        "  ↪ $($file.Name)" | Out-File -FilePath $logPath -Append
    }

    "" | Out-File -FilePath $logPath -Append
}

# ───── SUMMARY ─────
Write-Host "`n🔍 Dry run complete — $totalMoved file(s) would be routed." -ForegroundColor Blue
"Total Files: $totalMoved" | Out-File -FilePath $logPath -Append
"✅ Dry run complete." | Out-File -FilePath $logPath -Append
