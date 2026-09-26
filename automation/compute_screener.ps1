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

# VN-Index (data.json, ghi boi tac vu "Daily Update" luc 15:40, truoc tac vu nay 16:00)
# lam nguon cho Lop 1 (che do thi truong chung) va Lop 4 (suc manh tuong doi).
$vnIndexPath = Join-Path $root "data.json"
$vnPoints = $null
$marketRegime = [PSCustomObject]@{ status = "neutral"; vnClose = $null; ma50 = $null }
if (Test-Path $vnIndexPath) {
  $dataDoc = Get-Content -Path $vnIndexPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($dataDoc.vnindex -and $dataDoc.vnindex.points) {
    $vnPoints = @($dataDoc.vnindex.points)
    $marketRegime = Get-MarketRegime $vnPoints
  }
}
Write-Log "Market regime (VN-Index): $($marketRegime.status) (close=$($marketRegime.vnClose) MA50=$($marketRegime.ma50))"

# Nhom nganh (danh sach tinh, tu chinh tay - xem automation/data/sector_map.json) va toa dam
# vi mo (cap nhat thu cong dinh ky, xem automation/data/macro.json) - ca 2 la du lieu KHONG
# tu dong crawl hang ngay, chi doc lai file tinh moi lan chay.
$sectorMapPath = Join-Path $root "automation\data\sector_map.json"
$sectorMap = @{}
if (Test-Path $sectorMapPath) {
  $sectorDoc = Get-Content -Path $sectorMapPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $sectorDoc.sectors.PSObject.Properties | ForEach-Object { $sectorMap[$_.Name] = $_.Value }
}
Write-Log "Sector map: $($sectorMap.Count) symbols classified"

$macroPath = Join-Path $root "automation\data\macro.json"
$macro = $null
if (Test-Path $macroPath) {
  $macroDoc = Get-Content -Path $macroPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $macro = [PSCustomObject]@{ asOf = $macroDoc.asOf; summary = $macroDoc.summary; indicators = $macroDoc.indicators }
}

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
  buy_expired    = New-Object System.Collections.Generic.List[object]
  sell_confirmed = New-Object System.Collections.Generic.List[object]
  sell_watch     = New-Object System.Collections.Generic.List[object]
  neutral        = New-Object System.Collections.Generic.List[object]
}
$charts = @{}
$screened = 0
$flagged = 0
# Dung de tinh do rong thi truong (breadth) va suc manh nhom nganh tren CA 120 ma dang
# quet - khong chi 65 ma co tin hieu - nen phai luu 1 dong cho moi ma da quet, ke ca trung lap.
$breadthList = New-Object System.Collections.Generic.List[object]

