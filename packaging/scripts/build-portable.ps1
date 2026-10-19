<#
.SYNOPSIS
  SynerRoll Windows 便携包组装脚本
.DESCRIPTION
  将 Nuxt .output、Julia backend、Electron 壳、配置与运行时组装到 dist/SynerRoll-win64/ 目录。
  需先准备：
    - packaging/runtime/node/     portable Node（可选，Electron 自带 Node）
    - packaging/runtime/julia/    portable Julia
    - packaging/runtime/julia-depot/  最小 Julia 依赖
    - packaging/electron/         Electron 主进程源码
  用法：
    .\build-portable.ps1 [-Clean] [-SkipJulia] [-SkipElectronDep]
#>
param(
  [switch]$Clean,
  [switch]$SkipJulia,
  [switch]$SkipElectronDep
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent          # packaging/
$ProjectRoot = Split-Path $Root -Parent           # 项目根
$Dist = Join-Path $ProjectRoot 'dist\SynerRoll-win64'

Write-Host "=== SynerRoll 便携包组装 ===" -ForegroundColor Cyan
Write-Host "项目根: $ProjectRoot"
Write-Host "输出:   $Dist"

if ($Clean -and (Test-Path $Dist)) {
  Remove-Item $Dist -Recurse -Force
  Write-Host "已清理旧的 dist 目录"
}

# -- 目录骨架 ------------------------------------------
$dirs = @(
  $Dist,
  "$Dist\config",
  "$Dist\data",
  "$Dist\data\projects",
  "$Dist\data\tasks",
  "$Dist\data\licenses",
  "$Dist\logs",
  "$Dist\app",
  "$Dist\app\backend",
  "$Dist\resources",
  "$Dist\runtime"
)
foreach ($d in $dirs) { New-Item -ItemType Directory -Path $d -Force | Out-Null }

# -- 1. Nuxt .output -----------------------------------
Write-Host "`n[1/6] 复制 Nuxt .output..." -ForegroundColor Yellow
$OutputSrc = Join-Path $ProjectRoot '.output'
if (-not (Test-Path $OutputSrc)) {
  throw ".output 不存在，请先运行: npx nuxt build"
}
New-Item -ItemType Directory -Path "$Dist\app\.output" -Force | Out-Null
Copy-Item "$OutputSrc\*" "$Dist\app\.output" -Recurse -Force
$outputSize = (Get-ChildItem "$Dist\app\.output" -Recurse -File | Measure-Object Length -Sum).Sum / 1MB
Write-Host ("  .output: {0:N1} MB" -f $outputSize)

# -- 2. Julia backend 源码 -----------------------------
Write-Host "`n[2/6] 复制 Julia backend..." -ForegroundColor Yellow
$BackendSrc = Join-Path $ProjectRoot 'backend'
# 只复制源码与依赖清单，排除 data / tools / test
$backendItems = @('components', 'core', 'services', 'routes', 'utils', 'Project.toml', 'Manifest.toml', 'server.jl', 'BackendStandardized.jl', 'BackendStandardized-Base.jl')
foreach ($item in $backendItems) {
  $src = Join-Path $BackendSrc $item
  if (Test-Path -LiteralPath $src) {
    Copy-Item -LiteralPath $src "$Dist\app\backend" -Recurse -Force
  }
}
# 确保 perf_probe 存在（空实现）
if (-not (Test-Path "$Dist\app\backend\utils\perf_probe.jl")) {
  Write-Warning "perf_probe.jl 缺失"
}
Write-Host "  backend 源码已复制"

# -- 3. 组件库与模板 -----------------------------------
Write-Host "`n[3/6] 复制组件库与模板..." -ForegroundColor Yellow
New-Item -ItemType Directory -Path "$Dist\app\config" -Force | Out-Null
Copy-Item (Join-Path $ProjectRoot 'config\component-library.json') "$Dist\app\config" -Force
if (Test-Path (Join-Path $ProjectRoot 'templates')) {
  Copy-Item (Join-Path $ProjectRoot 'templates') "$Dist\app\templates" -Recurse -Force
}
Write-Host "  component-library.json + templates"

# -- 4. 配置 -------------------------------------------
Write-Host "`n[4/6] 写入配置..." -ForegroundColor Yellow
Copy-Item (Join-Path $Root 'config\synerroll.json') "$Dist\config" -Force
Copy-Item (Join-Path $Root 'config\synerroll.schema.json') "$Dist\config" -Force

# -- 5. Electron 壳 ------------------------------------
Write-Host "`n[5/6] 组装 Electron 壳..." -ForegroundColor Yellow
Copy-Item (Join-Path $Root 'electron\*') "$Dist" -Recurse -Force
# README
Copy-Item (Join-Path $Root 'README.md') "$Dist\README.md" -Force

# icon
$iconSrc = Join-Path $Root 'resources\icon.ico'
if (Test-Path $iconSrc) {
  Copy-Item $iconSrc "$Dist\resources" -Force
} else {
  Write-Warning "icon.ico 缺失（resources/icon.ico）"
}

if (-not $SkipElectronDep) {
  # 安装 electron 到 dist（仅生产依赖）
  Write-Host "  安装 Electron（首次较慢）..."
  Push-Location $Dist
  try {
    # 精简 package.json 只保留 electron
    $pkg = Get-Content 'package.json' -Raw | ConvertFrom-Json
    $pkg.dependencies = @{ electron = '^33.0.0' }
    $pkg | ConvertTo-Json -Depth 5 | Set-Content 'package.json' -Encoding UTF8
    & npm install --omit=dev --no-audit --no-fund 2>&1 | Out-Host
  } finally {
    Pop-Location
  }
}

# -- 6. Julia runtime（可选） --------------------------
if (-not $SkipJulia) {
  Write-Host "`n[6/6] 复制 Julia runtime / depot..." -ForegroundColor Yellow
  $JuliaSrc = Join-Path $Root 'runtime\julia'
  $DepotSrc = Join-Path $Root 'runtime\julia-depot'
  if (Test-Path $JuliaSrc) {
    Write-Host "  复制 julia runtime（可能数分钟）..."
    robocopy $JuliaSrc "$Dist\runtime\julia" /E /NFL /NDL /NJH /NJS /NP | Out-Null
  } else {
    Write-Warning "packaging/runtime/julia 不存在 — 请手动放置 portable Julia"
  }
  if (Test-Path $DepotSrc) {
    Write-Host "  复制 julia-depot（可能数分钟）..."
    robocopy $DepotSrc "$Dist\runtime\julia-depot" /E /NFL /NDL /NJH /NJS /NP | Out-Null
  } else {
    Write-Warning "packaging/runtime/julia-depot 不存在 — 请手动放置最小 depot"
  }
} else {
  Write-Host "`n[6/6] 跳过 Julia runtime" -ForegroundColor Yellow
}

# -- 汇总 ----------------------------------------------
Write-Host "`n=== 组装完成 ===" -ForegroundColor Green
$total = (Get-ChildItem $Dist -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB
Write-Host ("输出目录: {0}" -f $Dist)
Write-Host ("总大小:   {0:N1} MB" -f $total)
Write-Host "`n后续步骤："
Write-Host "  1. 将 portable Julia 放入 runtime\julia\（含 bin\julia.exe）"
Write-Host "  2. 将最小 depot 放入 runtime\julia-depot\"
Write-Host "  3. 双击 SynerRoll.exe 或运行 npx electron ."
Write-Host "  4. 验证后用 7z/zip 打包分发"
