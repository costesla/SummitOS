param(
    [Parameter(Mandatory = $true)]
    [string]$ProcessDate,       # yyyy-MM-dd
    [Parameter(Mandatory = $true)]
    [string]$TargetFolder,      # Day root folder

    [string]$ConfigPath = ".\config_tessie.json",
    [switch]$WhatIf
)

# ------------------------ CONFIG LOAD ------------------------
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Host "[ERROR] Tessie config not found at $ConfigPath" -ForegroundColor Red
    Write-Host "Please create a JSON file with: { ""api_token"": ""YOUR_TOKEN"", ""vin"": ""OPTIONAL_VIN"" }" -ForegroundColor Yellow
    exit 1
}

$cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$token = $cfg.api_token

if ([string]::IsNullOrWhiteSpace($token)) {
    Write-Host "[ERROR] 'api_token' missing in config." -ForegroundColor Red
    exit 1
}

# ------------------------ API CALL ------------------------

# Range: ProcessDate 00:00 to 23:59:59
$dateObj = [datetime]::ParseExact($ProcessDate, "yyyy-MM-dd", $null)
$tsStart = [int64](Get-Date $dateObj -UFormat %s)
$tsEnd = [int64](Get-Date $dateObj.AddDays(1).AddSeconds(-1) -UFormat %s)

# Tessie Endpoint: Get Charges
# GET https://api.tessie.com/{vin}/charges?from={from}&to={to}
# If VIN is omitted, it might get all vehicles or fail. Better to require VIN or iterate.
# For simplicity, if VIN is missing, we try generic or prompt user.
$vin = $cfg.vin
if (-not $vin) {
    # If no VIN, maybe fetch vehicles first? 
    # For MVP, let's assume user provides VIN or we query 'vehicles' endpoint to find first active one.
    Write-Host "[INFO] No VIN in config. Querying vehicles..." -ForegroundColor Cyan
    try {
        $vUrl = "https://api.tessie.com/vehicles?access_token=$token"
        $vRes = Invoke-RestMethod -Uri $vUrl -Method Get
        $vin = $vRes.results[0].vin
        Write-Host "-> Found VIN: $vin" -ForegroundColor Cyan
    }
    catch {
        Write-Host "[ERROR] Failed to fetch vehicles: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

$url = "https://api.tessie.com/$vin/charges?from=$tsStart&to=$tsEnd&access_token=$token"

Write-Host "Fetching charging data for $ProcessDate..." -ForegroundColor Cyan

if ($WhatIf) {
    Write-Host "[WHATIF] Would call API: $url" -ForegroundColor Yellow
    return
}

try {
    $response = Invoke-RestMethod -Uri $url -Method Get
    # Response structure depends on Tessie API. Usually 'results' array.
    $charges = $response.results
    
    $count = if ($charges) { $charges.Count } else { 0 }
    Write-Host "-> Found $count sessions." -ForegroundColor Green
    

    $outFileCharges = Join-Path $TargetFolder "charging_data.json"
    $response | ConvertTo-Json -Depth 10 | Out-File -LiteralPath $outFileCharges -Encoding UTF8
    Write-Host "Saved: $outFileCharges" -ForegroundColor Gray

    # ------------------------ DRIVES ------------------------
    $urlDrives = "https://api.tessie.com/$vin/drives?from=$tsStart&to=$tsEnd&access_token=$token"
    Write-Host "Fetching driving data for $ProcessDate..." -ForegroundColor Cyan
    
    $responseDrives = Invoke-RestMethod -Uri $urlDrives -Method Get
    $drives = $responseDrives.results
    
    $dCount = if ($drives) { $drives.Count } else { 0 }
    Write-Host "-> Found $dCount drives." -ForegroundColor Green
    
    $outFileDrives = Join-Path $TargetFolder "driving_data.json"
    $responseDrives | ConvertTo-Json -Depth 10 | Out-File -LiteralPath $outFileDrives -Encoding UTF8
    Write-Host "Saved: $outFileDrives" -ForegroundColor Gray

}
catch {
    Write-Host "[ERROR] API Call Failed: $($_.Exception.Message)" -ForegroundColor Red
}
