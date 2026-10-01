# Dung chung: nap file nay bang dot-source (". path\wyckoff_engine.ps1") de dung cac ham:
#   Get-TradingRange, Get-AvgVol, Compute-WyckoffForSymbol, Get-MarketRegime,
#   Get-StageContext, Get-RelativeStrength, Get-LayerAdjustment
# Khong goi Claude / agent nao. Chi xu ly du lieu OHLCV thuan tuy.
#
# --- "4 Lop Xac Nhan" (dung rut tu Dow/Weinstein/Minervini/CANSLIM/Darvas/VSA) ---
# Lop 3 (cau truc + effort-volume) la Compute-WyckoffForSymbol o duoi, giu nguyen.
# Cac ham duoi day la 3 lop con lai: (1) che do thi truong chung, (2) giai doan
# cua chinh ma, (4) suc manh tuong doi so VN-Index - dung de dieu chinh diem/tier
# CHU KHONG tao tin hieu moi (khong co Wyckoff trigger thi van la "trung lap").

function Get-AvgVol($points, $n) {
  $cnt = [Math]::Min($n, $points.Count)
  if ($cnt -eq 0) { return 0 }
  $sum = 0.0
  for ($i = $points.Count - $cnt; $i -lt $points.Count; $i++) { $sum += $points[$i].v }
  return $sum / $cnt
}

# Tinh nhanh gia dong cua / %thay doi phien / ty le KL so TB20 cho 1 ma. Dung khi
# Compute-WyckoffForSymbol tra ve null (khong co tin hieu Wyckoff ro rang) nhung
# van can hien thi ma do trong danh sach "trung lap" de nguoi dung search/xem duoc.
function Get-BasicQuote($points) {
  $n = $points.Count
  $last = $points[$n - 1]
  $prev = if ($n -gt 1) { $points[$n - 2] } else { $last }
  $avgVol20 = Get-AvgVol $points 20
  $changePct = if ($prev.c -gt 0) { (($last.c - $prev.c) / $prev.c) * 100 } else { 0 }
  $volRatio = if ($avgVol20 -gt 0) { $last.v / $avgVol20 } else { 0 }
  return [PSCustomObject]@{
    lastClose = $last.c
    changePct = [Math]::Round($changePct, 2)
    volRatio  = [Math]::Round($volRatio, 2)
  }
}

# Tim vung tich luy/phan phoi (trading range) gan nhat, ket thuc tai hoac truoc $preEnd (index),
# dai >=15 phien, (high-low)/mid <= 0.18. Tra ve $null neu khong tim thay.
function Get-TradingRange($points, $preEnd) {
  for ($end = $preEnd; $end -ge 14; $end--) {
    $start15 = $end - 14
    if ($start15 -lt 0) { continue }
    $hi = [double]::MinValue; $lo = [double]::MaxValue
    for ($i = $start15; $i -le $end; $i++) {
      if ($points[$i].h -gt $hi) { $hi = $points[$i].h }
      if ($points[$i].l -lt $lo) { $lo = $points[$i].l }
    }
    $mid = ($hi + $lo) / 2.0
    if ($mid -le 0 -or (($hi - $lo) / $mid) -gt 0.18) { continue }

    $bestLen = 15; $bestHi = $hi; $bestLo = $lo
    $curHi = $hi; $curLo = $lo
    $maxLen = [Math]::Min(60, $end + 1)
    for ($len = 16; $len -le $maxLen; $len++) {
      $start = $end - $len + 1
      $p = $points[$start]
      if ($p.h -gt $curHi) { $curHi = $p.h }
      if ($p.l -lt $curLo) { $curLo = $p.l }
      $mid2 = ($curHi + $curLo) / 2.0
      if ($mid2 -gt 0 -and (($curHi - $curLo) / $mid2) -le 0.18) {
        $bestLen = $len; $bestHi = $curHi; $bestLo = $curLo
      } else { break }
    }

    return [PSCustomObject]@{
      start = $end - $bestLen + 1
      end   = $end
      len   = $bestLen
      high  = $bestHi
      low   = $bestLo
    }
  }
  return $null
}

