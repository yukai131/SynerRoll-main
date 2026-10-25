import assert from 'node:assert/strict'
import { readFileSync, writeFileSync, existsSync, readdirSync } from 'node:fs'
import { resolve, join } from 'node:path'
import { DatabaseSync } from 'node:sqlite'
import { createHash } from 'node:crypto'

const [userDirectory, installDirectory] = process.argv.slice(2).map(value => resolve(value))
assert(userDirectory && installDirectory, 'Usage: node verify-installed.mjs <isolated-user-data> <installation-directory>')
const session = JSON.parse(readFileSync(join(userDirectory, 'session.json'), 'utf8'))
const library = JSON.parse(readFileSync(join(installDirectory, 'resources/app/config/component-library.json'), 'utf8')).components
const report = { startedAt: new Date().toISOString(), installation: installDirectory, userDirectory, session, checks: [] }
async function api(endpoint, body, method = body === undefined ? 'GET' : 'POST') {
  const response = await fetch(`${session.origin}/api/v1${endpoint}`, {
    method, headers: { 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(180_000)
  })
  const json = await response.json()
  assert(response.ok && json.success, `${method} ${endpoint}: ${JSON.stringify(json)}`)
  return json.data
}
function check(label) { report.checks.push(label); console.log(`PASS ${label}`) }
async function waitFor(endpoint, timeoutSeconds = 360) {
  const deadline = Date.now() + timeoutSeconds * 1000
  let state
  while (Date.now() < deadline) {
    state = await api(endpoint)
    if (state.status === 'completed') return state
    assert(!['failed', 'cancelled'].includes(state.status), JSON.stringify(state))
    await new Promise(resolve => setTimeout(resolve, 1000))
  }
  throw Error(`Timeout ${endpoint}: ${JSON.stringify(state)}`)
}
function node(id, key, x, y, boundaryIds = []) {
  const schema = library[key]
  const defaults = section => Object.fromEntries((schema[section] || []).map(field => [field.key, field.defaultValue ?? null]))
  const commonTechParams = defaults('commonTechFields')
  if ('capacity' in commonTechParams) commonTechParams.capacity = key === 'WT' ? 100 : 1000
  return { id, type: 'syner-node', position: { x, y }, data: {
    label: schema.label, componentKey: key, categoryKey: schema.category,
    style: { width: key === 'ELEC_BUS' ? 24 : 100, height: key === 'ELEC_BUS' ? 240 : 100, rotation: 0, fillColor: '#ffffff', strokeColor: '#334155', strokeWidth: 1, fontSize: 14, textColor: '#0f172a', borderRadius: 6, opacity: 1 },
    portConfig: Object.fromEntries(schema.ports.map(port => [port.id, port])),
    business: { componentKey: key, commonTechParams, commonEconomicParams: defaults('commonEconomicFields'), boundaryIds,
      layerConfigs: { '1': { status: 'stand_alone', techParams: defaults('layerTechFields'), economicParams: defaults('layerEconomicFields'), constraints: defaults('constraintFields'), objectives: defaults('objectiveFields') } } }
  } }
}
function edge(id, source, sourceHandle, target, targetHandle) {
  return { id, source, sourceHandle, target, targetHandle, data: { label: '', medium: 'electric', style: { strokeColor: '#eab308', strokeWidth: 2, strokeDasharray: '', labelColor: '#334155', arrowType: 'end' } } }
}
try {
  const health = await api('/health')
  assert(health.ready && health.solvers.HiGHS)
  check('Bundled Julia and HiGHS are ready')
  const brand = JSON.parse(readFileSync(join(installDirectory, 'resources/config/brand.json'), 'utf8'))
  const settingsPage = await fetch(`${session.origin}/settings`, { signal: AbortSignal.timeout(60_000) })
  const settingsHtml = await settingsPage.text()
  assert(settingsPage.ok && settingsHtml.includes(brand.displayName) && settingsHtml.includes(brand.publisher))
  const logo = await fetch(`${session.origin}/logo.png`, { signal: AbortSignal.timeout(30_000) })
  assert(logo.ok)
  const digest = value => createHash('sha256').update(value).digest('hex')
  assert.equal(digest(Buffer.from(await logo.arrayBuffer())), digest(readFileSync(join(installDirectory, 'resources/app/.output/public/logo.png'))))
  report.brand = { displayName: brand.displayName, publisher: brand.publisher, version: brand.version }
  check('Installed settings page renders official branding and serves the bundled logo')
  let { project } = await api('/project', { name: '安装验收：风电与电网供电', description: '自动验收专用项目，独立测试目录' })
  const id = project.id
  const invalidWorkspace = structuredClone(project.workspace)
  invalidWorkspace.canvases[0].nodes = [{ id: 'invalid-node', data: { componentKey: 'WT' } }]
  await assert.rejects(api(`/project/${id}/canvas`, { workspace: invalidWorkspace }, 'PUT'))
  assert.equal((await api(`/project/${id}`)).project.workspace.canvases[0].nodes.length, 0)
  check('Rejected malformed canvas leaves the persisted project store readable')
  const layerConfig = { layers: [
    { id: '1', name: '日层', length: '24h', step: '1h', forward: '24h' },
    { id: '2', name: '滚动层', length: '4h', step: '1h', forward: '4h' }
  ] }
  const canvasId = project.workspace.activeCanvasId
  const wind = node('node-wind', 'WT', 80, 80, ['qa-wind'])
  const grid = node('node-grid', 'GRID', 80, 300)
  const load = node('node-load', 'ELOAD', 720, 200, ['qa-load'])
  const bus = node('node-bus1', 'ELEC_BUS', 400, 200)
  bus.data.portConfig = { 'bus-left-1': { medium: 'electric', side: 'left', offset: 50 }, 'bus-right-1': { medium: 'electric', side: 'right', offset: 50 } }
  const edges = [edge('wind-bus', wind.id, 'power-out', bus.id, 'bus-left-1'), edge('grid-bus', grid.id, 'power-out', bus.id, 'bus-left-1'), edge('bus-grid', bus.id, 'bus-right-1', grid.id, 'power-in'), edge('bus-load', bus.id, 'bus-right-1', load.id, 'power-in')]
  project.workspace.canvases[0].nodes = [wind, grid, bus, load]
  for (const item of [wind, grid, load]) item.data.business.layerConfigs['2'] = structuredClone(item.data.business.layerConfigs['1'])
  project.workspace.canvases[0].edges = edges
  await api(`/project/${id}/canvas`, { workspace: project.workspace }, 'PUT')
  await api(`/project/${id}/layer-config`, { layerConfig }, 'PUT')
  await api(`/project/${id}/algorithm-config`, { algorithm: { ...project.algorithm, solver: 'HiGHS', slackEnabled: false }, solverConfig: project.solverConfig }, 'PUT')
  check('Project, canvas, topology, layers and solver saved through BFF')
  const csv = join(userDirectory, '验收边界.csv')
  const samples = Array.from({ length: 192 }, (_, i) => `${7 + Math.floor(i / 24) % 3},${40 + i % 24}`)
  writeFileSync(csv, `wind,load\n${samples.join('\n')}\n`)
  const metadata = []
  for (const [boundaryId, columnName, meaning, relatedComponent] of [['qa-wind', 'wind', 'wind_speed', 'WT'], ['qa-load', 'load', 'load', 'ELOAD']]) {
    const request = { projectId: id, filePath: csv, columnName, timeStep: '1h', calendarStartDate: '2026-01-01', meaning }
    const imported = await api('/boundary/import', request)
    assert.equal(imported.pointCount, 192)
    const transformed = await api('/boundary/transform', { ...request, layerConfig, interpolateType: 'copy', noiseLevel: 0 })
    assert.equal(transformed.layers.length, 2)
    await api('/boundary/submit', { projectId: id, boundaries: transformed.layers.map(layer => ({ ...layer, boundaryId, meaning, boundaryLength: '192h', boundaryStep: '1h', dayCount: 8, pointCount: 192, calendarStartDate: '2026-01-01', calendarEndDate: '2026-01-08' })) })
    metadata.push({ id: boundaryId, name: columnName, filePath: csv, columnName, meaning, relatedComponents: [relatedComponent], timeStep: '1h', timeMode: 'calendar', category: meaning === 'load' ? 'load' : 'weather', noiseLevel: 0, interpolateType: 'copy', randomDistribution: 'normal', boundaryMeta: { calendarStartDate: '2026-01-01', calendarEndDate: '2026-01-08', dayCount: 8, pointCount: 192, totalHours: 192, timeStep: '1h', timeMode: 'calendar' } })
  }
  await api(`/project/${id}/boundary`, { boundaries: metadata }, 'PUT')
  check('CSV import, resampling and project boundary SQLite persistence')
  const taskRequest = { projectId: id, canvasId, layerId: '1', mode: 'offline', simMode: 'single_layer', targetLayerId: '1', simStartTime: '0:00', simEndTime: '24:00', simStartDate: '2026-01-01', simEndDate: '2026-01-01', name: '安装验收 HiGHS', flexibility: { enabled: true, layerId: '1', operationMode: 'economic_operation', networkMode: 'grid_connected', requirementSource: 'user_defined', upwardRequirementKw: 5, downwardRequirementKw: 5 } }
  const created = await api('/task/create', taskRequest)
  report.projectId = id
  report.taskId = created.id
  const liveEvents = []
  const liveSocket = new WebSocket(`ws://127.0.0.1:${session.juliaPort}/ws/task/${created.id}`)
  liveSocket.onmessage = event => liveEvents.push(JSON.parse(event.data))
  await waitFor(`/task/${created.id}/state`)
  await new Promise(resolve => setTimeout(resolve, 1000))
  liveSocket.close()
  assert(liveEvents.some(event => event.type === 'flexibility'))
  assert(liveEvents.some(event => event.type === 'completed'))
  report.liveEventTypes = [...new Set(liveEvents.map(event => event.type))]
  check('Independent simulation worker forwards live flexibility and completion events')
  const data = await api(`/task/${created.id}/data?maxMinutes=1440&skipBoundary=true`)
  assert(data.rows.length > 0 && data.rows.some(row => row.value > 0))
  assert(data.probe.from_bff_sqlite)
  const economy = await api(`/task/${created.id}/economy`)
  assert(economy && Object.keys(economy).length)
  report.resultRows = data.rows.length
  check('Real HiGHS simulation, direct SQLite results and economic evaluation')
  await new Promise((resolve, reject) => {
    const socket = new WebSocket(`ws://127.0.0.1:${session.juliaPort}/ws/task/${created.id}`)
    const timer = setTimeout(() => { socket.close(); reject(Error('Task WebSocket timeout')) }, 20000)
    socket.onmessage = event => {
      try {
        const message = JSON.parse(event.data)
        assert.equal(message.type, 'status')
        assert.equal(message.status, 'completed')
        clearTimeout(timer); socket.close(); resolve()
      } catch (error) { clearTimeout(timer); socket.close(); reject(error) }
    }
    socket.onerror = () => { clearTimeout(timer); socket.close(); reject(Error('Task WebSocket connection failed')) }
  })
  check('Task WebSocket connects to the dynamically selected bundled Julia port')
  const flexibility = await api(`/task/${created.id}/flexibility?layerId=1`)
  assert(flexibility.config.enabled && flexibility.periods.length > 0 && flexibility.summaries.length > 0)
  report.flexibilityPeriods = flexibility.periods.length
  check('Device and system flexibility evaluation, margin summaries and SQLite reads')
  const multi = await api('/task/create', { ...taskRequest, simMode: 'multi_layer', flexibility: { ...taskRequest.flexibility, layerId: '2' } })
  report.multiTaskId = multi.id
  await waitFor(`/task/${multi.id}/state`, 600)
  const multiFlexibility = await api(`/task/${multi.id}/flexibility?layerId=2`)
  assert.equal(multiFlexibility.periods.length, 48)
  assert(multiFlexibility.summaries.length > 0)
  report.multiFlexibilityPeriods = multiFlexibility.periods.length
  check('Two-layer rolling simulation produces flexibility periods and summaries on the second layer')
  const schema = await api('/capacity-planning/form-schema', { projectId: id, canvasId })
  const variables = schema.variables.map(variable => ({ ...variable, lowerBound: 50, upperBound: 150, step: 10 }))
  assert(variables.length > 0)
  const clustering = { projectId: id, canvasId, featureIds: ['qa-wind', 'qa-load'], clusterCount: 2, preserveExtremes: true }
  const preview = await api('/capacity-planning/scenarios/preview', clustering)
  assert(preview.scenarios.length > 0)
  const planning = await api('/capacity-planning', { projectId: id, canvasId, planningLayerId: '1', variables, clustering, optimizer: { maxFuncEvals: 2, populationSize: 4, maxTimeSeconds: 900 } })
  report.planningId = planning.id
  await api(`/capacity-planning/${planning.id}/start`, {})
  await waitFor(`/capacity-planning/${planning.id}`, 960)
  const result = await api(`/capacity-planning/${planning.id}/result`)
  assert(Number.isFinite(result.fitness) && result.evaluationCount > 0)
  report.planningEvaluations = result.evaluationCount
  const comparison = await api(`/capacity-planning/${planning.id}/comparison`)
  assert(comparison.candidates.length > 0)
  check('Packaged independent capacity worker, optimization, persistence and comparison')
  const stored = await api(`/project/${id}`)
  assert.equal(stored.project.workspace.canvases[0].nodes.length, 4)
  assert(existsSync(join(userDirectory, 'data/projects.json')))
  assert(existsSync(join(userDirectory, `data/projects/${id}/boundary.db`)))
  check('All user data resides in isolated writable user directory')
  report.tasks = await Promise.all([created.id, multi.id].map(async taskId => {
    const task = await api(`/task/${taskId}/state`)
    return { id: task.id, status: task.status, createdAt: task.createdAt ?? task.created_at,
      finishedAt: task.finishedAt ?? task.finished_at }
  }))
  const databases = []
  function inspectDatabases(directory) {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const file = join(directory, entry.name)
      if (entry.isDirectory()) inspectDatabases(file)
      else if (entry.name.endsWith('.db')) {
        const db = new DatabaseSync(file, { readOnly: true })
        try {
          const rows = db.prepare('PRAGMA quick_check').all()
          const ok = rows.length === 1 && Object.values(rows[0])[0] === 'ok'
          databases.push({ path: file, ok })
          assert(ok, `SQLite integrity: ${file}`)
        } finally { db.close() }
      }
    }
  }
  inspectDatabases(join(userDirectory, 'data'))
  report.databaseIntegrity = { checked: databases.length, allOk: databases.every(db => db.ok), databases }
  check('Persisted SQLite databases pass quick_check before task cleanup')
  await api(`/task/${created.id}`, undefined, 'DELETE')
  assert(!existsSync(join(userDirectory, 'data/tasks', created.id)))
  const remainingTasks = await api(`/task/list?projectId=${id}`)
  assert(!remainingTasks.tasks.some(task => task.id === created.id))
  assert(remainingTasks.tasks.some(task => task.id === multi.id))
  check('Completed simulation cleanup removes its files and record while retaining the other task')
  await api(`/capacity-planning/${planning.id}`, undefined, 'DELETE')
  assert(!existsSync(join(userDirectory, 'data/capacity-planning', planning.id)))
  const remainingPlans = await api(`/capacity-planning?projectId=${id}`)
  assert(!remainingPlans.tasks.some(task => task.id === planning.id))
  assert(existsSync(join(userDirectory, `data/projects/${id}/boundary.db`)))
  check('Capacity cleanup removes calculation files and record while retaining project boundaries')
  report.finishedAt = new Date().toISOString()
  report.status = 'passed'
} catch (error) {
  report.status = 'failed'
  report.error = error.stack
  process.exitCode = 1
  console.error(error)
} finally {
  const file = join(userDirectory, 'acceptance-report.json')
  writeFileSync(file, JSON.stringify(report, null, 2))
  console.log(file)
}
