<#
    MobilityOS_Stage3_Extraction.ps1
    
    Role: OCR and Data Extraction
    Dependency: "tesseract.exe" must be in PATH or standard location.
    
    Usage:
        .\MobilityOS_Stage3_Extraction.ps1 -DayFolder "C:\...\2025\August\Week 1\08.15.25"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$DayFolder,

    [switch]$DryRun
)

# ---------------- CONFIG ----------------
# Standard Tesseract paths to check if not in PATH
$TesseractPaths = @(
    "C:\Program Files\Tesseract-OCR\tesseract.exe",
    "C:\Program Files (x86)\Tesseract-OCR\tesseract.exe",
    "$env:LOCALAPPDATA\Tesseract-OCR\tesseract.exe"
)

function Get-TesseractPath {
    param()
    # 1. Check PATH
    if (Get-Command "tesseract" -ErrorAction SilentlyContinue) {
        return "tesseract"
    }
    # 2. Check Standard Locations
    foreach ($p in $TesseractPaths) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

$TesPath = Get-TesseractPath
if (-not $TesPath) {
    Write-Host "[ERROR] Tesseract OCR not found. Please install it or add to PATH." -ForegroundColor Red
    exit 1
}
else {
    Write-Host "[INFO] Using Tesseract at: $TesPath" -ForegroundColor DarkGray
}

function Get-TextFromImage {
    param($ImagePath)
    try {
        # Run tesseract, output to stdout
        $p = Start-Process -FilePath $TesPath -ArgumentList "`"$ImagePath`" stdout -l eng --psm 6" -NoNewWindow -Wait -PassThru -RedirectStandardOutput "ocr_temp.txt"
        if ($p.ExitCode -ne 0) { return "" }
        if (Test-Path "ocr_temp.txt") {
            $txt = Get-Content "ocr_temp.txt" -Raw -Encoding UTF8
            Remove-Item "ocr_temp.txt" -Force -ErrorAction SilentlyContinue
            return $txt
        }
    }
    catch {
        Write-Host "[WARN] OCR Failed on $ImagePath : $($_.Exception.Message)" -ForegroundColor Yellow
    }
    return ""
}

function Classify-Card {
    param([string]$Text)
    $lower = $Text.ToLower()

    # Detail
    if ($lower -match "fare breakdown|trip total|earnings|receipt|trip details|your earnings") { return "detail" }
    
    # Pickup
    if ($lower -match "confirm pickup|start uberx|picking up") { return "pickup" }

    # Dropoff
    if ($lower -match "confirm dropoff|complete uberx|dropping off|rate rider") { return "dropoff" }

    # Offer
    if ($lower -match "opportunity|expected|includes|match|accept|exclusive") { return "offer" }

    return "unknown"
}

function Extract-Data {
    param([string]$Text, [string]$Type)
    
    $obj = [ordered]@{
        classification   = $Type
        raw_text_snippet = ($Text -replace '\s+', ' ').Substring(0, [math]::Min($Text.Length, 100))
        fare             = $null
        duration         = $null
        distance         = $null
    }

    # Fare: Max dollar amount found
    # Regex look for $XX.XX
    $fareMatches = [regex]::Matches($Text, '\$\s*(\d+\.\d{2})')
    $maxFare = 0.0
    foreach ($m in $fareMatches) {
        $v = [double]$m.Groups[1].Value
        if ($v -gt $maxFare) { $maxFare = $v }
    }
    if ($maxFare -gt 0) { $obj.fare = $maxFare }

    # Duration: "X min"
    if ($Text -match '(\d+)\s*min') {
        $obj.duration = [int]$matches[1]
    }

    # Distance: "X.X mi"
    if ($Text -match '(\d+\.?\d*)\s*mi') {
        $obj.distance = [double]$matches[1]
    }

    return $obj
}

# ---------------- MAIN ----------------
Write-Host " Scanning Blocks & Bucket in: $DayFolder" -ForegroundColor Cyan

# Gather Block folders AND the Bucket folder
$foldersToScan = @()
$blocks = Get-ChildItem -LiteralPath $DayFolder -Directory | Where-Object { $_.Name -match "^Block" -or $_.Name -match "^Trip" }
if ($blocks) { $foldersToScan += $blocks }

$bucketPath = Join-Path $DayFolder "Bucket"
if (Test-Path -LiteralPath $bucketPath) {
    # Treat Bucket as a folder to scan. We'll wrap it in an object with Name/FullName
    $foldersToScan += Get-Item -LiteralPath $bucketPath
}

if (-not $foldersToScan) {
    Write-Host "  [SKIP] No Block/Trip/Bucket folders found." -ForegroundColor DarkGray
    exit 0
}

foreach ($block in $foldersToScan) {
    Write-Host "  Processing $($block.Name)..." -ForegroundColor Cyan
    
    $images = Get-ChildItem -LiteralPath $block.FullName -File | Where-Object { $_.Extension -match "\.(jpg|jpeg|png)" }
    
    if (-not $images) { 
        Write-Host "    [SKIP] No images found." -ForegroundColor DarkGray
        continue 
    }

    $blockData = [ordered]@{
        offer   = $null
        pickup  = $null
        dropoff = $null
        detail  = $null
        unknown = @()
    }
    $foundAny = $false

    foreach ($img in $images) {
        if ($DryRun) {
            Write-Host "    [DRY RUN] Would OCR $($img.Name)" -ForegroundColor DarkGray
            $foundAny = $true
            continue
        }

        Write-Host "    [OCR] Reading $($img.Name)..." -NoNewline
        $txt = Get-TextFromImage -ImagePath $img.FullName
        
        if (-not [string]::IsNullOrWhiteSpace($txt)) {
            $type = Classify-Card -Text $txt
            $data = Extract-Data -Text $txt -Type $type
            
            Write-Host " Classified as: $type" -ForegroundColor Green

            if ($type -eq "unknown") {
                $blockData.unknown += $data
            }
            elseif ($blockData[$type] -ne $null) {
                Write-Host "      [WARN] Duplicate $type found. Overwriting." -ForegroundColor Yellow
                $blockData[$type] = $data
            }
            else {
                $blockData[$type] = $data
            }
            $foundAny = $true
        }
        else {
            Write-Host " [Unreadable]" -ForegroundColor Red
        }
    }

    if ($foundAny -and -not $DryRun) {
        $jsonFile = Join-Path $block.FullName "trip_data.json"
        try {
            $blockData | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $jsonFile -Encoding UTF8
            Write-Host "    -> Saved extracted data to trip_data.json" -ForegroundColor DarkGreen
        }
        catch {
            Write-Host "    [ERROR] Failed to save JSON: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}
