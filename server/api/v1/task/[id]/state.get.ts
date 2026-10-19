import { apiSuccess } from '#server/utils/response'
import { readTaskState } from '#server/utils/sqlite-reader'

/** getState BFF 直读 tasks.db，不打 Julia HTTP */
type StateCache = { at: number; data: Record<string, unknown> }
const stateCache = new Map<string, StateCache>()
const STATE_TTL_MS = 200

export default defineEventHandler(async (event) => {
  const id = getRouterParam(event, 'id')
  if (!id) {
    throw createError({ statusCode: 400, message: '缺少 task id' })
  }

  const now = performance.now()
  const hit = stateCache.get(id)
  if (hit && now - hit.at < STATE_TTL_MS) {
    return apiSuccess({
      ...hit.data,
      probe: { from_bff_sqlite: true, cache_hit: true, cache_age_ms: Math.round(now - hit.at) },
    })
  }

  try {
    const task = readTaskState(id)
    if (!task) {
      throw createError({ statusCode: 404, message: `任务不存在: ${id}` })
    }
    // 与原 Julia get_task 对齐的字段
    const payload = { ...task } as unknown as Record<string, unknown>
    stateCache.set(id, { at: performance.now(), data: payload })
    return apiSuccess({
      ...payload,
      probe: { from_bff_sqlite: true, cache_hit: false },
    })
  }
  catch (error) {
    if (hit) {
      return apiSuccess({
        ...hit.data,
        probe: { from_bff_sqlite: true, cache_hit: true, cache_stale: true },
      })
    }
    const message = error instanceof Error ? error.message : 'Unknown error'
    throw createError({
      statusCode: Number((error as { statusCode?: number }).statusCode) || 500,
      message,
    })
  }
})
