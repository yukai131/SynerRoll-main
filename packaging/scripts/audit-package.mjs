import { readFileSync, readdirSync, existsSync, statSync, writeFileSync } from 'node:fs'
import { join, relative, resolve, basename } from 'node:path'
import { createHash } from 'node:crypto'
import { createRequire } from 'node:module'

const root = resolve(import.meta.dirname, '../..')
const brand = JSON.parse(readFileSync(join(root, 'config/brand.json'), 'utf8'))
const resources = resolve(process.argv[2] || join(root, 'dist/psfa/win-unpacked/resources'))
const asar = createRequire(import.meta.url)('@electron/asar')
const hash = bytes => createHash('sha256').update(bytes).digest('hex')
const mismatches = []
let compared = 0
function compare(packaged, source, label) {
  compared++
  if (!existsSync(source) || hash(readFileSync(packaged)) !== hash(readFileSync(source))) mismatches.push(label)
}
function walk(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap(entry =>
    entry.isDirectory() ? walk(join(directory, entry.name)) : [join(directory, entry.name)])
}
const archive = join(resources, 'app.asar')
const shellFiles = ['main.js', 'runtime.cjs', 'preload.js', 'shell-preload.js', 'license.cjs', 'license-keys.json',
  ...walk(join(root, 'packaging/electron/ui')).map(file => relative(join(root, 'packaging/electron'), file).replaceAll('\\', '/'))]
for (const name of shellFiles) {
  compared++
  if (hash(asar.extractFile(archive, name)) !== hash(readFileSync(join(root, 'packaging/electron', name)))) mismatches.push(name)
}
for (const sub of ['backend', '.output', 'templates', 'config']) {
  for (const file of walk(join(resources, 'app', sub))) {
    const name = relative(join(resources, 'app'), file)
    compare(file, join(root, name), name)
  }
}
for (const name of ['prepare-runtime.cjs', 'prepare-runtime.jl']) {
  compare(join(resources, 'app', name), join(root, 'packaging/scripts', name), name)
}
compare(join(resources, 'config/brand.json'), join(root, 'config/brand.json'), 'brand.json')
compare(join(resources, 'config/runtime.cjs'), join(root, 'packaging/electron/runtime.cjs'), 'runtime.cjs resource')
compare(join(resources, '使用说明.md'), join(root, 'packaging/README.md'), 'usage')
compare(join(resources, 'icon.ico'), join(root, 'packaging/resources/icon.ico'), 'application icon')
const pkg = JSON.parse(asar.extractFile(archive, 'package.json'))
const publisher = typeof pkg.author === 'string' ? pkg.author : pkg.author?.name
if (pkg.version !== brand.version || publisher !== brand.publisher || pkg.productName !== brand.displayName) mismatches.push('package branding')
const installerName = `${brand.productName}-Setup-${brand.version}-x64.exe`
const installer = join(root, 'dist', installerName)
const digest = hash(readFileSync(installer))
compare(installer, join(root, 'dist/psfa', installerName), 'installer copy')
if (!readFileSync(`${installer}.sha256`, 'utf8').startsWith(digest)) mismatches.push('checksum sidecar')
const required = ['app/backend/simulation_worker.jl', 'app/backend/capacity_worker.jl',
  'runtime/julia/bin/julia.exe', 'runtime/julia/bin/julia-original.exe', 'runtime/node/node.exe',
  'runtime/psfa-sysimage.dll', 'runtime/julia-depot/packages/HiGHS']
const missing = required.filter(file => !existsSync(join(resources, file)))
const nativeFiles = walk(join(resources, 'runtime/julia-depot/artifacts'))
const coptLibraries = nativeFiles.filter(file => /copt.*\.(dll|lic)$/i.test(basename(file)))
const highsLibraries = nativeFiles.filter(file => /highs.*\.dll$/i.test(basename(file))).map(file => relative(resources, file))
const report = {
  status: !mismatches.length && !missing.length && !coptLibraries.length && highsLibraries.length ? 'passed' : 'failed',
  version: pkg.version, author: publisher, asarFiles: asar.listPackage(archive), compared,
  mismatches, missing, highsLibraries, coptLibraries, installer: { bytes: statSync(installer).size, sha256: digest }
}
writeFileSync(join(root, 'dist/psfa-package-audit.json'), JSON.stringify(report, null, 2) + '\n')
console.log(JSON.stringify(report, null, 2))
if (report.status !== 'passed') process.exitCode = 1
