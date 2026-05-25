$ErrorActionPreference = "Stop"
$baseUrl = "http://127.0.0.1:4307/api/execute"
$deviceIp = "192.168.1.111"

$spiral = @("CFG INPUT 30 16 1800", "P")
$dirs = @(@(1,0), @(0,1), @(-1,0), @(0,-1))
$di = 0
for ($len = 1; $len -le 6; $len++) {
  for ($r = 0; $r -lt 2; $r++) {
    $d = $dirs[$di % 4]
    for ($s = 0; $s -lt $len; $s++) {
      $spiral += "M $($d[0]) $($d[1])"
      $spiral += "P"
    }
    $di++
  }
}

Write-Host "=== Commands: $($spiral.Count) (spiral depth=6) ==="

function Run-Benchmark($label, $batchSize) {
  Write-Host ""
  Write-Host "--- $label ---"
  $body = @{
    target = "wifi"
    portPath = $deviceIp
    baudRate = 9876
    ackTimeoutMs = 10000
    retries = 1
    commands = $spiral
  }
  if ($batchSize) { $body.batchSize = $batchSize }

  $jsonBody = $body | ConvertTo-Json -Depth 4

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $result = Invoke-RestMethod -Uri $baseUrl -Method POST -ContentType "application/json" -Body $jsonBody
  } catch {
    Write-Host "FAILED: $_"
    return $null
  }
  $sw.Stop()
  $wallMs = $sw.ElapsedMilliseconds

  $batchLines = @($result.lines | Where-Object { $_ -match "batch=\d+ elapsed=" })
  $deviceElapsedMatches = [regex]::Matches(($batchLines -join "`n"), "elapsed=(\d+)")
  $totalDeviceMs = 0
  foreach ($m in $deviceElapsedMatches) { $totalDeviceMs += [int]$m.Groups[1].Value }

  $actionCount = $spiral.Count - 1
  $perAction = [math]::Round($wallMs / $actionCount, 1)

  Write-Host "  Wall clock: $wallMs ms"
  Write-Host "  Batches: $($batchLines.Count)"
  Write-Host "  Device exec: $totalDeviceMs ms"
  Write-Host "  Per action: $perAction ms"

  return @{
    Label = $label
    BatchSize = $batchSize
    WallMs = $wallMs
    BatchCount = $batchLines.Count
    TotalDeviceMs = $totalDeviceMs
    PerActionMs = $perAction
  }
}

Start-Sleep -Seconds 2
$r1 = Run-Benchmark "BATCH=1  (one-by-one)" 1

Start-Sleep -Seconds 2
$r2 = Run-Benchmark "BATCH=10 (batch mode)" 10

Write-Host ""
Write-Host "========================================"
Write-Host "  COMPARISON"
Write-Host "========================================"

if ($r1) {
  Write-Host ("{0}  wall={1}ms  dev={2}ms  per_action={3}ms" -f $r1.Label, $r1.WallMs, $r1.TotalDeviceMs, $r1.PerActionMs)
}
if ($r2) {
  Write-Host ("{0}  wall={1}ms  dev={2}ms  per_action={3}ms" -f $r2.Label, $r2.WallMs, $r2.TotalDeviceMs, $r2.PerActionMs)
}

if ($r1 -and $r2 -and $r1.WallMs -gt 0) {
  $speedup = [math]::Round(($r1.WallMs - $r2.WallMs) / $r1.WallMs * 100, 1)
  Write-Host ""
  Write-Host "Speedup: $speedup%"
  Write-Host ("{0}ms -> {1}ms per action" -f $r1.PerActionMs, $r2.PerActionMs)
}
