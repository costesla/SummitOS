param(
    [Parameter(Mandatory = $true)]
    [string]$TargetFolder,

    [int]$GapMinutes = 20,
    [switch]$WhatIf
)

if (-not (Test-Path $TargetFolder)) {
    Write-Host "[ERROR] Folder not found: $TargetFolder" -ForegroundColor Red
    exit 1
}

Write-Host "Scanning: $TargetFolder" -ForegroundColor Cyan
Write-Host "Gap Threshold: $GapMinutes minutes" -ForegroundColor DarkCyan

# 1. Gather files and parse dates
$files = Get-ChildItem -LiteralPath $TargetFolder -File
$fileList = @()

foreach ($f in $files) {
    $dt = $f.CreationTime # Default
    # Try parsing Screenshot_20250818_070154...
    if ($f.Name -match 'Screenshot_(\d{8})_(\d{6})') {
        try {
            $dt = [datetime]::ParseExact($matches[1] + $matches[2], "yyyyMMddHHmmss", $null)
        }
        catch {}
    }
    $fileList += [pscustomobject]@{ File = $f; Time = $dt }
}

# 2. Sort by time
$sorted = $fileList | Sort-Object Time

# 3. Iterate and Group
$tripID = 1
$prevTime = [datetime]::MinValue

if ($sorted.Count -eq 0) { Write-Host "No files found." -ForegroundColor Yellow; exit }

Write-Host "Found $($sorted.Count) files." -ForegroundColor Cyan

foreach ($item in $sorted) {
    if ($prevTime -ne [datetime]::MinValue) {
        $delta = ($item.Time - $prevTime).TotalMinutes
        if ($delta -gt $GapMinutes) {
            $tripID++
            Write-Host "   --- New Trip #$tripID (Gap: $([math]::Round($delta,1)) min) ---" -ForegroundColor DarkGray
        }
    }
    else {
        Write-Host "   --- Trip #1 Start ---" -ForegroundColor DarkGray
    }

    $newName = "Trip_${tripID}_$($item.File.Name)"
    
    # Avoid double renaming if already present
    if ($item.File.Name -match "^Trip_\d+_") {
        Write-Host "Skipping $($item.File.Name) (Already named)" -ForegroundColor DarkGray
    }
    elseif ($WhatIf) {
        Write-Host "[WHATIF] $($item.Time.ToString('HH:mm:ss')) | Rename: $($item.File.Name) -> $newName" -ForegroundColor Yellow
    }
    else {
        try {
            Rename-Item -LiteralPath $item.File.FullName -NewName $newName -ErrorAction Stop
            Write-Host "[$($item.Time.ToString('HH:mm:ss'))] Trip $tripID : $($item.File.Name) -> $newName" -ForegroundColor Green
        }
        catch {
            Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    $prevTime = $item.Time
}
Write-Host "Done. Total Trips identified: $tripID" -ForegroundColor Cyan
