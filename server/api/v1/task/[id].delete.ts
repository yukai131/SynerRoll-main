import { apiSuccess, rethrowAsApiError, throwBackendBizError } from '#server/utils/response'
import { JULIA } from '#server/utils/julia'

const JULIA_BACKEND_URL_BASE = JULIA.task()

/**
 * 清理任务（删除任务 DB + tasks.db 记录）
 * Path: /api/v1/task/:id
 */
export default defineEventHandler(async (event) => {
  const id = getRouterParam(event, 'id')
  if (!id) {
    throw createError({ statusCode: 400, message: '缺少 task id' })
  }

  try {
    const response = await $fetch<{
      success: boolean
      message?: string
    }>(`${JULIA_BACKEND_URL_BASE}/${id}`, { method: 'DELETE' })

    if (response.success) {
      return apiSuccess({}, response.message)
    }
    throwBackendBizError(response.message, '清理失败')
  }
  catch (error) {
    rethrowAsApiError(error, '清理失败')
  }
})
