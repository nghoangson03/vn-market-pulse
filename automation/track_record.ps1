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
. (Join-Path $root "automation\lib\wyckoff_engine.ps1")

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
# Ngay UTC cua lan chay nay - chi dung lam du phong khi khong doc duoc lich su gia cua ma
# (xem Get-PriceDate: "ngay vao so" phai la ngay cua gia dong cua dung lam entryPrice).
$today = $screener.generatedAt.Substring(0, 10)

$histCache = @{}
function Get-History($symbol) {
  if ($histCache.ContainsKey($symbol)) { return $histCache[$symbol] }
  $p = Join-Path $histDir "$symbol.json"
  $pts = if (Test-Path $p) { @((Get-Content -Path $p -Raw -Encoding UTF8 | ConvertFrom-Json).points) } else { @() }
  $histCache[$symbol] = $pts
  return $pts
}

# 🚨 Ngay vao so = ngay GIAO DICH cua gia dong cua dung lam entryPrice, KHONG phai ngay chay
# script: lan chay Chu nhat 27/09 lay gia dong cua thu Sau 25/09 nhung truoc day lai ghi
# entryDate = 27/09 (ngay khong co phien). Tra ve phien cuoi cung co gia <= $onOrBefore
# (bo trong = phien moi nhat), hoac $null neu chua co lich su.
function Get-PriceDate($symbol, $onOrBefore) {
  $pts = Get-History $symbol
  for ($i = $pts.Count - 1; $i -ge 0; $i--) {
    if (-not $onOrBefore -or $pts[$i].d -le $onOrBefore) { return $pts[$i].d }
  }
  return $null
}

# So phien giao dich tu ngay kich hoat tin hieu den ngay vao so - de sau nay do xem vao
# lenh tre (tin hieu da cu vai tuan) co lam giam ty le dung khong.
function Get-SessionsBetween($symbol, $fromDate, $toDate) {
  if (-not $fromDate -or -not $toDate) { return $null }
  $pts = Get-History $symbol
  if ($pts.Count -eq 0) { return $null }
  return @($pts | Where-Object { $_.d -gt $fromDate -and $_.d -le $toDate }).Count
}

