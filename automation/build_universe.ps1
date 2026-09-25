# Mot lan: do toan bo danh sach ma co phieu HOSE/HNX/UPCOM qua VNDirect dchart search,
# bang cach do de quy theo tien to (prefix) vi API gioi han cung 50 ket qua/lan goi.
# Ghi ra automation/cache/symbols.json. Khong goi Claude / agent nao.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$cacheDir = Join-Path $root "automation\cache"
New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
$logDir = Join-Path $root "automation\logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir "build_universe_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log($msg) {
  $line = "[$(Get-Date -Format 'HH:mm:ss')] $msg"
  Write-Output $line
  try { Add-Content -Path $logFile -Value $line -ErrorAction Stop } catch { }
}

$headers = @{
  "User-Agent" = "Mozilla/5.0"
  "Referer"    = "https://dstock.vndirect.com.vn/"
  "Origin"     = "https://dstock.vndirect.com.vn"
}
$alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".ToCharArray()

# "CO PHIEU" (stock) built from Unicode code points, not a literal in this file - PS 5.1
# reads .ps1 source using the system codepage without a BOM and mangles literal
# non-ASCII text, which would silently break a direct string comparison.
$STOCK_TYPE = [string]::new([char[]]@(67,7892,32,80,72,73,7870,85))

$found = @{}
$queryCount = 0

function Search-Prefix($prefix, $depth) {
  $script:queryCount++
  $uri = "https://dchart-api.vndirect.com.vn/dchart/search?query=$prefix&type=stock&exchange=&limit=50"
  try {
    $resp = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 15
  } catch {
    Start-Sleep -Milliseconds 500
    try {
      $resp = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 15
    } catch {
      Write-Log "WARN: search failed for prefix '$prefix': $($_.Exception.Message)"
      return
    }
  }
  Start-Sleep -Milliseconds 130

  if ($null -eq $resp) { return }
  $count = @($resp).Count

  if ($count -ge 50 -and $depth -lt 3) {
    foreach ($c in $alphabet) {
      Search-Prefix "$prefix$c" ($depth + 1)
    }
  } else {
    foreach ($r in @($resp)) {
      # The API's type=stock query param isn't fully enforced server-side (index/ETF
      # benchmark codes like VNINDEX, VN30, VNXALL... come back too), so also check
      # the per-result type field client-side.
      if ($r.symbol -and $r.type -eq $STOCK_TYPE -and $r.exchange -in @("HOSE","HNX","UPCOM")) {
        $found[$r.symbol] = [PSCustomObject]@{
          symbol   = $r.symbol
          name     = $r.description
          exchange = $r.exchange
        }
      }
    }
  }
}

Write-Log "Starting prefix crawl..."
foreach ($c in $alphabet) {
  Search-Prefix "$c" 1
}
Write-Log "Crawl done. Queries: $queryCount. Unique symbols found: $($found.Count)"

$list = $found.Values | Sort-Object symbol
$byExchange = $list | Group-Object exchange | Select-Object Name, Count
$byExchange | ForEach-Object { Write-Log " $($_.Name): $($_.Count)" }

$outPath = Join-Path $cacheDir "symbols.json"
$json = $list | ConvertTo-Json -Depth 3
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($outPath, $json, $utf8NoBom)
Write-Log "Wrote $outPath ($($list.Count) symbols)"
