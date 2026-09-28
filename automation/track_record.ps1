# Chay hang ngay SAU compute_screener.ps1 (goi tu run_daily_screener.ps1): ghi lai MOI tin
# hieu MUA/BAN moi xuat hien trong screener.json vao so nhat ky automation/data/signal_log.json
# (du lieu duoc commit vao git, khac cache/ bi gitignore), roi doi chieu cac tin hieu dang
# "open" voi gia THAT lay tu cache lich su de biet no "dung" (cham target/tranh duoc lo),
# "sai" (dinh stop/mat gia tri), hay "het han theo doi" (qua $MAX_HOLD_SESSIONS phien ma
# khong cham muc nao). Ghi tong hop ra track_record.json o goc repo cho wyckoff.html hien
# thi. Muc dich: doi chieu khuyen nghi voi ket qua that theo thoi gian, lam co so de dieu
# chinh engine (wyckoff_engine.ps1) sau nay dua tren bang chung thuc te thay vi doan mo.
# Thuan PowerShell xu ly du lieu cache co san, khong goi agent/LLM nao.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$histDir = Join-Path $root "automation\cache\history"
. (Join-Path $root "automation\lib\track_record_lib.ps1")

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
# So phien toi da giu 1 tin hieu o trang thai "open" truoc khi coi la het han theo doi
# (~2 thang giao dich) - du rong cho muc tieu do luong (chieu cao vung tich luy/phan phoi)
# thuong mat vai tuan de hien thuc hoa, nhung van co diem dung de khong "open" mai mai.
$MAX_HOLD_SESSIONS = 40
# T+2,5: mua xong phai doi ~2-3 phien lo moi ve tai khoan de ban duoc - neu gia cham
# target/stop ngay trong thoi gian nay thi nguoi mua VAN CHUA THE ban duoc gia do that su.
# Chi khoa chieu MUA (ban hang dang cam thi ban duoc ngay, khong bi khoa).
$T_PLUS_LOCK_SESSIONS = 2

$logDir = Join-Path $root "automation\logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir "track_record_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
function Write-Log($msg) {
  $line = "[$(Get-Date -Format 'HH:mm:ss')] $msg"
  Write-Output $line
  try { Add-Content -Path $logFile -Value $line -ErrorAction Stop } catch { }
}

$screenerPath = Join-Path $root "screener.json"
$screener = Get-Content -Path $screenerPath -Raw -Encoding UTF8 | ConvertFrom-Json
# Cung quy uoc voi wyckoff.html (screener.generatedAt.slice(0,10)): ngay UTC cua lan chay
# nay lam "ngay vao so" cho moi tin hieu moi phat hien hom nay.
$today = $screener.generatedAt.Substring(0, 10)

