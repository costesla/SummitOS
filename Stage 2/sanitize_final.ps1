$path = "C:\Users\PeterTeehan\OneDrive - COS Tesla LLC\MobilityOS\Uber Tracking\2025\December\Week 2\12.10.25"
Get-ChildItem $path -File | ForEach-Object {
    $newName = $_.Name -replace '^\d{4}_\d{4}_', ''
    $newName = $newName -replace '^\d{4}_\d{4}_', ''
    $newName = $newName -replace '^\d{4}_\d{4}_', ''
    if ($newName -ne $_.Name) {
        Rename-Item -LiteralPath $_.FullName -NewName $newName -Force -ErrorAction SilentlyContinue
    }
}