# Phan loai 1 ma theo bo quy tac Wyckoff-style. $points: mang {d,o,h,l,c,v} tang dan theo ngay.
# Tra ve $null neu khong du du lieu hoac khong co tin hieu (neutral).
function Compute-WyckoffForSymbol($symbol, $name, $exchange, $points) {
  $n = $points.Count
  if ($n -lt 40) { return $null }

  $triggerLookback = 15
  $preEnd = $n - 1 - $triggerLookback
  if ($preEnd -lt 14) { return $null }

  $tr = Get-TradingRange $points $preEnd
  if ($null -eq $tr) { return $null }

  $avgVol20 = Get-AvgVol $points 20
  if ($avgVol20 -le 0) { return $null }

  $rangeHigh = $tr.high
  $rangeLow = $tr.low
  $lastIdx = $n - 1
  $last = $points[$lastIdx]

  # boi canh xu huong truoc do: so gia dong cua dau vung TR voi ~20-40 phien truoc do
  $trStartClose = $points[$tr.start].c
  $refIdx = [Math]::Max(0, $tr.start - 30)
  $refClose = $points[$refIdx].c
  $context = "sideways"
  if ($refClose -gt 0) {
    $chg = ($trStartClose - $refClose) / $refClose
    if ($chg -le -0.10) { $context = "after_decline" }
    elseif ($chg -ge 0.10) { $context = "after_advance" }
  }

  # --- quet cac phien sau vung TR (trigger window) tim Spring/SOS/Test/LPS va UT/SOW/LPSY ---
  $springIdx = $null; $springVolRatio = $null
  $sosIdx = $null; $sosVolRatio = $null
  $testIdx = $null
  $lpsIdx = $null
  $utIdx = $null; $utVolRatio = $null
  $sowIdx = $null; $sowVolRatio = $null
  $lpsyIdx = $null

  # Spring/UT phai nam trong 10 phien gan nhat; SOS/SOW phai nam trong 15 phien gan nhat.
  # (Neu chi gioi han theo "sau vung TR" thi khi TR duoc tim thay o xa qua khu, tin hieu
  # co the la tin hieu CU tu nhieu tuan/thang truoc - khong con thoi su.)
  $setupCutoff = $lastIdx - 9
  $confirmedCutoff = $lastIdx - 14

  for ($i = $tr.end + 1; $i -le $lastIdx; $i++) {
    $p = $points[$i]
    $volRatio = if ($avgVol20 -gt 0) { $p.v / $avgVol20 } else { 0 }
    $hlRange = $p.h - $p.l
    $upperHalf = if ($hlRange -gt 0) { ($p.c - $p.l) / $hlRange -ge 0.5 } else { $true }
    $lowerHalf = if ($hlRange -gt 0) { ($p.c - $p.l) / $hlRange -lt 0.5 } else { $true }

    # Spring: pha day duoi rangeLow nhung dong cua lai >= rangeLow, KL <= 1.3x TB20
    if ($null -eq $springIdx -and $i -ge $setupCutoff -and $p.l -lt $rangeLow -and $p.c -ge $rangeLow -and $volRatio -le 1.3) {
      $springIdx = $i; $springVolRatio = $volRatio
    }
    # Test: 1-10 phien sau Spring, low gan rangeLow (trong 2%), KL < 0.7x KL phien Spring, dong cua > mo cua
    if ($null -ne $springIdx -and $null -eq $testIdx -and $i -gt $springIdx -and ($i - $springIdx) -le 10) {
      $springVol = $points[$springIdx].v
      if ($p.l -le $rangeLow * 1.02 -and $p.l -ge $rangeLow * 0.98 -and $p.v -lt (0.7 * $springVol) -and $p.c -gt $p.o) {
        $testIdx = $i
      }
    }
    # SOS: dong cua > rangeHigh, KL >= 1.5x TB20, dong cua o nua tren bien do phien
    if ($null -eq $sosIdx -and $i -ge $confirmedCutoff -and $p.c -gt $rangeHigh -and $volRatio -ge 1.5 -and $upperHalf) {
      $sosIdx = $i; $sosVolRatio = $volRatio
    }
    # LPS: sau SOS, phien hoi ve giu >= 0.98x rangeHigh, KL < TB20
    if ($null -ne $sosIdx -and $null -eq $lpsIdx -and $i -gt $sosIdx) {
      if ($p.l -ge $rangeHigh * 0.98 -and $p.v -lt $avgVol20) { $lpsIdx = $i }
    }

    # Upthrust: high > rangeHigh nhung dong cua lai <= rangeHigh, KL >= 1.3x TB20
    if ($null -eq $utIdx -and $i -ge $setupCutoff -and $p.h -gt $rangeHigh -and $p.c -le $rangeHigh -and $volRatio -ge 1.3) {
      $utIdx = $i; $utVolRatio = $volRatio
    }
    # SOW: dong cua < rangeLow, KL >= 1.5x TB20, dong cua o nua duoi bien do phien
    if ($null -eq $sowIdx -and $i -ge $confirmedCutoff -and $p.c -lt $rangeLow -and $volRatio -ge 1.5 -and $lowerHalf) {
      $sowIdx = $i; $sowVolRatio = $volRatio
    }
    # LPSY: sau SOW, phien hoi yeu high <= 1.02x rangeLow, KL thap hon
    if ($null -ne $sowIdx -and $null -eq $lpsyIdx -and $i -gt $sowIdx) {
      if ($p.h -le $rangeLow * 1.02 -and $p.v -lt $avgVol20) { $lpsyIdx = $i }
    }
  }

  # --- cham diem & phan loai, uu tien theo boi canh ---
  $buyResult = $null
  if ($null -ne $sosIdx) {
    $score = 80
    if ($null -ne $lpsIdx) { $score += 10 }
    if ($sosVolRatio -ge 2.0) { $score += 5 }
    if (($lastIdx - $sosIdx) -le 5) { $score += 5 }
    $score = [Math]::Min(100, $score)
    $note = "Vượt đỉnh vùng tích lũy $([Math]::Round($rangeHigh,2)) với khối lượng gấp $([Math]::Round($sosVolRatio,1)) lần TB20 phiên - dạng Sign of Strength."
    if ($null -ne $lpsIdx) { $note += " Đã có nhịp hồi giữ được vùng kháng cự cũ (Last Point of Support)." }
    $buyResult = [PSCustomObject]@{ phase = "markup_confirmed"; signal = "buy_confirmed"; score = $score; triggerIdx = $sosIdx; note = $note }
  } elseif ($null -ne $springIdx) {
    $score = 55
    if ($null -ne $testIdx) { $score += 15 }
    if ($springVolRatio -le 0.8) { $score += 5 }
    if (($lastIdx - $springIdx) -le 3) { $score += 4 }
    $score = [Math]::Min(79, $score)
    $note = "Xuyên thủng đáy vùng tích lũy $([Math]::Round($rangeLow,2)) rồi đóng cửa lại trên hỗ trợ, khối lượng chỉ bằng $([Math]::Round($springVolRatio,2)) lần TB20 - dạng Spring."
    if ($null -ne $testIdx) { $note += " Đã có phiên Test lại với khối lượng cạn kiệt, củng cố độ tin cậy." }
    $buyResult = [PSCustomObject]@{ phase = "accumulation_setup"; signal = "buy_watch"; score = $score; triggerIdx = $springIdx; note = $note }
  } elseif ($context -eq "after_decline" -and $tr.end -ge ($lastIdx - 30)) {
    $first10 = 0.0; $last10 = 0.0
    $c1 = 0; $c2 = 0
    for ($i = $tr.start; $i -lt [Math]::Min($tr.start + 10, $tr.end + 1); $i++) { $first10 += $points[$i].v; $c1++ }
    for ($i = [Math]::Max($tr.start, $tr.end - 9); $i -le $tr.end; $i++) { $last10 += $points[$i].v; $c2++ }
    if ($c1 -gt 0) { $first10 /= $c1 }
    if ($c2 -gt 0) { $last10 /= $c2 }
    if ($first10 -gt 0 -and $last10 -le (0.8 * $first10)) {
      $note = "Sau nhịp giảm, giá đi ngang trong vùng $([Math]::Round($rangeLow,2))-$([Math]::Round($rangeHigh,2)) trên $($tr.len) phiên, khối lượng bán ra giảm dần (còn $([Math]::Round(($last10/$first10)*100))% so đầu vùng) - dấu hiệu cung cạn dần."
      $buyResult = [PSCustomObject]@{ phase = "watch_range"; signal = "buy_watch"; score = 40; triggerIdx = $tr.end; note = $note }
    }
  }

  $sellResult = $null
  if ($null -ne $sowIdx) {
    $score = 80
    if ($null -ne $lpsyIdx) { $score += 10 }
    if ($sowVolRatio -ge 2.0) { $score += 5 }
    if (($lastIdx - $sowIdx) -le 5) { $score += 5 }
    $score = [Math]::Min(100, $score)
    $note = "Thủng đáy vùng phân phối $([Math]::Round($rangeLow,2)) với khối lượng gấp $([Math]::Round($sowVolRatio,1)) lần TB20 phiên - dạng Sign of Weakness."
    if ($null -ne $lpsyIdx) { $note += " Nhịp hồi sau đó yếu, không lấy lại được vùng hỗ trợ cũ (Last Point of Supply)." }
    $sellResult = [PSCustomObject]@{ phase = "markdown_confirmed"; signal = "sell_confirmed"; score = $score; triggerIdx = $sowIdx; note = $note }
  } elseif ($null -ne $utIdx) {
    $score = 55
    if ($utVolRatio -ge 2.0) { $score += 10 }
    if (($lastIdx - $utIdx) -le 3) { $score += 4 }
    $score = [Math]::Min(79, $score)
    $note = "Vượt đỉnh vùng giao dịch $([Math]::Round($rangeHigh,2)) trong phiên nhưng đóng cửa lại dưới/bằng đỉnh cũ, khối lượng gấp $([Math]::Round($utVolRatio,1)) lần TB20 - dạng Upthrust, cảnh báo hụt lực mua."
    $sellResult = [PSCustomObject]@{ phase = "distribution_setup"; signal = "sell_watch"; score = $score; triggerIdx = $utIdx; note = $note }
  } elseif ($context -eq "after_advance" -and $tr.end -ge ($lastIdx - 30)) {
    $note = "Sau nhịp tăng, giá đi ngang trong vùng $([Math]::Round($rangeLow,2))-$([Math]::Round($rangeHigh,2)) trên $($tr.len) phiên ở vùng đỉnh - cần theo dõi dấu hiệu phân phối."
    $sellResult = [PSCustomObject]@{ phase = "watch_top"; signal = "sell_watch"; score = 40; triggerIdx = $tr.end; note = $note }
  }

  $chosen = $null
  if ($null -ne $buyResult -and $null -ne $sellResult) {
    if ($buyResult.triggerIdx -eq $sellResult.triggerIdx) {
      $buyTier = if ($buyResult.signal -eq "buy_confirmed") { 2 } else { 1 }
      $sellTier = if ($sellResult.signal -eq "sell_confirmed") { 2 } else { 1 }
      $chosen = if ($buyTier -ge $sellTier) { $buyResult } else { $sellResult }
    } else {
      $chosen = if ($buyResult.triggerIdx -gt $sellResult.triggerIdx) { $buyResult } else { $sellResult }
    }
  } elseif ($null -ne $buyResult) { $chosen = $buyResult }
  elseif ($null -ne $sellResult) { $chosen = $sellResult }

  if ($null -eq $chosen) { return $null }

  $prev = if ($lastIdx -gt 0) { $points[$lastIdx - 1] } else { $last }
  $changePct = if ($prev.c -gt 0) { (($last.c - $prev.c) / $prev.c) * 100 } else { 0 }
  $volRatioLast = if ($avgVol20 -gt 0) { $last.v / $avgVol20 } else { 0 }

  return [PSCustomObject]@{
    symbol      = $symbol
    exchange    = $exchange
    name        = $name
    phase       = $chosen.phase
    signal      = $chosen.signal
    score       = [Math]::Round($chosen.score)
    lastClose   = $last.c
    changePct   = [Math]::Round($changePct, 2)
    volRatio    = [Math]::Round($volRatioLast, 2)
    support     = [Math]::Round($rangeLow, 2)
    resistance  = [Math]::Round($rangeHigh, 2)
    triggerDate = $points[$chosen.triggerIdx].d
    triggerIdx  = $chosen.triggerIdx
    note        = $chosen.note
  }
}

