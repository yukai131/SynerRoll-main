/**
 * BFF 直读 Julia 侧 SQLite（只读）。
 * 读路径不再打 Julia HTTP，避免排在 optimize! 后面。
 *
 * 依赖 Node 22+ 的 node:sqlite。
 */
import { DatabaseSync } from 'node:sqlite'
import { existsSync } from 'node:fs'
import { join } from 'node:path'
import { backendDataDir } from './backend-data.ts'

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
  cursor: number
  latest_cursor: number
  has_more: boolean
}

export interface SeriesReadOptions {
  minMinutes?: number
  maxMinutes?: number
  skipBoundary?: boolean
  boundaryOnly?: boolean
  afterId?: number
  limit?: number
  layerId?: string
  sourceId?: string
  varName?: string
  remark?: string
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
  opts: SeriesReadOptions = {}
): GetDataResult | null {
  const dbPath = taskTimeseriesDbPath(taskId)
  const db = openReadonly(dbPath)
  if (!db) return null

  const minMinutes = opts.minMinutes ?? 0
  const skipBoundary = Boolean(opts.skipBoundary)
  const t0 = performance.now()

  try {
    // 水位与数据在同一个只读快照中读取，避免并发提交被游标跳过。
    db.exec('BEGIN')
    const latest = Number((db.prepare('SELECT COALESCE(MAX(id), 0) AS id FROM time_series_data').get() as { id: number }).id)
    const incremental = opts.afterId !== undefined
    // 老任务可能尚未被 Julia 迁移；只读路径不改库，必要时兼容旧时间列。
    const needsTimeFilter = minMinutes > 0 || opts.maxMinutes !== undefined
    const hasMinuteColumn = !needsTimeFilter || (db.prepare('PRAGMA table_info(time_series_data)').all() as { name: string }[])
      .some(column => column.name === 'ts_min')
    const minuteExpr = hasMinuteColumn ? 'd.ts_min'
      : "(CAST(substr(d.ts, 1, instr(d.ts, ':') - 1) AS INTEGER) * 60 + CAST(substr(d.ts, instr(d.ts, ':') + 1) AS INTEGER))"
    let sql = `
      SELECT m.source_id AS sourceId, m.var_name AS varName, m.remark AS remark,
             m.layer_id AS layerId, d.ts AS ts, d.value AS value, d.id AS rowId
      FROM ${incremental
        ? 'time_series_data d JOIN time_series_meta m ON d.series_id = m.id'
        : 'time_series_meta m CROSS JOIN time_series_data d ON d.series_id = m.id'}
      WHERE 1=1
    `
    const params: Array<number | string> = []
    if (skipBoundary) {
      sql += ` AND substr(m.source_id, 1, 2) != 'b_'`
    }
    if (opts.boundaryOnly) sql += ` AND substr(m.source_id, 1, 2) = 'b_'`
    for (const [column, value] of [
      ['m.layer_id', opts.layerId], ['m.source_id', opts.sourceId],
      ['m.var_name', opts.varName], ['m.remark', opts.remark],
    ] as const) {
      if (value !== undefined) { sql += ` AND ${column}=?`; params.push(value) }
    }
    if (minMinutes > 0) {
      sql += ` AND ${minuteExpr} >= ?`
      params.push(minMinutes)
    }
    if (opts.maxMinutes !== undefined) { sql += ` AND ${minuteExpr} < ?`; params.push(opts.maxMinutes) }
    if (incremental) {
      sql += ' AND d.id > ? AND d.id <= ? ORDER BY d.id'
      params.push(opts.afterId!, latest)
    }
    const limit = opts.limit === undefined ? undefined : Math.max(1, Math.min(20000, Math.trunc(opts.limit)))
    if (limit !== undefined) { sql += ' LIMIT ?'; params.push(limit + 1) }

    const tQuery = performance.now()
    const raw = db.prepare(sql).all(...params) as Array<{
      sourceId: string
      varName: string
      remark: string | null
      layerId: string
      ts: string
      value: number
      rowId: number
    }>
    const hasMore = limit !== undefined && raw.length > limit
    if (hasMore) raw.pop()
    const queryMs = performance.now() - tQuery
    db.exec('COMMIT')

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
      cursor: hasMore ? Number(raw.at(-1)?.rowId ?? opts.afterId ?? 0) : latest,
      latest_cursor: latest,
      has_more: hasMore,
    }
  } finally {
    db.close()
  }
}

/** 独立只读连接：JSON 解析不再占用 Julia 的写锁。 */
export function readTaskFlexibility(taskId: string, opts: {
  layerId?: string; minMinutes?: number; afterRevision?: number
} = {}): Record<string, unknown> | null {
  const task = readTaskState(taskId)
  if (!task) return null
  const config = task.extra_json ? JSON.parse(task.extra_json).flexibility ?? { enabled: false } : { enabled: false }
  const layerId = opts.layerId ?? config.layerId ?? task.layer_id
  const db = openReadonly(taskTimeseriesDbPath(taskId))
  if (!db) return { config, periods: [], summaries: [], revision: 0 }
  const started = performance.now()
  try {
    db.exec('BEGIN')
    const tables = new Set((db.prepare("SELECT name FROM sqlite_master WHERE type='table'").all() as { name: string }[]).map(row => row.name))
    if (!tables.has('flexibility_period_results')) return { config, periods: [], summaries: [], revision: 0 }
    const versioned = tables.has('task_result_versions')
      && (db.prepare('PRAGMA table_info(flexibility_period_results)').all() as { name: string }[]).some(row => row.name === 'revision')
    const revision = versioned
      ? Number((db.prepare("SELECT version FROM task_result_versions WHERE kind='flexibility'").get() as { version: number } | undefined)?.version ?? 0)
      : 0
    const useDelta = versioned && opts.afterRevision !== undefined && opts.afterRevision <= revision
    let sql = 'SELECT result_json FROM flexibility_period_results WHERE layer_id=?'
    const params: Array<string | number> = [layerId]
    if (useDelta) { sql += ' AND revision>?'; params.push(opts.afterRevision!) }
    else if (opts.minMinutes !== undefined && opts.minMinutes > 0) { sql += ' AND timestamp_minutes>=?'; params.push(opts.minMinutes) }
    sql += ' ORDER BY timestamp_minutes, direction DESC'
    const queried = performance.now()
    const raw = db.prepare(sql).all(...params) as { result_json: string }[]
    const summaryRows = tables.has('flexibility_summary_results')
      ? db.prepare('SELECT result_json FROM flexibility_summary_results WHERE layer_id=? ORDER BY start_minutes').all(layerId) as { result_json: string }[]
      : []
    db.exec('COMMIT')
    const parseAt = performance.now()
    const periods = raw.map(row => JSON.parse(row.result_json))
    const summaries = summaryRows.map(row => JSON.parse(row.result_json))
    return {
      config, periods, summaries, revision, versioned, reset: !useDelta,
      probe: { from_bff_sqlite: true, period_count: raw.length,
        period_query_ms: parseAt - queried, period_parse_ms: performance.now() - parseAt,
        total_ms: performance.now() - started, revision },
    }
  } finally { db.close() }
}