$logPath = Join-Path $root "automation\data\signal_log.json"
$log = if (Test-Path $logPath) { Get-Content -Path $logPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
$entries = New-Object System.Collections.Generic.List[object]
if ($log -and $log.entries) { foreach ($e in @($log.entries)) { $entries.Add($e) | Out-Null } }
$existingIds = @{}
foreach ($e in $entries) { $existingIds[$e.id] = $true }

# Gan them property neu entry cu (ghi truoc khi co truong nay) chua co - ConvertFrom-Json
# tra ve PSCustomObject co dinh truong, gan thang $e.x = ... se loi neu x chua ton tai.
function Set-EntryField($entry, $name, $value) {
  if ($entry.PSObject.Properties[$name]) { $entry.$name = $value }
  else { $entry | Add-Member -NotePropertyName $name -NotePropertyValue $value }
}

# --- 0) Moi ma chi giu 1 vi the "dang theo doi" tai 1 thoi diem ---
# $activeBySymbol: ma -> entry dang mo (chua bi dao chieu). Truoc day moi lan tin hieu cu
# duoc kich hoat lai (khac triggerDate/phase) la ghi them 1 lenh moi du lenh cu con mo, nen
# 1 lan khuyen nghi bi dem nhieu lan (DXS, TCM, CTD, MWG, ACB...). Quy tac moi:
# - Cung chieu voi vi the dang mo -> ghi status "duplicate" (van luu id de khong ghi lai
#   lan sau, nhung KHONG tinh vao thong ke/vi the mo).
# - Nguoc chieu (dang MUA ma xuat hien tin hieu BAN hoac nguoc lai, VD AAA, VDS) -> danh
#   dau vi the cu reversedOn/reversedPrice = ngay/gia cua tin hieu moi; buoc 2 van doi chieu
#   vi the cu voi gia that TOI ngay do (neu da cham stop/target truoc thi giu ket qua do),
#   con chua cham gi thi dong o trang thai "reversed" tai gia luc dao chieu.
$activeBySymbol = @{}
function Get-SignalTier($entry) {
  if ($entry.phase -eq "pre_breakout") { return 2 }  # da kich hoat = vuot khang cu that
  if ($entry.signalAtEntry -like "*_confirmed") { return 2 }
  return 1
}
function Test-CanReverse($cur, $new) {
  if ($new.signalAtEntry -eq "buy_counter_trend") { return $false }
  return ((Get-SignalTier $new) -ge (Get-SignalTier $cur))
}
function Register-Entry($entry) {
  $cur = $activeBySymbol[$entry.symbol]
  if ($cur -and $cur.direction -eq $entry.direction) {
    $entry.status = "duplicate"
    Set-EntryField $entry "duplicateOf" $cur.id
    return
  }
  # Chong "lat keo" (them 01/10/2026): doi chieu 25/09-01/10 co 8/9 lenh BAN dong vi bi 1 tin hieu
  # MUA yeu hon (Spring/tich luy - thuong ngay sau SOW tren cung vung gia) dao chieu chi sau 1-4
  # phien. Nay chi dao chieu khi tin hieu moi MANH ngang hoac hon (xac nhan > theo doi), va tin
  # hieu bat day nguoc xu huong (khong phai khuyen nghi) khong bao gio dao chieu lenh dang mo.
  if ($cur -and -not (Test-CanReverse $cur $entry)) {
    $entry.status = "conflict"
    Set-EntryField $entry "conflictWith" $cur.id
    return
  }
  if ($cur) {
    Set-EntryField $cur "reversedOn" $entry.entryDate
    Set-EntryField $cur "reversedPrice" $entry.entryPrice
  }
  $activeBySymbol[$entry.symbol] = $entry
}

# Chuan hoa so nhat ky da co (idempotent - chay lai nhieu lan van ra cung ket qua): sua
# entryDate ve ngay giao dich that, roi xet trung lap/dao chieu theo thu tu thoi gian.
$fixedDates = 0
foreach ($e in $entries) {
  if ($e.status -eq "duplicate") { continue }
  $pd = Get-PriceDate $e.symbol $e.entryDate
  if ($pd -and $pd -ne $e.entryDate) { $e.entryDate = $pd; $fixedDates++ }
}
$openSorted = @($entries | Where-Object { $_.status -eq "open" -and -not $_.reversedOn } | Sort-Object -Property entryDate, id)
$dupBefore = @($entries | Where-Object { $_.status -eq "duplicate" }).Count
foreach ($e in $openSorted) { Register-Entry $e }
Write-Log "Normalized log: entryDate fixed=$fixedDates, duplicates marked=$(@($entries | Where-Object { $_.status -eq 'duplicate' }).Count - $dupBefore)"

# Boi canh thi truong/nganh luc phat tin hieu - luu kem moi entry de sau nay phan tich yeu
# to nao lam tang/giam ty le dung (tra cuu 1 lan cho ca lan chay).
$sectorInfo = @{}
foreach ($s in @($screener.sectorStrength)) { if ($s.sector) { $sectorInfo[$s.sector] = $s } }
$breadth = $screener.marketBreadth
$breadthStage2Pct = $null; $breadthStage4Pct = $null
if ($breadth -and $breadth.screenedCount -gt 0) {
  $breadthStage2Pct = [Math]::Round(($breadth.stage2Count / $breadth.screenedCount) * 100, 1)
  $breadthStage4Pct = [Math]::Round(($breadth.stage4Count / $breadth.screenedCount) * 100, 1)
}

# --- 1) Ghi tin hieu MOI (chua tung xuat hien - phan biet theo ma+ngay kich hoat+mau hinh) ---
$beforeCount = $entries.Count
$directionBuckets = @(
  @{ items = @($screener.buckets.buy_confirmed);  direction = "buy" },
  @{ items = @($screener.buckets.buy_watch);       direction = "buy" },
  # Bat day nguoc xu huong: khong phai khuyen nghi mua nhung van ghi so (thong ke rieng
  # overall.buyCounterTrend) de kiem chung quy tac tach nhom nay theo thoi gian.
  @{ items = @($screener.buckets.buy_counter_trend); direction = "buy" },
  @{ items = @($screener.buckets.sell_confirmed);  direction = "sell" },
  @{ items = @($screener.buckets.sell_watch);      direction = "sell" }
)
foreach ($db in $directionBuckets) {
  foreach ($item in $db.items) {
    $id = "$($item.symbol)_$($item.triggerDate)_$($item.phase)"
    if ($existingIds.ContainsKey($id)) { continue }

    # compute_screener.ps1 da loc san: buy_confirmed/buy_watch/sell_confirmed/sell_watch chi
    # chua cac tin hieu hasEdge=true (con "du dia" that su) - tin hieu het du dia da bi chuyen
    # sang buy_expired/sell_expired va khong nam trong 4 bucket duoc quet o day.
    if ($db.direction -eq "buy") {
      $badLevel = $item.stopLoss; $goodLevel = $item.target
    } else {
      $badLevel = $item.invalidation; $goodLevel = $item.downTarget
    }

    $entryDate = Get-PriceDate $item.symbol $null
    if (-not $entryDate) { $entryDate = $today }
    $sec = if ($item.sector) { $sectorInfo[$item.sector] } else { $null }

    $newEntry = [PSCustomObject]@{
      id                  = $id
      symbol              = $item.symbol
      name                = $item.name
      sector              = $item.sector
      direction           = $db.direction
      signalAtEntry       = $item.signal
      phase               = $item.phase
      triggerDate         = $item.triggerDate
      entryDate           = $entryDate
      entryPrice          = $item.lastClose
      badLevel            = $badLevel
      goodLevel           = $goodLevel
      scoreAtEntry        = $item.score
      marketRegimeAtEntry = $screener.marketRegime.status
      stageAtEntry        = $item.stage
      rsAtEntry           = $item.rs
      # Cac yeu to luc phat tin hieu - nguyen lieu de phan tich nguyen nhan dung/sai
      rawScoreAtEntry      = $item.rawScore
      volRatioAtEntry      = $item.volRatio
      supportAtEntry       = $item.support
      resistanceAtEntry    = $item.resistance
      rewardPctAtEntry     = $item.rewardPct
      riskRewardAtEntry    = $item.riskRewardRatio
      extensionPctAtEntry  = $item.extensionPct
      chaseWarningAtEntry  = [bool]$item.chaseWarning
      sessionsSinceTrigger = Get-SessionsBetween $item.symbol $item.triggerDate $entryDate
      sectorTierAtEntry    = if ($sec) { $sec.tier } else { $null }
      sectorScoreAtEntry   = if ($sec) { $sec.strengthScore } else { $null }
      sectorAvgRsAtEntry   = if ($sec) { $sec.avgRs } else { $null }
      breadthStage2Pct     = $breadthStage2Pct
      breadthStage4Pct     = $breadthStage4Pct
      vnCloseAtEntry       = $screener.marketRegime.vnClose
      vnMa50AtEntry        = $screener.marketRegime.ma50
      status              = "open"
      resolvedDate        = $null
      resolvedPrice       = $null
      actualReturnPct     = $null
      sessionsToResolve   = $null
    }
    Register-Entry $newEntry
    $entries.Add($newEntry) | Out-Null
    $existingIds[$id] = $true
  }
}
# --- 1b) Danh sach CHO "sap pha vo" (buy_early): KHONG vao lenh o gia hom nay. Ghi "pending",
# chi thanh lenh MUA that khi trong $EARLY_TRIGGER_WINDOW phien tiep theo co phien dong cua tren
# khang cu voi KL >= 1,5x TB20 (vao o gia dong cua phien do = lenh ATC); het han ma khong kich
# hoat -> "not_triggered" (khong tinh vao thong ke lai/lo). Moi ma chi 1 lenh cho tai 1 thoi diem.
$EARLY_TRIGGER_WINDOW = 10
foreach ($item in @($screener.buckets.buy_early)) {
  if (-not $item) { continue }
  $hasPending = @($entries | Where-Object { $_.symbol -eq $item.symbol -and $_.status -eq "pending" }).Count -gt 0
  if ($hasPending) { continue }
  $id = "$($item.symbol)_$($item.triggerDate)_pre_breakout"
  if ($existingIds.ContainsKey($id)) { continue }
  $sec = if ($item.sector) { $sectorInfo[$item.sector] } else { $null }
  $entries.Add([PSCustomObject]@{
    id = $id; symbol = $item.symbol; name = $item.name; sector = $item.sector; direction = "buy"
    signalAtEntry = "buy_early"; phase = "pre_breakout"; triggerDate = $item.triggerDate
    watchDate = $item.triggerDate; entryDate = $item.triggerDate; entryPrice = $null
    badLevel = $null; goodLevel = $item.target; scoreAtEntry = $null
    marketRegimeAtEntry = $screener.marketRegime.status; stageAtEntry = $item.stage; rsAtEntry = $item.rs
    supportAtEntry = $item.support; resistanceAtEntry = $item.resistance; triggerPriceAtWatch = $item.triggerPrice
    sectorTierAtEntry = if ($sec) { $sec.tier } else { $null }
    status = "pending"; resolvedDate = $null; resolvedPrice = $null; actualReturnPct = $null; sessionsToResolve = $null
  }) | Out-Null
  $existingIds[$id] = $true
}
foreach ($e in @($entries | Where-Object { $_.status -eq "pending" })) {
  $pts = Get-History $e.symbol
  $idxWatch = -1
  for ($i = 0; $i -lt $pts.Count; $i++) { if ($pts[$i].d -eq $e.watchDate) { $idxWatch = $i; break } }
  if ($idxWatch -lt 0) { continue }
  $R = [double]$e.resistanceAtEntry
  for ($k = 1; $k -le $EARLY_TRIGGER_WINDOW; $k++) {
    $j = $idxWatch + $k
    if ($j -ge $pts.Count) { break }
    $q = $pts[$j]
    $avg = 0.0; for ($t = $j - 20; $t -lt $j; $t++) { $avg += $pts[$t].v }; $avg /= 20
    if ($q.c -gt $R -and $avg -gt 0 -and $q.v -ge 1.5 * $avg) {
      Set-EntryField $e "status" "open"; Set-EntryField $e "entryDate" $q.d; Set-EntryField $e "entryPrice" $q.c
      Set-EntryField $e "badLevel" ([Math]::Round([Math]::Min($R * 0.97, $q.c * 0.95), 2))
      Set-EntryField $e "sessionsSinceTrigger" $k
      Register-Entry $e
      break
    }
    if ($k -eq $EARLY_TRIGGER_WINDOW) { Set-EntryField $e "status" "not_triggered"; Set-EntryField $e "resolvedDate" $q.d }
  }
}

$newOnes = @($entries | Select-Object -Skip $beforeCount)
Write-Log "New entries logged: $($newOnes.Count) (duplicate of an open position: $(@($newOnes | Where-Object { $_.status -eq 'duplicate' }).Count))"

# --- 2) Doi chieu (resolve) cac tin hieu dang "open" voi gia that ---
$resolvedCount = 0
foreach ($e in $entries) {
  if ($e.status -ne "open") { continue }
  $pts = Get-History $e.symbol
  $future = @($pts | Where-Object { $_.d -gt $e.entryDate } | Sort-Object d)
  $lockSessions = if ($e.direction -eq "buy") { $T_PLUS_LOCK_SESSIONS } else { 0 }
  # Vi the da bi dao chieu: chi doi chieu toi ngay xuat hien tin hieu nguoc chieu, roi dong
  # o gia luc dao chieu. Rieng MUA dao chieu ngay trong luc khoa T+2,5 (VD NVL mua 25/09,
  # 29/09 da ra tin hieu ban): nguoi mua chua ban duoc, nen doi chieu toi phien DAU TIEN ban
  # duoc va thoat o gia mo cua phien do (Resolve-Entry tinh "sai" neu da thung stop luc khoa).
  $reversalExit = $null
  if ($e.reversedOn) {
    $upTo = @($future | Where-Object { $_.d -le $e.reversedOn })
    if ($lockSessions -gt 0 -and $upTo.Count -le $lockSessions) {
      if ($future.Count -le $lockSessions) { continue }  # chua toi phien ban duoc - cho them
      $future = @($future | Select-Object -First ($lockSessions + 1))
      $exitBar = $future[$lockSessions]
      $reversalExit = [PSCustomObject]@{ status = "reversed"; resolvedDate = $exitBar.d; resolvedPrice = $exitBar.o; sessionsToResolve = $lockSessions + 1 }
    } else {
      $future = $upTo
      $reversalExit = [PSCustomObject]@{ status = "reversed"; resolvedDate = $e.reversedOn; resolvedPrice = $e.reversedPrice; sessionsToResolve = $upTo.Count }
    }
  }
  $res = if ($future.Count -gt 0) { Resolve-Entry $e.direction $e.entryPrice $e.badLevel $e.goodLevel $future $MAX_HOLD_SESSIONS $lockSessions } else { $null }
  if ($null -eq $res) { $res = $reversalExit }
  if ($null -eq $res) { continue }
  if ($res.exitRule) { Set-EntryField $e "exitRule" $res.exitRule }
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
$latestPriceCache = @{}
function Get-LatestPrice($symbol) {
  if ($latestPriceCache.ContainsKey($symbol)) { return $latestPriceCache[$symbol] }
  $pts = Get-History $symbol
  $price = if ($pts.Count -gt 0) { $pts[$pts.Count - 1].c } else { $null }
  $latestPriceCache[$symbol] = $price
  return $price
}
# VN-Index lam thuoc do so sanh (them 08/10/2026): win rate chi tren lenh DA DONG bi lech nang vi
# cat lo (~5%) gan hon target (15-40%) - lenh thua dong nhanh, lenh thang con mo. Nen tinh them
# lai/lo CA lenh dang mo theo gia moi nhat, va tru di bien dong VN-Index cung khoang thoi gian
# (alpha) de tach "tool chon dung ma" khoi "ca thi truong len/xuong".
$vnPts = @()
$dataPath = Join-Path $root "data.json"
if (Test-Path $dataPath) { $vnPts = @((Get-Content -Path $dataPath -Raw -Encoding UTF8 | ConvertFrom-Json).vnindex.points) }
function Get-VnClose($onOrBefore) {
  for ($i = $vnPts.Count - 1; $i -ge 0; $i--) { if (-not $onOrBefore -or $vnPts[$i].d -le $onOrBefore) { return $vnPts[$i].c } }
  return $null
}
# Lai/lo theo chieu tin hieu (lenh dong: gia dong lenh; lenh mo: gia moi nhat) va bien dong
# VN-Index cung chieu, cung khoang thoi gian.
function Get-MarkedReturn($e) {
  $sign = if ($e.direction -eq "buy") { 1 } else { -1 }
  if ($e.status -eq "open") {
    $px = Get-LatestPrice $e.symbol
    if ($null -eq $px -or -not $e.entryPrice) { return $null }
    $ret = (($px - $e.entryPrice) / $e.entryPrice) * 100 * $sign
    $endDate = $null
  } else {
    if ($null -eq $e.actualReturnPct) { return $null }
    $ret = [double]$e.actualReturnPct
    $endDate = $e.resolvedDate
  }
  $v0 = Get-VnClose $e.entryDate; $v1 = Get-VnClose $endDate
  $bench = if ($v0 -and $v1) { (($v1 - $v0) / $v0) * 100 * $sign } else { 0 }
  return [PSCustomObject]@{ ret = $ret; bench = $bench }
}

function Get-Stats($items) {
  $items = @($items)
  $closed = @($items | Where-Object { $_.status -ne "open" })
  $wins = @($closed | Where-Object { $_.status -eq "hit_target" })
  $losses = @($closed | Where-Object { $_.status -eq "hit_stop" })
  $expired = @($closed | Where-Object { $_.status -eq "expired_neutral" })
  $reversed = @($closed | Where-Object { $_.status -eq "reversed" })
  # Ty le thang = so lenh DONG CO LAI / tong so lenh da dong (ke ca dao chieu, het han). Truoc
  # 01/10/2026 chi tinh tren hit_target+hit_stop nen BAN hien "100%" khi 7/8 lenh la dao chieu.
  $profitable = @($closed | Where-Object { $_.actualReturnPct -gt 0 })
  $winRate = if ($closed.Count -gt 0) { [Math]::Round(($profitable.Count / $closed.Count) * 100, 1) } else { $null }
  $avgReturn = if ($closed.Count -gt 0) { [Math]::Round((($closed | Measure-Object -Property actualReturnPct -Average).Average), 2) } else { $null }
  $avgWin = if ($wins.Count -gt 0) { [Math]::Round((($wins | Measure-Object -Property actualReturnPct -Average).Average), 2) } else { $null }
  $marked = @($items | ForEach-Object { Get-MarkedReturn $_ } | Where-Object { $null -ne $_ })
  $mtmAvg = if ($marked.Count -gt 0) { [Math]::Round(($marked | Measure-Object -Property ret -Average).Average, 2) } else { $null }
  $mtmBench = if ($marked.Count -gt 0) { [Math]::Round(($marked | Measure-Object -Property bench -Average).Average, 2) } else { $null }
  $mtmProfitPct = if ($marked.Count -gt 0) { [Math]::Round((@($marked | Where-Object { $_.ret -gt 0 }).Count / $marked.Count) * 100, 1) } else { $null }
  $avgLoss = if ($losses.Count -gt 0) { [Math]::Round((($losses | Measure-Object -Property actualReturnPct -Average).Average), 2) } else { $null }
  return [PSCustomObject]@{
    openCount    = $items.Count - $closed.Count
    closedCount  = $closed.Count
    wins         = $wins.Count
    losses       = $losses.Count
    expired      = $expired.Count
    reversed     = $reversed.Count
    profitable   = $profitable.Count
    winRatePct   = $winRate
    avgReturnPct = $avgReturn
    avgWinPct    = $avgWin
    avgLossPct   = $avgLoss
    # Ca lenh dang mo tinh theo gia moi nhat (mark-to-market), so voi VN-Index cung khoang
    mtmCount         = $marked.Count
    mtmAvgReturnPct  = $mtmAvg
    mtmProfitablePct = $mtmProfitPct
    mtmBenchmarkPct  = $mtmBench
    mtmAlphaPct      = if ($null -ne $mtmAvg) { [Math]::Round($mtmAvg - $mtmBench, 2) } else { $null }
  }
}

# Tin hieu trung lap chi luu de khong ghi lai - khong tinh vao bat ky thong ke nao.
$tracked = @($entries | Where-Object { @("duplicate", "conflict", "pending", "not_triggered") -notcontains $_.status })
# Tin hieu "bat day nguoc xu huong" (buy_counter_trend - hoac buy_watch ghi so TRUOC khi co
# quy tac nay nhung thoa cung dieu kien) tach khoi thong ke MUA chinh, de overall.buy phan
# anh dung nhung gi bang Tiem nang MUA hien tai khuyen nghi.
function Test-CounterTrendEntry($e) {
  return ($e.direction -eq "buy" -and (Test-CounterTrendBuy $e.signalAtEntry $e.phase $e.stageAtEntry $e.rsAtEntry))
}
$counterTrendEntries = @($tracked | Where-Object { Test-CounterTrendEntry $_ })
$earlyEntries = @($tracked | Where-Object { $_.phase -eq "pre_breakout" })
$buyEntries = @($tracked | Where-Object { $_.direction -eq "buy" -and $_.phase -ne "pre_breakout" -and -not (Test-CounterTrendEntry $_) })
$sellEntries = @($tracked | Where-Object { $_.direction -eq "sell" })

# Xep theo mau hinh cau truc (SOS/Spring/Upthrust/SOW) - noi de sau nay xem mau hinh nao
# dang tin cay hon trong thuc te tren TTCK VN, lam co so dieu chinh trong so cham diem.
$byPhase = @()
foreach ($g in ($tracked | Group-Object -Property phase)) {
  $closed = @($g.Group | Where-Object { $_.status -ne "open" })
  if ($closed.Count -eq 0) { continue }
  $stats = Get-Stats $g.Group
  $byPhase += [PSCustomObject]@{
    phase        = $g.Name
    direction    = $g.Group[0].direction
    closedCount  = $stats.closedCount
    winRatePct   = $stats.winRatePct
    avgReturnPct = $stats.avgReturnPct
    mtmCount     = $stats.mtmCount
    mtmAlphaPct  = $stats.mtmAlphaPct
  }
}

# Ty le dung theo tung yeu to luc phat tin hieu (tier, Stage, thi truong chung, suc manh
# nganh) - de biet yeu to nao thuc su lam tang ty le dung, lam co so chinh trong so cham
# diem trong Get-LayerAdjustment thay vi doan. Chi tinh nhom da co lenh dong.
$byFactor = [ordered]@{}
foreach ($factor in @("signalAtEntry", "stageAtEntry", "marketRegimeAtEntry", "sectorTierAtEntry")) {
  $rows = @()
  foreach ($g in ($tracked | Group-Object -Property direction, $factor)) {
    $closed = @($g.Group | Where-Object { $_.status -ne "open" })
    if ($closed.Count -eq 0) { continue }
    $stats = Get-Stats $g.Group
    $rows += [PSCustomObject]@{
      value        = $g.Group[0].$factor
      direction    = $g.Group[0].direction
      closedCount  = $stats.closedCount
      winRatePct   = $stats.winRatePct
      avgReturnPct = $stats.avgReturnPct
      mtmCount     = $stats.mtmCount
      mtmAlphaPct  = $stats.mtmAlphaPct
    }
  }
  $byFactor[$factor] = @($rows)
}

$recentClosed = @($tracked | Where-Object { $_.status -ne "open" } | Sort-Object -Property resolvedDate -Descending | Select-Object -First 15)

$openPositions = @($entries | Where-Object { $_.status -eq "open" } | ForEach-Object {
  $latest = Get-LatestPrice $_.symbol
  $unrealized = if ($null -ne $latest) {
    if ($_.direction -eq "buy") { [Math]::Round((($latest - $_.entryPrice) / $_.entryPrice) * 100, 2) }
    else { [Math]::Round((($_.entryPrice - $latest) / $_.entryPrice) * 100, 2) }
  } else { $null }
  # Khoang cach (% tren gia hien tai) con lai toi muc cat lo / target, theo chieu cua tin
  # hieu: duong = chua cham, am = gia da vuot qua muc do (VD dang trong 2 phien khoa T+2,5).
  $pctToBad = $null; $pctToGood = $null
  if ($null -ne $latest -and $latest -gt 0) {
    if ($_.direction -eq "buy") {
      if ($null -ne $_.badLevel) { $pctToBad = [Math]::Round((($latest - $_.badLevel) / $latest) * 100, 2) }
      if ($null -ne $_.goodLevel) { $pctToGood = [Math]::Round((($_.goodLevel - $latest) / $latest) * 100, 2) }
    } else {
      if ($null -ne $_.badLevel) { $pctToBad = [Math]::Round((($_.badLevel - $latest) / $latest) * 100, 2) }
      if ($null -ne $_.goodLevel) { $pctToGood = [Math]::Round((($latest - $_.goodLevel) / $latest) * 100, 2) }
    }
  }
  [PSCustomObject]@{
    symbol        = $_.symbol
    name          = $_.name
    sector        = $_.sector
    direction     = $_.direction
    signalAtEntry = $_.signalAtEntry
    counterTrend  = [bool](Test-CounterTrendEntry $_)
    phase         = $_.phase
    triggerDate   = $_.triggerDate
    entryDate     = $_.entryDate
    entryPrice    = $_.entryPrice
    badLevel      = $_.badLevel
    goodLevel     = $_.goodLevel
    latestPrice   = $latest
    unrealizedPct = $unrealized
    pctToBad      = $pctToBad
    pctToGood     = $pctToGood
  }
} | Sort-Object -Property entryDate -Descending)

$trackRecord = [PSCustomObject]@{
  generatedAt     = (Get-Date).ToUniversalTime().ToString("o")
  startedTracking = "2026-09-28"
  overall         = [PSCustomObject]@{ buy = (Get-Stats $buyEntries); sell = (Get-Stats $sellEntries); buyCounterTrend = (Get-Stats $counterTrendEntries); buyEarly = (Get-Stats $earlyEntries) }
  earlyWatch      = [PSCustomObject]@{
    pending      = @($entries | Where-Object { $_.status -eq "pending" }).Count
    triggered    = $earlyEntries.Count
    notTriggered = @($entries | Where-Object { $_.status -eq "not_triggered" }).Count
  }
  byPhase         = @($byPhase)
  byFactor        = [PSCustomObject]$byFactor
  recentClosed    = $recentClosed
  openPositions   = $openPositions
}
$trJson = ConvertTo-Json -InputObject $trackRecord -Depth 6
[System.IO.File]::WriteAllText((Join-Path $root "track_record.json"), $trJson, $utf8NoBom)
Write-Log ("Wrote track_record.json (buy closed={0} sell closed={1} open={2})" -f `
  $trackRecord.overall.buy.closedCount, $trackRecord.overall.sell.closedCount, ($trackRecord.overall.buy.openCount + $trackRecord.overall.sell.openCount))
