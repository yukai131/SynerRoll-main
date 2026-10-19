import { apiSuccess } from '#server/utils/response'
import { JULIA } from '#server/utils/julia'

const JULIA_BACKEND_URL_BASE = JULIA.task()

/** 拉取任务的逐时段灵活性结果和全时域汇总。 */
export default defineEventHandler(async (event) => {
  const id = getRouterParam(event, 'id')
  if (!id) {
    throw createError({ statusCode: 400, message: '缺少 task id' })
  }

  const query = getQuery(event)
  const url = new URL(`${JULIA_BACKEND_URL_BASE}/${id}/flexibility`)
  if (typeof query.layerId === 'string' && query.layerId) {
    url.searchParams.set('layerId', query.layerId)
  }
  if (typeof query.minTs === 'string' && query.minTs) {
    url.searchParams.set('minTs', query.minTs)
  }
  if (typeof query.minMinutes === 'string' && query.minMinutes) {
    url.searchParams.set('minMinutes', query.minMinutes)
  }

  try {
    const response = await $fetch<{
      success: boolean
      data?: Record<string, unknown>
      message?: string
    }>(url.toString(), { method: 'GET' })

    if (response.success) {
      return apiSuccess(response.data ?? {}, response.message)
    }
    throw createError({
      statusCode: 400,
      message: response.message || '拉灵活性结果失败'
    })
  }
  catch (error) {
    const message = error instanceof Error ? error.message : 'Unknown error'
    throw createError({
      statusCode: 500,
      message: `Julia backend error: ${message}`
    })
  }
})
