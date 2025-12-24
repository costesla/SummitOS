# Check for Windows OCR capability in PowerShell
try {
    # Load Windows Runtime Types
    [Windows.Media.Ocr.OcrEngine, Windows.Foundation.UniversalApiContract, ContentType = WindowsRuntime] | Out-Null
    
    # Try to create an engine for English
    $lang = [Windows.Globalization.Language]::new("en-US")
    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($lang)
    
    if ($engine) {
        Write-Host "SUCCESS: Windows OCR Engine is available." -ForegroundColor Green
        Write-Host "Max Image Dimension: $($engine.MaxImageDimension)"
    }
    else {
        Write-Host "WARNING: Windows OCR Engine could not be created for 'en-US'." -ForegroundColor Yellow
        $avail = [Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages
        Write-Host "Available Languages: $(($avail | ForEach-Object { $_.LanguageTag }) -join ", ")"
    }
}
catch {
    Write-Error "FAILED: Windows OCR types could not be loaded. This feature might not be supported on this OS version/User Context."
    Write-Error $_
}