# --- Lop 1: che do thi truong chung (Dow Theory + CANSLIM "M") ---
function Get-SMA($points, $n, $endIdx) {
  if ($endIdx -lt ($n - 1) -or $endIdx -ge $points.Count) { return $null }
  $sum = 0.0
  for ($i = $endIdx - $n + 1; $i -le $endIdx; $i++) { $sum += $points[$i].c }
  return $sum / $n
}

# Thuan (bullish) khi VNIndex dang tren MA50 va MA50 dang doc len; nguoc (bearish)
# khi duoi MA50 va MA50 doc xuong; con lai la trung tinh (chua ro xu huong).
function Get-MarketRegime($vnPoints) {
  $lastIdx = $vnPoints.Count - 1
  $maNow = Get-SMA $vnPoints 50 $lastIdx
  $maPrev = Get-SMA $vnPoints 50 ($lastIdx - 10)
  if ($null -eq $maNow -or $null -eq $maPrev) {
    return [PSCustomObject]@{ status = "neutral"; vnClose = $vnPoints[$lastIdx].c; ma50 = $null }
  }
  $close = $vnPoints[$lastIdx].c
  $rising = $maNow -gt $maPrev
  $status = "neutral"
  if ($close -gt $maNow -and $rising) { $status = "bullish" }
  elseif ($close -lt $maNow -and -not $rising) { $status = "bearish" }
  return [PSCustomObject]@{ status = $status; vnClose = [Math]::Round($close, 2); ma50 = [Math]::Round($maNow, 2) }
}

