# Lay du lieu VN-Index & HNX-Index moi nhat tu VNDirect, cap nhat data.json, commit + push len GitHub.
# Chi dung PowerShell thuan, khong goi Claude Code / bat ky agent nao.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path $PSScriptRoot "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logFile = Join-Path $logDir "update_$stamp.log"

function Write-Log($msg) {
  $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg"
  Write-Output $line
  Add-Content -Path $logFile -Value $line
}

try {
  $dataPath = Join-Path $root "data.json"
  $data = Get-Content -Path $dataPath -Raw | ConvertFrom-Json

  $to = [int][double]::Parse((Get-Date -UFormat %s))
  $fromDate = (Get-Date).AddDays(-10)
  $from = [int][double]::Parse((Get-Date -Date $fromDate -UFormat %s))
  $nowIso = (Get-Date).ToUniversalTime().ToString("o")

  $symbolMap = @{ "VNINDEX" = "vnindex"; "HNX" = "hnx" }
  $totalAdded = 0
  $latestDate = $null

  foreach ($sym in $symbolMap.Keys) {
    $key = $symbolMap[$sym]
    $url = "https://dchart-api.vndirect.com.vn/dchart/history?resolution=D&symbol=$sym&from=$from&to=$to"
    Write-Log "Fetching $sym from VNDirect..."
    $resp = Invoke-RestMethod -Uri $url -Headers @{ "User-Agent" = "Mozilla/5.0" } -TimeoutSec 30

    if ($resp.s -ne "ok" -or -not $resp.t -or $resp.t.Count -eq 0) {
      Write-Log "WARNING: no data returned for $sym (status=$($resp.s)), skipping."
      continue
    }

    # existing points -> map keyed by date
    $existing = @{}
    foreach ($p in $data.$key.points) { $existing[$p.d] = $p }

    $newCount = 0
    for ($i = 0; $i -lt $resp.t.Count; $i++) {
      $d = [DateTimeOffset]::FromUnixTimeSeconds($resp.t[$i]).UtcDateTime.ToString("yyyy-MM-dd")
      if (-not $existing.ContainsKey($d)) { $newCount++ }
      $existing[$d] = [PSCustomObject]@{
        d = $d
        o = [math]::Round([double]$resp.o[$i], 2)
        h = [math]::Round([double]$resp.h[$i], 2)
        l = [math]::Round([double]$resp.l[$i], 2)
        c = [math]::Round([double]$resp.c[$i], 2)
        v = [long]$resp.v[$i]
      }
      if (-not $latestDate -or $d -gt $latestDate) { $latestDate = $d }
    }

    $mergedPoints = $existing.Values | Sort-Object d
    $data.$key.points = @($mergedPoints)
    $data.$key.updatedAt = $nowIso
    $totalAdded += $newCount
    Write-Log "$sym : $newCount session(s) added/updated, total $($mergedPoints.Count) points."
  }

  ($data | ConvertTo-Json -Depth 6 -Compress) | Out-File -FilePath $dataPath -Encoding utf8 -NoNewline

  Set-Location $root
  git add data.json
  $commitMsg = "Update daily VN-Index/HNX-Index data ($latestDate)"
  $commitOutput = git commit -m $commitMsg 2>&1
  Write-Log "git commit: $commitOutput"

  if ($LASTEXITCODE -eq 0) {
    $pushOutput = git push 2>&1
    Write-Log "git push: $pushOutput"
  } else {
    Write-Log "Nothing to commit, skip push."
  }

  Write-Log "DONE. Total sessions touched: $totalAdded. Latest date: $latestDate."
}
catch {
  Write-Log "ERROR: $($_.Exception.Message)"
  throw
}
finally {
  Get-ChildItem $logDir -Filter "update_*.log" -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-60) } |
    Remove-Item -Force -ErrorAction SilentlyContinue
}
