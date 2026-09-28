# Dung chung cho track_record.ps1: doi chieu cac tin hieu MUA/BAN da dua ra voi gia THAT
# lay tu cache lich su, de biet tin hieu "dung" (cham target/tranh duoc lo), "sai" (dinh
# stop/mat gia tri), hay chua ro (con mo/het han theo doi ma khong cham muc nao). Thuan
# xu ly so lieu, khong goi agent/LLM nao. (Get-SellLevels - tinh invalidation/downTarget
# cho chieu BAN - nay o wyckoff_engine.ps1 canh Get-TradeLevels, vi compute_screener.ps1
# cung dung no de dua tin hieu ban da "het du dia" vao bucket sell_expired.)

# Doi chieu 1 tin hieu dang "open" voi chuoi gia THAT sau ngay vao so ($futurePoints: mang
# {d,o,h,l,c,v} da loc d > entryDate, sap tang dan). $badLevel/$goodLevel la 2 muc gia doi
# xung theo chieu (MUA: badLevel=stopLoss, goodLevel=target; BAN: badLevel=invalidation,
# goodLevel=downTarget - gia GIAM toi day moi la "dung" cho tin hieu ban). Neu 1 phien cham
# ca 2 muc (bien do rong), uu tien kich ban XAU (than trong, khong gia dinh thoat kip o gia
# tot truoc). Neu qua $maxHoldSessions phien ma khong cham muc nao thi tra ve "het han" tai
# gia dong cua phien do. Tra ve $null neu van con mo (chua cham muc nao, chua het han).
#
# $lockSessions: so phien DAU TIEN sau ngay vao so ma KHONG duoc tinh la "cham" du gia co
# xuyen qua muc nao - dac thu T+2,5 cua chung khoan VN: mua xong phai doi ~2-3 phien lo moi
# ve tai khoan de ban duoc, nen neu gia cham target/stop ngay phien dau thi nguoi mua VAN
# CHUA THE BAN duoc gia do (xem cung ly do o Get-ExtensionRisk trong wyckoff_engine.ps1).
# Chi ap dung cho MUA (0 cho BAN - ban hang dang cam thi ban duoc ngay). Cac phien trong
# thoi gian khoa VAN duoc tinh vao dong ho $maxHoldSessions, chi khong duoc dung de "cham"
# muc nao ca.
function Resolve-Entry($direction, $entryPrice, $badLevel, $goodLevel, $futurePoints, $maxHoldSessions, $lockSessions) {
  for ($i = 0; $i -lt $futurePoints.Count; $i++) {
    $p = $futurePoints[$i]
    if ($i -ge $lockSessions) {
      $hitBad  = if ($direction -eq "buy") { $p.l -le $badLevel }  else { $p.h -ge $badLevel }
      $hitGood = if ($direction -eq "buy") { $p.h -ge $goodLevel } else { $p.l -le $goodLevel }

      if ($hitBad) {
        return [PSCustomObject]@{ status = "hit_stop"; resolvedDate = $p.d; resolvedPrice = $badLevel; sessionsToResolve = $i + 1 }
      }
      if ($hitGood) {
        return [PSCustomObject]@{ status = "hit_target"; resolvedDate = $p.d; resolvedPrice = $goodLevel; sessionsToResolve = $i + 1 }
      }
    }
    if (($i + 1) -ge $maxHoldSessions) {
      return [PSCustomObject]@{ status = "expired_neutral"; resolvedDate = $p.d; resolvedPrice = $p.c; sessionsToResolve = $i + 1 }
    }
  }
  return $null
}
