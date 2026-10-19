<#
.SYNOPSIS
  准备便携包用的最小 Julia depot
.DESCRIPTION
  在指定目录创建只含本项目依赖的 Julia depot（packages + artifacts）。
  用法：
    .\prepare-julia-depot.ps1 -OutDir "D:\path\to\julia-depot"
#>
param(
  [Parameter(Mandatory = $true)][string]$OutDir,
  [string]$BackendDir = (Join-Path (Split-Path $PSScriptRoot -Parent | Split-Path -Parent) 'backend')
)

$ErrorActionPreference = 'Stop'
Write-Host "=== 准备最小 Julia depot ===" -ForegroundColor Cyan
Write-Host "输出: $OutDir"
Write-Host "后端: $BackendDir"

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$outFull = (Resolve-Path $OutDir).Path
$backendFull = (Resolve-Path $BackendDir).Path

# 使用独立 depot，避免污染全局
$env:JULIA_DEPOT_PATH = $outFull

Write-Host "`n[1/3] 安装依赖到独立 depot..."
julia --project="$backendFull" -e "using Pkg; Pkg.instantiate(); Pkg.precompile()"

Write-Host "`n[2/3] 清理 compiled 缓存（可选，减小体积）..."
$compiled = Join-Path $outFull 'compiled'
if (Test-Path $compiled) {
  $sizeBefore = (Get-ChildItem $compiled -Recurse -File | Measure-Object Length -Sum).Sum / 1MB
  # 保留 stdlib 的 compiled，删除包的可重新预编译
  # 这里保守：只删 registries/logs/scratchspaces 中的缓存
  foreach ($sub in @('logs', 'scratchspaces')) {
    $p = Join-Path $outFull $sub
    if (Test-Path $p) {
      Get-ChildItem $p -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | Remove-Item -Force -ErrorAction SilentlyContinue
    }
  }
  Write-Host ("  compiled 约 {0:N0} MB（预编译缓存，可减少冷启动）" -f $sizeBefore)
}

Write-Host "`n[3/3] 统计体积..."
foreach ($sub in @('packages', 'artifacts', 'compiled', 'registries')) {
  $p = Join-Path $outFull $sub
  if (Test-Path $p) {
    $s = (Get-ChildItem $p -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB
    Write-Host ("  {0,-12} {1,8:N1} MB" -f $sub, $s)
  }
}
$total = (Get-ChildItem $outFull -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB
Write-Host ("  {0,-12} {1,8:N1} MB" -f 'TOTAL', $total)
Write-Host "`n完成。将此目录复制到便携包的 runtime\julia-depot\"
