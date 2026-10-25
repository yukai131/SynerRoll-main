import type { ScenarioPreviewResult } from '~~/types/capacity-planning'
import { JULIA } from '#server/utils/julia'
import { apiSuccess } from '#server/utils/response'

export default defineEventHandler(async (event) => {
  const id = getRouterParam(event, 'id') ?? ''
  try {
    const response = await $fetch<{
      success: boolean
      data?: ScenarioPreviewResult
      message?: string
    }>(`${JULIA.capacityPlanning()}/${encodeURIComponent(id)}/scenarios`)
    if (!response.success || !response.data) {
      throw createError({
        statusCode: 404,
        statusMessage: response.message || '典型场景结果尚未生成'
      })
    }
    return apiSuccess(response.data)
  }
  catch (error) {
    if (error && typeof error === 'object' && 'statusCode' in error) throw error
    throw createError({
      statusCode: 502,
      statusMessage: `Julia 后端不可用: ${error instanceof Error ? error.message : String(error)}`
    })
  }
})
