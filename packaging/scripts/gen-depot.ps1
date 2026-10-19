$ErrorActionPreference = 'Stop'
$OutDir = "D:\Downloads\SynerRoll-main\SynerRoll-main\dist\SynerRoll-win64\runtime\julia-depot"
$BackendDir = "D:\Downloads\SynerRoll-main\SynerRoll-main\dist\SynerRoll-win64\app\backend"
$Script = "D:\Downloads\SynerRoll-main\SynerRoll-main\packaging\scripts\instantiate.jl"

Write-Host "=== Generating minimal Julia depot ==="
Write-Host "Out: $OutDir"
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$outFull = (Resolve-Path $OutDir).Path
$backendFull = (Resolve-Path $BackendDir).Path

$env:JULIA_DEPOT_PATH = $outFull

Write-Host "Installing deps to isolated depot (this may take several minutes)..."
julia --project="$backendFull" "$Script"

Write-Host "=== Depot size summary ==="
foreach ($sub in @('packages','artifacts','compiled','registries','environments')) {
  $p = Join-Path $outFull $sub
  if (Test-Path $p) {
    $s = (Get-ChildItem $p -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB
    Write-Host ("  {0,-14} {1,8:N1} MB" -f $sub, $s)
  }
}
$total = (Get-ChildItem $outFull -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB
Write-Host ("  {0,-14} {1,8:N1} MB" -f 'TOTAL', $total)