foreach ($f in $targetFiles) {
  if ($null -eq $f) { continue }
  $doc = Get-Content -Path $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
  $pts = @($doc.points)
  if ($pts.Count -lt 40) { continue }
  $screened++

  $cleanName = $nameMap[$doc.symbol]
  if (-not $cleanName) { $cleanName = $doc.name }
  $sector = $sectorMap[$doc.symbol]
  $stageAll = if ($vnPoints) { Get-StageContext $pts } else { "unknown" }

  $result = Compute-WyckoffForSymbol $doc.symbol $cleanName $doc.exchange $pts
  if ($null -eq $result) {
    $q = Get-BasicQuote $pts
    $buckets.neutral.Add([PSCustomObject]@{
      symbol     = $doc.symbol
      exchange   = $doc.exchange
      name       = $cleanName
      lastClose  = $q.lastClose
      changePct  = $q.changePct
      volRatio   = $q.volRatio
      sector     = $sector
      stage      = $stageAll
    }) | Out-Null
    $breadthList.Add([PSCustomObject]@{ symbol = $doc.symbol; sector = $sector; stage = $stageAll; signal = "neutral"; rs = $null }) | Out-Null
    continue
  }

  $flagged++
  $rs = $null

  if ($vnPoints) {
    $stage = $stageAll
    $rs = Get-RelativeStrength $pts $vnPoints 20
    $adj = Get-LayerAdjustment $result.signal $result.score $marketRegime.status $stage $rs
    $result.signal = $adj.signal
    $result.score = $adj.score
    if ($adj.layerText) { $result.note = "$($result.note) $($adj.layerText)" }
    $result | Add-Member -NotePropertyName rawScore -NotePropertyValue $adj.rawScore
    $result | Add-Member -NotePropertyName stage -NotePropertyValue $stage
    $result | Add-Member -NotePropertyName rs -NotePropertyValue $rs

    # Rieng cho tin hieu MUA: canh bao mua duoi (T+2,5) + diem stop-loss/target CU THE -
    # dung phase GOC (truoc khi bi ha tier o tren) de chon dung muc lam stop, vi cau truc
    # SOS/Spring la that ke ca khi tier bi ha do boi canh 4 lop khong dong thuan.
    $sessionsSinceTrigger = ($pts.Count - 1) - $result.triggerIdx
    $ext = Get-ExtensionRisk $result.signal $result.lastClose $result.resistance $sessionsSinceTrigger
    if ($ext) {
      $result.note = "$($result.note) $($ext.text)"
      $result | Add-Member -NotePropertyName extensionPct -NotePropertyValue $ext.extensionPct
      $result | Add-Member -NotePropertyName chaseWarning -NotePropertyValue $true
    }

    $levels = Get-TradeLevels $result.signal $result.phase $result.lastClose $result.support $result.resistance
    if ($levels -and -not $levels.hasEdge) {
      # Tin hieu MUA that (SOS/Spring da xay ra) nhung khong con dang mua LUC NAY - chuyen
      # sang bucket rieng buy_expired, KHONG tinh vao buy_confirmed/buy_watch (breadth, xep
      # hang nganh, thong ke "so ma co tin hieu" deu tu dong loai no ra vi khop chinh xac
      # "buy_confirmed"/"buy_watch", khong dung wildcard "buy*").
      $result.note = "$($result.note) Đã có tín hiệu mua nhưng $($levels.reason) - KHÔNG khuyến nghị mua ở vùng giá này (chỉ hiện tín hiệu tiềm năng lãi ≥5%)."
      $result | Add-Member -NotePropertyName tradeSetupBroken -NotePropertyValue $true
      $result | Add-Member -NotePropertyName rewardPct -NotePropertyValue $levels.rewardPct
      $result.signal = $result.signal -replace "^buy_(confirmed|watch)$", "buy_expired"
    } elseif ($levels) {
      $result | Add-Member -NotePropertyName stopLoss -NotePropertyValue $levels.stopLoss
      $result | Add-Member -NotePropertyName target -NotePropertyValue $levels.target
      $result | Add-Member -NotePropertyName riskRewardRatio -NotePropertyValue $levels.riskRewardRatio
      $result | Add-Member -NotePropertyName rewardPct -NotePropertyValue $levels.rewardPct
    }
  }

  $result | Add-Member -NotePropertyName sector -NotePropertyValue $sector
  $buckets[$result.signal].Add($result) | Out-Null
  $breadthList.Add([PSCustomObject]@{ symbol = $doc.symbol; sector = $sector; stage = $stageAll; signal = $result.signal; rs = $rs }) | Out-Null

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
  if ($k -eq "neutral") {
    $sorted2 = $buckets[$k] | Sort-Object -Property symbol
  } else {
    $sorted2 = $buckets[$k] | Sort-Object -Property score -Descending
  }
  $buckets[$k] = @($sorted2)
}

Write-Log "totalUniverse=$totalUniverse screened=$screened flagged=$flagged neutral=$($buckets.neutral.Count)"
Write-Log "buy_confirmed=$($buckets.buy_confirmed.Count) buy_watch=$($buckets.buy_watch.Count) buy_expired=$($buckets.buy_expired.Count) sell_confirmed=$($buckets.sell_confirmed.Count) sell_watch=$($buckets.sell_watch.Count)"

