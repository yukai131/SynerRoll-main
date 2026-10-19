# 全链路启动验证：模拟 Electron main.js 的 bootServices 流程
$ErrorActionPreference = 'Continue'
$Dist = "D:\Downloads\SynerRoll-main\SynerRoll-main\dist\SynerRoll-win64"
$JuliaExe = "$Dist\runtime\julia\bin\julia.exe"
$BackendDir = "$Dist\app\backend"
$Depot = "$Dist\runtime\julia-depot"
$BffEntry = "$Dist\app\.output\server\index.mjs"
$JuliaPort = 18080
$BffPort = 13000

Write-Host "=== Full-chain boot verification ===" -ForegroundColor Cyan

# 1. Start Julia with portable runtime + depot
Write-Host "`n[1/3] Starting Julia (portable)..." -ForegroundColor Yellow
$env:PORT = "$JuliaPort"
$env:JULIA_DEPOT_PATH = $Depot
$env:JULIA_PROJECT = $BackendDir
$env:SYNERROLL_DATA_DIR = "$Dist\data"

$jl = Start-Process -FilePath $JuliaExe -ArgumentList "--project=`"$BackendDir`"","`"$BackendDir\server.jl`"" -PassThru -WindowStyle Hidden -RedirectStandardOutput "$Dist\logs\test-julia.log" -RedirectStandardError "$Dist\logs\test-julia-err.log"
Write-Host "  Julia PID: $($jl.Id)"

# Wait for Julia health
$ok = $false
for ($i = 0; $i -lt 60; $i++) {
  Start-Sleep -Seconds 2
  try {
    $r = Invoke-RestMethod -Uri "http://127.0.0.1:$JuliaPort/health" -TimeoutSec 3
    if ($r.status -eq 'ok') {
      Write-Host "  Julia HEALTHY: $($r | ConvertTo-Json -Compress)" -ForegroundColor Green
      $ok = $true
      break
    }
  } catch {
    if ($i % 5 -eq 0) { Write-Host "  waiting Julia... ($i)" }
  }
}
if (-not $ok) {
  Write-Host "  Julia FAILED" -ForegroundColor Red
  Get-Content "$Dist\logs\test-julia.log" -Tail 15 -ErrorAction SilentlyContinue
  Get-Content "$Dist\logs\test-julia-err.log" -Tail 15 -ErrorAction SilentlyContinue
  exit 1
}

# 2. Start BFF
Write-Host "`n[2/3] Starting BFF..." -ForegroundColor Yellow
$env:PORT = "$BffPort"
$env:NITRO_PORT = "$BffPort"
$env:HOST = "127.0.0.1"
$env:NITRO_HOST = "127.0.0.1"
$env:JULIA_BACKEND_URL = "http://127.0.0.1:$JuliaPort"
$env:NUXT_PUBLIC_JULIA_WS_BASE = "ws://127.0.0.1:$JuliaPort"

$bf = Start-Process -FilePath "node" -ArgumentList "`"$BffEntry`"" -PassThru -WindowStyle Hidden -RedirectStandardOutput "$Dist\logs\test-bff.log" -RedirectStandardError "$Dist\logs\test-bff-err.log"
Write-Host "  BFF PID: $($bf.Id)"

$ok = $false
for ($i = 0; $i -lt 30; $i++) {
  Start-Sleep -Seconds 2
  try {
    $r = Invoke-RestMethod -Uri "http://127.0.0.1:$BffPort/api/v1/health" -TimeoutSec 3
    if ($r.success -eq $true) {
      Write-Host "  BFF HEALTHY: $($r | ConvertTo-Json -Compress -Depth 5)" -ForegroundColor Green
      $ok = $true
      break
    }
  } catch {
    if ($i % 3 -eq 0) { Write-Host "  waiting BFF... ($i)" }
  }
}
if (-not $ok) {
  Write-Host "  BFF FAILED" -ForegroundColor Red
  Get-Content "$Dist\logs\test-bff.log" -Tail 15 -ErrorAction SilentlyContinue
  Get-Content "$Dist\logs\test-bff-err.log" -Tail 15 -ErrorAction SilentlyContinue
  Stop-Process -Id $jl.Id -Force -ErrorAction SilentlyContinue
  exit 1
}

# 3. Summary
Write-Host "`n[3/3] Chain status:" -ForegroundColor Yellow
Write-Host "  Julia : http://127.0.0.1:$JuliaPort/health  -> OK" -ForegroundColor Green
Write-Host "  BFF   : http://127.0.0.1:$BffPort/api/v1/health -> OK" -ForegroundColor Green
Write-Host "  Ready : $($r.data.ready)" -ForegroundColor Green
Write-Host "  Solvers: $($r.data.solvers | ConvertTo-Json -Compress)" -ForegroundColor Green

Write-Host "`n=== FULL CHAIN OK ===" -ForegroundColor Cyan
Write-Host "Stopping test processes..."
Stop-Process -Id $jl.Id -Force -ErrorAction SilentlyContinue
Stop-Process -Id $bf.Id -Force -ErrorAction SilentlyContinue
Write-Host "Done."
