<#
.SYNOPSIS
  裁剪便携包体积（安全删除可再生/非运行时必需文件）
#>
param(
  [string]$Dist = "D:\Downloads\SynerRoll-main\SynerRoll-main\dist\SynerRoll-win64",
  [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
Write-Host "=== 便携包体积裁剪 ===" -ForegroundColor Cyan
Write-Host "目标: $Dist"
if ($DryRun) { Write-Host "(DryRun 模式，不实际删除)" -ForegroundColor Yellow }

function Remove-Safe($path, $label) {
  if (-not (Test-Path $path)) { return }
  $s = (Get-ChildItem $path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB
  Write-Host ("  [-] {0,-42} {1,8:N1} MB" -f $label, $s)
  if (-not $DryRun) { Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue }
}

# 1. Julia runtime
Write-Host "`n[Julia runtime]" -ForegroundColor Yellow
Remove-Safe "$Dist\runtime\julia\share\doc"           "share/doc (文档)"
Remove-Safe "$Dist\runtime\julia\share\man"           "share/man"
Remove-Safe "$Dist\runtime\julia\share\applications"  "share/applications"
Remove-Safe "$Dist\runtime\julia\share\metainfo"      "share/metainfo"
Remove-Safe "$Dist\runtime\julia\include"             "include (C 头文件)"
Remove-Safe "$Dist\runtime\julia\uninstall"           "uninstall"

# 2. Julia depot
Write-Host "`n[Julia depot]" -ForegroundColor Yellow
Remove-Safe "$Dist\runtime\julia-depot\registries"     "registries (仅 Pkg 需要)"
Remove-Safe "$Dist\runtime\julia-depot\logs"           "logs"
Remove-Safe "$Dist\runtime\julia-depot\scratchspaces"  "scratchspaces"
Remove-Safe "$Dist\runtime\julia-depot\environments"   "environments"

# 3. Electron locales（保留 en + zh）
Write-Host "`n[Electron]" -ForegroundColor Yellow
$locales = "$Dist\node_modules\electron\dist\locales"
if (Test-Path $locales) {
  $removed = 0
  Get-ChildItem $locales -Filter "*.pak" | Where-Object { $_.Name -notmatch '^(en-US|zh-CN|zh-TW)' } | ForEach-Object {
    $s = $_.Length / 1MB
    Write-Host ("  [-] locale {0,-34} {1,6:N1} MB" -f $_.Name, $s)
    if (-not $DryRun) { Remove-Item $_.FullName -Force }
    $removed++
  }
}

# 4. .output source maps
Write-Host "`n[Nuxt .output]" -ForegroundColor Yellow
$maps = Get-ChildItem "$Dist\app\.output" -Recurse -File -Filter "*.map" -ErrorAction SilentlyContinue
if ($maps) {
  $s = ($maps | Measure-Object Length -Sum).Sum / 1MB
  Write-Host ("  [-] source maps ({0} files)            {1,8:N1} MB" -f $maps.Count, $s)
  if (-not $DryRun) { $maps | Remove-Item -Force }
}

# 5. 其他（SSR chunks 不可删 — 页面渲染依赖）

# 汇总
Write-Host "`n=== 裁剪后体积 ===" -ForegroundColor Cyan
foreach ($p in @("runtime\julia","runtime\julia-depot","node_modules","app","config")) {
  $full = Join-Path $Dist $p
  if (Test-Path $full) {
    $s = (Get-ChildItem $full -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB
    Write-Host ("  {0,-22} {1,8:N1} MB" -f $p, $s)
  }
}
$total = (Get-ChildItem $Dist -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB
Write-Host ("  {0,-22} {1,8:N1} MB" -f 'TOTAL', $total)