$logPath = Join-Path $root "automation\data\signal_log.json"
$log = if (Test-Path $logPath) { Get-Content -Path $logPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
$entries = New-Object System.Collections.Generic.List[object]
if ($log -and $log.entries) { foreach ($e in @($log.entries)) { $entries.Add($e) | Out-Null } }
$existingIds = @{}
foreach ($e in $entries) { $existingIds[$e.id] = $true }

# --- 1) Ghi tin hieu MOI (chua tung xuat hien - phan biet theo ma+ngay kich hoat+mau hinh) ---
$beforeCount = $entries.Count
$directionBuckets = @(
  @{ items = @($screener.buckets.buy_confirmed);  direction = "buy" },
  @{ items = @($screener.buckets.buy_watch);       direction = "buy" },
  @{ items = @($screener.buckets.sell_confirmed);  direction = "sell" },
  @{ items = @($screener.buckets.sell_watch);      direction = "sell" }
)
foreach ($db in $directionBuckets) {
  foreach ($item in $db.items) {
    $id = "$($item.symbol)_$($item.triggerDate)_$($item.phase)"
    if ($existingIds.ContainsKey($id)) { continue }

    if ($db.direction -eq "buy") {
      $badLevel = $item.stopLoss; $goodLevel = $item.target
    } else {
      $levels = Get-SellLevels $item.phase $item.lastClose $item.support $item.resistance
      if ($null -eq $levels) { continue }
      $badLevel = $levels.invalidation; $goodLevel = $levels.downTarget
    }

    $entries.Add([PSCustomObject]@{
      id                  = $id
      symbol              = $item.symbol
      name                = $item.name
      sector              = $item.sector
      direction           = $db.direction
      signalAtEntry       = $item.signal
      phase               = $item.phase
      triggerDate         = $item.triggerDate
      entryDate           = $today
      entryPrice          = $item.lastClose
      badLevel            = $badLevel
      goodLevel           = $goodLevel
      scoreAtEntry        = $item.score
      marketRegimeAtEntry = $screener.marketRegime.status
      stageAtEntry        = $item.stage
      rsAtEntry           = $item.rs
      status              = "open"
      resolvedDate        = $null
      resolvedPrice       = $null
      actualReturnPct     = $null
      sessionsToResolve   = $null
    }) | Out-Null
    $existingIds[$id] = $true
  }
}
Write-Log "New entries logged: $($entries.Count - $beforeCount)"

# --- 2) Doi chieu (resolve) cac tin hieu dang "open" voi gia that ---
$histCache = @{}
function Get-History($symbol) {
  if ($histCache.ContainsKey($symbol)) { return $histCache[$symbol] }
  $p = Join-Path $histDir "$symbol.json"
  $pts = if (Test-Path $p) { @((Get-Content -Path $p -Raw -Encoding UTF8 | ConvertFrom-Json).points) } else { @() }
  $histCache[$symbol] = $pts
  return $pts
}

$resolvedCount = 0
foreach ($e in $entries) {
  if ($e.status -ne "open") { continue }
  $pts = Get-History $e.symbol
  $future = @($pts | Where-Object { $_.d -gt $e.entryDate } | Sort-Object d)
  if ($future.Count -eq 0) { continue }
  $lockSessions = if ($e.direction -eq "buy") { $T_PLUS_LOCK_SESSIONS } else { 0 }
  $res = Resolve-Entry $e.direction $e.entryPrice $e.badLevel $e.goodLevel $future $MAX_HOLD_SESSIONS $lockSessions
  if ($null -eq $res) { continue }
  $e.status = $res.status
  $e.resolvedDate = $res.resolvedDate
  $e.resolvedPrice = $res.resolvedPrice
  $e.sessionsToResolve = $res.sessionsToResolve
  $e.actualReturnPct = if ($e.direction -eq "buy") {
    [Math]::Round((($res.resolvedPrice - $e.entryPrice) / $e.entryPrice) * 100, 2)
  } else {
    [Math]::Round((($e.entryPrice - $res.resolvedPrice) / $e.entryPrice) * 100, 2)
  }
  $resolvedCount++
}
Write-Log "Resolved this run: $resolvedCount"

# 🚨 $entries la System.Collections.Generic.List[object] - trong PowerShell 5.1 tren may
# nay, toan tu "@(...)" boc quanh THANG mot List[object] bi loi "Argument types do not
# match" (loi moi truong that, tai hien duoc voi CHI 1 phan tu, khong lien quan gi den
# ConvertTo-Json hay so luong item - xem D:\ClaudeData...\memory\holeit_env_powershell_quirks.md).
# Dung .ToArray() de doi sang object[] that truoc khi dua vao ConvertTo-Json (-InputObject
# thay vi pipe, danh rieng cho truong hop object[] lon, dong bo voi cach lam o duoi).
$logJson = ConvertTo-Json -InputObject ([PSCustomObject]@{ entries = $entries.ToArray() }) -Depth 6
[System.IO.File]::WriteAllText($logPath, $logJson, $utf8NoBom)

# --- 3) Tong hop ra track_record.json ---
function Get-Stats($items) {
  $items = @($items)
  $closed = @($items | Where-Object { $_.status -ne "open" })
  $wins = @($closed | Where-Object { $_.status -eq "hit_target" })
  $losses = @($closed | Where-Object { $_.status -eq "hit_stop" })
  $expired = @($closed | Where-Object { $_.status -eq "expired_neutral" })
  $decided = $wins.Count + $losses.Count
  $winRate = if ($decided -gt 0) { [Math]::Round(($wins.Count / $decided) * 100, 1) } else { $null }
  $avgReturn = if ($closed.Count -gt 0) { [Math]::Round((($closed | Measure-Object -Property actualReturnPct -Average).Average), 2) } else { $null }
  $avgWin = if ($wins.Count -gt 0) { [Math]::Round((($wins | Measure-Object -Property actualReturnPct -Average).Average), 2) } else { $null }
  $avgLoss = if ($losses.Count -gt 0) { [Math]::Round((($losses | Measure-Object -Property actualReturnPct -Average).Average), 2) } else { $null }
  return [PSCustomObject]@{
    openCount    = $items.Count - $closed.Count
    closedCount  = $closed.Count
    wins         = $wins.Count
    losses       = $losses.Count
    expired      = $expired.Count
    winRatePct   = $winRate
    avgReturnPct = $avgReturn
    avgWinPct    = $avgWin
    avgLossPct   = $avgLoss
  }
}

$buyEntries = @($entries | Where-Object { $_.direction -eq "buy" })
$sellEntries = @($entries | Where-Object { $_.direction -eq "sell" })

# Xep theo mau hinh cau truc (SOS/Spring/Upthrust/SOW) - noi de sau nay xem mau hinh nao
# dang tin cay hon trong thuc te tren TTCK VN, lam co so dieu chinh trong so cham diem.
$byPhase = @()
foreach ($g in ($entries | Group-Object -Property phase)) {
  $closed = @($g.Group | Where-Object { $_.status -ne "open" })
  if ($closed.Count -eq 0) { continue }
  $stats = Get-Stats $g.Group
  $byPhase += [PSCustomObject]@{
    phase        = $g.Name
    direction    = $g.Group[0].direction
    closedCount  = $stats.closedCount
    winRatePct   = $stats.winRatePct
    avgReturnPct = $stats.avgReturnPct
  }
}

$recentClosed = @($entries | Where-Object { $_.status -ne "open" } | Sort-Object -Property resolvedDate -Descending | Select-Object -First 15)

$latestPriceCache = @{}
function Get-LatestPrice($symbol) {
  if ($latestPriceCache.ContainsKey($symbol)) { return $latestPriceCache[$symbol] }
  $pts = Get-History $symbol
  $price = if ($pts.Count -gt 0) { $pts[$pts.Count - 1].c } else { $null }
  $latestPriceCache[$symbol] = $price
  return $price
}
$openPositions = @($entries | Where-Object { $_.status -eq "open" } | ForEach-Object {
  $latest = Get-LatestPrice $_.symbol
  $unrealized = if ($null -ne $latest) {
    if ($_.direction -eq "buy") { [Math]::Round((($latest - $_.entryPrice) / $_.entryPrice) * 100, 2) }
    else { [Math]::Round((($_.entryPrice - $latest) / $_.entryPrice) * 100, 2) }
  } else { $null }
  [PSCustomObject]@{
    symbol        = $_.symbol
    name          = $_.name
    sector        = $_.sector
    direction     = $_.direction
    phase         = $_.phase
    entryDate     = $_.entryDate
    entryPrice    = $_.entryPrice
    latestPrice   = $latest
    unrealizedPct = $unrealized
  }
} | Sort-Object -Property entryDate -Descending)

$trackRecord = [PSCustomObject]@{
  generatedAt     = (Get-Date).ToUniversalTime().ToString("o")
  startedTracking = "2026-09-28"
  overall         = [PSCustomObject]@{ buy = (Get-Stats $buyEntries); sell = (Get-Stats $sellEntries) }
  byPhase         = @($byPhase)
  recentClosed    = $recentClosed
  openPositions   = $openPositions
}
$trJson = ConvertTo-Json -InputObject $trackRecord -Depth 6
[System.IO.File]::WriteAllText((Join-Path $root "track_record.json"), $trJson, $utf8NoBom)
Write-Log ("Wrote track_record.json (buy closed={0} sell closed={1} open={2})" -f `
  $trackRecord.overall.buy.closedCount, $trackRecord.overall.sell.closedCount, ($trackRecord.overall.buy.openCount + $trackRecord.overall.sell.openCount))
