<#
    MobilityOS_Combined_Workflow.ps1

    A unified, production-ready runner that:
      1) Creates calendar-aligned folder tree for the ProcessDate (Sunday→Saturday).
      2) Moves images from source into the correct day’s Bucket (12:00 → +15h to 03:00 next day).
      3) Routes files:
         - Stage 1 keyword routes from Bucket into categories
         - Stage 2 Block routing (B{n}_ prefix or Trip_X mapped to Stage 2 blocks)
         - Optional intra-block keyword routing
      4) Cleans up empty ISO Week folders
      5) Logs everything + exports JSON/CSV summaries
      6) Supports Dry Run via -WhatIf (no changes made)

    Example (Dry Run first):
      Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
      Set-Location "C:\Users\Peter Teehan\OneDrive - COS Tesla LLC\MobilityOS\Scripts\Stage 2"

      .\MobilityOS_Combined_Workflow.ps1 `
        -Stage1ConfigPath ".\config_stage1.json" `
        -Stage2ConfigPath ".\config_stage2.json" `
        -ProcessDate "2025-08-15" `
        -WhatIf `
        -VerboseDebug

    LIVE RUN: remove -WhatIf
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$Stage1ConfigPath,

    [Parameter(Mandatory = $true)]
    [string]$Stage2ConfigPath,

    [Parameter(Mandatory = $true)]
    [string]$ProcessDate,          # yyyy-MM-dd

    # Calendar weeks (Sunday→Saturday). Cap to 5 by default (29–31 => Week 5).
    [ValidateSet(3, 4, 5, 6)]
    [int]$MaxWeeksInMonth = 5,

    # Time window for BucketDrop (default 00:00 -> +24h = end of day)
    [string]$TimeWindowStart = "00:00:00",
    [int]$TimeWindowHours = 24,
    # Optional end time for BucketDrop.
    [string]$TimeWindowEnd,
    [switch]$UseLastWriteTime,     # Use LastWriteTime instead of CreationTime

    # Routing toggles
    [switch]$SkipKeywordRouting = $true, # Default TRUE to allow Smart Grouping on all files
    [switch]$SkipBlockRouting = $true, # Default TRUE to preserve Smart Grouping folders
    [switch]$SkipIntraBlockKeywordRouting,

    # Exports
    [switch]$ExportSummaryJson = $true,
    [switch]$ExportSummaryCsv = $true,

    # Misc
    [switch]$VerboseDebug,
    [switch]$WhatIf
)

# ------------------------ UTIL & LOGGING ------------------------
$script:Summary = New-Object System.Collections.Generic.List[object]
$script:BlockCount = @{}
$script:CatCount = @{}

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "$ts`t$Message"
    # Only write to log file if parent directory exists (avoids errors in WhatIf mode where dir isn't created)
    if ($script:LogFile -and (Test-Path -LiteralPath (Split-Path $script:LogFile -Parent))) {
        try { Add-Content -Path $script:LogFile -Value $line -ErrorAction SilentlyContinue } catch {}
    }
    Write-Host $Message -ForegroundColor $Color
}
function Write-DebugLine { param([string]$Msg) if ($VerboseDebug) { Write-Log $Msg "Yellow" } }

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        if ($WhatIf) { Write-Log "[WHATIF] Would create: $Path" "Yellow" }
        else { New-Item -ItemType Directory -Path $Path -Force | Out-Null; Write-Log "[CREATE] $Path" "DarkGreen" }
    }
}
function Safe-Move {
    param([string]$Source, [string]$Dest)
    $destDir = Split-Path -Path $Dest -Parent
    Ensure-Directory -Path $destDir
    
    # Check if source and dest are the same (case-insensitive)
    if ($Source -eq $Dest) { return @{Action = "Skipped"; Dest = $Dest; Error = "Source and Destination are the same" } }

    if ($WhatIf) { Write-Log "[WHATIF] Move: $(Split-Path $Source -Leaf) -> $(Split-Path $Dest -Leaf)" "Yellow"; return @{Action = "WhatIf"; Dest = $Dest } }
    try { Move-Item -LiteralPath $Source -Destination $Dest -Force; Write-Log "[MOVE] $(Split-Path $Source -Leaf) -> $(Split-Path $Dest -Leaf)" "Green"; return @{Action = "Moved"; Dest = $Dest } }
    catch { Write-Log "[ERROR] Move failed $Source -> $Dest : $($_.Exception.Message)" "Red"; return @{Action = "Error"; Dest = $Dest; Error = $_.Exception.Message } }
}

