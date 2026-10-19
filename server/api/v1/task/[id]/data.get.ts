import { apiSuccess } from '#server/utils/response'
import {
  readTaskSeriesData,
  timeLabelToMinutes,
  taskTimeseriesDbPath,
} from '#server/utils/sqlite-reader'
import { existsSync } from 'node:fs'

/** BFF 直读 SQLite：getData 不打 Julia HTTP，避免排在 optimize! 后面 */
type DataPayload = {
  rows?: Record<string, unknown>[]
  probe?: Record<string, number | string | boolean>
  [k: string]: unknown
}
type CacheEntry = {
  at: number
  minMinutesUsed: number
  data: DataPayload
}

const dataCache = new Map<string, CacheEntry>()
const CACHE_TTL_MS = 250

function cacheKey(id: string, skipBoundary: boolean): string {
  return `${id}|${skipBoundary ? '1' : '0'}`
}

function parseMinMinutes(query: Record<string, unknown>): number {
  const raw = query.minMinutes ?? query.minTs
  if (typeof raw === 'number' && Number.isFinite(raw)) return raw
  if (typeof raw !== 'string' || !raw) return 0
  if (/^\d+$/.test(raw)) return Number(raw)
  return timeLabelToMinutes(raw) ?? 0
}

function filterRowsByMin(
  rows: Record<string, unknown>[] | undefined,
  minMinutes: number
): Record<string, unknown>[] {
  if (!rows?.length || minMinutes <= 0) return rows ?? []
  return rows.filter((row) => {
    const m = timeLabelToMinutes(String(row.ts ?? ''))
    return m === null || m >= minMinutes
  })
}

/**
 * 拉任务的时序数据（BFF 直读 timeseries.db）
 * Path: /api/v1/task/:id/data
 */
export default defineEventHandler(async (event) => {
  const id = getRouterParam(event, 'id')
  if (!id) {
    throw createError({ statusCode: 400, message: '缺少 task id' })
  }

  const query = getQuery(event)
  const minMinutes = parseMinMinutes(query)
  const skipBoundary = query.skipBoundary === '1' || query.skipBoundary === 'true'
  const key = cacheKey(id, skipBoundary)
  const now = performance.now()

  try {
    const dbPath = taskTimeseriesDbPath(id)
    if (!existsSync(dbPath)) {
      return apiSuccess({
        rows: [],
        probe: { total_ms: 0, row_count: 0, series_count: 0, from_bff_sqlite: true, missing_db: true },
      })
    }

    const hit = dataCache.get(key)
    if (hit && now - hit.at < CACHE_TTL_MS && minMinutes >= hit.minMinutesUsed) {
      const rows = filterRowsByMin(hit.data.rows, minMinutes)
      return apiSuccess({
        ...hit.data,
        rows,
        probe: {
          ...(hit.data.probe ?? {}),
          cache_hit: true,
          cache_age_ms: Math.round(now - hit.at),
          row_count: rows.length,
          from_bff_sqlite: true,
        },
      })
    }

    // 直读库（只读连接，可与 Julia 写并存）
    const result = readTaskSeriesData(id, { minMinutes, skipBoundary })
    if (!result) {
      return apiSuccess({
        rows: [],
        probe: { total_ms: 0, row_count: 0, from_bff_sqlite: true, missing_db: true },
      })
    }

    const data: DataPayload = {
      rows: result.rows,
      probe: {
        from_bff_sqlite: true,
        cache_hit: false,
        query_ms: Math.round(result.query_ms * 100) / 100,
        build_ms: Math.round(result.build_ms * 100) / 100,
        total_ms: Math.round((performance.now() - now) * 100) / 100,
        row_count: result.rows.length,
        series_count: result.series_count,
        raw_point_count: result.raw_point_count,
        max_device_ts: result.max_device_ts,
        max_device_min: result.max_device_min,
        min_minutes: minMinutes,
        skip_boundary: skipBoundary,
      },
    }
    dataCache.set(key, {
      at: performance.now(),
      minMinutesUsed: minMinutes,
      data,
    })
    return apiSuccess(data)
  }
  catch (error) {
    const message = error instanceof Error ? error.message : 'Unknown error'
    throw createError({
      statusCode: 500,
      message: `sqlite read error: ${message}`
    })
  }
})
