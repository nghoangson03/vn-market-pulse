# Hang ngay: lam moi 10 phien gan nhat cho tung ma da cache, tinh lai diem Wyckoff-style,
# ghi screener.json + screener_charts.json, commit + push. Chi PowerShell thuan, khong agent.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$histDir = Join-Path $root "automation\cache\history"
$logDir = Join-Path $root "automation\logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir "daily_screener_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log($msg) {
  $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg"
  Write-Output $line
  try { Add-Content -Path $logFile -Value $line -ErrorAction Stop } catch { }
}

try {
  $topNPath = Join-Path $root "automation\cache\topN_symbols.json"
  if (-not (Test-Path $topNPath)) {
    throw "Top-N symbol list not found ($topNPath). Run compute_screener.ps1 once first (it picks the top-N liquid symbols and saves this file)."
  }
  $topList = Get-Content -Path $topNPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $files = $topList | ForEach-Object {
    $p = Join-Path $histDir "$_.json"
    if (Test-Path $p) { Get-Item $p }
  } | Where-Object { $_ -ne $null }
  Write-Log "Refreshing $($files.Count) top-N cached symbols (out of $($topList.Count) listed)..."

  $headers = @{ "User-Agent" = "Mozilla/5.0" }
  $to = [int][double]::Parse((Get-Date -UFormat %s))
  $fromDate = (Get-Date).AddDays(-10)
  $from = [int][double]::Parse((Get-Date -Date $fromDate -UFormat %s))
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false

  $refreshed = 0; $failed = 0; $idx = 0
  foreach ($f in $files) {
    $idx++
    $doc = Get-Content -Path $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $sym = $doc.symbol
    $url = "https://dchart-api.vndirect.com.vn/dchart/history?resolution=D&symbol=$sym&from=$from&to=$to"

    $resp = $null
    try {
      $resp = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 20
    } catch {
      Start-Sleep -Milliseconds 300
      try { $resp = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 20 } catch { $resp = $null }
    }

    if ($null -eq $resp -or $resp.s -ne "ok" -or -not $resp.t -or @($resp.t).Count -eq 0) {
      $failed++
      Start-Sleep -Milliseconds 100
      continue
    }

    $existing = @{}
    foreach ($p in $doc.points) { $existing[$p.d] = $p }
    for ($i = 0; $i -lt $resp.t.Count; $i++) {
      $d = [DateTimeOffset]::FromUnixTimeSeconds($resp.t[$i]).UtcDateTime.ToString("yyyy-MM-dd")
      $existing[$d] = [PSCustomObject]@{
        d = $d
        o = [math]::Round([double]$resp.o[$i], 2)
        h = [math]::Round([double]$resp.h[$i], 2)
        l = [math]::Round([double]$resp.l[$i], 2)
        c = [math]::Round([double]$resp.c[$i], 2)
        v = [long]$resp.v[$i]
      }
    }
    $doc.points = @($existing.Values | Sort-Object d)
    $json = $doc | ConvertTo-Json -Depth 4 -Compress
    [System.IO.File]::WriteAllText($f.FullName, $json, $utf8NoBom)
    $refreshed++
    if ($idx % 150 -eq 0) { Write-Log "Progress $idx/$($files.Count)" }
    Start-Sleep -Milliseconds 100
  }
  Write-Log "Refresh done. refreshed=$refreshed failed=$failed"

  Write-Log "Recomputing screener..."
  & (Join-Path $PSScriptRoot "compute_screener.ps1")

  Set-Location $root
  git add screener.json screener_charts.json

  $prevEAP = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $dateTag = (Get-Date).ToString("yyyy-MM-dd")
  $commitMsg = "Update Wyckoff screener data ($dateTag)"
  $commitOutput = (git commit -m $commitMsg 2>&1 | Out-String).Trim()
  $commitExit = $LASTEXITCODE
  Write-Log "git commit (exit $commitExit): $commitOutput"

  if ($commitExit -eq 0) {
    $pushOutput = (git push 2>&1 | Out-String).Trim()
    $pushExit = $LASTEXITCODE
    Write-Log "git push (exit $pushExit): $pushOutput"
    $ErrorActionPreference = $prevEAP
    if ($pushExit -ne 0) { throw "git push failed: $pushOutput" }
  } else {
    $ErrorActionPreference = $prevEAP
    Write-Log "Nothing to commit, skip push."
  }

  Write-Log "DONE."
}
catch {
  Write-Log "ERROR: $($_.Exception.Message)"
  throw
}
finally {
  Get-ChildItem $logDir -Filter "*.log" -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-60) } |
    Remove-Item -Force -ErrorAction SilentlyContinue
}

exit 0