# --- Lop 2: giai doan cua chinh ma (Weinstein Stage Analysis + Minervini Trend Template, rut gon) ---
# stage2 = gia tren MA100 dang doc len (giai doan tang), stage4 = duoi MA100 doc xuong
# (giai doan giam). Can >=110 phien du lieu, neu khong tra "unknown".
function Get-StageContext($points) {
  $maLen = 100
  $lastIdx = $points.Count - 1
  if ($points.Count -lt ($maLen + 10)) { return "unknown" }
  $maNow = Get-SMA $points $maLen $lastIdx
  $maPrev = Get-SMA $points $maLen ($lastIdx - 10)
  if ($null -eq $maNow -or $null -eq $maPrev) { return "unknown" }
  $close = $points[$lastIdx].c
  $rising = $maNow -gt $maPrev
  if ($close -gt $maNow -and $rising) { return "stage2" }
  if ($close -lt $maNow -and -not $rising) { return "stage4" }
  return "neutral"
}

# --- Lop 4: suc manh tuong doi so VN-Index (CANSLIM "L" / IBD RS, rut gon) ---
# %thay doi gia cua ma tru %thay doi VNIndex trong cung $lookback phien gan nhat
# (khop theo vi tri cuoi day, khong khop theo ngay - ca 2 chuoi deu la phien giao
# dich HOSE nen lich gan nhu trung nhau, du chinh xac cho muc dich sang loc nay).
function Get-RelativeStrength($points, $vnPoints, $lookback) {
  $n = $points.Count; $vn = $vnPoints.Count
  if ($n -le $lookback -or $vn -le $lookback) { return $null }
  $stockBase = $points[$n - 1 - $lookback].c
  $vnBase = $vnPoints[$vn - 1 - $lookback].c
  if ($stockBase -le 0 -or $vnBase -le 0) { return $null }
  $stockChg = (($points[$n - 1].c - $stockBase) / $stockBase) * 100
  $vnChg = (($vnPoints[$vn - 1].c - $vnBase) / $vnBase) * 100
  return [Math]::Round($stockChg - $vnChg, 2)
}

