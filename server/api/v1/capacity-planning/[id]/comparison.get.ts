import type { CapacityPlanningComparison } from '~~/types/capacity-planning'
import { JULIA } from '#server/utils/julia'
import { apiSuccess, rethrowAsApiError, throwBackendBizError } from '#server/utils/response'

export default defineEventHandler(async (event) => {
  const planningId = getRouterParam(event, 'id') ?? ''
  try {
    const response = await $fetch<{
      success: boolean
      data?: CapacityPlanningComparison
      message?: string
    }>(`${JULIA.capacityPlanning()}/${encodeURIComponent(planningId)}/comparison`)
    if (!response.success || !response.data) {
      throwBackendBizError(response.message, '方案比较不可用')
    }
    return apiSuccess(response.data!)
  }
  catch (error) {
    rethrowAsApiError(error, '查询方案比较失败')
  }
})
