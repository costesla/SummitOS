param(
    [Parameter(Mandatory = $true)]
    [string]$TargetFolder,

    [switch]$WhatIf
)

$ValidCounts = 4
$Roles = @("Offer", "Pickup", "Dropoff", "Detail")

Write-Host "Scanning recursively: $TargetFolder" -ForegroundColor Cyan

# 1. Group files by Trip Number (regex from filename)
$allFiles = Get-ChildItem -LiteralPath $TargetFolder -File -Recurse
$grouped = @{}

foreach ($f in $allFiles) {
    if ($f.Name -match '(?i)Trip_(\d+)_') {
        $tid = [int]$matches[1]
        if (-not $grouped.ContainsKey($tid)) { $grouped[$tid] = @() }
        $grouped[$tid] += $f
    }
}

Write-Host "Found $($grouped.Count) unique trips." -ForegroundColor Cyan

foreach ($tripId in $grouped.Keys | Sort-Object) {
    $files = $grouped[$tripId] | Sort-Object CreationTime
    $count = $files.Count

    Write-Host "Trip $tripId : $count files" -NoNewline

    if ($count -eq 4) {
        Write-Host " [OK] -> Auto-Classifying" -ForegroundColor Green
        for ($i = 0; $i -lt 4; $i++) {
            $role = $Roles[$i]
            $file = $files[$i]
            
            # Construct new name: Trip_1_01_Offer.jpg
            # Keeping original extension
            $newName = "Trip_${tripId}_$($i+1)_${role}$($file.Extension)"
            
            if ($file.Name -ne $newName) {
                if ($WhatIf) {
                    Write-Host "   [WHATIF] Rename $($file.Name) -> $newName" -ForegroundColor Yellow
                }
                else {
                    Rename-Item -LiteralPath $file.FullName -NewName $newName -ErrorAction SilentlyContinue
                    Write-Host "   [RENAME] -> $newName" -ForegroundColor Gray
                }
            }
        }
    }
    else {
        Write-Host " [WARNING] Count matches $count (Expected 4). Skipping/Tagging." -ForegroundColor Yellow
        # Optional: Rename one file to tag the whole group? Or just log it.
        # For now, we leave them alone but log it HIGHLY visible.
    }
}
Write-Host "Done." -ForegroundColor Cyan