# Ket hop 3 lop tren de dieu chinh diem/tier cua 1 ket qua Wyckoff da co (KHONG dung
# de tao tin hieu moi). Chi CHO PHEP HA tier (confirmed -> watch), khong bao gio
# nang tier - dung tinh than "chi phan ung theo bang chung cau truc, khong doan truoc"
# cua Wyckoff: boi canh thuan chi lam tin hieu dang tin hon, khong the thay the cau truc.
function Get-LayerAdjustment($signal, $baseScore, $marketStatus, $stage, $rs) {
  $isBuy = $signal.StartsWith("buy")

  $marketDelta = 0; $marketNote = $null
  if ($marketStatus -eq "bullish") {
    if ($isBuy) { $marketDelta = 10; $marketNote = "thị trường chung thuận" }
    else { $marketDelta = -15; $marketNote = "thị trường chung ngược chiều" }
  } elseif ($marketStatus -eq "bearish") {
    if ($isBuy) { $marketDelta = -15; $marketNote = "thị trường chung ngược chiều" }
    else { $marketDelta = 10; $marketNote = "thị trường chung thuận" }
  }

  $stageDelta = 0; $stageNote = $null
  if ($stage -eq "stage2") {
    if ($isBuy) { $stageDelta = 10; $stageNote = "đúng giai đoạn Stage 2 (tăng)" }
    else { $stageDelta = -10; $stageNote = "giai đoạn còn Stage 2, chưa xác nhận suy yếu" }
  } elseif ($stage -eq "stage4") {
    if ($isBuy) { $stageDelta = -15; $stageNote = "giai đoạn còn Stage 4, chưa xác nhận phục hồi" }
    else { $stageDelta = 10; $stageNote = "đúng giai đoạn Stage 4 (giảm)" }
  }

  $rsDelta = 0; $rsNote = $null
  if ($null -ne $rs) {
    if ($rs -ge 5) {
      if ($isBuy) { $rsDelta = 8; $rsNote = "RS +$rs% so VNIndex" }
      else { $rsDelta = -8; $rsNote = "RS +$rs% so VNIndex - mạnh hơn thị trường, cần thận trọng" }
    } elseif ($rs -le -5) {
      if ($isBuy) { $rsDelta = -8; $rsNote = "RS $rs% so VNIndex - yếu hơn thị trường" }
      else { $rsDelta = 8; $rsNote = "RS $rs% so VNIndex" }
    }
  }

  $totalDelta = $marketDelta + $stageDelta + $rsDelta
  $adjustedScore = [Math]::Max(0, [Math]::Min(100, $baseScore + $totalDelta))

  $finalSignal = $signal
  if (($signal -eq "buy_confirmed" -or $signal -eq "sell_confirmed") -and $adjustedScore -lt 70) {
    $finalSignal = $signal -replace "_confirmed", "_watch"
  }

  $parts = @($marketNote, $stageNote, $rsNote) | Where-Object { $_ }
  $layerText = $null
  if ($parts.Count -gt 0) {
    $sign = if ($totalDelta -ge 0) { "+" } else { "" }
    $layerText = "Bối cảnh 4 lớp: " + ($parts -join "; ") + " ($sign$totalDelta đ)."
    if ($finalSignal -ne $signal) { $layerText += " Hạ xuống mức theo dõi vì bối cảnh chưa đồng thuận." }
  }

  return [PSCustomObject]@{
    score     = [Math]::Round($adjustedScore)
    rawScore  = [Math]::Round($baseScore)
    signal    = $finalSignal
    layerText = $layerText
  }
}

# --- Tin hieu MUA "bat day nguoc xu huong": Spring / vung tich luy (chua co SOS xac nhan)
# o ma dang Stage 4 (duoi MA100 doc xuong). Cau truc Wyckoff co the van dung, nhung doi
# chieu thuc te cho thay nhom nay lo nhieu hon han nen khong dua vao bang MUA. Dung chung cho
# compute_screener.ps1 (tach bucket) va track_record.ps1 (xep loai lai tin hieu da ghi so
# truoc khi co quy tac nay) de 2 noi luon cung 1 dinh nghia.
# 01/10/2026: bo dieu kien RS <= -5 (truoc chi tach Stage 4 + RS yeu). Backtest 2,5 nam top-120
# (03/2024-09/2026): Spring Stage 4 TB -0,38%/lenh (406 lenh) vs Stage 2 +0,66%; doi chieu that
# 25/09-01/10: 29 lenh mua Stage 4 chi 6 ma tang. $rs giu lai trong chu ky ham cho tuong thich.
function Test-CounterTrendBuy($signal, $phase, $stage, $rs) {
  if ($signal -ne "buy_watch" -and $signal -ne "buy_counter_trend") { return $false }
  if ($phase -ne "accumulation_setup" -and $phase -ne "watch_range") { return $false }
  return ($stage -eq "stage4")
}