# --- Do rong thi truong (breadth) tren toan bo $screened ma da quet ---
$stage2Count = ($breadthList | Where-Object { $_.stage -eq "stage2" }).Count
$stage4Count = ($breadthList | Where-Object { $_.stage -eq "stage4" }).Count
$marketBreadth = [PSCustomObject]@{
  screenedCount   = $breadthList.Count
  stage2Count     = $stage2Count
  stage4Count     = $stage4Count
  buySignalCount  = $buckets.buy_confirmed.Count + $buckets.buy_watch.Count
  sellSignalCount = $buckets.sell_confirmed.Count + $buckets.sell_watch.Count
  neutralCount    = $buckets.neutral.Count
}
Write-Log "Breadth: stage2=$stage2Count stage4=$stage4Count buy=$($marketBreadth.buySignalCount) sell=$($marketBreadth.sellSignalCount)"

# --- Suc manh nhom nganh: gop cac ma da quet theo $sectorMap, cham "diem manh yeu" tu
# RS trung binh + %ma dang Stage 2/4 + so tin hieu mua/ban rong - hoan toan tu du lieu da
# tinh, khong can nguon rieng. Nhom co <2 ma bi bo qua vi khong du de noi ve "dong tien". ---
$sectorStrength = @()
$sectorGroups = $breadthList | Where-Object { $_.sector } | Group-Object -Property sector
foreach ($g in $sectorGroups) {
  $items = $g.Group
  if ($items.Count -lt 2) { continue }
  $rsVals = $items | Where-Object { $null -ne $_.rs } | ForEach-Object { $_.rs }
  $avgRs = if ($rsVals.Count -gt 0) { ($rsVals | Measure-Object -Average).Average } else { $null }
  $buyCount = ($items | Where-Object { $_.signal -eq "buy_confirmed" -or $_.signal -eq "buy_watch" }).Count
  $sellCount = ($items | Where-Object { $_.signal -eq "sell_confirmed" -or $_.signal -eq "sell_watch" }).Count
  $stage2Pct = (($items | Where-Object { $_.stage -eq "stage2" }).Count / $items.Count) * 100
  $stage4Pct = (($items | Where-Object { $_.stage -eq "stage4" }).Count / $items.Count) * 100
  $rsScore = if ($null -ne $avgRs) { $avgRs } else { 0 }
  $strengthScore = [Math]::Round($rsScore + ($stage2Pct - $stage4Pct) * 0.3 + (($buyCount - $sellCount) * 5), 1)
  $tier = if ($strengthScore -ge 8) { "manh" } elseif ($strengthScore -le -8) { "yeu" } else { "trung_binh" }
  $sectorStrength += [PSCustomObject]@{
    sector        = $g.Name
    count         = $items.Count
    avgRs         = if ($null -ne $avgRs) { [Math]::Round($avgRs, 2) } else { $null }
    stage2Pct     = [Math]::Round($stage2Pct, 1)
    stage4Pct     = [Math]::Round($stage4Pct, 1)
    buyCount      = $buyCount
    sellCount     = $sellCount
    strengthScore = $strengthScore
    tier          = $tier
  }
}
$sectorStrength = @($sectorStrength | Sort-Object -Property strengthScore -Descending)
Write-Log "Sector strength: $($sectorStrength.Count) nhom (>=2 ma) duoc xep hang"

$nowIso = (Get-Date).ToUniversalTime().ToString("o")
$screener = [PSCustomObject]@{
  generatedAt     = $nowIso
  totalSymbols    = $hoseUniverseCount
  screenedSymbols = $screened
  marketRegime    = $marketRegime
  marketBreadth   = $marketBreadth
  sectorStrength  = $sectorStrength
  macro           = $macro
  buckets         = [PSCustomObject]@{
    buy_confirmed  = $buckets.buy_confirmed
    buy_watch      = $buckets.buy_watch
    buy_expired    = $buckets.buy_expired
    sell_confirmed = $buckets.sell_confirmed
    sell_watch     = $buckets.sell_watch
    neutral        = $buckets.neutral
  }
}

$screenerJson = $screener | ConvertTo-Json -Depth 6 -Compress
[System.IO.File]::WriteAllText((Join-Path $root "screener.json"), $screenerJson, $utf8NoBom)

$chartsJson = ($charts) | ConvertTo-Json -Depth 6 -Compress
[System.IO.File]::WriteAllText((Join-Path $root "screener_charts.json"), $chartsJson, $utf8NoBom)

Write-Log "Wrote screener.json and screener_charts.json"
