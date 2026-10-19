<#
.SYNOPSIS
  SynerRoll 一键出包脚本
  改完代码后跑这一条命令，产出可交付 zip。
.DESCRIPTION
  流程：nuxt build → 组装 dist → 裁剪体积 → 压缩 zip
  首次使用请先完成前置准备（见 docs/packaging-guide.md）。
.EXAMPLE
  .\release.ps1 -Version 0.2.0
.EXAMPLE
  .\release.ps1 -Version 0.2.1 -SkipJuliaCopy -SkipElectron
#>
param(
  [string]$Version = '0.0.0',
  [string]$DistDir = '',
  [switch]$SkipJuliaCopy,
  [switch]$SkipElectron,
  [switch]$NoZip,
  [switch]$Clean
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path $PSScriptRoot -Parent       # packaging/
$ProjectRoot = Split-Path $ScriptDir -Parent        # 项目根
if (-not $DistDir) { $DistDir = Join-Path $ProjectRoot 'dist\SynerRoll-win64' }
$DistParent = Split-Path $DistDir -Parent

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  SynerRoll 发行打包  v$Version" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "项目根: $ProjectRoot"
Write-Host "输出:   $DistDir"
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# ── 0. 清理 ──────────────────────────────────────────
if ($Clean -and (Test-Path $DistDir)) {
  Write-Host "`n[0/5] 清理旧 dist..." -ForegroundColor Yellow
  Remove-Item $DistDir -Recurse -Force
}

# ── 1. Nuxt build ────────────────────────────────────
Write-Host "`n[1/5] 构建 Nuxt..." -ForegroundColor Yellow
Push-Location $ProjectRoot
try {
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  cmd /c "cd /d "$ProjectRoot" && npx nuxt build" 2>&1 | Select-Object -Last 8
  $ErrorActionPreference = $prev
  if (-not (Test-Path (Join-Path $ProjectRoot '.output\server\index.mjs'))) {
    throw 'nuxt build 失败：.output/server/index.mjs 不存在'
  }
  Write-Host "  .output OK" -ForegroundColor Green
} finally {
  Pop-Location
}

# ── 2. 组装 dist ─────────────────────────────────────
Write-Host "`n[2/5] 组装发行目录..." -ForegroundColor Yellow

# 目录骨架
foreach ($d in @(
  $DistDir, "$DistDir\config", "$DistDir\data\projects", "$DistDir\data\tasks",
  "$DistDir\data\licenses", "$DistDir\logs", "$DistDir\app\backend",
  "$DistDir\resources", "$DistDir\runtime"
)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }

# .output
New-Item -ItemType Directory -Path "$DistDir\app\.output" -Force | Out-Null
Copy-Item (Join-Path $ProjectRoot '.output\*') "$DistDir\app\.output\" -Recurse -Force
Write-Host "  .output copied"

# Julia backend 源码
foreach ($item in @('components','core','services','routes','utils','Project.toml','Manifest.toml','server.jl','BackendStandardized.jl','BackendStandardized-Base.jl')) {
  $src = Join-Path $ProjectRoot "backend\$item"
  if (Test-Path -LiteralPath $src) {
    Copy-Item -LiteralPath $src "$DistDir\app\backend\" -Recurse -Force
  }
}
Write-Host "  backend copied"

# 组件库 + 模板
New-Item -ItemType Directory -Path "$DistDir\app\config" -Force | Out-Null
Copy-Item (Join-Path $ProjectRoot 'config\component-library.json') "$DistDir\app\config\" -Force
if (Test-Path (Join-Path $ProjectRoot 'templates')) {
  Copy-Item (Join-Path $ProjectRoot 'templates') "$DistDir\app\templates" -Recurse -Force
}
Write-Host "  config+templates copied"

# 配置
Copy-Item (Join-Path $ScriptDir 'config\synerroll.json') "$DistDir\config\" -Force
Copy-Item (Join-Path $ScriptDir 'config\synerroll.schema.json') "$DistDir\config\" -Force

# Electron 壳
Copy-Item (Join-Path $ScriptDir 'electron\*') $DistDir -Recurse -Force

# 图标
if (Test-Path (Join-Path $ScriptDir 'resources\icon.ico')) {
  Copy-Item (Join-Path $ScriptDir 'resources\icon.ico') "$DistDir\resources\" -Force
}
if (Test-Path (Join-Path $ScriptDir 'resources\icon-256.png')) {
  Copy-Item (Join-Path $ScriptDir 'resources\icon-256.png') "$DistDir\resources\" -Force
}

# README
Copy-Item (Join-Path $ScriptDir 'README.md') "$DistDir\README.md" -Force

# bat 入口
$batMap = @{
  'start.bat'                 = '启动 SynerRoll.bat'
  'start-cli.bat'             = '启动-命令行模式.bat'
  'stop-all.bat'              = '停止服务.bat'
  'export-diagnostics.bat'    = '导出诊断日志.bat'
}
foreach ($kv in $batMap.GetEnumerator()) {
  $src = Join-Path $ScriptDir "scripts\$($kv.Key)"
  if (Test-Path $src) { Copy-Item $src (Join-Path $DistDir $kv.Value) -Force }
}
Write-Host "  electron + bat + readme copied"

# ── 3. Julia runtime / depot ─────────────────────────
if (-not $SkipJuliaCopy) {
  Write-Host "`n[3/5] 拷贝 Julia runtime..." -ForegroundColor Yellow
  $JuliaSrc = Join-Path $ScriptDir 'runtime\julia'
  if (Test-Path $JuliaSrc) {
    robocopy $JuliaSrc "$DistDir\runtime\julia" /E /XD uninstall /NFL /NDL /NJH /NJS /NP | Out-Null
    Write-Host "  julia runtime OK"
  } else {
    Write-Warning "packaging/runtime/julia 不存在，跳过（首次请先准备）"
  }
  $DepotSrc = Join-Path $ScriptDir 'runtime\julia-depot'
  if (Test-Path $DepotSrc) {
    robocopy $DepotSrc "$DistDir\runtime\julia-depot" /E /NFL /NDL /NJH /NJS /NP | Out-Null
    Write-Host "  julia-depot OK"
  } else {
    Write-Warning "packaging/runtime/julia-depot 不存在，跳过（首次请先 gen-depot.ps1）"
  }
} else {
  Write-Host "`n[3/5] 跳过 Julia runtime（-SkipJuliaCopy）" -ForegroundColor Yellow
}

# Electron 依赖
if (-not $SkipElectron) {
  Write-Host "  安装 Electron..." -ForegroundColor Yellow
  $pkgJson = '{"name":"synerroll-launcher","version":"0.1.0","private":true,"main":"main.js","dependencies":{"electron":"^33.0.0"}}'
  Set-Content (Join-Path $DistDir 'package.json') $pkgJson -Encoding UTF8
  Push-Location $DistDir
  try {
    $env:ELECTRON_MIRROR = "https://npmmirror.com/mirrors/electron/"
    & npm install --omit=dev --no-audit --no-fund 2>&1 | Out-Null
    # 触发 electron 二进制下载
    if (Test-Path "node_modules\electron\install.js") {
      Push-Location "node_modules\electron"
      & node install.js 2>&1 | Out-Null
      Pop-Location
    }
    Write-Host "  Electron OK" -ForegroundColor Green
  } finally {
    Pop-Location
  }
}

# ── 4. 体积裁剪 ──────────────────────────────────────
Write-Host "`n[4/5] 体积裁剪..." -ForegroundColor Yellow

# Julia runtime
foreach ($item in @('share\doc','share\man','share\applications','share\metainfo','include','uninstall')) {
  $p = Join-Path $DistDir "runtime\julia\$item"
  if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
}
# depot
foreach ($item in @('registries','logs','scratchspaces','environments')) {
  $p = Join-Path $DistDir "runtime\julia-depot\$item"
  if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
}
# 无用 stdlib 预编译缓存
$trimPkgs = @('Pkg','REPL','REPLExt','Profile','Test','InteractiveUtils','Distributed','Downloads','LibGit2','Tar','ArgTools','StyledStrings','JuliaSyntaxHighlighting')
foreach ($base in @(
  "$DistDir\runtime\julia\share\julia\compiled\v1.12",
  "$DistDir\runtime\julia-depot\compiled\v1.12"
)) {
  foreach ($pkg in $trimPkgs) {
    $p = Join-Path $base $pkg
    if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
  }
}
# depot 里同名
foreach ($pkg in @('Pkg','REPL','Test','StyledStrings','Profile','InteractiveUtils','Distributed','Markdown')) {
  $p = Join-Path $DistDir "runtime\julia-depot\compiled\v1.12\$pkg"
  if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
}

# Electron locales（保留中英）
$locales = "$DistDir\node_modules\electron\dist\locales"
if (Test-Path $locales) {
  Get-ChildItem $locales -Filter '*.pak' |
    Where-Object { $_.Name -notmatch '^(en-US|zh-CN|zh-TW)' } |
    Remove-Item -Force -ErrorAction SilentlyContinue
}

# source maps
Get-ChildItem "$DistDir\app\.output" -Recurse -File -Filter '*.map' -ErrorAction SilentlyContinue |
  Remove-Item -Force -ErrorAction SilentlyContinue

Write-Host "  trim done"

# ── 5. 压缩 ──────────────────────────────────────────
if (-not $NoZip) {
  Write-Host "`n[5/5] 压缩 zip..." -ForegroundColor Yellow
  $zipName = "SynerRoll-win64-v$Version.zip"
  $zipPath = Join-Path $DistParent $zipName
  if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

  Push-Location $DistParent
  try {
    & tar -c --format=zip -f $zipName (Split-Path $DistDir -Leaf)
    if (-not (Test-Path $zipPath)) { throw 'zip 生成失败' }
  } finally {
    Pop-Location
  }
  $zipMB = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
  Write-Host "  $zipName  ($zipMB MB)" -ForegroundColor Green
} else {
  Write-Host "`n[5/5] 跳过压缩（-NoZip）" -ForegroundColor Yellow
}

# ── 汇总 ──────────────────────────────────────────────
$sw.Stop()
$totalMB = [math]::Round((Get-ChildItem $DistDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB, 0)

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  打包完成！耗时 $([int]$sw.Elapsed.TotalSeconds) 秒" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "安装目录: $DistDir  ($totalMB MB)"
if (-not $NoZip) {
  Write-Host "分发包:   $(Join-Path $DistParent "SynerRoll-win64-v$Version.zip")"
}
Write-Host ""
Write-Host "验证方法:" -ForegroundColor White
Write-Host "  cd `"$DistDir`""
Write-Host "  .\启动 SynerRoll.bat"
Write-Host "  # 等 ~20 秒后访问 http://127.0.0.1:3000"
