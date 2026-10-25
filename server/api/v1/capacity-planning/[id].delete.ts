import { JULIA } from '#server/utils/julia'
import { apiSuccess, rethrowAsApiError, throwBackendBizError } from '#server/utils/response'

const JULIA_BACKEND_URL = JULIA.capacityPlanning()

/** 清理容量规划任务及其全部计算数据。 */
export default defineEventHandler(async (event) => {
  const id = getRouterParam(event, 'id')
  if (!id) {
    throw createError({ statusCode: 400, statusMessage: '缺少 planning id' })
  }

  try {
    const response = await $fetch<{
      success: boolean
      data?: { planningId: string }
      message?: string
    }>(`${JULIA_BACKEND_URL}/${encodeURIComponent(id)}`, { method: 'DELETE' })

    if (!response.success) {
      throwBackendBizError(response.message, '清理容量规划任务失败')
    }
    return apiSuccess(response.data ?? { planningId: id }, response.message)
  }
  catch (error) {
    rethrowAsApiError(error, '清理容量规划任务失败')
  }
})
