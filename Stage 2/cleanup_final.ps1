$dayPath = "C:\Users\PeterTeehan\OneDrive - COS Tesla LLC\MobilityOS\Uber Tracking\2025\December\Week 2\12.10.25"
$bucketPath = Join-Path $dayPath "Bucket"

# Ensure Bucket exists
if (-not (Test-Path $bucketPath)) { New-Item -ItemType Directory -Path $bucketPath -Force }

# Get all directories starting with "Block"
# Get all directories starting with "Block" or "Trip"
$blocks = Get-ChildItem -Path $dayPath -Directory | Where-Object { $_.Name -match "^(Block|Trip)" }

foreach ($block in $blocks) {
    Write-Host "Consolidating $($block.Name)..."
    
    # Move files
    Get-ChildItem -Path $block.FullName -Recurse -File | ForEach-Object {
        # Strip "Trip..." prefix if present to reset filename
        $cleanName = $_.Name -replace '^(?i)Trip[0-9]*[_\-]*[0-9]*[_\-]*', ''
        $dest = Join-Path $bucketPath $cleanName
        
        # Handle duplicates by renaming if necessary, or just overwrite if identical
        Move-Item -LiteralPath $_.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
    }

    
    # Delete the empty block folder
    Remove-Item -LiteralPath $block.FullName -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
}

Write-Host "Consolidation Complete. All files returned to Bucket."