# --- Danh sach CHO "sap pha vo" (nhan dien SOM, truoc khi gia vuot khang cu) ---
# User 01/10/2026: "toi ki vong tool nhan biet som co phieu se tang chu khong phai tang roi moi
# ra tin hieu". Compute-WyckoffForSymbol chi tim vung tich luy ket thuc >=15 phien truoc nen
# ma DANG tich luy sat khang cu khong bao gio hien len cho toi khi da pha vo (va SOS duoc phep
# cu toi 14 phien). Ham nay tim nen gia dang dien ra TOI HOM NAY: >=20 phien, gia cach dinh nen
# <=5%, 10 phien gan nhat sit chat (bien do <=8%) va KL can (TB10 <=85% TB ca nen).
# 🚨 Backtest 2,5 nam: MUA NGAY khi vao danh sach KHONG co loi the (~ngang mua ngau nhien) - loi
# the nam o phien PHA VO: mua ATC khi phien do dong cua tren khang cu voi KL >=1,5x TB20 la
# +0,46%/lenh (121 lenh voi dung bo loc o duoi; +0,63% neu chi can "cach dinh nen <=5%", 587 lenh) vs SOS mua o gia mo cua phien sau (cach trang dang lam truoc day) -0,06%.
# Vi vay day la DANH SACH CHO kem dieu kien kich hoat, KHONG phai khuyen nghi mua ngay.
function Get-PreBreakout($points) {
  $n = $points.Count
  if ($n -lt 60) { return $null }
  $lastIdx = $n - 1
  $tr = Get-TradingRange $points $lastIdx
  if ($null -eq $tr -or $tr.end -lt ($lastIdx - 1) -or $tr.len -lt 20) { return $null }

  $last = $points[$lastIdx]
  $hi = $tr.high; $lo = $tr.low
  $distPct = (($hi - $last.c) / $hi) * 100
  if ($distPct -gt 5) { return $null }

  $h10 = [double]::MinValue; $l10 = [double]::MaxValue; $v10 = 0.0
  for ($i = $lastIdx - 9; $i -le $lastIdx; $i++) {
    if ($points[$i].h -gt $h10) { $h10 = $points[$i].h }
    if ($points[$i].l -lt $l10) { $l10 = $points[$i].l }
    $v10 += $points[$i].v
  }
  $v10 /= 10
  $vBase = 0.0
  for ($i = $tr.start; $i -le $tr.end; $i++) { $vBase += $points[$i].v }
  $vBase /= $tr.len
  $tightPct = (($h10 - $l10) / $last.c) * 100
  if ($tightPct -gt 8 -or $vBase -le 0) { return $null }
  # Bien do 10 phien < 2% = gia bi "neo" (VD NAF 01/10/2026 dung yen 47,8-48,1 suot nhieu tuan -
  # dau hieu chao mua cong khai/sap huy niem yet), khong phai nen tich luy that.
  if ($tightPct -lt 2) { return $null }
  $dry = $v10 / $vBase
  if ($dry -gt 0.85) { return $null }

  $avgVol20 = Get-AvgVol $points 20
  $prev = $points[$lastIdx - 1]
  $changePct = if ($prev.c -gt 0) { (($last.c - $prev.c) / $prev.c) * 100 } else { 0 }
  # Muc gia dung khop dung cach backtest: kich hoat = dong cua tren khang cu; cat lo = min(97%
  # khang cu, 95% gia vao) - gia vao chua biet truoc nen tinh theo khang cu (gia vao ~ khang cu).
  $trigger = [Math]::Round($hi * 1.005, 2)
  $stopLoss = [Math]::Round([Math]::Min($hi * 0.97, $trigger * 0.95), 2)
  $target = [Math]::Round($hi + ($hi - $lo), 2)
  $rewardPct = [Math]::Round((($target - $trigger) / $trigger) * 100, 1)
  $rr = [Math]::Round(($target - $trigger) / ($trigger - $stopLoss), 1)
  $note = "Đang tích lũy $($tr.len) phiên trong vùng $([Math]::Round($lo,2))-$([Math]::Round($hi,2)), giá cách đỉnh nền $([Math]::Round($distPct,1))%, 10 phiên gần nhất siết chặt (biên độ $([Math]::Round($tightPct,1))%), khối lượng cạn còn $([Math]::Round($dry*100))% so với cả nền. CHƯA MUA: chỉ mua khi có phiên đóng cửa trên $([Math]::Round($hi,2)) với khối lượng ≥1,5 lần TB20 (đặt lệnh ATC khi thấy giá vượt $trigger kèm khối lượng lớn trong phiên); nếu vượt rồi tụt lại dưới đỉnh nền lúc đóng cửa thì bỏ qua."

  return [PSCustomObject]@{
    symbol       = $null
    phase        = "pre_breakout"
    signal       = "buy_early"
    score        = $null
    lastClose    = $last.c
    changePct    = [Math]::Round($changePct, 2)
    volRatio     = if ($avgVol20 -gt 0) { [Math]::Round($last.v / $avgVol20, 2) } else { 0 }
    support      = [Math]::Round($lo, 2)
    resistance   = [Math]::Round($hi, 2)
    triggerDate  = $last.d
    triggerIdx   = $lastIdx
    triggerPrice = $trigger
    distPct      = [Math]::Round($distPct, 1)
    tightPct     = [Math]::Round($tightPct, 1)
    volDryPct    = [Math]::Round($dry * 100)
    baseLen      = $tr.len
    stopLoss     = $stopLoss
    target       = $target
    rewardPct    = $rewardPct
    riskRewardRatio = $rr
    note         = $note
  }
}

