/**
 * BFF 直读 Julia 侧 SQLite（只读）。
 * 读路径不再打 Julia HTTP，避免排在 optimize! 后面。
 *
 * 依赖 Node 22+ 的 node:sqlite。
 */
import { DatabaseSync } from 'node:sqlite'
import { existsSync } from 'node:fs'
import { join } from 'node:path'

export interface TaskRow {
  id: string
  project_id: string
  canvas_id: string
  layer_id: string
  mode: string
  name: string | null
  status: string
  params_hash: string
  sim_start_time: string
  sim_end_time: string | null
  sim_start_date: string | null
  sim_end_date: string | null
  cur_time: string | null
  created_at: string
  updated_at: string
  started_at: string | null
  finished_at: string | null
  error_message: string | null
  extra_json: string | null
}

export interface DataRow {
  sourceId: string
  varName: string
  remark?: string
  layerId: string
  ts: string
  value: number
}

export interface GetDataResult {
  rows: DataRow[]
  series_count: number
  raw_point_count: number
  max_device_ts: string
  max_device_min: number
  query_ms: number
  build_ms: number
}

function backendDataDir(): string {
  // Nuxt 以项目根为 cwd；兼容打包后相对 backend/data
  const candidates = [
    process.env.SYNERROLL_DATA_DIR,
    join(process.cwd(), 'backend', 'data'),
    join(process.cwd(), '..', 'backend', 'data'),
  ].filter(Boolean) as string[]
  for (const dir of candidates) {
    if (existsSync(join(dir, 'tasks.db'))) return dir
  }
  return join(process.cwd(), 'backend', 'data')
}

export function tasksDbPath(): string {
  return join(backendDataDir(), 'tasks.db')
}

export function taskTimeseriesDbPath(taskId: string): string {
  return join(backendDataDir(), 'tasks', taskId, 'timeseries.db')
}

/** "H:MM" → 分钟数；非法返回 null */
export function timeLabelToMinutes(ts: string): number | null {
  const parts = String(ts).split(':')
  if (parts.length < 2) return null
  const h = Number(parts[0])
  const m = Number(parts[1])
  if (!Number.isFinite(h) || !Number.isFinite(m)) return null
  return h * 60 + m
}

function openReadonly(dbPath: string): DatabaseSync | null {
  if (!existsSync(dbPath)) return null
  try {
    const db = new DatabaseSync(dbPath, { readOnly: true })
    // 与 Julia 写端并存：只读也设 busy，避免 WAL 下偶发 database is locked
    try {
      db.exec('PRAGMA busy_timeout=10000')
      db.exec('PRAGMA query_only=ON')
    } catch {
      /* pragma optional */
    }
    return db
  } catch {
    return null
  }
}

export function readTaskState(taskId: string): TaskRow | null {
  const db = openReadonly(tasksDbPath())
  if (!db) return null
  try {
    const row = db.prepare('SELECT * FROM tasks WHERE id = ?').get(taskId) as TaskRow | undefined
    return row ?? null
  } finally {
    db.close()
  }
}

/**
 * 从任务 timeseries.db 读结果点。
 * minMinutes: 只返回 ts 分钟数 >= minMinutes
 * skipBoundary: 跳过 source_id 以 b_ 开头的边界序列
 */
export function readTaskSeriesData(
  taskId: string,
  opts: { minMinutes?: number; skipBoundary?: boolean } = {}
): GetDataResult | null {
  const dbPath = taskTimeseriesDbPath(taskId)
  const db = openReadonly(dbPath)
  if (!db) return null

  const minMinutes = opts.minMinutes ?? 0
  const skipBoundary = Boolean(opts.skipBoundary)
  const t0 = performance.now()

  try {
    // SQL 侧尽量过滤；ts 为 "H:MM"
    let sql = `
      SELECT m.source_id AS sourceId, m.var_name AS varName, m.remark AS remark,
             m.layer_id AS layerId, d.ts AS ts, d.value AS value
      FROM time_series_data d
      JOIN time_series_meta m ON d.series_id = m.id
      WHERE 1=1
    `
    const params: Array<number | string> = []
    if (skipBoundary) {
      sql += ` AND m.source_id NOT LIKE 'b_%'`
    }
    if (minMinutes > 0) {
      sql += ` AND (CAST(substr(d.ts, 1, instr(d.ts, ':') - 1) AS INTEGER) * 60
                    + CAST(substr(d.ts, instr(d.ts, ':') + 1) AS INTEGER)) >= ?`
      params.push(minMinutes)
    }

    const tQuery = performance.now()
    const raw = db.prepare(sql).all(...params) as Array<{
      sourceId: string
      varName: string
      remark: string | null
      layerId: string
      ts: string
      value: number
    }>
    const queryMs = performance.now() - tQuery

    const tBuild = performance.now()
    const rows: DataRow[] = []
    const seriesSet = new Set<string>()
    let maxDeviceMin = 0
    let maxDeviceTs = ''
    for (const r of raw) {
      rows.push({
        sourceId: String(r.sourceId),
        varName: String(r.varName),
        remark: r.remark == null ? undefined : String(r.remark),
        layerId: String(r.layerId),
        ts: String(r.ts),
        value: Number(r.value),
      })
      seriesSet.add(`${r.sourceId}|${r.varName}|${r.layerId}`)
      const m = timeLabelToMinutes(r.ts)
      if (m !== null && m > maxDeviceMin && !String(r.sourceId).startsWith('b_')) {
        maxDeviceMin = m
        maxDeviceTs = String(r.ts)
      }
    }
    const buildMs = performance.now() - tBuild

    return {
      rows,
      series_count: seriesSet.size,
      raw_point_count: rows.length,
      max_device_ts: maxDeviceTs,
      max_device_min: maxDeviceMin,
      query_ms: queryMs,
      build_ms: buildMs,
    }
  } finally {
    db.close()
  }
}
