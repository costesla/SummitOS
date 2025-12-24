param(
    [string]$ProcessedRoot = "C:\Users\Peter Teehan\OneDrive - COS Tesla LLC\MobilityOS\Uber Tracking\2025\Processed",
    [string]$Date = "2025-12-12"
)

Write-Host "=== MobilityOS Stage 4b: OCR Enrichment (Polling) ===" -ForegroundColor Cyan
# Ensure Types
try {
    [Windows.Media.Ocr.OcrEngine, Windows.Foundation.UniversalApiContract, ContentType = WindowsRuntime] | Out-Null
    [Windows.Globalization.Language, Windows.Foundation.UniversalApiContract, ContentType = WindowsRuntime] | Out-Null
    [Windows.Storage.StorageFile, Windows.Foundation.UniversalApiContract, ContentType = WindowsRuntime] | Out-Null
    [Windows.Storage.FileAccessMode, Windows.Foundation.UniversalApiContract, ContentType = WindowsRuntime] | Out-Null
    
    $lang = [Windows.Globalization.Language]::new("en-US")
    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($lang)
}
catch {
    Write-Error "Failed to load types."
    exit
}

function Await-WinRT($op) {
    # Status: 0=Started, 1=Completed, 2=Canceled, 3=Error
    while ($op.Status -eq 0) { Start-Sleep -Milliseconds 50 }
    
    if ($op.Status -eq 1) {
        return $op.GetResults()
    }
    elseif ($op.Status -eq 3) {
        throw "WinRT Async Op Failed: $($op.ErrorCode.Message)"
    }
    return $null
}

$folders = Get-ChildItem -Path $ProcessedRoot -Directory | Where-Object { $_.Name -match $Date }

foreach ($folder in $folders) {
    Write-Host "`nEvent: $($folder.Name)" -NoNewline
    $images = Get-ChildItem -Path $folder.FullName -Filter "*.jpg"
    $target = $images | Where-Object { $_.Name -match "Uber Driver" } | Select-Object -First 1
    if (-not $target) { $target = $images | Where-Object { $_.Name -match "Uber" } | Select-Object -First 1 }
    
    if ($target) {
        Write-Host " -> Scanning: $($target.Name)" -NoNewline
        try {
            $fileOp = [Windows.Storage.StorageFile]::GetFileFromPathAsync($target.FullName)
            $file = Await-WinRT $fileOp
            
            $streamOp = $file.OpenAsync([Windows.Storage.FileAccessMode]::Read)
            $stream = Await-WinRT $streamOp
            
            $decOp = [Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)
            $decoder = Await-WinRT $decOp
            
            $bmpOp = $decoder.GetSoftwareBitmapAsync()
            $bmp = Await-WinRT $bmpOp
            
            $ocrOp = $engine.RecognizeAsync($bmp)
            $result = Await-WinRT $ocrOp
            
            $lines = $result.Lines | ForEach-Object { $_.Text }
            $fullText = $lines -join " | "
            
            Write-Host " [Success: $($lines.Count) lines]" -ForegroundColor Green
            
            # Extract Address
            $addressGuess = ""
            foreach ($line in $lines) {
                if ($line -match "\d+\s+[A-Za-z0-9]+\s+(St|Ave|Rd|Blvd|Dr|Ln|Way|Pl|Cir|Ct|Pkwy)") {
                    $addressGuess = $line; break
                }
                if ($line -match "^To (.+)") { $addressGuess = $matches[1]; break }
            }
            if ($addressGuess) { Write-Host "    Addr: $addressGuess" -ForegroundColor Yellow }
            
            # Save
            $jsonPath = Join-Path $folder.FullName "tessie_data.json"
            if (Test-Path $jsonPath) {
                $json = Get-Content $jsonPath | ConvertFrom-Json
                $json | Add-Member -MemberType NoteProperty -Name "OCR_Raw_Text" -Value $fullText -Force
                $json | Add-Member -MemberType NoteProperty -Name "OCR_Address_Guess" -Value $addressGuess -Force
                $json | ConvertTo-Json -Depth 5 | Out-File $jsonPath
            }

        }
        catch {
            Write-Host " [Error: $_]" -ForegroundColor Red
        }
    }
}
