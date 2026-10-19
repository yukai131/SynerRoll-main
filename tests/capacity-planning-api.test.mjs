import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { tmpdir } from 'node:os'
import { createRequire } from 'node:module'
import vm from 'node:vm'
import ts from 'typescript'

const root = resolve(import.meta.dirname, '..')
const nativeRequire = createRequire(import.meta.url)

function fixture() {
  const directory = mkdtempSync(join(tmpdir(), 'synerroll-capacity-api-'))
  let project = {
    id: 'project-test', updateTime: 'v1',
    workspace: { activeCanvasId: 'A', canvases: ['A', 'B'].map(id => ({
      id, name: id, updatedAt: 'v1', nodes: [{ id: 'device', data: {
        business: { componentKey: 'WT', commonTechParams: { capacity: id === 'A' ? 100 : 999 }, fittingModelId: 'fit-1', boundaryIds: id === 'A' ? ['wind', 'load'] : ['other'] }
      } }], edges: []
    })) }, fittingModels: [{ id: 'fit-1', params: { a: 2 } }],
    boundaries: [
      { id: 'wind', boundaryMeta: { calendarStartDate: '2026-01-01', calendarEndDate: '2026-12-31', dayCount: 365 } },
      { id: 'load', boundaryMeta: { calendarStartDate: '2026-02-01', calendarEndDate: '2026-11-30', dayCount: 303 } },
      { id: 'other', boundaryMeta: { calendarStartDate: '2027-01-01', calendarEndDate: '2027-01-31', dayCount: 31 } }
    ]
  }
  const original = structuredClone(project)
  let version = 1
  const calls = []
  let computeFails = false
  const task = { id: 'cp-fixture', status: 'completed', projectId: project.id, canvasId: 'A',
    bestEvaluationId: 7, config: { planningLayerId: '1', clustering: { datasetId: 'dataset-1' } } }
  const result = { projectUpdatedAt: 'v1', variables: [{ componentId: 'device', componentKey: 'WT',
    componentName: '风机', unit: 'kW', optimalValue: 200 }] }
  const createError = options => Object.assign(new Error(options.message ?? options.statusMessage), options)
  const cache = new Map()
  function load(relative) {
    const filename = resolve(root, relative)
    if (cache.has(filename)) return cache.get(filename)
    const source = ts.transpileModule(readFileSync(filename, 'utf8'), {
      compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS }
    }).outputText
    const module = { exports: {} }
    const mockedRequire = id => {
      if (id === '#server/utils/project-store') return {
        readProjectById: async () => structuredClone(project),
        updateProject: async (_id, updater) => {
          const updated = updater(structuredClone(project))
          project = { ...updated, updateTime: `v${++version}` }
          return structuredClone(project)
        }
      }
      if (id.startsWith('#server/')) return load(`server/${id.slice(8)}.ts`)
      if (id.startsWith('~~/')) return load(`${id.slice(3)}.ts`)
      return nativeRequire(id)
    }
    const context = vm.createContext({ module, exports: module.exports, require: mockedRequire,
      process: { cwd: () => directory, env: { JULIA_BACKEND_URL: 'http://127.0.0.1:18991' } },
      structuredClone, crypto: globalThis.crypto, console, createError,
      defineEventHandler: handler => handler, getRouterParam: (event, key) => event.params[key],
      readBody: async event => event.body,
      $fetch: async (url, options) => {
        calls.push({ url, options })
        if (url.endsWith('/api/task/create')) {
          if (computeFails) throw new Error('solver unavailable')
          return { success: true, data: { id: 'verification-task' } }
        }
        if (url.includes('/datasets/')) return { success: true, data: { pointCount: 8760, resolutionMinutes: 60 } }
        if (url.endsWith('/result')) return { success: true, data: structuredClone(result) }
        if (url.endsWith('/comparison')) return { success: true, data: { candidates: [{ evaluationId: 7 }] } }
        return { success: true, data: structuredClone(task) }
      }
    })
    new vm.Script(source, { filename }).runInContext(context)
    cache.set(filename, module.exports)
    return module.exports
  }
  return { directory, load, original, calls, task, result, get project() { return project },
    set computeFails(value) { computeFails = value },
    close() { rmSync(directory, { recursive: true, force: true }) } }
}
const route = (f, path) => f.load(`server/api/v1/capacity-planning/${path}`).default
const apply = (f, target = 'current-canvas') => route(f, '[id]/apply-and-simulate.post.ts')({
  params: { id: f.task.id }, body: { expectedProjectUpdatedAt: f.project.updateTime,
    mode: 'offline', name: 'verification', target, newCanvasName: '方案画布' }
})
const undo = (f, applyId) => route(f, 'applies/[applyId]/undo.post.ts')({ params: { applyId } })
const redo = (f, applyId) => route(f, 'applies/[applyId]/redo.post.ts')({ params: { applyId } })

