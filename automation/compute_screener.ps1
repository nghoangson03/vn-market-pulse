# Doc automation/cache/history/*.json, chon TOP_N ma von hoa lon + thanh khoan cao nhat
# (xep hang theo gia tri giao dich binh quan 20 phien), cham diem Wyckoff-style tren tap do,
# ghi screener.json + screener_charts.json vao goc repo. Danh sach top-N duoc chot 1 lan vao
# automation/cache/topN_symbols.json va tai su dung cho cac lan chay sau (kha ca chay hang
# ngay) de gioi han pham vi quet + thoi gian chay. Khong dung agent nao.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$cacheDir = Join-Path $root "automation\cache"
$histDir = Join-Path $cacheDir "history"
$topNPath = Join-Path $cacheDir "topN_symbols.json"
. (Join-Path $root "automation\lib\wyckoff_engine.ps1")

$TOP_N = 120
# Only screen HOSE (the VN-Index universe) - HNX and UPCOM are excluded per request.
$ALLOWED_EXCHANGES = @("HOSE")

$logDir = Join-Path $root "automation\logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir "compute_screener_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
function Write-Log($msg) {
  $line = "[$(Get-Date -Format 'HH:mm:ss')] $msg"
  Write-Output $line
  try { Add-Content -Path $logFile -Value $line -ErrorAction Stop } catch { }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding $false

# Cross-reference against symbols.json (the current, authoritative stock universe) rather
# than just listing automation/cache/history/*.json - that directory can carry stale files
# for symbols no longer in the universe (e.g. an earlier crawl before a filter fix).
$symbolsPath = Join-Path $cacheDir "symbols.json"
$universe = Get-Content -Path $symbolsPath -Raw -Encoding UTF8 | ConvertFrom-Json
$totalUniverse = $universe.Count

# symbols.json (written straight from live API JSON, never round-tripped through a
# file read) is the clean source for company names. The per-symbol history cache
# files also carry a name field, but earlier runs wrote it after a Get-Content call
# that lacked -Encoding UTF8, which mangled non-ASCII names on PS 5.1 - use this map
# instead of $doc.name so screener.json gets correct names regardless of what's
# sitting in the (gitignored, local-only) history cache.
$nameMap = @{}
foreach ($u in $universe) { $nameMap[$u.symbol] = $u.name }

$allFiles = $universe | ForEach-Object {
  $p = Join-Path $histDir "$($_.symbol).json"
  if (Test-Path $p) { Get-Item $p }
} | Where-Object { $_ -ne $null }
$hoseUniverseCount = ($universe | Where-Object { $_.exchange -in $ALLOWED_EXCHANGES }).Count
Write-Log "Universe: $totalUniverse symbols total ($hoseUniverseCount on $($ALLOWED_EXCHANGES -join '/')), $($allFiles.Count) with cached history"

if (Test-Path $topNPath) {
  $topList = Get-Content -Path $topNPath -Raw -Encoding UTF8 | ConvertFrom-Json
  Write-Log "Using existing top-N list ($($topList.Count) symbols) from $topNPath"
  $targetFiles = $topList | ForEach-Object {
    $p = Join-Path $histDir "$_.json"
    if (Test-Path $p) { Get-Item $p }
  }
} else {
  $rankFiles = $universe | Where-Object { $_.exchange -in $ALLOWED_EXCHANGES } | ForEach-Object {
    $p = Join-Path $histDir "$($_.symbol).json"
    if (Test-Path $p) { Get-Item $p }
  } | Where-Object { $_ -ne $null }
  Write-Log ("No top-N list yet - ranking {0} cached symbols on {1} by avg traded value (20-session)..." -f $rankFiles.Count, ($ALLOWED_EXCHANGES -join '/'))
  $ranked = New-Object System.Collections.Generic.List[object]
  foreach ($f in $rankFiles) {
    $doc = Get-Content -Path $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $pts = @($doc.points)
    if ($pts.Count -lt 40) { continue }
    $n = $pts.Count
    $cnt = [Math]::Min(20, $n)
    $sum = 0.0
    for ($i = $n - $cnt; $i -lt $n; $i++) { $sum += ($pts[$i].c * $pts[$i].v) }
    $avgTradedVal = $sum / $cnt
    $ranked.Add([PSCustomObject]@{ symbol = $doc.symbol; avgTradedVal = $avgTradedVal; file = $f }) | Out-Null
  }
  $sorted = $ranked | Sort-Object -Property avgTradedVal -Descending
  Write-Log "Traded value around the cutoff (rank 100-140):"
  for ($i = 99; $i -lt [Math]::Min(140, $sorted.Count); $i++) {
    Write-Log ("  #{0} {1}: {2:N0} VND/day" -f ($i+1), $sorted[$i].symbol, $sorted[$i].avgTradedVal)
  }

  $top = $sorted | Select-Object -First $TOP_N
  $topList = $top | ForEach-Object { $_.symbol }
  $targetFiles = $top | ForEach-Object { $_.file }

  $topListJson = $topList | ConvertTo-Json -Depth 2
  [System.IO.File]::WriteAllText($topNPath, $topListJson, $utf8NoBom)
  Write-Log "Picked top $($topList.Count) symbols by liquidity, saved to $topNPath"
}

$buckets = @{
  buy_confirmed  = New-Object System.Collections.Generic.List[object]
  buy_watch      = New-Object System.Collections.Generic.List[object]
  sell_confirmed = New-Object System.Collections.Generic.List[object]
  sell_watch     = New-Object System.Collections.Generic.List[object]
}
$charts = @{}
$screened = 0
$flagged = 0

foreach ($f in $targetFiles) {
  if ($null -eq $f) { continue }
  $doc = Get-Content -Path $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
  $pts = @($doc.points)
  if ($pts.Count -lt 40) { continue }
  $screened++

  $cleanName = $nameMap[$doc.symbol]
  if (-not $cleanName) { $cleanName = $doc.name }
  $result = Compute-WyckoffForSymbol $doc.symbol $cleanName $doc.exchange $pts
  if ($null -eq $result) { continue }

  $flagged++
  $buckets[$result.signal].Add($result) | Out-Null

  $chartPts = $pts | Select-Object -Last 120 | ForEach-Object { [PSCustomObject]@{ d=$_.d; o=$_.o; h=$_.h; l=$_.l; c=$_.c; v=$_.v } }
  $charts[$doc.symbol] = [PSCustomObject]@{
    symbol     = $doc.symbol
    support    = $result.support
    resistance = $result.resistance
    triggerDate= $result.triggerDate
    points     = $chartPts
  }
}

foreach ($k in @($buckets.Keys)) {
  $sorted2 = $buckets[$k] | Sort-Object -Property score -Descending
  $buckets[$k] = @($sorted2)
}

Write-Log "totalUniverse=$totalUniverse screened=$screened flagged=$flagged"
Write-Log "buy_confirmed=$($buckets.buy_confirmed.Count) buy_watch=$($buckets.buy_watch.Count) sell_confirmed=$($buckets.sell_confirmed.Count) sell_watch=$($buckets.sell_watch.Count)"

$nowIso = (Get-Date).ToUniversalTime().ToString("o")
$screener = [PSCustomObject]@{
  generatedAt     = $nowIso
  totalSymbols    = $hoseUniverseCount
  screenedSymbols = $screened
  buckets         = [PSCustomObject]@{
    buy_confirmed  = $buckets.buy_confirmed
    buy_watch      = $buckets.buy_watch
    sell_confirmed = $buckets.sell_confirmed
    sell_watch     = $buckets.sell_watch
  }
}

$screenerJson = $screener | ConvertTo-Json -Depth 6 -Compress
[System.IO.File]::WriteAllText((Join-Path $root "screener.json"), $screenerJson, $utf8NoBom)

$chartsJson = ($charts) | ConvertTo-Json -Depth 6 -Compress
[System.IO.File]::WriteAllText((Join-Path $root "screener_charts.json"), $chartsJson, $utf8NoBom)

Write-Log "Wrote screener.json and screener_charts.json"