# ------------------------ CALENDAR WEEK LOGIC ------------------------
function Get-CalendarWeek {
    param([datetime]$Date, [ValidateSet(3, 4, 5, 6)][int]$MaxWeeks = 5)
    $first = Get-Date -Year $Date.Year -Month $Date.Month -Day 1
    $daysBackToSun = [int]$first.DayOfWeek   # Sunday=0..Saturday=6
    $firstWeekStart = $first.AddDays(-$daysBackToSun).Date
    $week = [math]::Floor(($Date.Date - $firstWeekStart).TotalDays / 7) + 1
    if ($week -lt 1) { $week = 1 }
    if ($week -gt $MaxWeeks) { $week = $MaxWeeks }
    return $week
}

# ------------------------ STAGE CONFIG LOAD ------------------------
try {
    $cfg1 = Get-Content -LiteralPath $Stage1ConfigPath -Raw | ConvertFrom-Json
    $cfg2 = Get-Content -LiteralPath $Stage2ConfigPath -Raw | ConvertFrom-Json
}
catch {
    Write-Host "[ERROR] Failed to load config(s): $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

if (-not $cfg1.rootDestinationPath) { Write-Host "[ERROR] Stage1 missing rootDestinationPath." -ForegroundColor Red; exit 1 }
if (-not $cfg1.sourceBaseFolder) { Write-Host "[ERROR] Stage1 missing sourceBaseFolder." -ForegroundColor Red; exit 1 }

# Use Add-Member for safe assignment to PSCustomObject
if (-not $cfg1.folderDateFormat) { $cfg1 | Add-Member -MemberType NoteProperty -Name "folderDateFormat" -Value "MM.dd.yy" -Force }
if (-not $cfg1.acceptedExtensions) { $cfg1 | Add-Member -MemberType NoteProperty -Name "acceptedExtensions" -Value @(".jpg", ".jpeg") -Force }
if (-not $cfg2.destinationBaseFolder) { $cfg2 | Add-Member -MemberType NoteProperty -Name "destinationBaseFolder" -Value $cfg1.rootDestinationPath -Force }

# Prepare logging
$logRoot = if ($cfg1.logFolderPath) { $cfg1.logFolderPath } else { Join-Path $PSScriptRoot "Logs" }
Ensure-Directory -Path $logRoot
$logStamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
$logFileName = if ($cfg1.logFileName) { [IO.Path]::GetFileNameWithoutExtension($cfg1.logFileName) } else { "MobilityOS_Run_All" }
$script:LogFile = Join-Path $logRoot ("{0}_{1}.log" -f $logFileName, $logStamp)

Write-Log "=== MobilityOS Unified Run Started ===" "Cyan"
Write-Log ("Configs: Stage1={0} | Stage2={1}" -f $Stage1ConfigPath, $Stage2ConfigPath) "DarkGray"
$modeStr = if ($WhatIf) { "DRY RUN" } else { "LIVE" }
Write-Log ("Mode: {0}" -f $modeStr) "DarkGray"

# Parse ProcessDate
try { $procDate = [datetime]::ParseExact($ProcessDate, "yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture) }
catch { Write-Log "[ERROR] ProcessDate must be yyyy-MM-dd" "Red"; exit 1 }

# ------------------------ FOLDER TREE (MONTH/WEEK/DAY/BUCKET) ------------------------
$monthName = $procDate.ToString("MMMM", [Globalization.CultureInfo]::InvariantCulture)
$dayFolder = $procDate.ToString($cfg1.folderDateFormat, [Globalization.CultureInfo]::InvariantCulture)
$weekNum = Get-CalendarWeek -Date $procDate -MaxWeeks $MaxWeeksInMonth

$global:MonthRoot = Join-Path $cfg1.rootDestinationPath $monthName
$weekRoot = Join-Path $global:MonthRoot ("Week {0}" -f $weekNum)
$dayRoot = Join-Path $weekRoot $dayFolder
$bucketPath = Join-Path $dayRoot "Bucket"

Ensure-Directory -Path $global:MonthRoot
Ensure-Directory -Path $weekRoot
Ensure-Directory -Path $dayRoot
Ensure-Directory -Path $bucketPath

Write-DebugLine "[DEBUG] MonthRoot: $global:MonthRoot"
Write-DebugLine "[DEBUG] WeekRoot : $weekRoot"
Write-DebugLine "[DEBUG] DayRoot  : $dayRoot"
Write-DebugLine "[DEBUG] Bucket   : $bucketPath"

# **New: upfront path confirmation**
Write-Log ("[PATH] Source images : {0}" -f $cfg1.sourceBaseFolder) "Cyan"
Write-Log ("[PATH] Destination   : {0}" -f $bucketPath) "Cyan"

# ------------------------ BUCKET DROP (Time window) ------------------------
$startTime = [datetime]::ParseExact("$ProcessDate $TimeWindowStart", 'yyyy-MM-dd HH:mm:ss', $null)
if ($PSBoundParameters.ContainsKey('TimeWindowEnd') -and $TimeWindowEnd) {
    $tmpEnd = [datetime]::ParseExact("$ProcessDate $TimeWindowEnd", 'yyyy-MM-dd HH:mm:ss', $null)
    if ($tmpEnd -lt $startTime) {
        $endTime = $tmpEnd.AddDays(1)
    }
    else {
        $endTime = $tmpEnd
    }
    $TimeWindowHours = [int][math]::Ceiling(($endTime - $startTime).TotalHours)
}
else {
    $endTime = $startTime.AddHours($TimeWindowHours)
}
Write-DebugLine "[DEBUG] Window: $startTime → $endTime"

$exts = @($cfg1.acceptedExtensions | ForEach-Object { $_.ToLower() })
$src = $cfg1.sourceBaseFolder
if (-not (Test-Path -LiteralPath $src)) { Write-Log "[ERROR] Source folder not found: $src" "Red"; exit 1 }

# Gather files
$imageFiles = Get-ChildItem -LiteralPath $src -Recurse -File | Where-Object {
    $exts -contains ([IO.Path]::GetExtension($_.Name).ToLower())
}
# Filter by time window
if ($UseLastWriteTime) {
    $imageFiles = $imageFiles | Where-Object { $_.LastWriteTime -ge $startTime -and $_.LastWriteTime -lt $endTime }
}
else {
    $imageFiles = $imageFiles | Where-Object { $_.CreationTime -ge $startTime -and $_.CreationTime -lt $endTime }
}

Write-Log ("[BUCKET] Found {0} image(s) for time window" -f $imageFiles.Count) "Cyan"

foreach ($file in $imageFiles) {
    $dest = Join-Path $bucketPath $file.Name
    $res = Safe-Move -Source $file.FullName -Dest $dest
    $script:Summary.Add([pscustomobject]@{
            Step = "BucketDrop"; File = $file.Name; From = $file.FullName; To = $res.Dest; Action = $res.Action; Error = ($res.Error | Out-String).Trim()
        })
}

# ------------------------ STAGE 1: KEYWORD ROUTING FROM BUCKET ------------------------
function Route-ByKeyword {
    param([string]$RootForDay, [string]$Bucket, $RoutesObject)

    if (-not $RoutesObject) { return }
    $props = $RoutesObject.PSObject.Properties
    if (-not $props) { return }

    # Pre-compile regexes for performance
    $routeRules = @()
    foreach ($p in $props) {
        $keywords = @($p.Value) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        if ($keywords) {
            $pattern = "(?i)(" + (($keywords | ForEach-Object { [regex]::Escape($_) }) -join "|") + ")"
            $routeRules += [pscustomobject]@{ Category = $p.Name; Regex = [regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::Compiled) }
        }
    }

    # Only files currently in Bucket
    $files = Get-ChildItem -LiteralPath $Bucket -File -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        foreach ($rule in $routeRules) {
            if ($rule.Regex.IsMatch($f.Name)) {
                $destDir = Join-Path $RootForDay $rule.Category
                Ensure-Directory -Path $destDir
                $destFile = Join-Path $destDir $f.Name
                $res = Safe-Move -Source $f.FullName -Dest $destFile

                if (-not $script:CatCount.ContainsKey($rule.Category)) { $script:CatCount[$rule.Category] = 0 }
                $script:CatCount[$rule.Category]++

                $script:Summary.Add([pscustomobject]@{
                        Step = "KeywordRoute"; Category = $rule.Category; Keyword = "MATCH"; File = $f.Name; From = $f.FullName; To = $res.Dest; Action = $res.Action; Error = ($res.Error | Out-String).Trim()
                    })
                break # Move once, first match wins
            }
        }
    }
}

if (-not $SkipKeywordRouting) {
    Route-ByKeyword -RootForDay $dayRoot -Bucket $bucketPath -RoutesObject $cfg1.routes
}

# ------------------------ STAGE 2: BLOCK ROUTING ------------------------
function Get-TripNumberFromName {
    param([string]$Name)
    # Support 1–3 digit trip numbers: Trip_1, Trip-08, Trip 176, t5, t200, etc.
    $patterns = @('(?i)\btrip[_\-\s]*0*([0-9]{1,3})', '(?i)\bt([0-9]{1,3})')
    foreach ($pat in $patterns) {
        $m = [regex]::Match($Name, $pat)
        if ($m.Success) {
            $n = 0; if ([int]::TryParse($m.Groups[1].Value, [ref]$n)) { return $n }
        }
    }
    return $null
}
function Resolve-BlockByTrip($TripNo, $BlocksObj) {
    if (-not $TripNo -or -not $BlocksObj) { return $null }
    foreach ($prop in $BlocksObj.PSObject.Properties) {
        $def = $prop.Value
        if ($def.tripNumbers -contains $TripNo) {
            if ($def.folderName) { return $def.folderName } else { return $prop.Name }
        }
    }
    return $null
}
function Route-Blocks {
    param([string]$DayRoot, [object]$Cfg2)

    # files in Day root & Bucket & categories (we will route anything under DayRoot that matches)
    Write-DebugLine "[DEBUG] Scanning for blocks in: $DayRoot"
    $files = Get-ChildItem -LiteralPath $DayRoot -File -Recurse -ErrorAction SilentlyContinue
    Write-DebugLine "[DEBUG] Found $($files.Count) files to check."

    foreach ($f in $files) {
        $relative = $f.FullName.Substring($DayRoot.Length).TrimStart('\')
        $blockName = $null

        # Priority 1: B{n}_ prefix
        if ($f.Name -match '^(?i)B(\d+)_') {
            $blockName = "Block $($matches[1])"
        }
        else {
            # Priority 2: Trip number mapped via Stage2.blocks
            $trip = Get-TripNumberFromName -Name $f.Name
            if ($trip) {
                # Write-DebugLine "[DEBUG] File $($f.Name) -> Trip $trip"
                $resolved = Resolve-BlockByTrip -TripNo $trip -BlocksObj $Cfg2.blocks
                if ($resolved) { $blockName = $resolved; Write-DebugLine "[DEBUG] Resolved Trip $trip -> $resolved" }
            }
        }

        if ($blockName) {
            $destDir = Join-Path $DayRoot $blockName
            Ensure-Directory -Path $destDir
            $dest = Join-Path $destDir $f.Name
            # Avoid double move (already in block)
            if ($f.DirectoryName.TrimEnd('\') -ieq $destDir.TrimEnd('\')) { continue }
            $res = Safe-Move -Source $f.FullName -Dest $dest

            if (-not $script:BlockCount.ContainsKey($blockName)) { $script:BlockCount[$blockName] = 0 }
            $script:BlockCount[$blockName]++

            $script:Summary.Add([pscustomobject]@{
                    Step = "BlockRoute"; Block = $blockName; File = $f.Name; From = $f.FullName; To = $res.Dest; Action = $res.Action; Error = ($res.Error | Out-String).Trim()
                })
        }
    }
}

# ------------------------ STAGE 2.5: SMART GROUPING (BUCKET -> BLOCKS) ------------------------
function Group-BucketTrips {
    param([string]$DayRoot, [int]$GapMinutes = 20, [datetime]$ProcessDate)

    $bucketDir = Join-Path $DayRoot "Bucket"
    if (-not (Test-Path -LiteralPath $bucketDir)) { return }

    Write-DebugLine "[DEBUG] Smart Grouping in: $bucketDir (Gap: $GapMinutes min)"

    # 1. Gather all image files
    $files = Get-ChildItem -LiteralPath $bucketDir -File | Where-Object { $_.Name -match "\.(jpg|jpeg|png)$" }
    if (-not $files) { return }

    # 2. Parse creation time & Filter by ProcessDate
    $start = $ProcessDate.Date
    $end = $start.AddDays(1)
    
    $fileList = @()
    foreach ($f in $files) {
        if ($ProcessDate -and ($f.CreationTime -lt $start -or $f.CreationTime -ge $end)) {
            Write-DebugLine "[DEBUG] Skipping out-of-date file: $($f.Name) ($($f.CreationTime))"
            continue
        }
        $fileList += [pscustomobject]@{ File = $f; Time = $f.CreationTime }
    }
    
    # 3. Sort
    $sorted = $fileList | Sort-Object Time
    
    # 4. Group
    $prevTime = [datetime]::MinValue
    $currentBlockName = $null
    
    # -- Trip Indexing Logic --
    # We want "Trip01", "Trip02" based on sequence.
    $tripIndex = 0

    foreach ($item in $sorted) {
        $timestampId = $item.Time.ToString("yyyyMMdd_HHmm")

        if ($prevTime -eq [datetime]::MinValue) {
            # First item
            $tripIndex++
            # Format: Trip{DD}_Timestamp
            $seqStr = "{0:D2}" -f $tripIndex
            $currentBlockName = "Trip${seqStr}_$timestampId"
        }
        else {
            $delta = ($item.Time - $prevTime).TotalMinutes
            if ($delta -gt $GapMinutes) {
                # New Group -> Increment Index
                $tripIndex++
                $seqStr = "{0:D2}" -f $tripIndex
                $currentBlockName = "Trip${seqStr}_$timestampId"
            }
        }
        
        $destDir = Join-Path $DayRoot $currentBlockName
        Ensure-Directory -Path $destDir
        
        # RENAME LOGIC: Strip old "Trip..." prefixes to avoid "Trip01_Trip01_..."
        # Replace existing "TripXX_" or "Trip_YYYY..." prefix with nothing
        $cleanName = $item.File.Name -replace '^(?i)Trip[0-9]*[_\-]*[0-9]*[_\-]*', ''
        
        # New Name: Trip01_20251210_0757_OriginalName.jpg
        # Only add prefix if not already present
        if ($cleanName -notmatch "^$currentBlockName") {
            $newName = "${currentBlockName}_${cleanName}"
        }
        else {
            $newName = $cleanName
        }

        $destFile = Join-Path $destDir $newName
        if (-not $script:BlockCount.ContainsKey($currentBlockName)) { $script:BlockCount[$currentBlockName] = 0 }
        $script:BlockCount[$currentBlockName]++

        $script:Summary.Add([pscustomobject]@{
                Step = "Ingest"; Block = $currentBlockName; File = $item.File.Name; From = $item.File.FullName; To = $res.Dest; Action = $res.Action; Error = ($res.Error | Out-String).Trim()
            })
        
        $prevTime = $item.Time
    }
}

# ------------------------ EXECUTION FLOW ------------------------

# New Main Flow: Source -> Smart Grouping (Trips)
if (-not $SkipBlockRouting) {
    # This function handles Importing AND Grouping in one pass
    Group-BucketTrips -DayRoot $dayRoot -ProcessDate $procDate -GapMinutes 20
}

# Intra-block keyword routing (optional)
# Intra-block keyword routing (optional)
if (-not $SkipIntraBlockKeywordRouting -and $cfg1.routes) {
    # Scan Trip* folders instead of Block*
    $blocks = Get-ChildItem -LiteralPath $dayRoot -Directory -Filter "Trip*" -ErrorAction SilentlyContinue
    foreach ($b in $blocks) {
        $files = Get-ChildItem -LiteralPath $b.FullName -File -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            $moved = $false
            foreach ($prop in $cfg1.routes.PSObject.Properties) {
                $category = $prop.Name
                foreach ($kw in @($prop.Value)) {
                    if ([string]::IsNullOrWhiteSpace($kw)) { continue }
                    if ($f.Name -match ("(?i)" + [regex]::Escape($kw))) {
                        $destDir = Join-Path $b.FullName $category
                        Ensure-Directory -Path $destDir
                        $dest = Join-Path $destDir $f.Name
                        $res = Safe-Move -Source $f.FullName -Dest $dest

                        if (-not $script:CatCount.ContainsKey($category)) { $script:CatCount[$category] = 0 }
                        $script:CatCount[$category]++

                        $script:Summary.Add([pscustomobject]@{
                                Step = "BlockKeywordRoute"; Block = $b.Name; Category = $category; Keyword = $kw; File = $f.Name; From = $f.FullName; To = $res.Dest; Action = $res.Action; Error = ($res.Error | Out-String).Trim()
                            })
                        
                        $moved = $true
                        break
                    }
                }
                if ($moved) { break }
            }
        }
    }
}

# ------------------------ CLEANUP: EMPTY ISO WEEK FOLDERS ------------------------
$validWeekNames = 1..$MaxWeeksInMonth | ForEach-Object { "Week $_" }
$weekDirs = Get-ChildItem -LiteralPath $global:MonthRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^Week\s+\d+$' }
foreach ($wd in $weekDirs) {
    if ($validWeekNames -notcontains $wd.Name) {
        $has = Get-ChildItem -LiteralPath $wd.FullName -Force | Select-Object -First 1
        if ($null -eq $has) {
            if ($WhatIf) { Write-Log "[WHATIF] Remove obsolete empty: $($wd.FullName)" "Yellow" }
            else { Remove-Item -LiteralPath $wd.FullName -Force; Write-Log "[CLEANUP] Removed obsolete empty: $($wd.FullName)" "DarkYellow" }
        }
    }
}

# ------------------------ SUMMARY & EXPORTS ------------------------
Write-Log "=== Summary ===" "Cyan"
if ($script:BlockCount.Keys.Count -gt 0) {
    Write-Log "Blocks:" "Cyan"
    foreach ($k in ($script:BlockCount.Keys | Sort-Object)) { Write-Log ("  {0} : {1}" -f $k, $script:BlockCount[$k]) }
}
if ($script:CatCount.Keys.Count -gt 0) {
    Write-Log "Categories:" "Cyan"
    foreach ($k in ($script:CatCount.Keys | Sort-Object)) { Write-Log ("  {0} : {1}" -f $k, $script:CatCount[$k]) }
}

if ($ExportSummaryJson) {
    $jsonOut = Join-Path $logRoot ("MobilityOS_Run_All_Summary_{0}.json" -f $logStamp)
    if (Test-Path -LiteralPath $logRoot) {
        try { $script:Summary | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $jsonOut -Encoding UTF8; Write-Log "Summary JSON: $jsonOut" "DarkCyan" } catch { Write-Log "[ERROR] JSON export failed: $($_.Exception.Message)" "Red" }
    }
    elseif ($WhatIf) { Write-Log "[WHATIF] Would export JSON: $jsonOut" "Yellow" }
}
if ($ExportSummaryCsv) {
    $csvOut = Join-Path $logRoot ("MobilityOS_Run_All_Summary_{0}.csv" -f $logStamp)
    if (Test-Path -LiteralPath $logRoot) {
        try { $script:Summary | Export-Csv -LiteralPath $csvOut -NoTypeInformation -Encoding UTF8; Write-Log "Summary CSV: $csvOut" "DarkCyan" } catch { Write-Log "[ERROR] CSV export failed: $($_.Exception.Message)" "Red" }
    }
    elseif ($WhatIf) { Write-Log "[WHATIF] Would export CSV: $csvOut" "Yellow" }
}

# ------------------------ STAGE 3, 4, 5: INTELLIGENCE & REPORTING ------------------------
Write-Log "=== Triggering downstream stages ===" "Cyan"

# Stage 3: OCR Extraction (PowerShell)
$ocrScript = Join-Path $PSScriptRoot "MobilityOS_Stage3_Extraction.ps1"
if (Test-Path -LiteralPath $ocrScript) {
    Write-Log "[STAGE 3] Running OCR Extraction..." "Cyan"
    $ocrParams = @{
        DayFolder = $dayRoot
        DryRun    = $WhatIf
    }

    try {
        & $ocrScript @ocrParams
        if ($LASTEXITCODE -ne 0) {
            Write-Log "[ERROR] Stage 3 script exited with code $LASTEXITCODE. (Tesseract missing?)" "Red"
        }
        else {
            Write-Log "[STAGE 3] Completed." "Green"
        }
    }
    catch {
        Write-Log "[ERROR] Stage 3 failed: $($_.Exception.Message)" "Red"
    }
}
else {
    Write-Log "[WARN] Stage 3 script not found: $ocrScript" "Yellow"
}

# Stage 4: Tessie Integration
$tessieScript = Join-Path $PSScriptRoot "MobilityOS_Stage4_Tessie.ps1"
if (Test-Path -LiteralPath $tessieScript) {
    Write-Log "[STAGE 4] Fetching Tessie Data..." "Cyan"
    $tessieParams = @{
        ProcessDate  = $ProcessDate
        TargetFolder = $dayRoot
        WhatIf       = $WhatIf
    }
    try {
        & $tessieScript @tessieParams
        Write-Log "[STAGE 4] Completed." "Green"
    }
    catch {
        Write-Log "[ERROR] Stage 4 failed: $($_.Exception.Message)" "Red"
    }
}

# Stage 5: Reporting
$reportScript = Join-Path $PSScriptRoot "MobilityOS_Stage5_Report.ps1"
if (Test-Path -LiteralPath $reportScript) {
    Write-Log "[STAGE 5] Generating Report..." "Cyan"
    # Stage 5 logic itself is safe, but we pass DryRun to avoid appending to Master Dataset during tests.
    try {
        $repParams = @{
            TargetFolder = $dayRoot
            DryRun       = $WhatIf
        }
        & $reportScript @repParams
        Write-Log "[STAGE 5] Completed." "Green"
    }
    catch {
        Write-Log "[ERROR] Stage 5 failed: $($_.Exception.Message)" "Red"
    }
}

# ------------------------ FINAL CLEANUP (Remove JSON Artifacts) ------------------------
Write-Log "[CLEANUP] Removing temp JSON artifacts (trip_data.json)..." "Cyan"
Get-ChildItem -LiteralPath $dayRoot -Recurse -Filter "trip_data.json" -File -ErrorAction SilentlyContinue | Remove-Item -Force
Write-Log "  -> Artifacts removed." "DarkGray"


Write-Log ("Log file: {0}" -f $script:LogFile) "DarkGray"
Write-Log "=== MobilityOS Unified Run Finished ===" "Cyan"