# --- Canh bao "mua duoi" rieng cho dac thu T+2,5 cua thi truong VN: mua xong phai
# doi ~2-3 phien lo moi ve tai khoan de ban duoc, nen neu vao lenh khi gia da chay
# qua xa diem pha (resistance) thi luc gia dao chieu trong luc cho ve la KHONG THE
# cat lo kip. Chi ap dung cho tin hieu MUA (ban hang dang cam thi ban duoc ngay,
# khong bi khoa T+2,5). Lay tinh than "dung mua duoi qua xa pivot" cua Minervini/O'Neil,
# nhung ly do dua ra la rui ro thanh khoan/thanh toan cua VN, khong phai "tin hieu gia".
# Day la truc rui ro THOI DIEM VAO LENH, tach biet voi truc "tin hieu that hay khong"
# cua Get-LayerAdjustment - nen KHONG dung diem/tier, chi tra ve canh bao rieng.
function Get-ExtensionRisk($signal, $lastClose, $resistance, $sessionsSinceTrigger) {
  if (-not $signal.StartsWith("buy")) { return $null }
  if ($null -eq $resistance -or $resistance -le 0) { return $null }

  $extensionPct = (($lastClose - $resistance) / $resistance) * 100
  $extended = ($extensionPct -ge 8) -or ($sessionsSinceTrigger -ge 6 -and $extensionPct -ge 4)
  if (-not $extended) { return $null }

  $pctTxt = [Math]::Round($extensionPct, 1)
  $sign = if ($pctTxt -ge 0) { "+" } else { "" }
  $text = "Đã chạy $sign$pctTxt% / $sessionsSinceTrigger phiên kể từ điểm phá $([Math]::Round($resistance,2)) - mua đuổi lúc này rủi ro cao vì T+2,5 (mua xong ~2-3 phiên mới bán được lô này), nếu đảo chiều sẽ không kịp cắt lỗ."

  return [PSCustomObject]@{
    extensionPct         = $pctTxt
    sessionsSinceTrigger = $sessionsSinceTrigger
    text                 = $text
  }
}

# --- Diem stop-loss & target CU THE cho tin hieu MUA (khong noi chung chung "vung ho
# tro/khang cu" - phai ra duoc 1 con so). Chi tinh tu chinh vung tich luy da phat hien
# ra tin hieu, khong dung %co dinh:
# - stopLoss: buy_confirmed (da SOS) dat duoi vung khang cu cu - luc nay da thanh ho
#   tro moi, mat la gay that bai breakout; buy_watch (moi Spring, chua SOS) dat duoi
#   day vung tich luy (support) - vi luan diem Spring dua tren viec giu duoc muc nay.
#   Tru them 3% de tranh bi quet nhieu 1 phien (bien do gia HOSE toi da +-7%/phien).
# - target: chieu cao vung tich luy (resistance-support) chieu tu diem pha len - ky
#   thuat "do hop" pho bien (Darvas box / muc tieu Wyckoff rut gon).
function Get-TradeLevels($signal, $phase, $lastClose, $support, $resistance) {
  if (-not $signal.StartsWith("buy")) { return $null }
  if ($null -eq $support -or $null -eq $resistance -or $resistance -le $support) { return $null }

  # Nguong lai toi thieu: mua ma tiem nang lai duoi muc nay thi sau phi giao dich VN
  # (phi moi gioi 2 chieu + thue ban 0.1%, thuc te ~0.5-1% round-trip) gan nhu khong con
  # lai - user yeu cau CHI hien tin hieu mua khi tiem nang lai >=5%.
  $MIN_REWARD_PCT = 5.0

  $rangeHeight = $resistance - $support
  $stopBase = if ($phase -eq "markup_confirmed") { $resistance } else { $support }
  # San 5% duoi gia hien tai: neu stopBase*0.97 nam qua sat gia (VD Spring vua dong cua sat
  # ngay tren support), stop qua gan se bi nhieu 1 phien binh thuong (+-1-2%) quet ra ngay,
  # va lam RR ao len hang chuc lan. Lay muc THAP HON (rong hon) giua 2 cach tinh.
  $stopLoss = [Math]::Round([Math]::Min($stopBase * 0.97, $lastClose * 0.95), 2)
  $target = [Math]::Round($resistance + $rangeHeight, 2)

  $risk = $lastClose - $stopLoss
  $reward = $target - $lastClose
  $rewardPct = [Math]::Round(($reward / $lastClose) * 100, 1)

  # 2 ly do khien 1 tin hieu MUA that (SOS/Spring that su xay ra) khong con dang mua LUC NAY:
  # (1) gia da lui ve duoi muc stop ly thuyet (breakout dang that bai), hoac (2) gia da chay
  # qua xa - target do luong (chieu cao vung tich luy chieu tu diem pha) khong con du 5% nua,
  # co khi con THAP HON ca gia hien tai (da vuot target truoc khi co tin hieu). Ca 2 truong
  # hop deu tra ve hasEdge=false thay vi vao lenh voi ty le lai/rui ro te.
  if ($risk -le 0 -or $rewardPct -lt $MIN_REWARD_PCT) {
    $reason =
      if ($risk -le 0) { "giá đã lùi về dưới vùng phá $([Math]::Round($resistance,2)) - tín hiệu breakout đang yếu đi" }
      elseif ($rewardPct -le 0) { "giá đã vượt qua target đo lường $target - hết dư địa tăng theo cách tính này" }
      else { "target chỉ còn cách giá hiện tại +$rewardPct% (dưới ngưỡng lãi tối thiểu $([int]$MIN_REWARD_PCT)%), trừ phí giao dịch gần như không còn lãi" }
    return [PSCustomObject]@{
      hasEdge   = $false
      stopLoss  = $stopLoss
      target    = $target
      rewardPct = $rewardPct
      reason    = $reason
    }
  }

  $rr = [Math]::Round($reward / $risk, 1)
  return [PSCustomObject]@{
    hasEdge         = $true
    stopLoss        = $stopLoss
    target          = $target
    rewardPct       = $rewardPct
    riskRewardRatio = $rr
  }
}

