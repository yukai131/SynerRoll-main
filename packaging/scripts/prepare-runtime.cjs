// Installer executes this with the bundled Node; no system runtime/network is needed.
const fs = require('node:fs')
const path = require('node:path')
const { spawnSync } = require('node:child_process')
const installation = path.resolve(process.argv[2])
const resources = path.join(installation, 'resources')
const { juliaConfiguration, migrateLegacyData } = require(path.join(resources, 'config/runtime.cjs'))
const brand = JSON.parse(fs.readFileSync(path.join(resources, 'config/brand.json'), 'utf8'))
const userRoot = process.env.SYNERROLL_USER_DATA || path.join(process.env.APPDATA, brand.productName)
const logs = path.join(userRoot, 'logs')
fs.mkdirSync(logs, { recursive: true })
const logPath = path.join(logs, 'installation-prepare.log')
const output = fs.openSync(logPath, 'a')
const startedAt = Date.now()
async function prepare() {
try {
  if (!process.env.SYNERROLL_USER_DATA) await migrateLegacyData(userRoot)
  const config = juliaConfiguration(resources, userRoot)
  const result = spawnSync(config.executable, [...config.args, path.join(resources, 'app/prepare-runtime.jl')], {
    env: { ...process.env, ...config.env, SYNERROLL_CAPACITY_WORKER: '1', SYNERROLL_DISABLE_COPT: '1' },
    cwd: config.backend, windowsHide: true, stdio: ['ignore', output, output], timeout: 30 * 60 * 1000
  })
  if (result.error || result.status !== 0) throw result.error || Error(`Julia exited ${result.status}`)
  fs.writeFileSync(path.join(userRoot, 'runtime-ready.json'), JSON.stringify({ version: brand.version, preparedAt: new Date().toISOString(), seconds: (Date.now() - startedAt) / 1000 }, null, 2))
  console.log('PSFA runtime preparation completed.')
} catch (error) {
  fs.appendFileSync(logPath, `\n${error.stack || error}\n`)
  console.error(`PSFA runtime preparation failed. Log: ${logPath}`)
  process.exitCode = 1
} finally { fs.closeSync(output) }
}
prepare().catch(error => { console.error(error); process.exitCode = 1 })