test('apply current canvas, persist provenance, undo and redo without altering another canvas or fitting', async () => {
  const f = fixture()
  try {
    const response = await apply(f)
    assert.equal(response.data.taskCreated, true)
    assert.equal(f.project.workspace.canvases[0].nodes[0].data.business.commonTechParams.capacity, 200)
    assert.deepEqual(f.project.workspace.canvases[1], f.original.workspace.canvases[1])
    assert.deepEqual(f.project.fittingModels, f.original.fittingModels)
    assert.ok(f.calls.every(call => call.url.startsWith('http://127.0.0.1:18991/')))
    const records = await f.load('server/utils/apply-store.ts').listApplies(f.task.id)
    assert.equal(records.length, 1)
    assert.equal(records[0].candidateId, 7)
    assert.equal(records[0].targetCanvasId, 'A')
    assert.equal(f.calls.find(call => call.url.endsWith('/api/task/create')).options.body.canvasId, 'A')
    const computation = f.calls.find(call => call.url.endsWith('/api/task/create')).options.body
    assert.equal(computation.simStartDate, '2026-02-01')
    assert.equal(computation.simEndDate, '2026-11-30')
    assert.equal(computation.simEndTime, '7272:00')
    assert.equal(f.calls.some(call => call.url.includes('/datasets/')), false)
    await undo(f, response.data.applyId)
    assert.equal(f.project.workspace.canvases[0].nodes[0].data.business.commonTechParams.capacity, 100)
    await redo(f, response.data.applyId)
    assert.equal(f.project.workspace.canvases[0].nodes[0].data.business.commonTechParams.capacity, 200)
    assert.deepEqual(f.project.workspace.canvases[1], f.original.workspace.canvases[1])
  } finally { f.close() }
})

test('apply to new canvas, verify target, remove and restore it', async () => {
  const f = fixture()
  try {
    const response = await apply(f, 'new-canvas')
    const targetId = response.data.targetCanvasId
    assert.equal(f.project.workspace.canvases.length, 3)
    assert.deepEqual(f.project.workspace.canvases.slice(0, 2), f.original.workspace.canvases)
    assert.equal(f.calls.find(call => call.url.endsWith('/api/task/create')).options.body.canvasId, targetId)
    assert.equal(f.calls.find(call => call.url.endsWith('/api/task/create')).options.body.projectJson.workspace.activeCanvasId, targetId)
    assert.equal(f.project.workspace.activeCanvasId, 'A')
    await undo(f, response.data.applyId)
    assert.equal(f.project.workspace.canvases.length, 2)
    await redo(f, response.data.applyId)
    assert.equal(f.project.workspace.canvases.find(canvas => canvas.id === targetId).nodes[0].data.business.commonTechParams.capacity, 200)
  } finally { f.close() }
})

test('stale projects and missing later devices roll back the entire capacity application', async () => {
  const f = fixture()
  try {
    await assert.rejects(() => route(f, '[id]/apply-and-simulate.post.ts')({ params: { id: f.task.id },
      body: { expectedProjectUpdatedAt: 'old-version' } }), error => error.statusCode === 409)
    f.result.variables.push({ componentId: 'deleted', componentKey: 'PV', optimalValue: 300 })
    await assert.rejects(() => apply(f), error => error.statusCode === 409)
    assert.deepEqual(f.project, f.original)
  } finally { f.close() }
})

test('undo and redo reject content edits even when the canvas timestamp was preserved', async () => {
  const f = fixture()
  try {
    const response = await apply(f)
    f.project.workspace.canvases[0].nodes[0].data.business.commonTechParams.capacity = 250
    await assert.rejects(() => undo(f, response.data.applyId), error => error.statusCode === 409)
    f.project.workspace.canvases[0].nodes[0].data.business.commonTechParams.capacity = 200
    await undo(f, response.data.applyId)
    f.project.workspace.canvases[0].name = '用户改名'
    await assert.rejects(() => redo(f, response.data.applyId), error => error.statusCode === 409)
  } finally { f.close() }
})

test('verification creation failures leave an undoable application and report the partial result', async () => {
  const f = fixture()
  try {
    f.computeFails = true
    const response = await apply(f)
    assert.equal(response.data.projectApplied, true)
    assert.equal(response.data.taskCreated, false)
    assert.match(response.data.message, /solver unavailable/)
    await undo(f, response.data.applyId)
    assert.equal(f.project.workspace.canvases[0].nodes[0].data.business.commonTechParams.capacity, 100)
  } finally { f.close() }
})

test('comparison proxy uses the configured Julia address', async () => {
  const f = fixture()
  try {
    const response = await route(f, '[id]/comparison.get.ts')({ params: { id: f.task.id } })
    assert.equal(response.data.candidates[0].evaluationId, 7)
    assert.equal(f.calls[0].url, 'http://127.0.0.1:18991/api/capacity-planning/cp-fixture/comparison')
  } finally { f.close() }
})

test('calendar boundary applications require no datasetId and reject disjoint coverage before mutation', async () => {
  const f = fixture()
  try {
    delete f.task.config.clustering.datasetId
    const response = await apply(f)
    assert.equal(response.data.datasetId, null)
    await undo(f, response.data.applyId)
    f.project.boundaries[1].boundaryMeta.calendarStartDate = '2027-01-01'
    f.project.boundaries[1].boundaryMeta.calendarEndDate = '2027-01-31'
    const before = structuredClone(f.project)
    await assert.rejects(() => apply(f), error => error.statusCode === 400)
    assert.deepEqual(f.project, before)
  } finally { f.close() }
})
