import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, writeFileSync, appendFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import net from 'node:net'
import { createRequire } from 'node:module'

const [installation, userRoot] = process.argv.slice(2).map(value => resolve(value))
if (!installation || !userRoot) throw Error('Usage: verify-services.mjs <installation> <isolated-user-directory>')
const resources = join(installation, 'resources')
const { juliaConfiguration } = createRequire(import.meta.url)(join(resources, 'config/runtime.cjs'))
const config = juliaConfiguration(resources, userRoot)
mkdirSync(join(userRoot, 'logs'), { recursive: true })
const env = { ...process.env, ...config.env, SYNERROLL_USER_DATA: userRoot,
  SYNERROLL_DISABLE_COPT: '1', JULIA_LOAD_PATH: '@;@stdlib',
  PATH: `${process.env.SystemRoot}\\System32;${process.env.SystemRoot}` }
const children = []
const report = { installation, userRoot, startedAt: new Date().toISOString() }
const node = join(resources, 'runtime/node/node.exe')
async function port() {
  return new Promise((resolve, reject) => {
    const server = net.createServer()
    server.on('error', reject)
    server.listen(0, '127.0.0.1', () => { const number = server.address().port; server.close(() => resolve(number)) })
  })
}
function start(label, executable, args, overrides = {}, cwd = installation) {
  const child = spawn(executable, args, { cwd, env: { ...env, ...overrides }, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] })
  children.push(child)
  for (const stream of [child.stdout, child.stderr]) stream.on('data', bytes => appendFileSync(join(userRoot, 'logs', `verify-${label}.log`), bytes))
  child.on('error', error => { child.startError = error })
  return child
}
async function ended(child) {
  if (child.exitCode !== null) return child.exitCode
  return new Promise(resolve => child.once('exit', resolve))
}
async function healthy(url, child, ready) {
  const deadline = Date.now() + 300_000
  while (Date.now() < deadline) {
    if (child.startError) throw child.startError
    if (child.exitCode !== null) throw Error(`Service exited ${child.exitCode}: ${url}`)
    try { const result = await (await fetch(url, { signal: AbortSignal.timeout(5000) })).json(); if (ready(result)) return }
    catch {}
    await new Promise(resolve => setTimeout(resolve, 250))
  }
  throw Error(`Health timeout: ${url}`)
}
try {
  if (!existsSync(join(userRoot, 'runtime-ready.json'))) {
    const prepare = start('prepare', node, [join(resources, 'app/prepare-runtime.cjs'), installation])
    if (await ended(prepare) !== 0) throw Error('Runtime preparation failed')
  }
  const juliaPort = await port()
  let bffPort = await port()
  while (bffPort === juliaPort) bffPort = await port()
  const started = Date.now()
  const julia = start('julia', config.executable, [...config.args, join(config.backend, 'server.jl')], { PORT: String(juliaPort), PSFA_SKIP_STARTUP_WARMUP: '1' }, config.backend)
  const bff = start('bff', node, [join(resources, 'app/.output/server/index.mjs')], {
    PORT: String(bffPort), NITRO_PORT: String(bffPort), HOST: '127.0.0.1', NITRO_HOST: '127.0.0.1',
    JULIA_BACKEND_URL: `http://127.0.0.1:${juliaPort}`, NUXT_PUBLIC_JULIA_WS_BASE: `ws://127.0.0.1:${juliaPort}`
  }, join(resources, 'app'))
  await Promise.all([
    healthy(`http://127.0.0.1:${juliaPort}/health`, julia, info => info.status === 'ok' && info.solvers?.HiGHS),
    healthy(`http://127.0.0.1:${bffPort}/api/v1/health`, bff, info => info.data?.ready)
  ])
  const session = { origin: `http://127.0.0.1:${bffPort}`, juliaPort, bffPort,
    pid: process.pid, juliaPid: julia.pid, bffPid: bff.pid, startupSeconds: (Date.now() - started) / 1000, mode: 'headless-acceptance' }
  report.session = session
  writeFileSync(join(userRoot, 'session.json'), JSON.stringify(session, null, 2))
  console.log(`SERVICES_READY ${session.startupSeconds}s`)
  const verification = start('acceptance', node, [join(import.meta.dirname, 'verify-installed.mjs'), userRoot, installation])
  if (await ended(verification) !== 0) throw Error(`Acceptance failed: ${join(userRoot, 'acceptance-report.json')}`)
  const auditFile = join(userRoot, 'library-audit.json')
  const auditProgram = 'include(ARGS[1]); warmup_backend(; strict=true); using Libdl; write(ARGS[2], JSON3.write(Dict("depots" => DEPOT_PATH, "libraries" => Libdl.dllist())))'
  const audit = start('libraries', config.executable,
    [...config.args, '-e', auditProgram, join(config.backend, 'server.jl'), auditFile],
    { SYNERROLL_CAPACITY_WORKER: '1' }, config.backend)
  if (await ended(audit) !== 0) throw Error('Native library audit failed')
  const libraries = JSON.parse(readFileSync(auditFile, 'utf8'))
  const approvedRoots = [join(resources, 'runtime'), process.env.SystemRoot, join(userRoot, 'julia-depot')]
    .map(directory => resolve(directory).toLowerCase() + '\\')
  const externalLibraries = libraries.libraries.filter(file => !approvedRoots.some(root => resolve(file).toLowerCase().startsWith(root)))
  report.libraryAudit = { loadedLibraries: libraries.libraries.length, externalLibraries, depots: libraries.depots }
  if (externalLibraries.length) throw Error(`Unexpected native dependencies: ${externalLibraries.join(', ')}`)
  report.status = 'passed'
} catch (error) {
  report.status = 'failed'
  report.error = error.stack
  process.exitCode = 1
  console.error(error)
} finally {
  for (const child of children.reverse()) {
    if (child.exitCode === null && child.pid) {
      const killer = spawn(join(process.env.SystemRoot, 'System32/taskkill.exe'), ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' })
      await new Promise(resolve => { killer.once('exit', resolve); killer.once('error', resolve) })
      await ended(child)
    }
  }
  report.childrenExited = children.every(child => child.exitCode !== null)
  report.finishedAt = new Date().toISOString()
  writeFileSync(join(userRoot, 'service-verification.json'), JSON.stringify(report, null, 2))
}
