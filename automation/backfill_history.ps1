# Mot lan: doc automation/cache/symbols.json, lay ~180 ngay OHLCV cho tung ma tu VNDirect,
# ghi vao automation/cache/history/<SYMBOL>.json. Khong goi Claude / agent nao.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$cacheDir = Join-Path $root "automation\cache"
$histDir = Join-Path $cacheDir "history"
New-Item -ItemType Directory -Force -Path $histDir | Out-Null
$logDir = Join-Path $root "automation\logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir "backfill_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log($msg) {
  $line = "[$(Get-Date -Format 'HH:mm:ss')] $msg"
  Write-Output $line
  try { Add-Content -Path $logFile -Value $line -ErrorAction Stop } catch { }
}

$symbolsPath = Join-Path $cacheDir "symbols.json"
$symbols = Get-Content -Path $symbolsPath -Raw | ConvertFrom-Json
Write-Log "Loaded $($symbols.Count) symbols."

$headers = @{ "User-Agent" = "Mozilla/5.0" }
$to = [int][double]::Parse((Get-Date -UFormat %s))
$fromDate = (Get-Date).AddDays(-190)
$from = [int][double]::Parse((Get-Date -Date $fromDate -UFormat %s))
$utf8NoBom = New-Object System.Text.UTF8Encoding $false

$ok = 0; $empty = 0; $fail = 0; $idx = 0; $skipped = 0
foreach ($s in $symbols) {
  $idx++
  $outPath = Join-Path $histDir "$($s.symbol).json"
  if (Test-Path $outPath) { $skipped++; continue }
  $url = "https://dchart-api.vndirect.com.vn/dchart/history?resolution=D&symbol=$($s.symbol)&from=$from&to=$to"

  $resp = $null
  try {
    $resp = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 20
  } catch {
    Start-Sleep -Milliseconds 400
    try { $resp = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 20 } catch { $resp = $null }
  }

  if ($null -eq $resp -or $resp.s -ne "ok" -or -not $resp.t -or @($resp.t).Count -eq 0) {
    $empty++
    if ($idx % 100 -eq 0) { Write-Log "Progress $idx/$($symbols.Count) (ok=$ok empty=$empty fail=$fail)" }
    Start-Sleep -Milliseconds 120
    continue
  }

  $pts = New-Object System.Collections.Generic.List[object]
  for ($i = 0; $i -lt $resp.t.Count; $i++) {
    $d = [DateTimeOffset]::FromUnixTimeSeconds($resp.t[$i]).UtcDateTime.ToString("yyyy-MM-dd")
    $pts.Add([PSCustomObject]@{
      d = $d
      o = [math]::Round([double]$resp.o[$i], 2)
      h = [math]::Round([double]$resp.h[$i], 2)
      l = [math]::Round([double]$resp.l[$i], 2)
      c = [math]::Round([double]$resp.c[$i], 2)
      v = [long]$resp.v[$i]
    })
  }

  $doc = [PSCustomObject]@{
    symbol   = $s.symbol
    name     = $s.name
    exchange = $s.exchange
    points   = $pts
  }
  $json = $doc | ConvertTo-Json -Depth 4 -Compress
  [System.IO.File]::WriteAllText($outPath, $json, $utf8NoBom)
  $ok++
  if ($idx % 100 -eq 0) { Write-Log "Progress $idx/$($symbols.Count) (ok=$ok empty=$empty fail=$fail)" }
  Start-Sleep -Milliseconds 120
}

Write-Log "DONE. ok=$ok empty=$empty total=$($symbols.Count)"