# --- Doi xung Get-TradeLevels o tren nhung cho tin hieu BAN (sell_confirmed/sell_watch).
# Dung chinh support/resistance da co san tren moi ket qua Wyckoff (ca 2 chieu deu tra ve):
# - invalidation: muc GIA neu hoi phuc lai qua day thi coi nhu luan diem BAN sai (gia da
#   vuot lai vung khang cu/ho tro cu). Doi xung voi stopLoss ben MUA: sell_confirmed (da SOW,
#   tham chi thung ho tro) lay lai support cu lam moc, sell_watch (moi Upthrust, con quanh
#   quan trong vung) lay resistance lam moc. Nhan 1.03 (rong hon 3% tranh nhieu 1 phien) va
#   lay MAX voi 1.05x gia hien tai (doi xung voi MIN ben stopLoss MUA).
# - downTarget: chieu cao vung tich luy/phan phoi chieu XUONG tu day vung (doi xung voi
#   target ben MUA chieu LEN tu dinh vung).
#
# 🚨 hasEdge (them 28/09 sau khi phat hien bug PNJ that): Get-TradingRange KHONG gioi han tim
# vung tich luy xa toi dau ve qua khu - voi ma giam sau lien tuc (VD PNJ rot ~75->~30 trong 6
# thang) no co the roi vao 1 vung tu vai thang truoc, hoan toan khong con lien quan gia hien
# tai. Dung 2 dieu kien doi xung voi Get-TradeLevels (risk<=0, reward<=0) de bat truong hop
# nay: neu gia da HOI PHUC vuot invalidation (risk<=0) hoac da GIAM QUA ca downTarget roi
# (reward<=0, luan diem BAN da "het du dia" - chinh la truong hop PNJ, downTarget tinh tu 1
# vung qua cu cao hon ca gia hien tai) thi tra ve hasEdge=false thay vi de nguyen 1 muc gia
# vo nghia duoc dung lam "tin hieu that". Khong dat MIN_REWARD_PCT nhu ben MUA vi ban hang
# dang cam khong co chi phi "mo lenh" can bu lai bang % loi nhuan toi thieu.
function Get-SellLevels($signal, $phase, $lastClose, $support, $resistance) {
  if (-not $signal.StartsWith("sell")) { return $null }
  if ($null -eq $support -or $null -eq $resistance -or $resistance -le $support) { return $null }
  $rangeHeight = $resistance - $support
  $invalidBase = if ($phase -eq "markdown_confirmed") { $support } else { $resistance }
  $invalidation = [Math]::Round([Math]::Max($invalidBase * 1.03, $lastClose * 1.05), 2)
  $downTarget = [Math]::Round($support - $rangeHeight, 2)
  if ($downTarget -le 0) { return $null }

  $risk = $invalidation - $lastClose
  $reward = $lastClose - $downTarget
  $rewardPct = [Math]::Round(($reward / $lastClose) * 100, 1)

  if ($risk -le 0 -or $rewardPct -le 0) {
    $reason =
      if ($risk -le 0) { "giá đã hồi phục vượt mốc đảo chiều $([Math]::Round($invalidation,2)) - tín hiệu bán đang yếu đi" }
      else { "giá đã giảm qua target đo lường $downTarget - vùng tích lũy dùng để tính đã quá cũ/không còn liên quan giá hiện tại" }
    return [PSCustomObject]@{ hasEdge = $false; invalidation = $invalidation; downTarget = $downTarget; rewardPct = $rewardPct; reason = $reason }
  }

  return [PSCustomObject]@{ hasEdge = $true; invalidation = $invalidation; downTarget = $downTarget; rewardPct = $rewardPct }
}
