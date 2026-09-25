# Dung chung: nap file nay bang dot-source (". path\wyckoff_engine.ps1") de dung cac ham:
#   Get-TradingRange, Get-AvgVol, Compute-WyckoffForSymbol
# Khong goi Claude / agent nao. Chi xu ly du lieu OHLCV thuan tuy.

function Get-AvgVol($points, $n) {
  $cnt = [Math]::Min($n, $points.Count)
  if ($cnt -eq 0) { return 0 }
  $sum = 0.0
  for ($i = $points.Count - $cnt; $i -lt $points.Count; $i++) { $sum += $points[$i].v }
  return $sum / $cnt
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
    note        = $chosen.note
  }
}
