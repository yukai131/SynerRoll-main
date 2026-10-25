param([switch]$SkipRuntime, [switch]$SkipFrontend, [switch]$SkipSysimage, [switch]$StageOnly)
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if (-not $env:ELECTRON_MIRROR) { $env:ELECTRON_MIRROR = 'https://npmmirror.com/mirrors/electron/' }
if (-not $env:ELECTRON_BUILDER_BINARIES_MIRROR) { $env:ELECTRON_BUILDER_BINARIES_MIRROR = 'https://npmmirror.com/mirrors/electron-builder-binaries/' }
$stage = Join-Path $projectRoot 'packaging\release-stage'
$env:PSFA_STAGE_DIR = $stage
Set-Location -LiteralPath $projectRoot
$env:NUXT_TELEMETRY_DISABLED = '1'
function Check-Exit([string]$Label) { if ($LASTEXITCODE -ne 0) { throw "$Label failed (exit $LASTEXITCODE)" } }
function Copy-Tree([string]$Source, [string]$Target, [string[]]$Exclude = @()) {
  $copyArgs = @($Source, $Target, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
  if ($Exclude.Count) { $copyArgs += '/XD'; $copyArgs += $Exclude }
  & robocopy @copyArgs | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "Copy failed: $Source" }
}
if (-not $SkipFrontend) { & npm.cmd run build; Check-Exit 'Nuxt build' }
if (-not (Test-Path -LiteralPath '.output\server\index.mjs')) { throw 'Nuxt output missing' }
# Always replace application payload; never ship stale backend files or user databases.
$payload = [IO.Path]::GetFullPath((Join-Path $stage 'app'))
if (-not $payload.StartsWith($stage + [IO.Path]::DirectorySeparatorChar)) { throw 'Invalid stage path' }
if (Test-Path -LiteralPath $payload) { Remove-Item -LiteralPath $payload -Recurse -Force }
New-Item -ItemType Directory -Path "$payload\backend", "$payload\config", "$stage\runtime\node" -Force | Out-Null
Copy-Tree "$projectRoot\.output" "$payload\.output"
foreach ($directory in @('components','core','services','routes','utils')) {
  Copy-Tree "$projectRoot\backend\$directory" "$payload\backend\$directory"
}
foreach ($file in @('server.jl','capacity_worker.jl','simulation_worker.jl','Project.toml','Manifest.toml')) {
  Copy-Item -LiteralPath "$projectRoot\backend\$file" -Destination "$payload\backend\$file" -Force
}
foreach ($file in @('prepare-runtime.cjs','prepare-runtime.jl')) {
  Copy-Item -LiteralPath "$projectRoot\packaging\scripts\$file" -Destination "$payload\$file" -Force
}
Copy-Item -LiteralPath "$projectRoot\config\component-library.json" -Destination "$payload\config" -Force
Copy-Tree "$projectRoot\templates" "$payload\templates"
New-Item -ItemType Directory -Path "$stage\config" -Force | Out-Null
Copy-Item -LiteralPath "$projectRoot\config\brand.json" -Destination "$stage\config\brand.json" -Force
Copy-Item -LiteralPath "$projectRoot\packaging\config\synerroll.json" -Destination "$stage\config\synerroll.json" -Force
Copy-Item -LiteralPath "$projectRoot\packaging\electron\runtime.cjs" -Destination "$stage\config\runtime.cjs" -Force
Copy-Item -LiteralPath "$projectRoot\packaging\resources\icon.ico" -Destination "$stage\icon.ico" -Force
if (-not $SkipRuntime) {
  $juliaExe = (Get-Command julia.exe -ErrorAction Stop).Source
  $juliaRoot = Split-Path (Split-Path $juliaExe -Parent) -Parent
  $nodeExe = (Get-Command node.exe -ErrorAction Stop).Source
  Copy-Tree $juliaRoot "$stage\runtime\julia" @('doc','man','include','uninstall')
  Copy-Item -LiteralPath $nodeExe -Destination "$stage\runtime\node\node.exe" -Force
  $env:JULIA_PKG_PRECOMPILE_AUTO = '0'
  & $juliaExe --startup-file=no --project=backend -e 'using Pkg; Pkg.instantiate()'
  Check-Exit 'Julia instantiate'
  $depot = [IO.Path]::GetFullPath("$stage\runtime\julia-depot")
  if (-not $depot.StartsWith($stage + [IO.Path]::DirectorySeparatorChar)) { throw 'Invalid depot path' }
  if (Test-Path -LiteralPath $depot) { Remove-Item -LiteralPath $depot -Recurse -Force }
  & $juliaExe --startup-file=no --project=backend packaging/scripts/export-depot.jl $depot
  Check-Exit 'Julia depot export'
  $nodeVersion = & node.exe --version
  Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/nodejs/node/$nodeVersion/LICENSE" -OutFile "$stage\Node-LICENSE.txt"
  Add-Content -LiteralPath "$stage\THIRD-PARTY-NOTICES.txt" -Value "`nNode.js $nodeVersion" -Encoding utf8
  Get-Content -LiteralPath "$stage\Node-LICENSE.txt" | Add-Content -LiteralPath "$stage\THIRD-PARTY-NOTICES.txt" -Encoding utf8
  Copy-Item -LiteralPath "$stage\runtime\julia\LICENSE.md" -Destination "$stage\Julia-LICENSE.md" -Force
  Get-Content -LiteralPath "$stage\Julia-LICENSE.md" | Add-Content -LiteralPath "$stage\THIRD-PARTY-NOTICES.txt" -Encoding utf8
}
& node.exe packaging/scripts/patch-julia-utf8.mjs "$stage\runtime\julia\bin\julia.exe"
Check-Exit 'Julia UTF-8 process manifest'
$noticesPath = Join-Path $stage 'THIRD-PARTY-NOTICES.txt'
$noticesText = [IO.File]::ReadAllText($noticesPath).Replace('SynerRoll bundled third-party notices', 'PSFA bundled third-party notices')
if (-not $noticesText.Contains('PSFA Julia manifest modification')) {
  $noticesText += "`nPSFA Julia manifest modification: the Julia executable requests a UTF-8 process code page for Windows 10 1903+. The original signed executable is preserved as runtime/julia/bin/julia-original.exe. Julia native libraries and application code are unmodified by this resource edit.`n"
}
[IO.File]::WriteAllText($noticesPath, $noticesText)
if (-not $SkipSysimage) {
  $env:JULIA_CPU_TARGET = 'generic'
  & julia.exe --startup-file=no --project=packaging/compiler -e 'using Pkg; Pkg.instantiate()'
  Check-Exit 'Compiler instantiate'
  & julia.exe --startup-file=no --project=packaging/compiler packaging/scripts/build-sysimage.jl
  Check-Exit 'Julia system image'
}
foreach ($required in @('runtime\julia\bin\julia.exe','runtime\psfa-sysimage.dll','runtime\node\node.exe','runtime\julia-depot\packages\HiGHS','THIRD-PARTY-NOTICES.txt')) {
  if (-not (Test-Path -LiteralPath (Join-Path $stage $required))) { throw "Missing runtime component: $required" }
}
if ($StageOnly) { return }
& npx.cmd electron-builder --config packaging/electron-builder.cjs --win --x64 --publish never
Check-Exit 'Windows installer'
Get-ChildItem -LiteralPath "$projectRoot\dist\psfa" -Filter '*Setup*.exe' | ForEach-Object {
  Copy-Item -LiteralPath $_.FullName -Destination "$projectRoot\dist\$($_.Name)" -Force
}
Get-ChildItem -LiteralPath "$projectRoot\dist" -Filter '*Setup*.exe' | ForEach-Object {
  $digest = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  Set-Content -LiteralPath ($_.FullName + '.sha256') -Value "$digest  $($_.Name)" -Encoding ascii
}
